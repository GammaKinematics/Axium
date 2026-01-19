{
  description = "Axium - Personal Chromium Build";

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

      axiumGnFlags = import ./gn-flags.nix;
      customPatches = [
        ./patches/enable-vertical-tabs.patch
      ];

      # Cloud build script
      cloudBuildScript = pkgs.writeShellScriptBin "axium-cloud-build" ''
        set -euo pipefail

        : "''${HCLOUD_TOKEN:?Set HCLOUD_TOKEN}"
        : "''${CACHIX_AUTH_TOKEN:?Set CACHIX_AUTH_TOKEN}"

        REPO_URL="https://github.com/GammaKinematics/Axium.git"
        SERVER_TYPE="''${SERVER_TYPE:-ccx33}"
        SERVER_NAME="axium-builder-$(date +%s)"
        CACHE_NAME="axium"

        log() { echo -e "\033[0;32m[+]\033[0m $1"; }
        warn() { echo -e "\033[1;33m[!]\033[0m $1"; }

        log "Creating Hetzner server: $SERVER_NAME ($SERVER_TYPE)..."
        SERVER_JSON=$(${pkgs.hcloud}/bin/hcloud server create \
          --name "$SERVER_NAME" \
          --type "$SERVER_TYPE" \
          --image ubuntu-24.04 \
          --location hel1 \
          -o json)

        SERVER_ID=$(echo "$SERVER_JSON" | ${pkgs.jq}/bin/jq -r '.server.id')
        SERVER_IP=$(echo "$SERVER_JSON" | ${pkgs.jq}/bin/jq -r '.server.public_net.ipv4.ip')

        log "Server: $SERVER_IP (ID: $SERVER_ID)"
        log "Waiting for SSH..."
        sleep 30

        for i in {1..30}; do
          ${pkgs.openssh}/bin/ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            root@"$SERVER_IP" true 2>/dev/null && break
          sleep 10
        done

        log "Uploading build script..."
        ${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" bash -c "cat > /root/build.sh" <<REMOTE
        #!/usr/bin/env bash
        exec > >(tee /root/build.log) 2>&1

        cleanup() {
          echo "=== Deleting server in 60 seconds... ==="
          sleep 60
          export HCLOUD_TOKEN="$HCLOUD_TOKEN"
          hcloud server delete "$SERVER_ID" --poll-interval 5s
        }

        echo "=== Build started at \$(date) ==="

        # Install Nix
        if ! curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes; then
          echo "FAILED: Nix install" > /root/build.status
          cleanup
          exit 1
        fi
        source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        mkdir -p ~/.config/nix
        echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

        # Install tools
        if ! nix profile install nixpkgs#cachix nixpkgs#git nixpkgs#hcloud; then
          echo "FAILED: Tool install" > /root/build.status
          cleanup
          exit 1
        fi

        # Setup cachix
        cachix authtoken "$CACHIX_AUTH_TOKEN"

        # Clone and build
        if ! git clone "$REPO_URL" /build/axium; then
          echo "FAILED: Git clone" > /root/build.status
          cleanup
          exit 1
        fi
        cd /build/axium
        if ! nix build .#browser --cores 0 -j auto -L; then
          echo "FAILED: Nix build" > /root/build.status
          cleanup
          exit 1
        fi

        # Push to cache
        if ! cachix push "$CACHE_NAME" ./result; then
          echo "FAILED: Cachix push" > /root/build.status
          cleanup
          exit 1
        fi

        echo "=== Build finished at \$(date) ==="
        echo "SUCCESS" > /root/build.status
        cleanup
        REMOTE

        log "Starting detached build..."
        ${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" \
          "chmod +x /root/build.sh && nohup /root/build.sh > /dev/null 2>&1 &"

        log ""
        log "Build running in background on $SERVER_IP"
        log ""
        log "Monitor:  ssh root@$SERVER_IP tail -f /root/build.log"
        log "Status:   ssh root@$SERVER_IP cat /root/build.status"
        log "Server:   https://console.hetzner.cloud/projects -> Servers"
        log ""
        log "Server will self-destruct after build completes."
        log "If build fails, manually delete: hcloud server delete $SERVER_ID"
      '';

    in
    {
      packages.${system} = {
        browser = pkgs.ungoogled-chromium.overrideAttrs (old: {
          pname = "axium";
          patches = old.patches ++ customPatches;
        });

        cloud-build = cloudBuildScript;
        default = self.packages.${system}.browser;
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
          echo "Axium dev shell"
          echo "  nix run .#cloud-build  - Build on Hetzner"
          echo "  nix build .#browser    - Build locally"
          echo ""
          echo "Required env vars for cloud build:"
          echo "  HCLOUD_TOKEN, CACHIX_AUTH_TOKEN, REPO_URL"
        '';
      };

      overlays.default = final: prev: {
        axium = self.packages.${system}.browser;
      };
    };
}
