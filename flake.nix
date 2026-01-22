{
  description = "Axium Engine - De-googled Chromium content/ library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      engineGnFlags = import ./gn-flags-engine.nix;

      enginePatches = [
        ./patches/compiler-optimizations.patch
      ];

    in
    {
      packages.${system} = {
        engine = pkgs.ungoogled-chromium.passthru.mkDerivation (base: {
          packageName = "axium-engine";

          # Only build content/ - no chrome, no shell
          buildTargets = [ "content" ];

          # Ungoogled-chromium patches + ours
          patches = base.patches ++ enginePatches;

          # Engine-specific GN flags
          gnFlags = engineGnFlags;

          # Single output (no sandbox needed for library)
          outputs = [ "out" ];
        });

        default = self.packages.${system}.engine;
      };

      devShells.${system}.default = pkgs.mkShell {
        shellHook = ''
          echo "Axium Engine"
          echo ""
          echo "  nix build  - Build de-googled Chromium content/ library"
        '';
      };
    };
}
