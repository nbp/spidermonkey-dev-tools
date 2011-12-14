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

    jsBuildNoMJIT =
      { tarball ? jobs.tarball {}
      , system ? builtins.currentSystem
      }:

      let pkgs = import nixpkgs { inherit system; }; in
      with pkgs.lib;
      pkgs.releaseTools.nixBuild {
        name = "ionmonkey-no-mjit";
        src = tarball;
        postUnpack = ''
          sourceRoot=$sourceRoot/js/src
          echo Compile in $sourceRoot
        '';
        buildInputs = with pkgs; [ perl python ];
        configureFlags = [ "--enable-debug" "--disable-optimize"
          "--disable-methodjit"
        ];
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

    jsOptBuildNoMJIT =
      { tarball ? jobs.tarball {}
      , system ? builtins.currentSystem
      }:

      let pkgs = import nixpkgs { inherit system; }; in
      let build = jobs.jsBuildNoMJIT { inherit tarball system; }; in
      with pkgs.lib;

      pkgs.lib.overrideDerivation build (attrs: {
        name = "ionmonkey-opt-no-mjit";
        configureFlags = [ "--disable-methodjit" ];
      });

    # jsBuildNoMJIT =
    #   { tarball ? jobs.tarball {}
    #   , system ? builtins.currentSystem
    #   }:

    #   let pkgs = import nixpkgs { inherit system; }; in
    #   let build = jobs.jsBuild { inherit tarball system; }; in
    #   with pkgs.lib;

    #   pkgs.lib.overrideDerivation build (attrs: {
    #     name = "ionmonkey-no-mjit";
    #     configureFlags = attrs.configureFlags ++ [ "--disable-methodjit" ];
    #   });

    jsSpeedCheckInterp =
      { tarball ? jobs.tarball {}
      , optBuild ? jobs.jsOptBuildNoMJIT { }
      , system ? builtins.currentSystem
      , jitTestOpt ? "--args=-n"
      , jitTestSuite ? "sunspider v8"
      }:

      let pkgs = import nixpkgs { inherit system; }; in
      let opts = jitTestOpt; in
      pkgs.releaseTools.nixBuild {
        name = "ionmonkey-speed-check";
        src = tarball;
        buildInputs = with pkgs; [ python glibc ];
        dontBuild = true;
        checkPhase = ''
          ensureDir $out
          export TZ="US/Pacific"
          export TZDIR="${pkgs.glibc}/share/zoneinfo"
          echo ./js/src/jit-test/jit_test.py --no-progress --tinderbox -f --jitflags= ${opts} ${optBuild}/bin/js ${jitTestSuite}
          python ./js/src/jit-test/jit_test.py --no-progress --tinderbox -f --jitflags= ${opts} ${optBuild}/bin/js ${jitTestSuite}
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
      , build ? jobs.jsBuildNoMJIT { }
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
          export TZ="US/Pacific"
          export TZDIR="${pkgs.glibc}/share/zoneinfo"
          export IONFLAGS="all"
          python ./js/src/jit-test/jit_test.py --no-progress --tinderbox -f --ion-tbpl -o --no-slow ${build}/bin/js ion 2>&1 | tee ./log | grep -v 'TEST\|PASS\|FAIL|\--ion'
          cat  > $out/failures.html <<EOF
          <head><title>Compilation stats of IonMonkey</title></head>
          <body>
          <p>Number of compilation failures : $(grep -c "\[Abort\] IM Compilation failed." ./log)</p>
          <p>Unsupported opcode (sorted):
          <ol>
          $(sed -n "/Unsupported opcode/ { s,(line .*),,; p }" ./log | sort | uniq -c | sort -nr | sed 's,[^0-9]*\([0-9]\+\).*: \(.*\),<li value=\1>\2,')
          </ol></p>
          <p>Number of GVN congruence : $(grep -c "\[GVN\] marked"  ./log)</p>
          <p>Number of snapshots : $(grep -c "\[Snapshots\] Assigning snapshot" ./log)</p>
          <p>Number of bailouts : $(grep -c "\[Bailouts\] Bailing out" ./log)</p>
          </body>
          EOF
        '';
        dontInstall = true;
        dontFixup = true;

        meta = {
          description = "Run test suites to collect compilation stats.";
          schedulingPriority = "50";
        };
      };
  };

  speedTest = mode: gvn: licm: ra: inline:
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
      ;

      args = "--ion"
      + optionalString (mode == "eager") " --ion-eager"
      + optionalString (mode == "infer") " -n"
      + " --ion-gvn=${gvn}"
      + " --ion-licm=${licm}"
      + " --ion-regalloc=${ra}"
      + " --ion-inlining=${inline}"
      ;
    in

    setAttrByPath [ ("jsSpeedCheckIon_" + name) ] (
      { tarball ? jobs.tarball {}
      , optBuild ? jobs.jsOptBuildNoMJIT { }
      , system ? builtins.currentSystem
      }:

      let
        pkgs = import nixpkgs { inherit system; };
        build = jobs.jsSpeedCheckInterp {
          inherit tarball system;
          jitTestOpt = "--args='${args}'";
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
    flip map [ "on" "off" ] (inline:
      speedTest mode gvn licm ra inline
    ))))));

in
  jobs // speedTests
