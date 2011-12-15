{ nixpkgs ? <nixpkgs>
, officialRelease ? false
}:

let
  pkgs = import nixpkgs {};

  defaultJsBuild =
    { tarball ? jobs.tarball {}
    , system ? builtins.currentSystem
    , override ? {}
    }:

    let pkgs = import nixpkgs { inherit system; }; in
    with pkgs.lib;
    pkgs.releaseTools.nixBuild ({
      src = tarball;
      postUnpack = ''
        sourceRoot=$sourceRoot/js/src
        echo Compile in $sourceRoot
      '';
      buildInputs = with pkgs; [ perl python ];
      configureFlags = [ "--enable-debug" "--disable-optimize" ];
      postInstall = ''
        ./config/nsinstall -t js $out/bin
      '';
      doCheck = false;
    } // override);



  jobs = rec {
    tarball =
      { ionmonkeySrc ? { outPath = <ionmonkey>; }
      }:

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
      { tarball ? jobs.tarball {}
      , system ? builtins.currentSystem
      }:

      let pkgs = import nixpkgs { inherit system; }; in
      with pkgs.lib;
      pkgs.releaseTools.nixBuild {
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
        configureFlags = [ "--enable-debug" "--disable-optimize" ]
        ++ optionals (system == "i686-linux") [ "i686-pv-linux-gnu" ]
        ++ optionals (system == "armv7l-linux") [ "armv7l-unknown-linux-gnueabi" ]
        ;
        postInstall = ''
          ./config/nsinstall -t js $out/bin
        '';
        doCheck = false;

        meta = {
          description = "Build JS shell.";
          # Should think about reducing the priority of i686-linux.
          schedulingPriority = "100";
        };
      };

    jsOptBuild =
      { tarball ? jobs.tarball {}
      , system ? builtins.currentSystem
      }:

      let pkgs = import nixpkgs { inherit system; }; in
      let build = jobs.jsBuild { inherit tarball system; }; in
      with pkgs.lib;

      pkgs.lib.overrideDerivation build (attrs: {
        name = "ionmonkey-opt";
        configureFlags = []
        ++ optionals (system == "i686-linux") [ "i686-pv-linux-gnu" ]
        ++ optionals (system == "armv7l-linux") [ "armv7l-unknown-linux-gnueabi" ]
        ;
      });

    jsSpeedCheckJM =
      { optBuild ? jobs.jsOptBuild {}
      , system ? builtins.currentSystem
      , jitTestOpt ? "-m -n"
      # bencmarks
      , sunspider ? { outPath = <sunspider>; }
      , v8 ? { outPath = <v8>; }
      , kraken ? { outPath = <kraken>; }
      }:

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
          schedulingPriority = "10";
        };
      };

    jsIonStats =
      { tarball ? jobs.tarball {}
      , build ? jobs.jsBuild {}
      , system ? builtins.currentSystem
      }:

      let pkgs = import nixpkgs { inherit system; }; in

      pkgs.releaseTools.nixBuild {
        name = "ionmonkey-check";
        src = tarball;
        buildInputs = with pkgs; [ python ];
        dontBuild = true;
        checkPhase = ''
          ensureDir $out
          TZ="US/Pacific" \
          TZDIR="${pkgs.glibc}/share/zoneinfo" \
          IONFLAGS=all \
          python ./js/src/jit-test/jit_test.py --no-progress --tinderbox -f --ion-tbpl -o --no-slow ${build}/bin/js ion 2>&1 | tee $out/log | grep -v 'TEST\|PASS\|FAIL|\--ion'
          cat  > $out/stats.html <<EOF
          <head><title>Compilation stats of IonMonkey</title></head>
          <body>
          <p>Number of compilation failures : $(grep -c "\[Abort\] IM Compilation failed." $out/log)</p>
          <p>Unsupported opcode (sorted):
          <ol>
          $(sed -n "/Unsupported opcode/ { s,(line .*),,; p }" $out/log | sort | uniq -c | sort -nr | sed 's,[^0-9]*\([0-9]\+\).*: \(.*\),<li value=\1>\2,')
          </ol></p>
          <p>Number of GVN congruence : $(grep -c "\[GVN\] marked"  $out/log)</p>
          <p>Number of snapshots : $(grep -c "\[Snapshots\] Assigning snapshot" $out/log)</p>
          <p>Number of bailouts : $(grep -c "\[Bailouts\] Bailing out" $out/log)</p>
          </body>
          EOF
          echo "report stats $out/stats.html" > $out/nix-support/hydra-build-products
        '';
        dontInstall = true;
        dontFixup = true;

        meta = {
          description = "Run test suites to collect compilation stats.";
          schedulingPriority = "50";
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
      { tarball # ? jobs.tarball {}
      , optBuild # ? jobs.jsOptBuildNoMJIT { }
      , system # ? builtins.currentSystem
      }:

      let
        pkgs = import nixpkgs { inherit system; };
        build = jobs.jsSpeedCheckJM {
          inherit tarball system;
          jitTestOpt = args;
        };
      in
      with pkgs.lib;

      pkgs.lib.overrideDerivation build (attrs: {
        name = attrs.name + "-" + name;
      })
    );

  speedTests = with pkgs.lib;
    fold (x: y: x // y) {} (
    flip concatMap [ "eager" "infer" "none" ] (mode:
    flip concatMap [ "off" "pessimistic" "optimistic" ] (gvn:
    flip concatMap [ "off" "on" ] (licm:
    flip concatMap [ "greedy" "lsra" ] (ra:
    flip concatMap [ "on" "off" ] (inline:
    flip map [ "on" "off" ] (osr:
      speedTest mode gvn licm ra inline osr
    )))))));

in
  jobs // speedTests
