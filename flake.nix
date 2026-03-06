{
  description = "Axium - Minimal browser engine test harness";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    webkit = {
      url = "git+https://github.com/WebKit/WebKit?ref=refs/tags/wpewebkit-2.51.92&shallow=1";
      flake = false;
    };

    display-onix.url = "path:/data/Browser/Display-Onix";
    bindings-onix = {
      url = "path:/data/Browser/Bindings-Onix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lvgl-onix = {
      url = "path:/data/Browser/LVGL-Onix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    theme-onix.url = "path:/data/Browser/Theme-Onix";
    font-onix.url = "path:/data/Browser/Font-Onix";
    edge-onix.url = "path:/data/Browser/Edge-Onix";

    adblock-rust = {
      url = "path:/data/Browser/adblock-rust";
      flake = false;
    };

    uassets = {
      url = "git+https://github.com/uBlockOrigin/uAssets?shallow=1";
      flake = false;
    };
    ublock = {
      url = "git+https://github.com/gorhill/uBlock?shallow=1";
      flake = false;
    };

    translations = {
      url = "git+file:///data/Browser/translations?submodules=1";
      flake = false;
    };

    translation-models = {
      url = "file+https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/translations-models/records";
      flake = false;
    };

    gstreamer-src = {
      url = "git+https://gitlab.freedesktop.org/gstreamer/gstreamer.git?ref=refs/tags/1.28.1&shallow=1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, webkit, display-onix, bindings-onix, lvgl-onix, theme-onix, font-onix, edge-onix, adblock-rust, uassets, ublock, translations, translation-models, gstreamer-src }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # ─── Static+LTO build options ───
      o3 = true;              # -O3 for all compilations
      march = "x86-64-v3";    # AVX2/BMI2 — or null for baseline x86-64

      # Static+LTO package set (musl + clang + full LTO + optimizations).
      # Follows the Fex pattern: useLLVM gives clang + compiler-rt + lld,
      # crossOverlay injects -flto so all compiled code is LLVM bitcode.
      # WebKit itself uses -DLTO_MODE=thin (too large for full LTO linking).
      pkgsLto = import nixpkgs {
        localSystem = system;
        crossSystem = {
          config = "x86_64-unknown-linux-musl";
          isStatic = true;
          useLLVM = true;
        };
        crossOverlays = [
          (final: prev: {
            # Base opt flags without -flto (for builds that handle LTO themselves, e.g. WebKit cmake)
            stdenvNoLto = prev.stdenvAdapters.withCFlags
              (pkgs.lib.optionals o3 [ "-O3" ]
                ++ pkgs.lib.optionals (march != null) [ "-march=${march}" ])
              prev.stdenv;
            stdenv = prev.stdenvAdapters.withCFlags
              ([ "-flto" ]
                ++ pkgs.lib.optionals o3 [ "-O3" ]
                ++ pkgs.lib.optionals (march != null) [ "-march=${march}" ])
              prev.stdenv;
          })
          # Second overlay: globally disable checks + targeted fixes.
          # Test binaries segfault linking bitcode .o without -flto — tests are
          # useless in this env.
          (final: prev: {
            stdenv = prev.stdenv // {
              mkDerivation = args:
                let
                  inject = a: a // { doCheck = false; doInstallCheck = false; };
                in prev.stdenv.mkDerivation (
                  if builtins.isFunction args then (finalAttrs: inject (args finalAttrs))
                  else inject args
                );
            };
            # Bash 5.3 typedef bool conflicts with clang 21 C23 default.
            # All three bash variants are independent callPackage invocations.
            bashNonInteractive = prev.bashNonInteractive.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                substituteInPlace bashansi.h \
                  --replace-fail 'typedef unsigned char bool;' \
                    '#if __STDC_VERSION__ >= 202311L
  #include <stdbool.h>
#else
  typedef unsigned char bool;
#endif'
              '';
            });
            bash = prev.bash.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                substituteInPlace bashansi.h \
                  --replace-fail 'typedef unsigned char bool;' \
                    '#if __STDC_VERSION__ >= 202311L
  #include <stdbool.h>
#else
  typedef unsigned char bool;
#endif'
              '';
            });
            bashInteractive = prev.bashInteractive.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                substituteInPlace bashansi.h \
                  --replace-fail 'typedef unsigned char bool;' \
                    '#if __STDC_VERSION__ >= 202311L
  #include <stdbool.h>
#else
  typedef unsigned char bool;
#endif'
              '';
            });
            # glib's meson runs cc.run() checks during configure (frexpl, printf).
            # With -flto, some test binaries crash (bitcode issues). Tell meson
            # it can't run host binaries — the gnulib fallback correctly assumes
            # frexpl/printf work on linux.
            glib = prev.glib.overrideAttrs (old: {
              preConfigure = (old.preConfigure or "") + ''
                cat > no-exe-wrapper.txt <<'EOF'
[properties]
needs_exe_wrapper = true
EOF
                mesonFlagsArray+=(--cross-file="$PWD/no-exe-wrapper.txt")
              '';
            });
            # Go segfaults during bootstrap in cross/LTO env — skip it, we don't need captree
            libcap = prev.libcap.override { withGo = false; };
            # wayland tools not needed, pulls unnecessary deps
            libxkbcommon = prev.libxkbcommon.override { withWaylandTools = false; };
            # llvm-strip can't handle LLVM bitcode .o — libvpx Makefile runs $(STRIP) itself
            libvpx = prev.libvpx.overrideAttrs { env.STRIP = "true"; };
            # libglvnd marks isStatic as badPlatform but we need it to satisfy WebKit's
            # unconditional epoxy dependency. GL is never called at runtime; LTO strips it.
            libglvnd = prev.libglvnd.overrideAttrs { meta.badPlatforms = []; };
            # jitterentropy requires -O0 but our -O3 in NIX_CFLAGS_COMPILE overrides it.
            # Jitter RNG is supplementary — /dev/urandom is the primary entropy source.
            libgcrypt = prev.libgcrypt.overrideAttrs (old: {
              configureFlags = (old.configureFlags or []) ++ [ "--disable-jent-support" ];
            });
            # freetype: LLVM cross toolchain exposes windres, which configure detects
            # and then tries to compile ftver.rc (Windows resource) — fails on Linux.
            # Setting RC="" before configure prevents detection. depsBuildBuild provides
            # a native CC that configure needs for build-time tools in cross mode.
            freetype = prev.freetype.overrideAttrs (old: {
              depsBuildBuild = (old.depsBuildBuild or []) ++ [ prev.buildPackages.stdenv.cc ];
              preConfigure = (old.preConfigure or "") + ''
                export RC=""
              '';
            });
          })
        ];
      };

      # ─── Static-independent values ───

      pages = import ./Pages/pages.nix { inherit pkgs; };

      generatedBindings = bindings-onix.lib.generate {
        package = "axium";
        keyboard = [{ backend = "xcb"; }];
        mouse = [{ backend = "xcb"; }];
      };

      lvglBindings = lvgl-onix.lib.bindings { package = "axium"; };

      fontSources = font-onix.lib.sources { package = "axium"; };

      iconFont = font-onix.lib.mkIconFont {
        inherit pkgs;
        font = "${pkgs.font-awesome}/share/fonts/opentype/Font Awesome 7 Free-Solid-900.otf";
        codepoints = [
          "F005"  # STAR
          "F00D"  # CLOSE
          "F013"  # COG (settings)
          "F017"  # CLOCK
          "F019"  # DOWNLOAD
          "F021"  # REFRESH
          "F032"  # BOLD
          "F033"  # ITALIC
          "F04B"  # PLAY
          "F04C"  # PAUSE
          "F04D"  # STOP
          "F053"  # LEFT
          "F054"  # RIGHT
          "F05E"  # BAN
          "F065"  # EXPAND (fullscreen)
          "F067"  # PLUS
          "F074"  # SHUFFLE
          "F084"  # KEY
          "F0C1"  # LINK
          "F0C4"  # CUT
          "F0C5"  # COPY
          "F0C7"  # SAVE
          "F0C9"  # BARS
          "F0CD"  # UNDERLINE
          "F0EA"  # PASTE
          "F1AB"  # TRANSLATE
          "F35D"  # EXTERNAL-LINK-ALT
          "F3ED"  # SHIELD-HALVED
          "F6A9"  # VOLUME-MUTE
          "F6FA"  # MASK (incognito)
        ];
      };

      edgeSources = edge-onix.lib.sources;

      # ─── Dynamic build (default, unchanged) ───

      engine = import ./Engine/engine.nix {
        inherit pkgs webkit pages;
      };

      lvgl = lvgl-onix.lib.mkLvgl {
        hostPkgs = pkgs;
        inherit pkgs;
        widgets = ["button" "label" "textarea" "arc"];
      };

      themeOdin = theme-onix.lib.generate {
        package = "axium";
        theme = lvgl.passthru.theme;
      };

      adblock = import ./Adblock/adblock.nix { inherit pkgs adblock-rust engine uassets ublock; };

      keepass = import ./Keepass/keepass.nix { inherit pkgs; };

      translate = import ./Translate/translate.nix { inherit pkgs translations translation-models; };

      # ─── Static+LTO build ───

      sGstreamer = import ./Engine/gstreamer-full.nix {
        pkgs = pkgsLto; hostPkgs = pkgs;
        inherit gstreamer-src;
      };

      sEngine = import ./Engine/engine.nix {
        pkgs = pkgsLto; hostPkgs = pkgs;
        inherit webkit pages;
        gstreamer = sGstreamer;
        static_lto = true;
      };

      sLvgl = lvgl-onix.lib.mkLvgl {
        hostPkgs = pkgs;
        pkgs = pkgsLto;
        lto = true;
        widgets = ["button" "label" "textarea" "arc"];
      };

      sTranslate = import ./Translate/translate.nix {
        pkgs = pkgsLto; hostPkgs = pkgs;
        inherit translations translation-models;
        static_lto = true;
      };

      sKeepass = import ./Keepass/keepass.nix { pkgs = pkgsLto; };

    in {
      packages.${system} = rec {
        inherit (adblock) lib ext resources;
        inherit (engine) webkit shim pages;
        static-webkit = sEngine.webkit;
        static-gstreamer = sGstreamer;
        translate-lib = translate.lib;

        browser = import ./Browser/browser.nix {
          inherit pkgs engine pages display-onix generatedBindings
                  lvgl lvglBindings themeOdin fontSources iconFont edgeSources
                  adblock keepass translate;
        };

        static = import ./Browser/browser.nix {
          pkgs = pkgsLto;
          hostPkgs = pkgs;
          engine = sEngine;
          gstreamer = sGstreamer;
          inherit pages display-onix generatedBindings
                  lvglBindings fontSources iconFont edgeSources
                  adblock themeOdin;
          lvgl = sLvgl;
          keepass = sKeepass;
          translate = sTranslate;
          inherit o3 march;
          static_lto = true;
        };

        default = browser;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ odin gdb ];
        inputsFrom = [ engine.webkit ];
      };
    };
}
