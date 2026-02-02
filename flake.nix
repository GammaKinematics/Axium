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
  };

  outputs = { self, nixpkgs, webkit, adblock-rust }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      packages.${system} = rec {
        engine = import ./Engine {
          inherit pkgs webkit;
        };

        adblock = import ./Adblock {
          inherit pkgs adblock-rust;
        };

        browser = import ./Browser {
          inherit pkgs engine adblock;
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
