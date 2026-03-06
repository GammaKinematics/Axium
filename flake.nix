{
  description = "Axium - Minimal browser engine test harness";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    webkit = {
      url = "git+https://github.com/WebKit/WebKit?shallow=1";
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
  };

  outputs = { self, nixpkgs, webkit, display-onix, bindings-onix, lvgl-onix, theme-onix, font-onix, edge-onix, adblock-rust, uassets, ublock, translations, translation-models }:
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
        # Many packages mark isStatic as badPlatform (dlopen-based).
        # We only need them as build deps — allow them all.
        config.allowUnsupportedSystem = true;
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
            # Test binaries segfault linking bitcode .o without -flto at link time
            zlib = prev.zlib.overrideAttrs { doCheck = false; };
            brotli = prev.brotli.overrideAttrs { doCheck = false; };
            bzip2 = prev.bzip2.overrideAttrs { doCheck = false; };
            libpng = prev.libpng.overrideAttrs { doCheck = false; doInstallCheck = false; };
            libxkbcommon = (prev.libxkbcommon.override {
              withWaylandTools = false;
            }).overrideAttrs { doCheck = false; };
            # Go segfaults during bootstrap in cross/LTO env — skip it, we don't need captree
            libcap = prev.libcap.override { withGo = false; };
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

      sEngine = import ./Engine/engine.nix {
        pkgs = pkgsLto; hostPkgs = pkgs;
        inherit webkit pages;
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
