#!/usr/bin/env python

import os, re, sys


class TestFactory:
    def __init__(self, testFactory):
        self.testFactory = testFactory
        self.create = None
        self.tests = []

    def append(self, line):
        if not self.create:
            self.create = self.testFactory.start()
        self.create.append(line)
        if self.create.finished:
            self.tests.append(self.create)
            self.create = None


class SpewLineFactory:
    """
    Build class corresponding to events based on a sequence of log lines.
    Multiple events can be build simultaneously.
    """

    def __init__(self, eventFactories):
        self.eventFactory = eventFactories
        self.create = []
        self.events = []

    def append(self, spew, line):
        """
        Receive every spew lines and build the corresponding objects which are
        extracting information from the log.
        """
        nextRound = []
        for builder in self.eventFactories:
            event = builder.start(spew, line)
            if event:
                nextRound.append(event)
        for event in self.create:
            event.append(spew, line)
            if event.finished:
                self.events.append(event)
            else:
                nextRound.append(event)
        self.create = nextRound


class IonScript:
    re_spew = re.compile(r"Codegen|Safepoints|RegAlloc|Snapshots|LICM|GVN|Alias|MIR|Abort")

    # Analyzing script foo.js:1 (0x7ff7a2d07700)
    re_start = re.compile(r"Analyzing script (?P<script>\S+):(?P<line>\d+) \(.*\)")
    # Created IonScript 0x24fccc0 (raw 0x7ff7a43ff840)
    re_stopGood = re.compile(r"Created IonScript (?P<IonScript>0x[0-9a-fA-F]+) \(raw .*\)")
    re_stopAbort = re.compile(r"Abort")

    def __init__(self, startMatch):
        self.finished = False
        self.script = startMatch.group("script")
        self.line = int(startMatch.group("line"))
        self.abortMessage = ""
        self.aborted = False
        self.ionScript = None
        return

    @staticmethod
    def start(spew, line):
        if not re_spew.match(spew):
            return None
        match = re_start.match(line)
        if not match:
            return None
        return IonScript(match)

    def append(self, spew, line):
        if not re_spew.match(spew):
            return
        if re_stopAbort.match(spew):
            self.aborted = True
            self.abortMessage = self.abortMessage + line
            return
        elif self.aborted:
            self.finished = True
            return
        match = re_stopGood.match(line)
        if match:
            self.ionScript = match.group("IonScript")
            self.finished = True
            return


class Bailout:
    re_spew = re.compile(r"Bailout")

    # [Bailouts] Took bailout! Snapshot offset: 238
    re_start = re.compile(r"Took (?:(?P<invalidation>.*) )?bailout! Snapshot offset: (?P<snapshotOff>\d+)")
    # [Bailouts] Bailing out /.../string-base64.js:1, IonScript 0x1da07a0
    re_ionscript = re.compile(r" Bailing out (?P<location>[^:]+:\d+), IonScript (?P<IonScript>0x[0-9a-fA-F]+)")
    # [Bailouts]  reading from snapshot offset 238 size 664
    # [Bailouts]  bailing from bytecode: getgname, MIR: typebarrier [728], LIR: typebarrier [457]
    re_sig = re.compile(r" bailing from bytecode: (?P<bcOp>\S+), MIR: (?P<mirOp>\S+) [(?P<mirId>\d+)], LIR: (?P<lirOp>\S+) [(?P<mirId>\d+)]")
    # [Bailouts]  restoring frame
    # [Bailouts]  expr stack slots 1, is function frame 0
    # [Bailouts]  pushing 0 expression stack slots
    # [Bailouts]  new PC is offset 839 within script 0x7fc919f07280 (line 124)
    re_stop = re.compile(r" new PC is offset (?P<pcOff>\d+) within script (?P<script>0x[0-9a-fA-F]+) (line (?P<line>\d+))")

    def __init__(self, startMatch):
        self.finished = False
        self.signature = (None, None, None)
        self.ids = (None, None)
        self.isInvalidation = startMatch.group("invalidation") is not None
        self.snapshotOffset = startMatch.group("snapshotOff")
        self.pcOffset = None
        self.ionScript = ""
        self.location = ""
        return

    @staticmethod
    def start(spew, line):
        if not re_spew.match(spew):
            return None
        match = re_start.match(line)
        if not match:
            return None
        return Bailout(match)

    def append(spew, line):
        if not re_spew.match(spew):
            return
        match = re_ionscript.match(line)
        if match:
            self.location = match.group("location")
            self.ionScript = match.group("IonScript")
            return
        match = re_sig.match(line)
        if match:
            self.ids = (int(match.group("mirId")), int(match.group("lirId")))
            return
        match = re_stop.match(line)
        if match:
            self.finished = True
            return


class Test:
    re_tbplOutput = re.compile("""
        ^TEST-(?P<status>PASS|\S*)
        \s\|\s \S*(?P<args>(?:\s[-]+\S+)*) \s*\|\s
        (?P<test>[^:]+)(?::(?P<reason>.*))?
        """, re.VERBOSE)
    re_exitCode = re.compile(r"Exit code: (?P<ec>[-]?\d*)")
    re_spew = re.compile(r"^\[(?P<spew>[^]]+)\]\s(?P<line>.*)")

    def __init__(self):
        self.finished = False
        self.test = ""
        self.status = "PASS"
        self.exitCode = 0
        self.args = ""
        self.reason = None
        self.output = []
        self.eventHandler = SpewLineFactory([IonScript, Bailout])
        self.tbplSummary = ""
        self.lastSpew = ""

    @staticmethod
    def start():
        return Test()

    def append(self, line):
        res = self.re_tbplOutput.match(line)
        if res is not None:
            self.tbplSummary = line
            self.test = res.group("test")
            self.status = res.group("status")
            self.args = res.group("args")
            self.reason = res.group("reason")
            self.finish()
        else:
            self.output.append(line)
            spew = self.re_spew.match(line)
            if spew:
                self.lastSpew = spew.group("spew")
                line = spew.group("line")
            self.eventHandler.append(self.lastSpew, line)

    def finish(self):
        # Only finalize if there is something.
        self.finished = True

        # Extract the exit code from the latest message.
        # Set the exit code if we found one.
        if len(self.output):
            res = self.re_exitCode.search(self.output[-1])
            if res:
                self.exitCode = int(res.group("ec"))

        self.output = []
        if self.status != "PASS":
            self.doPrint()

    def doPrint(self):
        sys.stdout.write("[%d] ./js %s %s => %s\n" % (self.exitCode, self.args, self.test, self.reason))


class Summary:
    interesting = []
    re_neutralizePath = re.compile(r"(/\S+)*/js/src")

    def __init__(self, log):
        self.interesting = []
        self.testsHandler = TestFactory(Test)
        with open(log, 'r') as logContent:
            for line in logContent:
                self.testsHandler.append(self.neutralizePath(line))

    def neutralizePath(self, line):
        return re.sub(self.re_neutralizePath, '.', line)

    def doPrint(self):
        for t in self.interesting:
            t.doPrint()


def main(argv):
    # from optparse import OptionParser
    # op = OptionParser(usage='%prog ionFlagsAll.log outputDir')
    if len(argv) != 1:
        sys.exit(1)
    s = Summary(argv[0])
    # s.doPrint()


if __name__ == '__main__':
    main(sys.argv[1:])
