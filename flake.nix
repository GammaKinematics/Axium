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

      engineGnFlags = import ./gn-flags-engine.nix;

      enginePatches = [
        ./patches/compiler-optimizations.patch
      ];

      # Fetch esbuild 0.25.1 binary to match devtools-frontend node_modules
      esbuild-bin = pkgs.fetchurl {
        url = "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.25.1.tgz";
        hash = "sha256-o5csINGVRXkrpsar5WS2HJH2bPokL/m//Z5dWcZUUuU=";
      };

      # Cloud build script - autonomous with tmux for monitoring
      cloudBuildScript = pkgs.writeShellScriptBin "axium-cloud-build" ''
        set -euo pipefail

        : "''${HCLOUD_TOKEN:?Set HCLOUD_TOKEN}"
        : "''${CACHIX_AUTH_TOKEN:?Set CACHIX_AUTH_TOKEN}"

        REPO_URL="https://github.com/GammaKinematics/Axium.git"
        REPO_BRANCH="axium-engine"
        SERVER_TYPE="''${SERVER_TYPE:-ccx33}"
        SERVER_NAME="axium-engine-builder-$(date +%s)"

        log() { echo -e "\033[0;32m[+]\033[0m $1"; }
        warn() { echo -e "\033[0;33m[!]\033[0m $1"; }

        log "Creating Hetzner server: $SERVER_NAME ($SERVER_TYPE)..."
        SERVER_JSON=$(${pkgs.hcloud}/bin/hcloud server create \
          --name "$SERVER_NAME" \
          --type "$SERVER_TYPE" \
          --image ubuntu-24.04 \
          --location hel1 \
          --ssh-key V3 \
          -o json)

        SERVER_ID=$(echo "$SERVER_JSON" | ${pkgs.jq}/bin/jq -r '.server.id')
        SERVER_IP=$(echo "$SERVER_JSON" | ${pkgs.jq}/bin/jq -r '.server.public_net.ipv4.ip')

        log "Server: $SERVER_IP (ID: $SERVER_ID)"
        log "Waiting for SSH..."
        sleep 30

        for i in {1..30}; do
          ${pkgs.openssh}/bin/ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$SERVER_IP" true 2>/dev/null && break
          sleep 10
        done

        SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

        log "Installing Nix on remote server..."
        ${pkgs.openssh}/bin/ssh $SSH_OPTS root@"$SERVER_IP" bash <<'SETUP'
set -euo pipefail
curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
nix profile install nixpkgs#cachix nixpkgs#git nixpkgs#tmux nixpkgs#hcloud
SETUP

        log "Cloning repository (branch: $REPO_BRANCH)..."
        ${pkgs.openssh}/bin/ssh $SSH_OPTS root@"$SERVER_IP" "source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh && git clone -b $REPO_BRANCH $REPO_URL /build/axium-engine"

        # Create the build script on the remote server
        ${pkgs.openssh}/bin/ssh $SSH_OPTS root@"$SERVER_IP" "cat > /build/run-build.sh" <<BUILDSCRIPT
#!/usr/bin/env bash
set -euo pipefail
source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
cd /build/axium-engine

export HCLOUD_TOKEN="''${HCLOUD_TOKEN}"
export CACHIX_AUTH_TOKEN="''${CACHIX_AUTH_TOKEN}"

echo ""
echo "=========================================="
echo "  AXIUM ENGINE BUILD"
echo "=========================================="
echo ""
echo "Build started at \$(date)"
echo "Building: content/ library"
echo ""

if nix build .#engine --cores 0 -j auto -L 2>&1 | tee build.log; then
    echo ""
    echo "=========================================="
    echo "  BUILD SUCCEEDED"
    echo "=========================================="
    echo ""
    echo "Pushing to cachix..."
    cachix authtoken "\$CACHIX_AUTH_TOKEN"
    if cachix push axium ./result; then
        echo "Cachix push complete!"
    else
        echo "Cachix push failed!"
    fi
else
    echo ""
    echo "=========================================="
    echo "  BUILD FAILED"
    echo "=========================================="
fi

echo ""
echo "Build finished at \$(date)"
BUILDSCRIPT
        ${pkgs.openssh}/bin/ssh $SSH_OPTS root@"$SERVER_IP" chmod +x /build/run-build.sh

        log ""
        log "============================================"
        log "  SERVER READY - STARTING BUILD"
        log "============================================"
        log ""
        log "Server: $SERVER_IP (ID: $SERVER_ID)"
        log ""
        log "Build will run in tmux. On success: pushes to cachix"
        log "Delete server manually when done: hcloud server delete $SERVER_ID"
        log ""
        warn "TIPS:"
        log "  - Ctrl+B [ to scroll/pause output, q to resume"
        log "  - Ctrl+B D to detach (build continues)"
        log "  - To resume: ssh -t root@$SERVER_IP tmux attach -t build"
        log ""
        log "============================================"
        log ""

        read -p "Press Enter to SSH and start the build (or Ctrl+C to exit)..."
        ${pkgs.openssh}/bin/ssh $SSH_OPTS -t root@"$SERVER_IP" "tmux new -s build /build/run-build.sh"
      '';

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

          # Custom install phase for engine library output
          installPhase = ''
            runHook preInstall

            mkdir -p $out/{lib,include,share/axium-engine}

            # === Static Archive ===
            echo "Creating static archive from object files..."
            find out/Release/obj -name "*.o" -type f > /tmp/objects.txt
            echo "Found $(wc -l < /tmp/objects.txt) object files"
            ar rcs $out/lib/libaxium-engine.a @/tmp/objects.txt

            # === Headers ===
            echo "Copying headers..."
            # Copy all headers - can strip down later
            for dir in \
              base \
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
        });

        cloud-build = cloudBuildScript;
        default = self.packages.${system}.engine;
      };

      apps.${system} = {
        cloud-build = {
          type = "app";
          program = "${cloudBuildScript}/bin/axium-cloud-build";
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          hcloud
          cachix
          jq
          openssh
        ];

        shellHook = ''
          echo "Axium Engine"
          echo ""
          echo "  nix build              - Build locally"
          echo "  nix run .#cloud-build  - Build on Hetzner"
          echo ""
          echo "Required env vars for cloud build:"
          echo "  HCLOUD_TOKEN, CACHIX_AUTH_TOKEN"
        '';
      };
    };
}
