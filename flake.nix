{
  description = "Axium Engine - De-googled Chromium content/ library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  nixConfig = {
    extra-substituters = [ "https://axium.cachix.org" ];
    extra-trusted-public-keys = [ "axium.cachix.org-1:BfzPfRTbbCYmaQrVLSWchgsR4ScA9ZCZ389FyWspUH8=" ];
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      engineGnFlags = import ./gn-flags.nix;

      enginePatches = [
        ./patches/compiler-optimizations.patch
        ./patches/disable-guest-view-assert.patch
      ];

      # Fetch esbuild 0.25.1 binary to match devtools-frontend node_modules
      # (Commented out - devtools frontend disabled)
      # esbuild-bin = pkgs.fetchurl {
      #   url = "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.25.1.tgz";
      #   hash = "sha256-o5csINGVRXkrpsar5WS2HJH2bPokL/m//Z5dWcZUUuU=";
      # };

      # Local build server configuration
      buildServer = "lebowski@192.168.2.26";
      buildDir = "/home/lebowski/axium-engine";
      repoUrl = "https://github.com/GammaKinematics/Axium-Engine.git";

      # Build script for local build server
      buildScript = pkgs.writeShellScriptBin "axium-build" ''
        set -euo pipefail

        SERVER="${buildServer}"
        BUILD_DIR="${buildDir}"
        REPO_URL="${repoUrl}"
        BRANCH="''${1:-stripped-engine}"

        log() { echo -e "\033[0;32m[+]\033[0m $1"; }
        err() { echo -e "\033[0;31m[!]\033[0m $1"; }

        log "Axium Engine Build"
        log "Server: $SERVER"
        log "Branch: $BRANCH"
        echo ""

        # Check SSH connectivity
        log "Checking SSH connection..."
        if ! ${pkgs.openssh}/bin/ssh -o ConnectTimeout=5 "$SERVER" true 2>/dev/null; then
          err "Cannot connect to $SERVER"
          exit 1
        fi

        # Clone or update repo
        log "Fetching source from git..."
        ${pkgs.openssh}/bin/ssh "$SERVER" bash <<REMOTE
set -euo pipefail
if [ -d "$BUILD_DIR/.git" ]; then
  cd "$BUILD_DIR"
  git fetch origin
  git checkout "$BRANCH"
  git reset --hard "origin/$BRANCH"
else
  rm -rf "$BUILD_DIR"
  git clone -b "$BRANCH" "$REPO_URL" "$BUILD_DIR"
fi
REMOTE

        # Kill existing build session if any
        ${pkgs.openssh}/bin/ssh "$SERVER" "tmux kill-session -t axium-build 2>/dev/null || true"

        # Start build in tmux
        log "Starting build..."
        ${pkgs.openssh}/bin/ssh "$SERVER" "tmux new-session -d -s axium-build 'cd $BUILD_DIR && nix build .#engine --cores 0 -j auto -L --log-format bar-with-logs 2>&1 | stdbuf -oL tee build.log; echo; echo Build finished - press enter to close; read'"

        echo ""
        log "============================================"
        log "  BUILD STARTED"
        log "============================================"
        echo ""
        log "Attach:  ssh -t $SERVER tmux attach -t axium-build"
        log "Logs:    ssh $SERVER tail -f $BUILD_DIR/build.log"
        log "Kill:    ssh $SERVER tmux kill-session -t axium-build"
        echo ""

        read -p "Press Enter to attach to build session (Ctrl+C to exit)..."
        ${pkgs.openssh}/bin/ssh -t "$SERVER" "tmux attach -t axium-build"
      '';

    in
    {
      packages.${system} = {
        engine = pkgs.ungoogled-chromium.passthru.mkDerivation (base: {
          packageName = "axium-engine";

          # Only build content/ - no chrome, no shell
          # Build content library and resource packs
          buildTargets = [
            "content"
            "content:content_resources"
            "third_party/blink/public:resources"
            "ui/resources:ui_resources_grd"
          ];

          # Ungoogled-chromium patches + ours
          patches = base.patches ++ enginePatches;

          # Engine-specific GN flags
          gnFlags = engineGnFlags;

          # Symlink esbuild where devtools-frontend expects it
          # (Commented out - devtools frontend disabled)
          # postPatch = base.postPatch + ''
          #   mkdir -p third_party/devtools-frontend/src/third_party/esbuild
          #   tar -xzf ${esbuild-bin} -C third_party/devtools-frontend/src/third_party/esbuild --strip-components=1
          #   mv third_party/devtools-frontend/src/third_party/esbuild/bin/esbuild third_party/devtools-frontend/src/third_party/esbuild/esbuild
          # '';

          # Single output (no sandbox needed for library)
          outputs = [ "out" ];

          # Custom install phase for engine library output
          installPhase = ''
            runHook preInstall

            mkdir -p $out/{lib,include,share/axium-engine}

            # === Static Archive ===
            echo "Creating static archive from object files..."
            find out/Release/obj -name "*.o" -type f > /tmp/objects.txt
            echo "Found $(wc -l < /tmp/objects.txt) object files"
            ar rcs $out/lib/libaxium-engine.a @/tmp/objects.txt

            # === Source Headers ===
            echo "Copying source headers..."
            for dir in \
              base \
              build \
              cc \
              components \
              content \
              crypto \
              device \
              gin \
              gpu \
              ipc \
              media \
              mojo \
              net \
              sandbox \
              services \
              skia \
              storage \
              ui \
              url \
              v8 \
              third_party/abseil-cpp \
              third_party/blink/public \
              third_party/perfetto/include
            do
              if [ -d "$dir" ]; then
                find "$dir" -name "*.h" -type f | while read -r header; do
                  target="$out/include/$header"
                  mkdir -p "$(dirname "$target")"
                  cp "$header" "$target"
                done
              fi
            done

            # === Generated Headers ===
            echo "Copying generated headers from out/Release/gen/..."
            if [ -d "out/Release/gen" ]; then
              find out/Release/gen -name "*.h" -type f | while read -r header; do
                # Strip out/Release/gen/ prefix
                rel_path="''${header#out/Release/gen/}"
                target="$out/include/$rel_path"
                mkdir -p "$(dirname "$target")"
                cp "$header" "$target"
              done
            fi

            # === Resources ===
            echo "Copying resources..."
            cp out/Release/*.pak $out/share/axium-engine/ 2>/dev/null || true
            cp out/Release/icudtl.dat $out/share/axium-engine/ 2>/dev/null || true
            cp -r out/Release/locales $out/share/axium-engine/ 2>/dev/null || true
            cp out/Release/*.bin $out/share/axium-engine/ 2>/dev/null || true

            echo "=== Engine install complete ==="
            echo "Library:   $out/lib/libaxium-engine.a"
            echo "Headers:   $out/include/"
            echo "Resources: $out/share/axium-engine/"

            runHook postInstall
          '';

          # Override postFixup - base chromium tries to patchelf binaries that don't exist for library build
          postFixup = ''
            echo "Skipping postFixup binary patching (library build)"
          '';
        });

        build = buildScript;
        default = self.packages.${system}.engine;
      };

      apps.${system} = {
        build = {
          type = "app";
          program = "${buildScript}/bin/axium-build";
        };
        default = self.apps.${system}.build;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          openssh
          tmux
        ];

        shellHook = ''
          echo "Axium Engine (stripped)"
          echo ""
          echo "  nix run                - Build on server (stripped-engine branch)"
          echo "  nix run .#build main   - Build specific branch"
          echo "  nix build              - Build locally"
          echo ""
        '';
      };
    };
}
