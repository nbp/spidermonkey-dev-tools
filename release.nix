{ nixpkgs ? <nixpkgs>
, officialRelease ? false
, ionmonkeySrc ? { outPath = <ionmonkey>; }
}:

let
  pkgs = import nixpkgs {};

  jobs = rec {

    tarball =
      pkgs.releaseTools.sourceTarball {
        name = "ionmonkey-tarball";
        src = ionmonkeySrc;
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
          cd ..
          ensureDir "$out/tarballs"
          tar --exclude-vcs -caf "$out/tarballs/$dir.tar.bz2" $dir
          cd -

          runHook postDist
        '';
        inherit officialRelease;
      };

    jsBuild =
      { system ? builtins.currentSystem
      , doBuild ? true
      }:

      assert doBuild;

      let pkgs = import nixpkgs { inherit system; }; in
      with pkgs.lib;
      (pkgs.releaseTools.nixBuild {
        name = "ionmonkey";
        src = tarball;
        postUnpack = ''
          sourceRoot=$sourceRoot/js/src
          echo Compile in $sourceRoot
        '';
        buildInputs = with pkgs; [ perl python ];
        CONFIG_SITE = pkgs.writeText "config.site" ''
          ${if system == "armv7l-linux" then ''
            CC="gcc -mcpu=cortex-a9 -mtune=cortex-a9"
            CXX="g++ -mcpu=cortex-a9 -mtune=cortex-a9"
          '' else ""
          }
        '';
        configureFlags = [ "--enable-debug=-ggdb3" "--disable-optimize" ]
        ++ optionals (system == "i686-linux") [ "i686-pv-linux-gnu" ]
        ++ optionals (system == "armv7l-linux") [ "armv7l-unknown-linux-gnueabi" ]
        ;
        postInstall = ''
          ./config/nsinstall -t js $out/bin
        '';
        doCheck = false;
        dontStrip = true;

        meta = {
          description = "Build JS shell.";
          # Should think about reducing the priority of i686-linux.
          schedulingPriority = "100";
        };
      }) // {
        inherit tarball;
      };

    jsOptBuild =
      { system ? builtins.currentSystem
      , doOptBuild ? true
      }:

      assert doOptBuild;

      let pkgs = import nixpkgs { inherit system; }; in
      let build = jobs.jsBuild { inherit system; }; in
      with pkgs.lib;

      pkgs.lib.overrideDerivation build (attrs: {
        name = "ionmonkey-opt";
        configureFlags = []
        ++ optionals (system == "i686-linux") [ "i686-pv-linux-gnu" ]
        ++ optionals (system == "armv7l-linux") [ "armv7l-unknown-linux-gnueabi" ]
        ;
      });

    jsSpeedCheckJM =
      { system ? builtins.currentSystem
      , jitTestOpt ? " -m -n "
      # bencmarks
      , sunspider # ? { outPath = <sunspider>; }
      , v8 # ? { outPath = <v8>; }
      , kraken # ? { outPath = <kraken>; }
      , doSpeedCheck ? true
      }:

      assert doSpeedCheck;

      let build = jsOptBuild { inherit system; }; in
      let pkgs = import nixpkgs { inherit system; }; in
      let opts = jitTestOpt; in
      pkgs.releaseTools.nixBuild {
        name = "ionmonkey-speed-check";
        src = optBuild;
        buildInputs = with pkgs; [ perl glibc ];
        dontBuild = true;
        checkPhase = ''
          ensureDir $out
          export TZ="US/Pacific"
          export TZDIR="${pkgs.glibc}/share/zoneinfo"

          ensureDir $out/sunspider
          ensureDir $out/kraken

          # run sunspider
          cp -r ${sunspider} ./sunspider
          chmod -R u+rw ./sunspider
          cd ./sunspider
          latest=$(ls -1 ./tests/ | sed -n '/sunspider/ { s,/$,,; p }' | sort -r | head -n 1)
          perl ./sunspider --shell ${optBuild}/bin/js --args="${jitTestOpt}" --suite=$latest | tee $out/sunspider.log
          for f in *-results; do
              cp -r $f $out/sunspider
          done
          cd -
          # run kraken
          cp -r ${kraken} ./kraken
          chmod -R u+rw ./kraken
          cd ./kraken
          latest=$(ls -1 ./tests/ | sed -n '/kraken/ { s,/$,,; p }' | sort -r | head -n 1)
          perl ./sunspider --shell ${optBuild}/bin/js --args="${jitTestOpt}" --suite=$latest | tee $out/kraken.log
          for f in *-results; do
              cp -r $f $out/kraken
          done
          cd -
          # run v8
          cd ${v8}
          ${optBuild}/bin/js ${jitTestOpt} ./run.js | tee $out/v8.log
          cd -
          sed -n '/====/,/Results/ { p }' $out/sunspider.log $out/kraken.log | cat - $out/v8.log > $out/summary.txt
          echo "report stats $out/summary.txt" > $out/nix-support/hydra-build-products
        '';
        dontInstall = true;
        dontFixup = true;

        meta = {
          description = "Run test suites.";
          schedulingPriority = "50";
        };
      };

    jsSpeedCheckIon =
      { system ? builtins.currentSystem
      # bencmarks
      , sunspider, v8, kraken
      , doSpeedCheck ? true
      }:

      assert doSpeedCheck;

      let
        pkgs = import nixpkgs { inherit system; };
        build = jobs.jsSpeedCheckJM {
          inherit system sunspider v8 kraken;
          jitTestOpt = "--ion -n";
        };
      in
      with pkgs.lib;

      pkgs.lib.overrideDerivation build (attrs: {
        name = attrs.name + "-ion";
      });

    jsIonStats =
      { system ? builtins.currentSystem
      , doStats ? true
      }:

      assert doStats;

      let build = jobs.jsBuild { inherit system; }; in
      let pkgs = import nixpkgs { inherit system; }; in

      pkgs.releaseTools.nixBuild {
        name = "ionmonkey-check";
        src = tarball;
        buildInputs = with pkgs; [ python gnused ];
        dontBuild = true;
        checkPhase = ''
          ensureDir $out
          TZ="US/Pacific" \
          TZDIR="${pkgs.glibc}/share/zoneinfo" \
          IONFLAGS=all \
          python ./js/src/jit-test/jit_test.py --no-progress --tinderbox -f --ion-tbpl -o --no-slow --timeout=10 ${build}/bin/js ion 2>&1 | tee ./log | grep 'TEST\|PASS\|FAIL\|TIMEOUT\|--ion'

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
          pass=$(grep -c "^TEST-PASS" ./log || true)
          echo -n .
          fail=$(grep -c "^TEST-UNEXPECTED" ./log || true)
          echo -n .
          sed -n "/Unsupported opcode/ { s,(line .*),,; p }" ./log | sort | uniq -c | sort -nr > ./unsupported.log
          echo -n .
          sed -n '/TEST/ d; /Assertion/ { s,/[^ ]*nix-build[^/]*/,,g; p };' $out/failures.txt | sort | uniq -c | sort -nr > ./assertions.log

          echo > $out/stats.html "
          <head><title>Compilation stats of IonMonkey</title></head>
          <body>
          <p>Number of compilation failures : $comp_failures</p>
          <p>Unsupported opcode (sorted):
          <ol>$(sed 's,[^0-9]*\([0-9]\+\).*: \(.*\),<li value=\1>\2,' ./unsupported.log)</ol></p>
          <p>Failing assertions:
          <ol>$(sed 's,[^0-9]*\([0-9]\+\) \(.*\),<li value=\1>\2,' ./assertions.log)</ol></p>
          <p>Number of GVN congruence : $gvn</p>
          <p>Number of snapshots : $snapshots</p>
          <p>Number of bailouts : $bailouts</p>
          <p>Number of tests : PASS: $pass, FAIL: $fail</p>
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
        };
      };
  };

  speedTest = mode: gvn: licm: ra: inline: osr:
    with pkgs.lib;
    let
      name = ""
      + optionalString (mode == "eager") "Eager"
      + optionalString (mode == "infer") "Infer"
      + optionalString (mode == "none")  "None_"
      + "_"
      + optionalString (gvn == "off")         "GVNn"
      + optionalString (gvn == "pessimistic") "GVNp"
      + optionalString (gvn == "optimistic")  "GVNo"
      + "_"
      + optionalString (licm == "off") "LICMn"
      + optionalString (licm == "on")  "LICMy"
      + "_"
      + optionalString (ra == "greedy") "RAg"
      + optionalString (ra == "lsra")   "RAl"
      + "_"
      + optionalString (inline == "off") "INLn"
      + optionalString (inline == "on")  "INLy"
      + "_"
      + optionalString (osr == "off") "OSRn"
      + optionalString (osr == "on")  "OSRy"
      ;

      args = "--ion"
      + optionalString (mode == "eager") " --ion-eager"
      + optionalString (mode == "infer") " -n"
      + " --ion-gvn=${gvn}"
      + " --ion-licm=${licm}"
      + " --ion-regalloc=${ra}"
      + " --ion-inlining=${inline}"
      + " --ion-osr=${osr}"
      ;
    in

    setAttrByPath [ ("jsSpeedCheckIon_" + name) ] (
      { system ? builtins.currentSystem
      , sunspider, v8, kraken
      }:

      let
        pkgs = import nixpkgs { inherit system; };
        build = jobs.jsSpeedCheckJM {
          inherit system sunspider v8 kraken;
          jitTestOpt = args;
        };
      in
      with pkgs.lib;

      pkgs.lib.overrideDerivation build (attrs: {
        name = attrs.name + "-" + name;
      })
    );

  hasOnlyOneVariation = switches: with pkgs.lib;
    builtins.lessThan
      (length (filter (switch: !switch.default) switches))
      2;

  # First value of the list of option is the default value.
  switchOver = defaults: rest: f:  with pkgs.lib;
    let switches =
         map (v: {value = v; default = true;}) defaults
      ++ map (v: {value = v; default = false;}) rest;
    in
      flip concatMap switches f;

  speedTests = with pkgs.lib;
    fold (x: y: x // y) {} (
      switchOver ["infer"] ["eager" "none"] (mode:
      switchOver [ "optimistic" ] [ "off" "pessimistic" ] (gvn:
      switchOver [ "on" ] [ "off"] (licm:
      switchOver [ "lsra" ] [ "greedy" ] (ra:
      switchOver [ "on" ] [ "off"] (inline:
      switchOver [ "on" ] [ "off"] (osr:
        optional (hasOnlyOneVariation [mode gvn licm ra inline osr]) (
          speedTest mode.value gvn.value licm.value ra.value inline.value osr.value
        )
      ))))))
   );

in
  jobs /* // speedTests */
