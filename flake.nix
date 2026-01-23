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

      # Fetch esbuild 0.25.1 binary to match devtools-frontend node_modules
      esbuild-bin = pkgs.fetchurl {
        url = "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.25.1.tgz";
        hash = "sha256-o5csINGVRXkrpsar5WS2HJH2bPokL/m//Z5dWcZUUuU=";
      };

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

          # Symlink esbuild where devtools-frontend expects it
          postPatch = base.postPatch + ''
            mkdir -p third_party/devtools-frontend/src/third_party/esbuild
            tar -xzf ${esbuild-bin} -C third_party/devtools-frontend/src/third_party/esbuild --strip-components=1
            mv third_party/devtools-frontend/src/third_party/esbuild/bin/esbuild third_party/devtools-frontend/src/third_party/esbuild/esbuild
          '';

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
