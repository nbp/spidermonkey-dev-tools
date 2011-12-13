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
        configureFlags = [ "--enable-debug" "--disable-optimize" ];
        postInstall = ''
          ./config/nsinstall -t js $out/bin
        '';
        doCheck = false;

        name = "ionmonkey";

        meta = {
          description = "Build JS shell.";
          # Should think about reducing the priority of i686-linux.
          schedulingPriority =
            if system != "armv7l-linux" then "100"
            else "50";
        };
      };

    jsBuildNoMJIT =
      { tarball ? jobs.tarball {}
      , system ? builtins.currentSystem
      }:

      let pkgs = import nixpkgs { inherit system; }; in
      let build = jobs.jsBuild { inherit tarball system; } in
      with pkgs.lib;

      pkgs.lib.overrideDerivation build (attrs: {
        name = "ionmonkey-no-mjit";

        configureFlags = attrs.configureFlags ++ [ "--disable-methodjit" ];

        meta = {
          description = "Build JS shell without methodJit.";
          # Should think about reducing the priority of i686-linux.
          schedulingPriority =
            if system != "armv7l-linux" then "50"
            else "100";
        };
      });

    jsCheck =
      { tarball ? jobs.tarball {}
      , build ? jobs.jsBuildNoJIT { }
      , system ? builtins.currentSystem
      , jitTestOpt ? ""
      , jitTestIM ? true
      }:

      let pkgs = import nixpkgs { inherit system; }; in
      let opts =
        if jitTestIM then "--ion-tbpl ${jitTestOpt}"
        else jitTestOpt;
      in
      pkgs.releaseTools.nixBuild {
        name = "ionmonkey-check";
        src = tarball;
        buildInputs = with pkgs; [ python ];
        dontBuild = true;
        checkPhase = ''
          ensureDir $out
          python ./js/src/jit-test/jit_test.py --no-progress --tinderbox -f ${opts} ${build}/bin/js
        '';
        dontInstall = true;
        dontFixup = true;

        meta = {
          description = "Run test suites.";
          schedulingPriority = if jitTestIM then "50" else "10";
        };
      };

    jsIonStats =
      { tarball ? jobs.tarball {}
      , build ? jobs.jsBuildNoJIT { }
      , system ? builtins.currentSystem
      }:

      let pkgs = import nixpkgs { inherit system; }; in

      pkgs.releaseTools.nixBuild {
        name = "ionmonkey-check";
        src = tarball;
        buildInputs = with pkgs; [ python ];
        dontBuild = true;
        IONFLAGS="all";
        checkPhase = ''
          ensureDir $out
          python ./js/src/jit-test/jit_test.py --no-progress --tinderbox -f --ion-tbpl -o --no-slow ${build}/bin/js 2>&1 | tee ./log | grep TEST-
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
          schedulingPriority = if jitTestIM then "50" else "10";
        };
      };
  };

in
  jobs
