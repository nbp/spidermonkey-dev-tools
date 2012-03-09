{ nixpkgs ? <nixpkgs>
, officialRelease ? false
, ionmonkeySrc ? { outPath = <ionmonkey>; }
, doBuild ? true
, doOptBuild ? true
, doSpeedCheck ? true
, doStats ? true
}:

let
  pkgs = import nixpkgs {};

  # Hydra is using build.system to organize the results based on the
  # architecture on which is has been build, but not based on the host on which
  # the produced binaries are supposed to run.  To let hydra sort them as we
  # expect, we lie to it by changing the system attribute such as it correspond
  # to the system argument given to the nix expression, and thus let it sort as
  # we expect.
  lieHydraSystem = system: { inherit system; };

  cross = {system}:
    let
      pkgs = import nixpkgs { inherit system; };
      crossSystem =
        if system == "armv7l-linux" then {
          config = "armv7l-unknown-linux-gnueabi";
          bigEndian = false;
          arch = "arm";
          gcc.arch = "armv7-a";
          float = "soft";
          withTLS = true;
          libc = "glibc";
          platform = pkgs.platforms.versatileARM;
          openssl.system = "linux-generic32";
        }
        else null;
    in
      rec {
        build = {
          system = if isNull crossSystem then system else "x86_64-linux";
          pkgs = import nixpkgs { inherit crossSystem; inherit (build) system; };
        };
        host = {
          system = system;
          pkgs = import nixpkgs { inherit system; };
        };
      };

  # we have to keep it away from the job, because we cannot extend the hostDrv
  # with overriveDerivation yet.
  buildIon =
      { system ? builtins.currentSystem
      , args ? (default: {})
      }:

      with (cross { inherit system; });
      # with { inherit (build) pkgs; };
      with pkgs.lib;

      let
        default = rec {
          name = "ionmonkey";
          stdenv = build.pkgs.stdenvCross;
          src = jobs.tarball;

          buildNativeInputs = with build.pkgs; [ perl python ];
          # buildInputs = with pkgs; [ gdb ];

          #postUnpack = ''
          #  sourceRoot=$sourceRoot/js/src
          #  echo Compile in $sourceRoot
          #'';

          CONFIG_SITE = pkgs.writeText "config.site" ''
            ${if host.system == "armv7l-linux" then ''
              HOST_CC="gcc"
              HOST_CXX="g++"
              CC="armv7l-unknown-linux-gnueabi-gcc -fno-short-enums -fno-exceptions -march=armv7-a -mthumb -mfpu=vfp -mfloat-abi=softfp -pipe" # -mcpu=cortex-a9 -mtune=cortex-a9"
              CXX="armv7l-unknown-linux-gnueabi-g++ -fno-short-enums -fno-exceptions -march=armv7-a -mthumb -mfpu=vfp -mfloat-abi=softfp -pipe" # -mcpu=cortex-a9 -mtune=cortex-a9"
            '' else ""
            }
            ${if host.system == "x86_64-darwin" then ''
              # These are use to override the configure script impurity which
              # default to gcc-4.2 binary name, and enforce the one define in
              # the environment.
              CC="gcc"
              CXX="g++"
            '' else ""}
          '';

          preConfigure =
          # Build out of source tree and make the source tree read-only.  This
          # helps catch violations of the GNU Coding Standards (info
          # "(standards) Configuration"), like `make distcheck' does.
          '' mkdir "../build"
             cd "../build"
             configureScript="../$sourceRoot/js/src/configure"

             echo "building out of source tree, from \`$PWD'..."
          '';

          # Print g++/gcc/ld command line addition made by Nix.
          # postConfigure = ''export  NIX_DEBUG=1'';

          optimizeConfigureFlags = [ "--enable-debug-symbols=-ggdb3" ];
          debugConfigureFlags = [ "--enable-debug=-ggdb3" "--disable-optimize" ];
          crossConfigureFlags = []
          ++ optionals (host.system == "i686-linux") [ "i686-pv-linux-gnu" ]
          ++ optionals (host.system == "armv7l-linux") [ "armv7l-unknown-linux-gnueabi" ];

          configureFlags = debugConfigureFlags ++ crossConfigureFlags;

          #installPhase = "exit 1";
          postInstall = ''
            ./config/nsinstall -t js $out/bin
          '';
          doCheck = false;
          NIX_STRIP_DEBUG = 0;
          dontStrip = true;

          meta = {
            description = "Build JS shell.";
            # Should think about reducing the priority of i686-linux.
            schedulingPriority = "100";
          };
        };
      in

      (pkgs.releaseTools.nixBuild (default // args default)).hostDrv
      // lieHydraSystem host.system;

  jobs = {

    tarball =
      pkgs.releaseTools.sourceTarball rec {
        name = "ionmonkey-tarball";
        src = ionmonkeySrc;
        version = "";
        versionSuffix =
          if officialRelease then ""
          else if src ? rev then toString src.rev
          else "";
        buildInputs = [];
        autoconf = pkgs.autoconf213;
        autoconfPhase = ''
          export VERSION=""
          export VERSION_SUFFIX=""

          eval "$preAutoconf"

          cd js/src/
          if test -x ./bootstrap; then ./bootstrap
          elif test -x ./bootstrap.sh; then ./bootstrap.sh
          elif test -x ./autogen.sh; then ./autogen.sh
          elif test -x ./autogen ; then ./autogen
          elif test -x ./reconf; then ./reconf
          elif test -f ./configure.in || test -f ./configure.ac; then
              autoreconf -i -f --verbose
          else
              echo "No bootstrap, bootstrap.sh, configure.in or configure.ac. Assuming this is not an GNU Autotools package."
          fi
          cd -

          eval "$postAutoconf"
        '';

        distPhase = ''
          runHook preDist

          dir=$(basename $(pwd))
          case $dir in
            (git-export) vcs=git;;
            (hg-archive) vcs=hg;;
            (*) vcs=unk;;
          esac
          cd ..
          ensureDir "$out/tarballs"
          tar --exclude-vcs -caf "$out/tarballs/$vcs-${version}${versionSuffix}.tar.bz2" $dir
          cd -

          runHook postDist
        '';
        inherit officialRelease;
      };

    } // pkgs.lib.optionalAttrs doBuild {

    jsBuild =
      { system ? builtins.currentSystem
      }:

      buildIon { inherit system; };

    } // pkgs.lib.optionalAttrs doOptBuild {

    jsOptBuild =
      { system ? builtins.currentSystem
      }:

      buildIon {
        inherit system;
        args = default: with default; {
          name = "ionmonkey-opt";
          configureFlags = optimizeConfigureFlags ++ crossConfigureFlags;
        };
      };

    } // pkgs.lib.optionalAttrs doSpeedCheck {

    jsSpeedCheckIon =
      { system ? builtins.currentSystem
      # bencmarks
      , sunspider ? { outPath = <sunspider>; }
      , v8 ? { outPath = <v8>; }
      , kraken ? { outPath = <kraken>; }
      }:

      let jitTestOpt = "--ion -n"; in
      let build = jobs.jsOptBuild { inherit system; }; in
      let pkgs = import nixpkgs { inherit system; }; in
      let opts = jitTestOpt; in

      pkgs.releaseTools.nixBuild {
        name = "ionmonkey-bench";
        src = build;
        buildInputs = with pkgs; [ perl glibc valgrind ];
        dontBuild = true;
        checkPhase = ''
          ensureDir $out
          export TZ="US/Pacific"
          export TZDIR="${pkgs.glibc}/share/zoneinfo"

          # run sunspider
          cp -r ${sunspider} ./sunspider
          chmod -R u+rw ./sunspider
          cd ./sunspider
          latest=$(ls -1 ./tests/ | sed -n '/sunspider/ { s,/$,,; p }' | sort -r | head -n 1)
          for test in $(cat ./tests/$latest/LIST); do
              args="${jitTestOpt}"
              if test -e ./tests/$latest/$test-data.js; then
                  args="$args -f ./tests/$latest/$test-data.js"
              fi
              args="$args -f ./tests/$latest/$test.js"
              callgrindOutput=$out/$latest-$test.callgrind

              valgrind --tool=callgrind --callgrind-out-file=$callgrindOutput -- ${build}/bin/js $args && \
                  echo "file callgrind-output $callgrindOutput" >> $out/nix-support/hydra-build-products || \
                  true
          done
          cd -

          # run kraken
          cp -r ${kraken} ./kraken
          chmod -R u+rw ./kraken
          cd ./kraken
          latest=$(ls -1 ./tests/ | sed -n '/kraken/ { s,/$,,; p }' | sort -r | head -n 1)
          for test in $(cat ./tests/$latest/LIST); do
              args="${jitTestOpt}"
              if test -e ./tests/$latest/$test-data.js; then
                  args="$args -f ./tests/$latest/$test-data.js"
              fi
              args="$args -f ./tests/$latest/$test.js"
              callgrindOutput=$out/$latest-$test.callgrind

              valgrind --tool=callgrind --callgrind-out-file=$callgrindOutput -- ${build}/bin/js $args && \
                  echo "file callgrind-output $callgrindOutput" >> $out/nix-support/hydra-build-products || \
                  true
          done
          cd -

          # run v8
          cd ${v8}
          latest=v8
          for test in $(sed -n '/^load/ { /base.js/ d; s/.*(.\(.*\)\.js.).*/\1/; p } ' run.js); do
              args="${jitTestOpt} -f base.js -f $test.js"
              callgrindOutput=$out/$latest-$test.callgrind

              valgrind --tool=callgrind --callgrind-out-file=$callgrindOutput -- ${build}/bin/js $args && \
                  echo "file callgrind-output $callgrindOutput" >> $out/nix-support/hydra-build-products || \
                  true
          done
          cd -
        '';
        dontInstall = true;
        dontFixup = true;

        meta = {
          description = "Run test suites.";
          schedulingPriority = "50";
        };
      };

    } // pkgs.lib.optionalAttrs doStats {

    jsIonStats =
      { system ? builtins.currentSystem
      , checkDirs ? "ion"
      }:

      let build = jobs.jsBuild { inherit system; }; in
      let pkgs = import nixpkgs { inherit system; }; in

      pkgs.releaseTools.nixBuild {
        name = "ionmonkey-check";
        src = jobs.tarball;
        buildInputs = with pkgs; [ python gnused ];
        dontBuild = true;
        checkPhase = ''
          ensureDir $out
          TZ="US/Pacific" \
          TZDIR="${pkgs.glibc}/share/zoneinfo" \
          IONFLAGS=all \
          python ./js/src/jit-test/jit_test.py --no-progress --tinderbox -f --ion-tbpl -o --no-slow --timeout=60 ${build}/bin/js ${checkDirs} 2>&1 | tee ./log | grep 'TEST\|PASS\|FAIL\|TIMEOUT\|--ion'

          # List of all failing test with the debug output.
          echo -n Report failures
          sed -n 'x; s,.*,,; x; :beg; /TEST-PASS/ { d }; /TEST-UNEXPECTED/ { G; p; d }; H; n; b beg;' ./log > $out/failures.txt
          echo "report fail-log $out/failures.txt" >> $out/nix-support/hydra-build-products
          echo .

          # Collect stats about the current run.
          echo -n Generate Stats
          comp_failures=$(grep -c "\[Abort\] IM Compilation failed." ./log || true)
          echo -n .
          gvn=$(grep -c "\[GVN\] marked"  ./log || true)
          echo -n .
          snapshots=$(grep -c "\[Snapshots\] Assigning snapshot" ./log || true)
          echo -n .
          bailouts=$(grep -c "\[Bailouts\] Bailing out" ./log || true)
          echo -n .
          sed -n "/Bailing out/ { s/.*jit-test/jit-test/; s/,.*//; h; }; /bailing from/ { s/ \[[0-9]\+\]//g; s/^\[Bailouts\] //; G; s/\\n/ (/; s/$/)/; x; s/.*//; x; /(.\+)/ { p } }" ./log > ./bailouts-from.log
          sort ./bailouts-from.log | uniq -c | sort -nr > ./bailouts-from-sorted.log
          echo -n .
          sed "s/ *(.*)//" ./bailouts-from.log | sort | uniq -c | sort -nr > ./bailouts-sorted.log
          echo -n .
          pass=$(grep -c "^TEST-PASS" ./log || true)
          echo -n .
          fail=$(grep -c "^TEST-UNEXPECTED" ./log || true)
          echo -n .
          sed -n "/Unsupported opcode/ { s,(line .*),,; p }" ./log | sort | uniq -c | sort -nr > ./unsupported.log
          echo -n .
          sed -n '/^Exit code: / { s/Exit code: //; p }' $out/failures.txt | sort -n | uniq > ./exit-codes.log

          for ec in : $(cat ./exit-codes.log); do
            test $ec = : && continue
            echo -n -
            sed -n '/TEST/ d; /Exit code: '$ec'/ { x; s,/[^ ]*nix-build[^/ ]*/,,g; s,0x[0-9a-fA-F]*,0xADDR,g; p }; h' $out/failures.txt | \
               sort | uniq -c | sort -nr > ./exit.$ec.log
            echo -n -
            sed -n '/^TEST/ h; /Exit code: '$ec'/ { x; s,/[^ ]*nix-build[^ ]*/js/src,.,g; s,^[^|]*|,,; s,jit_test.py,./js,; s,[ ]*|, ,; s,:, =>,; s,0x[0-9a-fA-F]*,0xADDR,g; p }' $out/failures.txt > ./testexit.$ec.log
            echo -n .
          done

          ecToText() {
            case $1 in
              (-11) echo "Message before segmentation fault:";;
              (-9) echo "Timeout? (killed):";;
              (-6) echo "C++ assertions:";;
              (3) echo "JS assertions:";;
              (*) echo "Message before exit code $1:";;
            esac
          }

          echo > $out/stats.html "
          <head><title>Compilation stats of IonMonkey on ${system}</title></head>
          <body>
          <p>Running system : ${system}</p>
          ${if checkDirs == "" then
            "<p>Checked directories : ${checkDirs}</p>"
          else ""}
          <p>Number of tests : PASS: $pass, FAIL: $fail</p>
          $(for ec in : $(cat ./exit-codes.log); do
              test $ec = : && continue
              echo "
              <p>$(ecToText $ec)
              <ol>$(sed 's,[^0-9]*\([0-9]\+\) \(.*\),<li value=\1>\2,' ./exit.$ec.log)</ol></p>
              <ul>$(sed 's,\(.*\),<li>\1,' ./testexit.$ec.log)</ul></p>
              "
            done)
          <p>Number of compilation failures : $comp_failures</p>
          <p>Unsupported opcode (sorted):
          <ol>$(sed 's,[^0-9]*\([0-9]\+\).*: \(.*\),<li value=\1>\2,' ./unsupported.log)</ol></p>
          <p>Number of GVN congruence : $gvn</p>
          <p>Number of snapshots : $snapshots</p>
          <p>Number of bailouts : $bailouts
          <ol>$(sed 's,[^0-9]*\([0-9]\+\).* from \(.*\),<li value=\1>\2,' ./bailouts-sorted.log)</ol></p>
          <p>Bailouts signature per tests:
          <ol>$(sed 's,[^0-9]*\([0-9]\+\).* from \(.*\),<li value=\1>\2,' ./bailouts-from-sorted.log)</ol></p>
          </body>
          "

          echo -n .
          echo "report stats $out/stats.html" >> $out/nix-support/hydra-build-products
          echo .

          # Cause failures if the fail-log is not empty.
          test $fail -eq 0
        '';
        dontInstall = true;
        dontFixup = true;
        succeedOnFailure = true;

        meta = {
          description = "Run test suites to collect compilation stats.";
          schedulingPriority = "90";
        };
      };
  };

in
  jobs /* // speedTests */
