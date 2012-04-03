#!/usr/bin/env python

import os, re, sys

class Test:
    # tbplOutput = re.compile(r"""
    #     TEST-(?P<status>PASS|(?P<failed>\S*))    #
    #     \s|\s\S*\s                               #
    #     (?P<args>(?: -\S+)*)                     #
    #     \s+|\s                                   #
    #     (?P<testfile>\S+)                        #
    #     (?\s:\s(?P<reason>.*))?                  #
    #     """, re.VERBOSE)
    tbplOutput = re.compile(r"TEST-(?P<status>PASS|(?P<failed>\S*))")

    def __init__(self):
        self.testfile = ""
        self.status = "Pass"
        self.options = ""
        self.reason = ""
        self.output = []
        self.tbplSummary = ""
        self.finished = False

    def addLogLine(self, line):
        res = self.tbplOutput.match(line)
        if res is not None:
            self.tbplSummary = line
            # self.testfile = res["testfile"]
            self.status = res.group("status")
            # self.options = res["args"]
            # self.reason = res["reason"]
            self.finished = True
        else:
            self.output.append(line)

    def isFinished(self):
        return self.finished

    def doPrint(self):
        sys.stdout.write(self.tbplSummary)
        for o in self.output:
            sys.stdout.write(o)

class Summary:
    interesting = []

    def __init__(self, log):
        self.interesting = []
        with open(log, 'r') as logContent:
            t = Test()
            for line in logContent:
                t.addLogLine(line)
                if t.isFinished():
                    self.collectTest(t)
                    t = Test()

    def collectTest(self, t):
        if t.status != "PASS":
            self.interesting.append(t)

    def doPrint(self):
        for t in self.interesting:
            t.doPrint()

def main(argv):
    # from optparse import OptionParser
    # op = OptionParser(usage='%prog ionFlagsAll.log outputDir')
    if len(argv) != 1:
        sys.exit(1)
    s = Summary(argv[0])
    s.doPrint()

if __name__ == '__main__':
    main(sys.argv[1:])
