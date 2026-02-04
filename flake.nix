{
  description = "Axium - Minimal and private browser built on WebKit WPE with Brave's adblocker";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    webkit = {
      url = "git+https://github.com/WebKit/WebKit?shallow=1";
      flake = false;
    };

    adblock-rust = {
      url = "git+https://github.com/brave/adblock-rust?shallow=1";
      flake = false;
    };

    lvgl-nix.url = "path:/data/Browser/LVGL-Nix";
  };

  outputs = { self, nixpkgs, webkit, adblock-rust, lvgl-nix }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # Optimization defaults
      optDefaults = {
        optimize = true;
        march = "x86-64-v3";
        fastMath = true;
      };

      lvgl = lvgl-nix.lib.mkLvgl (optDefaults // {
        lto = false;  # Can't use LTO - Odin uses GNU ld without LTO plugin
        tinyTtf = false;  # Disable for now - use built-in Montserrat fonts
        odinBindings = true;
        logging = true;  # Enable logging to debug rendering
        logLevel = "INFO";  # TRACE, INFO, WARN, ERROR, USER, NONE
        # Use GLFW + OpenGL for GL context, but SW rendering for widgets
        # This gives us: EGL context for WebKit texture import + working SW widget rendering
        glfw = true;
        x11 = false;
        sdl = false;
        opengl = true;       # LV_USE_OPENGLES = 1 (GL context + texture APIs)
        openglDraw = false;  # LV_USE_DRAW_OPENGLES = 0 (use SW for widget drawing)
        # Theme - uses nix-generated theme
        darkMode = true;
        # customTheme = {};  # Override default theme values here if needed
      });

    in {
      packages.${system} = rec {
        inherit lvgl;

        engine = import ./Engine ({
          inherit pkgs webkit;
          lto = false;  # Skip LTO for WebKit - too memory intensive
        } // optDefaults);

        adblock = import ./Adblock {
          inherit pkgs adblock-rust;
        };

        # Bindings are now included in lvgl/odin/
        browser = import ./Browser {
          inherit pkgs lvgl;
        };

        default = browser;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          odin
          ccache
          gdb
        ];

        inputsFrom = [
          self.packages.${system}.engine
          self.packages.${system}.adblock
        ];
      };
    };
}
