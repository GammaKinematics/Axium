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
        SERVER_NAME="axium-builder-$$"
        CACHE_NAME="axium"

        log() { echo -e "\033[0;32m[+]\033[0m $1"; }
        warn() { echo -e "\033[1;33m[!]\033[0m $1"; }

        cleanup() {
          if [[ -n "''${SERVER_ID:-}" ]]; then
            warn "Destroying server $SERVER_NAME..."
            ${pkgs.hcloud}/bin/hcloud server delete "$SERVER_ID" || true
          fi
        }
        trap cleanup EXIT

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

        log "Running build on remote..."
        ${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" bash <<REMOTE
        set -euxo pipefail
        curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
        source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        mkdir -p ~/.config/nix
        echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
        nix profile install nixpkgs#cachix nixpkgs#git
        cachix authtoken "$CACHIX_AUTH_TOKEN"
        git clone "$REPO_URL" /build/axium
        cd /build/axium
        nix build .#browser --cores 0 -j auto -L
        cachix push "$CACHE_NAME" ./result
        REMOTE

        log "Done! Cached at https://axium.cachix.org"
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
