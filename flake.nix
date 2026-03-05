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

      pages = import ./Pages/pages.nix { inherit pkgs; };

      engine = import ./Engine/engine.nix {
        inherit pkgs webkit pages;
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
        widgets = ["button" "label" "textarea" "arc"];
      };

      lvglBindings = lvgl-onix.lib.bindings { package = "axium"; };

      themeOdin = theme-onix.lib.generate {
        package = "axium";
        theme = lvgl.passthru.theme;
      };

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

      adblock = import ./Adblock/adblock.nix { inherit pkgs adblock-rust engine uassets ublock; };

      keepass = import ./Keepass/keepass.nix { inherit pkgs; };

      translate = import ./Translate/translate.nix { inherit pkgs translations translation-models; };

    in {
      packages.${system} = rec {
        inherit (adblock) lib ext resources;
        inherit (engine) webkit shim pages;
        translate-lib = translate.lib;

        browser = import ./Browser/browser.nix {
          inherit pkgs engine pages display-onix generatedBindings
                  lvgl lvglBindings themeOdin fontSources iconFont edgeSources
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
