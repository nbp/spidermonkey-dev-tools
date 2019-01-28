#!/bin/sh

export LC_ALL=C
export TZ=America/Los_Angeles
export PYTHONDONTWRITEBYTECODE=1
: ${NIX_SHELL:=/run/current-system/sw/bin/nix-shell}
: ${IN_MAKE_SH:=false}
: ${SILENT:=false}
#echo cc=$CC cxx=$CXX my_cc=$my_CC my_cxx=$my_CXX

exitcode=0
arch_sel=
bld_sel=
cc_sel=
phase_sel=
aphase_sel=
kontinue=false
firefox=false
xpcshell=false
nspr=false
enabledbg=false
oomCheck=false
deterministic=false
gczeal=false
tracelog=false
thm=false
ggc=false
cgc=false
asan=false
ubsan=false
msan=false
tsan=false
spew=true
fuzz=false
noion=false
logref=false
taskspooler=false
warning=true
perf=false
wtest=false
bisect=
badexitcode=
nix=true
fhs=false
impure=false
nocl=false
arg=$1; shift;
oldarg=
# Record if this is a nix-shel context, otherwise this is a task argument.
ctx_p=false
task=""
while test "$arg" != "$oldarg"; do
    ctx_p=false;
    case ${arg%%-*} in
        (x86|x64|arm|arm64|mips64|mips32|none|none32) arch_sel="$arch_sel ${arg%%-*}"; ctx_p=true;;
        (dbg|odbg|pro|opt|oopt) bld_sel="$bld_sel ${arg%%-*}"; ctx_p=true;;
        (gcc*|clang*) cc_sel="$cc_sel ${arg%%-*}"; ctx_p=true;;
        (autoconf|cfg|make|chk|run|runf|runt|runi|chk?|chk??|chk???|chksimd|regen|mach|src_mach|machcfg|unagi|flame|octane|ss|kk|aa|asmapps|asmubench|val|vgdb|rr|shell|clobber)
            last="${arg%%-*}";
            phase_sel="$phase_sel $last";;
        (patch) aphase_sel="$aphase_sel ${arg%%-*}";;
        (k) kontinue=true;;
        (ff) firefox=true;;
        (fhs) fhs=true;;
        (ts) taskspooler=true;;
        (xpc) xpcshell=true;;
        (nspr) nspr=true;;
        (enabledbg) enabledbg=true;;
        (oom) oomCheck=true;;
        (dt) deterministic=true;;
        (gcz) gczeal=true;;
        (tr) tracelog=true;;
        (thm) thm=true;;
        (ggc) ggc=true;;
        (cgc) cgc=true;;
        (asan) asan=true;;
        (ubsan) ubsan=true;;
        (msan) msan=true;;
        (tsan) tsan=true;;
        (nospew) spew=false;;
        (fuzz) fuzz=true;;
        (noion) noion=true;;
        (nowarn) warning=false;;
        (perf) perf=true;;
        (wtest) wtest=true;;
        (thm) thm=true;;
        (logref) logref=true;;
        (impure) impure=true;;
        (nocl) nocl=true;;
        (bisect_segv_run) bisect=run; badexitcode=139; last=run; phase_sel="$phase_sel $last";;
        (bisect_trap_run) bisect=run; badexitcode=133; last=run; phase_sel="$phase_sel $last";;
        (bisect_success_run) bisect=run; badexitcode=0; last=run; phase_sel="$phase_sel $last";;
        (*) echo 1>&2 "Unknown variation flag '$arg'.";
        exit 1;;
    esac
    if test $ctx_p = false; then
        task=${task}${task:+-}${arg%%-*}
    fi
    oldarg=$arg
    arg=${arg#*-}
done

test -z "$arch_sel" && arch_sel="x64"
test -z "$bld_sel" && bld_sel="pro"
test -z "$cc_sel" && cc_sel="clang"
test -z "$phase_sel" && phase_sel="make"
phase_sel="$phase_sel $aphase_sel"

TS=""
if $taskspooler; then
    if which ts 2>/dev/null; then
        TS=$(which ts)
    else
        echo 1>2 "Unable to find the task spooler."
    fi
fi

top_file(){
  local filename=$1
  local p=$2
  while test ! -r "$p/$filename"; do
    if test -z "$p"; then
      break;
    else
      p=${p%/*}
    fi
  done
  if test -r "$p/$filename"; then
    echo "$p/$filename"
  fi
}

failed=false

catch_failure() {
    local exitcode=$1
    reset='\e[0;0m'
    highlight='\e[0;31m'
    if ! $SILENT ; then
        echo -e 1>&2 "error: ${highlight}Failed while building variant: $arch-$bld ($phase)${reset}"
    fi
    failed=true

    # "git bisect" use exit code 125 to know when the code cannot be tested.
    if test -n "$bisect"; then
        echo $bisect : $badexitcode : $exitcode
        test \! "$phase" = "$bisect" && exit 125
        if test -n "$badexitcode"; then
            test "$badexitcode" = "$exitcode" && exit 99
            exit 0
        fi
    fi

    # Continue in case of failures.
    $kontinue || (printf '\a'; exit 1)
}

maybeExport() {
    local name=$1
    test -v $name && echo "export $name='$(eval echo \$$name)';";
}

maybeExportPrefix() {
    local name=$1
    env |  env | gawk -F= '/^'"$name"'/ { printf "export %s=\"%s\";", $1, $2; }';
}

RELEASE_NIX=
run() {
    reset='\e[0;0m'
    highlight='\e[0;35m'

    if ! $SILENT ; then
        echo -e 1>&2 "${TS:+wait-&-}exec: ${highlight}$@${reset}"
    fi

    # mach try to parse the environment, and the fact that these are present cause troubles.
    unset shellHook;
    unset configurePhase;

    if $IN_MAKE_SH ; then
        eval "$@"
    elif $nix ; then
        # echo -e 1>&2 "${TS:+wait-&-}enter nix-shell:${reset}"
        if test $nativeArch = x64; then
            archAttr=x86_64-linux
        elif test $nativeArch = x86; then
            archAttr=i686-linux
        elif test $nativeArch = aarch64; then
            archAttr=aarch64-linux
        else
            echo 1>&2 "Unknown nativeArch ($nativeArch)"
            exit 1
        fi
        hook="
          export NIX_GCC_WRAPPER_EXEC_HOOK='$(top_file "rewrite-rpath-link.sh" $buildtmpl)';
          export NIX_CC_WRAPPER_EXEC_HOOK='$(top_file "rewrite-rpath-link.sh" $buildtmpl)';
          $(maybeExport MOZBUILD_STATE_PATH)
          export MOZCONFIG_TEMPLATE=\$MOZCONFIG;
          $(maybeExport MOZCONFIG)
          $(maybeExport LC_ALL)
          $(maybeExport TZ)
          $(maybeExport DISPLAY)
          $(maybeExport PYTHONDONTWRITEBYTECODE)
          $(maybeExport NIX_STRIP_DEBUG)
          $(maybeExport JS_CODE_COVERAGE_OUTPUT_DIR)
          $(maybeExport IONFILTER)
          $(maybeExport IONFLAGS)
          $(maybeExport ENABLE_THM)
          $(maybeExport TLOPTIONS)
          $(maybeExport TLLOG)
          $(maybeExport XRE_NO_WINDOWS_CRASH_DIALOG)
          $(maybeExportPrefix MOZ_)
          $(maybeExportPrefix JIT_)
          $(maybeExportPrefix BP_)
          $(maybeExportPrefix XPCOM_)
          export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt;
          export IN_MAKE_SH=true;
          $(maybeExport IN_EMACS)
          export SHELL;
          $(maybeExport LD_LIBRARY_PATH)
          $(maybeExport RUSTFLAGS)
          cd $PWD;
        "
        # Note: "cd $PWD;" is resolved with the path before the nix-shell, while
        # the path set before running the nix-shell command is used for the
        # shell hook.
        command="$(echo "$@")"
        pure="--pure"
        if $fhs; then
            fhsAttr=".fhs.env"
            #pure=""
            echo $command
        else
            fhsAttr=""
        fi
        if $impure; then
            pure=""
        fi
        # MOZ_LOG  MOZ_GDB_SLEEP
        cd $topsrcdir;
        NIX_SHELL_HOOK="$hook" \
                      $NIX_SHELL "$RELEASE_NIX" \
                      -A "gecko.$archAttr.$cc$fhsAttr" \
                      $pure --command "$command"
        cd -
    elif test -z "$TS"; then
        "$@"
    else
        $TS -nf "$@"
    fi
    exitcode=$?
    test $exitcode -gt 0 -o \( -n "$bisect" -a "$phase" = "$bisect" \) && \
        catch_failure $exitcode
}

checkForBenchmarks() {
    local governor=$(cat /sys/bus/cpu/devices/cpu0/cpufreq/scaling_governor)
    if test $governor != performance; then
        echo 1>&2 "Governor are set to \"$governor\", use the following command to change to performance:

  echo performance | sudo tee /sys/bus/cpu/devices/cpu*/cpufreq/scaling_governor

"
        exit 1
    fi

    # STOP all firefox
    pkill -s 19 firefox
}

afterBenchmark() {
    # CONT-inue the execution of all firefox
    pkill -s 18 firefox
}

generate_patch() {
    if git st | grep -c '\(.M\|M.\)'; then
        echo 2>&1 "Please commit the changes and re-test."
        exit 1
    else
        tg patch -r ~/mozilla
    fi
}

gen_builddir() {
    local arch="$arch"
    if test \! -e "$builddir/../config.site" -a -e "$buildtmpl"; then
        mkdir -p "$builddir"
        cd "$builddir/.."
        # cp $(top_file ".init" $buildtmpl) .
        # cp $(top_file ".preinit" $buildtmpl) .
        cp $(top_file "config.site" $buildtmpl) .
        cd -
    fi
}

get_srcdir() {
    local source=$(top_file "mach" $(pwd -L))
    source=$(dirname "$source")
    echo $source
}

get_js_srcdir() {
    local source=$(get_srcdir)
    source=${source%/js/src}
    echo ${source}/js/src
}

cond() {
    eval "($1) && echo true || echo false"
}

generate_conf_args() {
    shell=$(cond "! $firefox && ! $nspr")
    if $fuzz; then
        firefox=false;
        nspr=false;
        shell=false;
        dbg=false
        pro=false
        odbg=false
        opt=false
        oopt=false
    else
        dbg=$(cond "test $bld = dbg")
        pro=$(cond "test $bld = pro")
        odbg=$(cond "test $bld = odbg")
        opt=$(cond "test $bld = opt")
        oopt=$(cond "test $bld = oopt")
    fi
    machine=$(uname -m)
    case $arch in
        (x86|arm|mips32|none32) is32b=true;;
        (*) is32b=false;;
    esac
    sed -n '/true / { s/true //; p; }' <<EOF
true --prefix=$instdir
$(cond "$fuzz") --enable-posix-nspr-emulation
$(cond "$fuzz") --enable-valgrind
$(cond "$fuzz") --enable-gczeal
$(cond "$fuzz") --disable-tests
$(cond "$fuzz") --disable-profiling
$(cond "$fuzz") --enable-debug
$(cond "$fuzz") --enable-optimize
# --with-system-jpeg --with-system-zlib --with-system-bz2 --disable-crashreporter --disable-necko-wifi --disable-installer --disable-updater"
$(cond "$firefox") --enable-application=browser
$(cond "$firefox") --disable-install-strip
$(cond "$firefox") --enable-js-shell
$(cond "$firefox || $shell") --disable-jemalloc
$(cond "$firefox || $shell") --enable-valgrind
$(for extra in $NIX_EXTRA_CONFIGURE_ARGS; do
    echo "$(cond "($fuzz || $shell) && test $machine = x86_64") $extra"
done)
# conf_args="$conf_args --disable-gstreamer --disable-pulseaudio"
$(cond "$firefox || $nspr") --disable-pulseaudio
$(cond "$shell") --enable-nspr-build
$(cond "$oomCheck") --enable-oom-backtrace
$(cond "$deterministic") --enable-more-deterministic
$(cond "$gczeal") --enable-gczeal
$(cond "$tracelog") --enable-trace-logging
$(cond "$thm") --enable-thm
$(cond "$ggc") --enable-exact-rooting
$(cond "$ggc") --enable-gcgenerational
$(cond "$cgc") --enable-gccompacting
$(cond "$asan || $ubsan") --enable-address-sanitizer
$(cond "$msan") --enable-memory-sanitizer
$(cond "$tsan") --enable-thread-sanitizer
$(cond "$spew") --enable-jitspew
false --disable-masm-verbose
$(cond "$noion") --disable-ion
$(cond "$logref") --enable-logrefcnt
$(cond "! $nspr") --enable-ctypes
$(cond "! $nspr") --enable-oom-breakpoint
$(cond "$nocl") --disable-cranelift

$(cond "$dbg || $pro || $enabledbg") --enable-debug=-ggdb3
$(cond "($opt || $oopt) && ! $enabledbg") --enable-debug-symbols=-ggdb3
$(cond "$odbg || (($opt || $oopt) && ! $enabledbg)") --disable-debug
$(cond "$dbg") --disable-optimize
$(cond "$pro || $opt || $oopt") --enable-optimize
$(cond "$odbg") --enable-optimize='-g -Og'
true --enable-profiling
$(cond "$oopt || $perf") --enable-release

$(cond "! $nspr && $warning") --enable-warnings-as-errors
$(cond "! $nspr && $perf") --enable-perf

$(cond "$wtest") --enable-tests
$(cond "! $wtest") --disable-tests

$(cond "$nspr && test $arch = x64") --enable-64bit
$(cond "$is32b -a $machine = x86_64") --host=i686-unknown-linux-gnu
$(cond "$is32b -a $machine = x86_64") --target=i686-unknown-linux-gnu
$(cond "test $arch = arm -a $machine = x86_64") --enable-simulator=arm
$(cond "test $arch = arm64 -a $machine = x86_64") --enable-simulator=arm64
$(cond "test $arch = mips64") --enable-simulator=mips64
$(cond "test $arch = mips32") --enable-simulator=mips32
$(cond "test $arch = none") --disable-ion
$(cond "test $arch = none") --enable-64bit
$(cond "test $arch = none32") --disable-ion

# Generate a compile_commands.json file in addition to the usual makefiles.
# see https://developer.mozilla.org/en-US/docs/Mozilla/Projects/SpiderMonkey/Build_Documentation#Developer_(debug)_build
$(cond "$shell && test $machine = x86_64") --enable-build-backends=CompileDB,FasterMake,RecursiveMake
EOF
}

# TODO use trap here !

for p in $phase_sel; do
    if test $p = regen; then
        PROFILE_NIX=/home/nicolas/mozilla/profile.nix
        nix-store -r $( nix-instantiate --show-trace $PROFILE_NIX) | \
            tee /dev/stderr | \
            tail -n $(nix-instantiate $PROFILE_NIX 2>/dev/null | wc -l) | \
            while read drv; do

            sum=$(echo $drv | sed 's,.*-profile-\([^-]*\)-\([^-]*\),\1:\2,')
            cc=${sum%:*}
            arch=${sum#*:}
            ln -sfT $drv /nix/var/nix/profiles/per-user/nicolas/mozilla/profile-$cc-$arch
        done
        exit 0
    elif test $p = unagi; then
        run sudo chroot ~/deb-chroot/ /bin/bash -c '. ~/.bashrc; . ~/.bashrc; ~/awsa/run-benchmark.sh ~/B2G '"$@"
        exit 0
    elif test $p = flame; then
        run sudo chroot ~/deb-chroot/ /bin/bash -c '. ~/.bashrc; . ~/.bashrc; ~/awsa/run-benchmark.sh ~/flame '"$@"
        exit 0
    fi
done

# Infer the project directory based on the command line arguments.
if $firefox || $xpcshell; then
    topsrcdir=$(get_srcdir)
    srcdir=$topsrcdir
    projectdir=firefox
elif $nspr; then
    topsrcdir=$(get_srcdir)
    srcdir=$topsrcdir/nsprpub
    projectdir=nsprpub
else
    topsrcdir=$(get_srcdir)
    srcdir=$(get_js_srcdir)
    projectdir=js
fi

# Infer the build and install directories, based on the location of the
# top-level source directory.
topbuilddir=$topsrcdir/../_build/
test -e $topbuilddir || mkdir -p $topbuilddir
topbuilddir=$(cd $topbuilddir; pwd -L)

topinstdir=$topsrcdir/../_inst/
test -e $topinstdir || mkdir -p $topinstdir
topinstdir=$(cd $topinstdir; pwd -L)

# Find the name of the current work-directory.
topsrcname=$(basename $topsrcdir)
configsum=$topbuilddir/$projectdir/repo/$topsrcname/config.sum
test -e $configsum || mkdir -p $(dirname $configsum)

# if we are building with Nix, look for the nearest release.nix file.
RELEASE_NIX=$(top_file release.nix $srcdir)

# Infer the branch name which would be used as part of the name of the build
# directory.
cd $srcdir
if test -n "$BRANCH"; then
    branch=$BRANCH
elif branch=$(git symbolic-ref HEAD 2>/dev/null); then
    branch=${branch#*/*/}
elif branch=$(git rev-parse --short HEAD 2>/dev/null); then
    :
else
    branch=
fi
cd -

arch_max=$(echo $arch_sel | wc -w)
arch_cnt=1
for arch in $arch_sel; do

bld_max=$(echo $bld_sel | wc -w)
bld_cnt=1
for bld in $bld_sel; do
  bld_name=$bld
  if $deterministic; then
    bld_name=${bld_name}-dt
  fi
  if $thm; then
    bld_name=${bld_name}-thm
  fi

cc_max=$(echo $cc_sel | wc -w)
cc_cnt=1
for cc in $cc_sel; do

    buildspec=$arch/$cc/$bld_name
    nsprbuildspec=$arch/$cc/$bld

    builddir=$topbuilddir/$projectdir/${branch+$branch/}$buildspec
    instdir=$topinstdir/$projectdir/${branch+$branch/}$buildspec
    shell=$topbuilddir/$projectdir/js${branch+-$(echo "$branch" | tr '/' '-')}-$bld_name-$arch-$cc
    buildtmpl=$HOME/mozilla/_build_tmpl/$buildspec
    # oldarch=$arch
    # test $arch = arm && arch=x64

    # Handle emulated architectures.
    nativeArch=$arch
    case $(uname -m) in
        (x86_64)
            if test $arch = "arm" -o $arch = "mips32" -o $arch = "none32"; then
                nativeArch=x86
            elif test $arch = "arm64" -o $arch = "mips64" -o $arch = "none"; then
                nativeArch=x64
            fi;;
        (aarch64)
            nativeArch=aarch64
            ;;
    esac

    export LD_LIBRARY_PATH=$builddir/dist/bin
    export NIX_STRIP_DEBUG=0
    # arch=$oldarch

    ## Recurse in make.sh such that we can run the configure phase and all other
    ## commands in the nix-shell.
    if ! $IN_MAKE_SH; then
        # SILENT=true;
        run $0 $arch-$bld-$cc-$task "$@";
        continue;
    fi

    gen_builddir
    # export CONFIG_SITE=$builddir/../config.site;
    #export CC;
    #export CXX;

    test -e "$builddir" || mkdir -p "$builddir"
    touch $configsum
    rm -f $builddir/.src || ln -sf $srcdir $builddir/.src
    phase_sel_case="$phase_sel"

    checkConfig=true
    case $phase_sel in
        (*runf*) checkConfig=false;;
        (*mach*)
          export AUTOCONF=$(which autoconf)
          export MOZBUILD_STATE_PATH=$builddir/.mozbuild;
          export MOZCONFIG=$builddir/.mozconfig;
          checkConfig=false;
          if test \! -e $MOZBUILD_STATE_PATH -o \! -e $MOZCONFIG; then
              test \! -e $MOZBUILD_STATE_PATH || echo "Reconfigure: Cannot find $MOZBUILD_STATE_PATH"
              test \! -e $MOZCONFIG || echo "Reconfigure: Cannot find $MOZCONFIG"
              phase_sel_case="machcfg $phase_sel_case";
          fi;
          ;;
    esac
    if test -n "$BRANCH"; then
        checkConfig=false
    fi

    config_in=$srcdir/old-configure.in
    test -e $config_in || config_in=$srcdir/configure.in
    if $checkConfig ; then
        if test "$(md5sum "$config_in" | sed 's/ .*//')" != "$(cat "$configsum")" -o \! -x $srcdir/configure; then
            phase_sel_case="autoconf cfg $phase_sel_case"
        elif test "$(cat "$builddir/config.sum")" != "$(cat "$configsum")"; then
            phase_sel_case="cfg $phase_sel_case"
        elif test "$config_in" -nt "$srcdir/configure" -o "$srcdir/configure" -nt "$builddir/config.status"; then
            touch "$srcdir/configure"
            touch "$builddir/config.status"
        fi
    fi

for phase in $phase_sel_case; do
    args=
    if test $last = $phase; then
        args="$@"
    fi

    case $phase in
        (autoconf)
            # does that once for all builds.
            cd $srcdir;
            if $nspr; then
                nix-build '<nixpkgs>' -A autoconf -o /tmp/autoconf-latest
                run /tmp/autoconf-latest/bin/autoconf
                rm -f /tmp/autoconf-latest
            else
                run autoconf
            fi
            md5sum "$config_in" | sed 's/ .*//' > "$configsum"
            cd -
            ;;
        (cfg)
            conf_args=$(generate_conf_args | tr -s '\n' ' ')
            phase="configure"
            cd $builddir;
            # export HOST_LDFLAGS="-rpath $builddir/dist/bin"
            run "$srcdir/configure" $conf_args
            cd -
            cp "$configsum" "$builddir/config.sum"
            ;;

        (machcfg)
            echo "Enable telemetry in $MOZBUILD_STATE_PATH/machrc"
            mkdir -p $MOZBUILD_STATE_PATH
            cat >$MOZBUILD_STATE_PATH/machrc <<EOF
[build]
telemetry = true
EOF
            echo "Generate MOZCONFIG: $MOZCONFIG"
            cat >$MOZCONFIG <<EOF
# Do not source automation scripts, but read them to reverse engineer options
# that we want.
# . "\$topsrcdir/build/mozconfig.common"

# Content of \$MOZCONFIG_TEMPLATE provided by the shellHook of the derivation.
$(cat $MOZCONFIG_TEMPLATE)

# Content produced by make.sh generate_conf_args function
mk_add_options MOZ_OBJDIR=$builddir
mk_add_options AUTOCLOBBER=1
$(generate_conf_args | sed 's/^/ac_add_options /')
EOF
            ;;

        (src_mach)
            cd $topsrcdir;
            run "./mach" "$@";
            ;;

        (mach)
            cd $builddir;
            if test -z $IN_EMACS; then
                run "$topsrcdir/mach" "$@";
            else
                run "$topsrcdir/mach" --log-no-times "$@" | sed 's/^TIER: pre-export export compile misc libs tools //';
            fi
            ;;

        (make)
            export CXXFLAGS="--expensive-definedness-checks=yes"
            if test -z "$args"; then
                args="-skj8";
            fi
            if $ubsan; then
                SANFLAGS=bool,bounds,vla-bound
                export CXXFLAGS="-fsanitize=$SANFLAGS -fno-sanitize-recover=$SANFLAGS"
                export CFLAGS="-fsanitize=$SANFLAGS -fno-sanitize-recover=$SANFLAGS"
            fi
            case $arch in
                # (arm)
                #     export PATH=$PATH:$HOME/.nix-profile/bin
                #     archive="$builddir/src.tgz"
                #     run echo "git-archive ..."
                #     git archive -o "$archive" --prefix=src/ --remote "$srcdir/../../" HEAD || exit 1
                #     case $bld in
                #         (dbg)
                #             attr=jsBuild
                #             ;;
                #         (opt)
                #             attr=jsOptBuild
                #             ;;
                #     esac
                #     run echo "nix-instantiate ..."
                #     drv=$(echo '(import /home/nicolas/mozilla/sync-repos/release.nix { ionmonkeySrc = '"$builddir/src.tgz"'; }).'"$attr"' { system = "armv7l-linux"; }' | nix-instantiate -I /home/nicolas/mozilla - || exit 2)
                #     run echo "nix-store -r ..."
                #     store=$(nix-store -r $drv || exit 3)
                #     ln -sf $store "$builddir/result"
                #     run ln -sf "$builddir/result/bin/js" "$builddir/js"
                #     ;;
                (*)
                    LC_ALL=C run make -C "$builddir" "$args"
                    ;;
            esac

            if $firefox || $nspr; then
                LC_ALL=C run make -C "$builddir" install "$args"
            else
                test -e "$shell" && rm -f "$shell"
                if test -d "$builddir/js/src"; then
                    ln -sf  "$builddir/js/src/js" "$shell"
                else
                    ln -sf  "$builddir/js" "$shell"
                fi
            fi
            ;;

        (chk)
            LC_ALL=C run make -C "$builddir" check "$@"
            ;;

        (chki)
            # check ion test directory.
            #LC_ALL=C run make -C "$builddir" check-ion-test "$@"
            run python2 $srcdir/jit-test/jit_test.py --ion --no-slow "$shell" ion
            ;;

        (chka)
            # check ion test directory.
            #LC_ALL=C run make -C "$builddir" check-ion-test "$@"
            chkaOpt="$chkaOpt --ion"
            kontinue_save=$kontinue
            kontinue=true

            if $firefox ; then
                : ${MOCHITEST=plain}
                # TEST_PATH='/tests/MochiKit-1.4.2/tests/test_MochiKit-Style.html' EXTRA_TEST_ARGS='--debugger=gdb' make mochitest-plain
                LC_ALL=C run make -C "$builddir" mochitest-$MOCHITEST
            else
                run python2 $srcdir/tests/jstests.py --wpt=disabled --jitflags=ion -F -t 10 "$@" $(readlink "$shell")
                run python2 $srcdir/jit-test/jit_test.py $chkaOpt --no-slow "$@" "$shell"
            fi

            kontinue=$kontinue_save
            ;;

        (chkv)
            # check ion test directory.
            #LC_ALL=C run make -C "$builddir" check-ion-test "$@"
            chkaOpt="$chkaOpt --ion"
            kontinue_save=$kontinue
            kontinue=true

            run python2 $srcdir/tests/jstests.py --wpt=disabled --valgrind --jitflags=ion -F "$@" $(readlink "$shell")
            run python2 $srcdir/jit-test/jit_test.py --valgrind $chkaOpt --no-slow "$@" "$shell"

            kontinue=$kontinue_save
            ;;


        (chksimd)
            # check ion test directory.
            #LC_ALL=C run make -C "$builddir" check-ion-test "$@"
            chkaOpt="$chkaOpt --ion"
            kontinue_save=$kontinue
            kontinue=true

            run python2 $srcdir/jit-test/jit_test.py $chkaOpt --args="--no-asmjs --ion-regalloc=backtracking" --no-slow "$@" "$shell" asm.js

            kontinue=$kontinue_save
            ;;


        (chkt)
            if test $(cd $srcdir/tests; ls 2>/dev/null $(echo " $@" | sed 's/ -/ \\\\-/g') | wc -l) -gt 0; then
                run python2 $srcdir/tests/jstests.py --wpt=disabled --jitflags=ion -o -s --no-progress  $(readlink "$shell") "$@"
            else
                run python2 $srcdir/jit-test/jit_test.py --ion -s -f -o "$shell" "$@"
            fi
            ;;

        (chkrr)
            if test $(cd $srcdir/tests; ls 2>/dev/null $(echo " $@" | sed 's/ -/ \\\\-/g') | wc -l) -gt 0; then
                run python2 $srcdir/tests/jstests.py --wpt=disabled --jitflags=ion -o -s --no-progress -g --debugger='rr record -h'  $(readlink "$shell") "$@"
            else
                run python2 $srcdir/jit-test/jit_test.py --ion -s -f -o -G "$shell" "$@"
            fi
            ;;

        (chktt)
            if test $(cd $srcdir/tests; ls 2>/dev/null $(echo " $@" | sed 's/ -/ \\\\-/g') | wc -l) -gt 0; then
                run python2 $srcdir/tests/jstests.py --wpt=disabled --jitflags=all -o -s --no-progress  $(readlink "$shell") "$@"
            else
                run python2 $srcdir/jit-test/jit_test.py --tbpl -s -f -o "$shell" "$@"
            fi
            ;;

        (chkgdb)
            cd $srcdir
            run python2 $srcdir/gdb/run-tests.py --gdb=$(type -P gdb) --srcdir=$topsrcdir --builddir=$builddir/js/src/gdb --testdir=$srcdir/gdb/tests $builddir "$@"
            cd -
            ;;

        (chkxpc)
            : ${MOCHITEST=plain}
            # TEST_PATH='/tests/MochiKit-1.4.2/tests/test_MochiKit-Style.html' EXTRA_TEST_ARGS='--debugger=gdb' make mochitest-plain
            if test -z "$TEST_PATH"; then
                LC_ALL=C run make -C "$builddir" xpcshell-tests
            else
                XPCSHELL_TESTS=$(dirname "$TEST_PATH") relativesrcdir=. SOLO_FILE=$(basename "$TEST_PATH") \
                LC_ALL=C run make -C "$builddir" check-one
            fi
            ;;

        (clobber)
            run rm -rf "$builddir" "$shell"
            ;;

        (shell)
            export PATH=$PATH:~/.nix-profile/bin/:/var/run/current-system/sw/bin/
            run "$@"
            ;;

        (runf|run)
            if $firefox ; then
              run "$builddir/dist/bin/firefox" "$@"
            elif $xpcshell ; then
              run "$builddir/dist/bin/xpcshell" "$@"
            else
              run "$shell" "$@"
            fi
            ;;

        (val)
            if $firefox ; then
              run valgrind --smc-check=all-non-file --vex-iropt-register-updates=allregs-at-mem-access --show-mismatched-frees=no --read-inline-info=yes -- "$builddir/dist/bin/firefox" "$@"
            elif $xpcshell ; then
              run valgrind --smc-check=all-non-file --vex-iropt-register-updates=allregs-at-mem-access -- "$builddir/dist/bin/xpcshell" "$@"
            else
              run valgrind --smc-check=all-non-file --vex-iropt-register-updates=allregs-at-mem-access -- "$shell" "$@"
            fi
            ;;

        (rr)
            if $firefox ; then
              run rr record -S "$builddir/dist/bin/firefox" "$@"
            elif $xpcshell ; then
              run rr record -S "$builddir/dist/bin/xpcshell" "$@"
            else
              run rr record -S "$shell" "$@"
            fi
            ;;

        (vgdb)
            if $firefox ; then
              run valgrind --smc-check=all-non-file --vex-iropt-register-updates=allregs-at-mem-access --show-mismatched-frees=no --read-inline-info=yes --vgdb-error=0 -- "$builddir/dist/bin/firefox" "$@"
            elif $xpcshell ; then
              run valgrind --smc-check=all-non-file --vex-iropt-register-updates=allregs-at-mem-access --vgdb-error=0 -- "$builddir/dist/bin/xpcshell" "$@"
            else
              run valgrind --smc-check=all-non-file --vex-iropt-register-updates=allregs-at-mem-access --vgdb-error=0 -- "$shell" "$@"
            fi
            ;;

        (runt)
            args=""
            tests=""
            debug=""
            for i in $@; do
                case "$i" in
                    (-g) debug="-g";;
                    (-*) args="$args $i";;
                    (*) tests="$tests $i";;
                esac
            done
            run python2 $srcdir/jit-test/jit_test.py -w /dev/null --no-progress --write-failure-output -o --jitflags="" --args="$args" "$shell" $tests $debug
            ;;

        (runi)
            phase="runi interp"
            # run "$shell" "$@"
            failed=false
            kontinue_save=$kontinue
            kontinue=true
            empty_opt=
            for mode in none eager; do
                mode_opt=$empty_opt
                test $mode = infer && mode_opt="$mode_opt"
                test $mode = eaginf && mode_opt="$mode_opt --ion-eager"
            for baseline in none enabled eager; do
                baseline_opt=$mode_opt
                test $baseline = none && baseline_opt="$baseline_opt --no-baseline"
                test $baseline = enabled && baseline_opt="$baseline_opt"
                test $baseline = eager && baseline_opt="$baseline_opt --baseline-eager"
            for gvn in off on; do
                gvn_opt=$timode_opt
                test $gvn != on && gvn_opt="$gvn_opt --ion-gvn=$gvn"
            for licm in off on; do
                licm_opt=$gvn_opt
                test $licm != on && licm_opt="$licm_opt --ion-licm=$licm"
            for ra in lsra; do
                ra_opt=$licm_opt
                test $ra != lsra && ra_opt="$ra_opt --ion-regalloc=$ra"
            for inline in on off; do
                inline_opt=$ra_opt
                test $inline != on && inline_opt="$inline_opt --ion-inlining=$inline"
            for osr in on off; do
                osr_opt=$inline_opt
                test $osr != on && osr_opt="$osr_opt --ion-osr=$osr"

            opt=$osr_opt
            phase="runi ion mode=$mode gvn=$gvn licm=$licm regalloc=$ra inlining=$inline osr=$osr"
            run "$shell" $opt "$@"

            done
            done
            done
            done
            done
            done
            done
            phase="runi"
            kontinue=$kontinue_save
            ;;

        (octane)
            checkForBenchmarks
            cd ~/mozilla/arewefastyet/benchmarks/octane/
            run "$shell" "$@" -f ./run.js
            cd -
            afterBenchmark
            ;;

        (ss)
            checkForBenchmarks
            cd ~/mozilla/arewefastyet/benchmarks/SunSpider/
            script="echo -n; perl ./sunspider --shell=\"$shell\" $@ | sed -n '/====/ { :b; n; p; b b; }'"
            run bash -c "$script"
            cd -
            afterBenchmark
            ;;

        (kk)
            checkForBenchmarks
            cd ~/mozilla/arewefastyet/benchmarks/kraken/
            script="echo -n; perl ./sunspider --suite=kraken-1.1 --shell=\"$shell\" $@ | sed -n '/====/ { :b; n; p; b b; }'"
            run bash -c "$script"
            cd -
            afterBenchmark
            ;;

        (aa)
            checkForBenchmarks
            cd ~/mozilla/arewefastyet/benchmarks/misc/
            script="echo -n; perl ./sunspider --shell=\"$shell\" $@ | sed -n '/====/ { :b; n; p; b b; }'"
            run bash -c "$script"
            cd -
            afterBenchmark
            ;;

        (asmapps)
            checkForBenchmarks
            cd ~/mozilla/arewefastyet/benchmarks/asmjs-apps/
            script="echo -n; python ./harness.py \"$shell\" -- $@"
            run bash -c "$script"
            cd -
            afterBenchmark
            ;;

        (asmubench)
            checkForBenchmarks
            cd ~/mozilla/arewefastyet/benchmarks/asmjs-ubench/
            script="echo -n; python ./harness.py \"$shell\" -- $@"
            run bash -c "$script"
            cd -
            afterBenchmark
            ;;

        (patch)
            if test $arch_cnt -eq $arch_max -a $bld_cnt -eq $bld_max -a $cc_cnt -eq $cc_max; then
                cd $srcdir;
                run generate_patch
                cd -
            fi
            ;;
    esac

    # end of phase, cc, bld, arch

done
done
done
done

if ! $IN_MAKE_SH; then
    printf '\a'
fi
exit $exitcode
