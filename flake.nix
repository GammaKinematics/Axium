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

      engine = import ./Engine/engine.nix {
        inherit pkgs webkit;
        optimize = false;
        march = null;
        fastMath = false;
        lto = false;
      };

      generatedBindings = bindings-onix.lib.generate {
        package = "axium";
        keyboard = [{ backend = "xcb"; }];
        mouse = [{ backend = "xcb"; }];
      };

      lvgl = lvgl-onix.lib.mkLvgl {
        hostPkgs = pkgs;
        inherit pkgs;
        widgets = ["button" "label" "textarea"];
        iconCodes = [
          "F00D"  # CLOSE
          "F021"  # REFRESH
          "F053"  # LEFT
          "F054"  # RIGHT
          "F05E"  # BAN
          "F067"  # PLUS
          "F074"  # RANDOM/SHUFFLE
          "F084"  # KEY
          "F0C5"  # COPY
          "F0C7"  # SAVE
          "F0C9"  # BARS
          "F1AB"  # TRANSLATE
          "F3ED"  # SHIELD-HALVED
        ];
        iconSizes = [ 14 ];
      };

      lvglBindings = lvgl-onix.lib.bindings { package = "axium"; };

      themeOdin = theme-onix.lib.generate {
        package = "axium";
        theme = lvgl.passthru.theme;
      };

      fontOdin = font-onix.lib.generate {
        package = "axium";
        font = { name = "sans-serif"; path = ""; sizes = { base = 14; }; };
      };

      edgeSources = edge-onix.lib.sources;

      adblock = import ./Adblock/adblock.nix { inherit pkgs adblock-rust engine uassets ublock; };

      keepass = import ./Keepass/keepass.nix { inherit pkgs; };

      translate = import ./Translate/translate.nix { inherit pkgs translations translation-models; };

    in {
      packages.${system} = rec {
        inherit (adblock) lib ext resources;
        inherit (engine) webkit shim;
        translate-lib = translate.lib;

        browser = import ./Browser/browser.nix {
          inherit pkgs engine display-onix generatedBindings
                  lvgl lvglBindings themeOdin fontOdin font-onix edgeSources
                  adblock keepass translate;
        };

        default = browser;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ odin gdb ];
        inputsFrom = [ engine.webkit ];
      };
    };
}
