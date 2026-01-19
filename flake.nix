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

        log "Uploading build script..."
        ${pkgs.openssh}/bin/ssh $SSH_OPTS root@"$SERVER_IP" bash -c "cat > /root/build.sh" <<REMOTE
        #!/usr/bin/env bash
        set -euxo pipefail

        export HCLOUD_TOKEN="$HCLOUD_TOKEN"
        export CACHIX_AUTH_TOKEN="$CACHIX_AUTH_TOKEN"
        SERVER_ID="$SERVER_ID"
        REPO_URL="$REPO_URL"
        CACHE_NAME="$CACHE_NAME"

        cleanup() {
          echo ""
          echo "=== Self-destructing server in 30 seconds... ==="
          sleep 30
          hcloud server delete "\$SERVER_ID" --poll-interval 5s
        }
        trap cleanup EXIT

        echo "=== Build started at \$(date) ==="

        # Install Nix
        echo ">>> Installing Nix..."
        curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
        source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        mkdir -p ~/.config/nix
        echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

        # Install tools
        echo ">>> Installing tools (cachix, git, hcloud)..."
        nix profile install nixpkgs#cachix nixpkgs#git nixpkgs#hcloud

        # Setup cachix
        echo ">>> Setting up cachix..."
        cachix authtoken "\$CACHIX_AUTH_TOKEN"

        # Clone repo
        echo ">>> Cloning repo..."
        git clone "\$REPO_URL" /build/axium
        cd /build/axium

        # Build
        echo ">>> Starting nix build..."
        nix build .#browser --cores 0 -j auto -L

        # Push to cache
        echo ">>> Pushing to cachix..."
        cachix push "\$CACHE_NAME" ./result

        echo ""
        echo "=== Build finished successfully at \$(date) ==="
        REMOTE

        log "Installing screen and starting build session..."
        ${pkgs.openssh}/bin/ssh $SSH_OPTS root@"$SERVER_IP" "apt-get update -qq && apt-get install -y -qq screen"

        log ""
        log "============================================"
        log "Connecting to build session..."
        log "  - Watch the build progress"
        log "  - Detach: Ctrl+A then D"
        log "  - Reconnect: ssh root@$SERVER_IP screen -r"
        log "  - Server self-destructs when build ends"
        log "============================================"
        log ""

        ${pkgs.openssh}/bin/ssh $SSH_OPTS -t root@"$SERVER_IP" "screen -S build /root/build.sh"
      '';

    in
    {
      packages.${system} = {
        browser = pkgs.ungoogled-chromium.overrideAttrs (old: {
          pname = "axium";
          patches = (old.patches or []) ++ customPatches;
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
