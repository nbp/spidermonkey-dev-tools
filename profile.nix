let
  nixpkgs = /etc/nixos/nixpkgs;
  defaultPkgs = import nixpkgs {};
  lib = defaultPkgs.lib;

  getBuildDrv = drv : if (builtins.isAttrs drv && drv ? buildDrv) then drv.buildDrv else drv;
  getHostDrv = drv : if (builtins.isAttrs drv && drv ? hostDrv) then drv.hostDrv else drv;

  variations = with lib; {

  envVariations = {
    env = {config, ...}: {
      key = "env";
      options = {
        basename = mkOption {
          default = "profile";
          type = with types; string;
        };
        name = mkOption {
          default = "";
          type = with types; string;
        };
        paths = mkOption {
          default = [];
          type = with types; listOf package;
        };
        links = mkOption {
          default = [];
          type = with types; listOf package;
        };
        pkgs = mkOption {
          type = with types; attrsOf inferred;
        };
        result = mkOption {
          type = with types; package;
        };
      };

      config = {
        result = config.pkgs.buildEnv {
          ignoreCollisions = true;
          pathsToLink = ["/"];
          paths = map getBuildDrv config.paths
          ++ map getHostDrv config.links;
          name = config.basename + config.name;
        };
      };
    };
  };

  sourceVariations = {
    source = {config, ...}: {
      key = "source";
      options = {
        nixpkgs = mkOption {
          default = "/etc/nixos/nixpkgs";
          type = with types; string;
        };
        system = mkOption {
          default = builtins.currentSystem;
          type = with types; string;
        };
        crossSystem = mkOption {
          default = null;
          type = with types; nullOr attrs;
        };
      };
      config = {
        pkgs = import config.nixpkgs {
          inherit (config) system crossSystem;
        };
      };
    };
  };

  archVariations = {
    x64 = {
      key = "x64";
      name = "-x64";
      system = "x86_64-linux";
    };
    x86 = {
      key = "x86";
      name = "-x86";
      system = "i686-linux";
    };
/*
    arm = {
      key = "arm";
      name = "-arm";
      # Cross compile to arm.
      system = "x86_64-linux";
      crossSystem = {
        config = "armv7l-unknown-linux-gnueabi";  
        bigEndian = false;
        arch = "arm";
        float = "soft";
        withTLS = true;
        libc = "glibc";
        platform = defaultPkgs.platforms.sheevaplug;
        openssl.system = "linux-generic32";
      };
    };
*/
  };

  gccVariations = {
    gcc46 = {config, ...}: {
      key = "gcc46";
      name = "-gcc46";
      gcc = config.pkgs.gcc46;
    };
    gcc45 = {config, ...}: {
      key = "gcc45";
      name = "-gcc45";
      gcc = config.pkgs.gcc45;
    };
/*
    gcc44 = {config, ...}: {
      key = "gcc44";
      name = "-gcc44";
      gcc = config.pkgs.gcc44;
    };
    gcc43 = {config, ...}: {
      key = "gcc43";
      name = "-gcc43";
      gcc = config.pkgs.gcc43;
    };
*/
    gcc42 = {config, ...}: {
      key = "gcc42";
      name = "-gcc42";
      gcc = config.pkgs.gcc42;
    };
/*
    gcc295 = {config, ...}: {
      key = "gcc295";
      name = "-gcc295";
      gcc = config.pkgs.gcc295;
    };
*/
  };

  restVariations = {
    rest = {config, ...}: {
      key = "rest";
      options = {
        gcc = mkOption {
          type = with types; package;
        };
      };
      config = {
        paths = with config.pkgs; [

          autoconf213 automake bash bc config.gcc.binutils cairo ccache
          colordiff config.gcc.coreutils curl cvs dbus dbus_glib gtkLibs.atk
          diffstat diffutils doxygen file findutils flex fontconfig freetype
          gamin gawk gnome.GConf /*gdb*/ gtkLibs.gdk_pixbuf getopt gettext
          ghostscript config.gcc config.gcc.libc gnome.glib gnome.gnome_vfs
          gnugrep gnum4 gnumake gnupatch gnuplot gnused gnutar graphviz
          gtkLibs.gtk gzip help2man imagemagick /* inkscape */

          gnome.libart_lgpl gnome.libbonobo gnome.libbonoboui libelf
          gnome.libgnome gnome.libgnomecanvas gnome.libgnomeui xlibs.libICE
          gnome.libIDL libnih libnotify libpng xlibs.libSM libsmbios libusb
          xlibs.libX11 xlibs.libXau xlibs.libxcb xlibs.libXdmcp xlibs.libXext
          libxml2 libxslt xlibs.libXt libyaml man mercurial mesa /*nspr*/ nss
          gnome.ORBit2 ortp gtkLibs.pango pciutils pcre perl pkgconfig
          /*pmutils*/ policykit popt postfix xlibs.printproto procps python27
          docutils pythonPackages.pyyaml xlibs.renderproto /*rlwrap*/ /*rsync*/
          socat sqlite /*strace*/ time udev /*usbutils*/ wget which
          xlibs.xextproto xlibs.xproto yasm

          /* Needed by the browser */
          alsaLib
          xlibs.libXrender 
          zlib

          /* Needed for building with --enable-valgrind */
          valgrind

          /* Needed for checking firefox mochitests */
          python.modules.sqlite3

          /* For optimized builds? */
          pythonPackages.simplejson
        ];

        links = [
        ];
      };
    };
  };

};

  evalVariant = variant: rec {
    # These are the extra arguments passed to every module.  In
    # particular, Nixpkgs is passed through the "pkgs" argument.
    extraArgs = { inherit lib variant; };

    # Merge the option definitions in all modules, forming the full
    # system configuration.  It's not checked for undeclared options.
    buildVariant = lib.fixMergeModules variant extraArgs;

    buildDefinitions = buildVariant.config;
    buildDeclarations = buildVariant.options;
    inherit (buildVariant) options;

    # Optionally check wether all config values have corresponding
    # option declarations.
    config =
      # assert pkgs.lib.checkModule "" buildVariant;
      buildVariant.config;
  };

  join = xll: yll: with lib;
    if yll == [] || xll == [] then [] else
      concatMap (xl:
        map (yl:
          xl ++ yl
        ) yll
      ) xll
  ;

  joins = ll: with lib;
    fold (xl: yl: join (map (x: [x]) xl) yl) [[]] ll;

  produceVariants = with lib;
    joins (map attrValues (attrValues variations));

  buildVariants = with lib;
    map (x: (evalVariant x).config.result) produceVariants;
in
  with lib;
  buildVariants
