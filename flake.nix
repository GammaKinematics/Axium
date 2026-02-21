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
  };

  outputs = { self, nixpkgs, webkit, display-onix, bindings-onix, lvgl-onix, theme-onix }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      engine = import ./Engine {
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
        displayFormat = "xrgb8888";
        thorvg = false;
        widgets = ["button" "label" "textarea"];
      };

      lvglBindings = lvgl-onix.lib.bindings { package = "axium"; };

      themeOdin = theme-onix.lib.generate {
        package = "axium";
        theme = lvgl.passthru.theme;
      };

      generatedUI = pkgs.writeText "ui.odin" (import ./Browser/UI/ui.nix {});

    in {
      packages.${system} = rec {
        inherit engine;

        browser = import ./Browser {
          inherit pkgs engine display-onix generatedBindings
                  lvgl lvglBindings themeOdin generatedUI;
        };

        default = browser;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ odin gdb ];
        inputsFrom = [ self.packages.${system}.engine ];
      };
    };
}
