{
  description = "Axium - Minimal browser engine test harness";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

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

    webkit = {
      url = "git+https://github.com/WebKit/WebKit?shallow=1";
      flake = false;
    };

    gstreamer-src = {
      url = "git+https://gitlab.freedesktop.org/gstreamer/gstreamer.git?ref=refs/tags/1.28.1&shallow=1";
      flake = false;
    };

    adblock-rust = {
      url = "git+https://github.com/brave/adblock-rust?shallow=1";
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

  outputs = { self, nixpkgs, webkit, display-onix, bindings-onix, lvgl-onix, theme-onix, font-onix, edge-onix, adblock-rust, uassets, ublock, translations, translation-models, gstreamer-src }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      pkgsLto = import ./cross.nix { inherit nixpkgs system; };

      # ─── Configuration ───

      backends = ["x11"];   # display server backends: "x11", "wayland"
      gpu = true;           # GPU compositing (EGL/GL)

      # ─── Shared (same for all build variants) ───

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

      # ─── Parametric build ───

      mkBuild = { static ? false }:
        let
          buildPkgs = if static then pkgsLto else pkgs;
          hostPkgs = pkgs;
          needsDetour = gpu && static;

          gstreamer = if static then import ./Engine/gstreamer-full.nix {
            pkgs = buildPkgs; inherit hostPkgs gstreamer-src;
          } else null;

          engine = import ./Engine/engine.nix {
            pkgs = buildPkgs;
            inherit hostPkgs webkit pages static;
            gpu = if static then false else gpu;
            gstreamer = if static then gstreamer else null;
          };

          lvgl = lvgl-onix.lib.mkLvgl {
            pkgs = buildPkgs;
            inherit hostPkgs gpu static;
            widgets = ["button" "label" "textarea" "arc"];
          };

          themeOdin = theme-onix.lib.generate {
            package = "axium";
            theme = lvgl.theme;
          };

          adblock = import ./Adblock/adblock.nix {
            pkgs = buildPkgs;
            inherit hostPkgs adblock-rust engine uassets ublock static;
          };

          keepass = import ./Keepass/keepass.nix { pkgs = buildPkgs; };

          translate = import ./Translate/translate.nix {
            pkgs = buildPkgs;
            inherit hostPkgs translations translation-models;
          };

          display = display-onix.lib.mkDisplay {
            package = "axium";
            pkgs = buildPkgs;
            inherit backends gpu;
            detour = needsDetour;
          };

          detour = if needsDetour then display-onix.lib.mkDetour {
            inherit hostPkgs;
            pkgs = buildPkgs;
            lto = static;
          } else null;

        in {
          browser = import ./Browser/browser.nix {
            pkgs = buildPkgs;
            inherit hostPkgs engine pages generatedBindings
                    lvgl lvglBindings themeOdin fontSources iconFont edgeSources
                    adblock keepass translate
                    display detour static;
          };
          inherit engine lvgl adblock keepass translate gstreamer display detour;
        };

      dynamicBuild = mkBuild {};
      staticBuild = mkBuild { static = true; };

    in {
      packages.${system} = rec {
        dynamic = dynamicBuild.browser;
        static = staticBuild.browser;
        default = dynamic;

        # Debug outputs
        inherit (dynamicBuild.engine) shim pages;
        dynamic-webkit = dynamicBuild.engine.webkit;
        inherit (dynamicBuild.adblock) lib resources;
        translate-lib = dynamicBuild.translate.lib;
        static-webkit = staticBuild.engine.webkit;
        static-adblock-lib = staticBuild.adblock.lib;
        static-gstreamer = staticBuild.gstreamer.drv;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          odin gdb strace ltrace valgrind
          binutils elfutils patchelf        # readelf, nm, strings, objdump, ar
          llvmPackages.bintools-unwrapped   # llvm-nm, llvm-objdump, llvm-readelf, llvm-ar
          llvmPackages.libllvm              # llvm-dis, llvm-bcanalyzer, opt, llvm-lto
          pkg-config cmake ninja meson
          nix-tree nix-diff
        ];
        inputsFrom = [ dynamicBuild.engine.webkit ];
      };
    };
}
