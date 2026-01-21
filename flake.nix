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
        # Service factory stubs
        ./patches/stub-prediction-service.patch
        ./patches/stub-contextual-cueing.patch
        ./patches/stub-google-groups.patch
        ./patches/stub-popular-sites.patch
        ./patches/stub-sync-service.patch
        ./patches/stub-identity-manager.patch
        ./patches/stub-signin-manager.patch
        ./patches/stub-background-download.patch
        ./patches/stub-extension-telemetry.patch
        ./patches/stub-read-anything.patch
        # Hardware API stubs
        ./patches/stub-bluetooth.patch
        ./patches/stub-midi.patch
        # DevTools stub
        ./patches/stub-devtools.patch
      ];

      # Cloud build script - interactive mode
      cloudBuildScript = pkgs.writeShellScriptBin "axium-cloud-build" ''
        set -euo pipefail

        : "''${HCLOUD_TOKEN:?Set HCLOUD_TOKEN}"
        : "''${CACHIX_AUTH_TOKEN:?Set CACHIX_AUTH_TOKEN}"

        REPO_URL="https://github.com/GammaKinematics/Axium.git"
        SERVER_TYPE="''${SERVER_TYPE:-ccx33}"
        SERVER_NAME="axium-builder-$(date +%s)"
        CACHE_NAME="axium"

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
        echo ">>> Installing Nix..."
        curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
        source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        mkdir -p ~/.config/nix
        echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

        echo ">>> Installing tools..."
        nix profile install nixpkgs#cachix nixpkgs#git nixpkgs#hcloud

        echo ">>> Setup complete"
        SETUP

        log "Cloning repository..."
        ${pkgs.openssh}/bin/ssh $SSH_OPTS root@"$SERVER_IP" "source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh && git clone $REPO_URL /build/axium"

        # Save connection info locally
        INFO_FILE="/tmp/axium-build-$$"
        cat > "$INFO_FILE" <<EOF
        SERVER_IP=$SERVER_IP
        SERVER_ID=$SERVER_ID
        CACHE_NAME=$CACHE_NAME
        EOF

        log ""
        log "============================================"
        log "  Server ready: $SERVER_IP"
        log "============================================"
        log ""
        log "Saved to: $INFO_FILE"
        log ""
        warn "MANUAL STEPS:"
        log ""
        log "1. Connect to server:"
        log "   ssh root@$SERVER_IP"
        log ""
        log "2. Start build:"
        log "   cd /build/axium"
        log "   nix build .#browser --cores 0 -j auto -L"
        log ""
        log "3. If build succeeds, push to cache:"
        log "   cachix authtoken \$CACHIX_AUTH_TOKEN"
        log "   cachix push $CACHE_NAME ./result"
        log ""
        log "4. Delete server when done:"
        log "   hcloud server delete $SERVER_ID"
        log ""
        log "============================================"
        log ""

        read -p "Press Enter to SSH into the server (or Ctrl+C to exit)..."
        ${pkgs.openssh}/bin/ssh $SSH_OPTS -t root@"$SERVER_IP" "cd /build/axium && exec bash -l"
      '';

    in
    {
      packages.${system} = {
        # Build browser with custom GN flags and patches
        browser = let
          # Convert our GN flags attrset to string format
          mkGnFlags = attrs: pkgs.lib.concatStringsSep " " (
            pkgs.lib.mapAttrsToList (k: v:
              if builtins.isBool v then "${k}=${if v then "true" else "false"}"
              else if builtins.isInt v then "${k}=${toString v}"
              else "${k}=\"${toString v}\""
            ) attrs
          );

          extraGnFlagsStr = mkGnFlags axiumGnFlags;

          # Override the browser derivation to add our GN flags and patches
          axiumBrowser = pkgs.ungoogled-chromium.passthru.browser.overrideAttrs (old: {
            pname = "axium-browser";

            # Append our patches
            patches = old.patches ++ customPatches;

            # Append our GN flags to the existing gnFlags string
            gnFlags = old.gnFlags + " " + extraGnFlagsStr;
          });

          # Get the sandbox from the build
          axiumSandbox = axiumBrowser.passthru.sandbox or pkgs.ungoogled-chromium.passthru.browser.passthru.sandbox;

        in pkgs.runCommand "axium-${axiumBrowser.version}" {
          inherit (axiumBrowser) version;
          pname = "axium";
          meta = axiumBrowser.meta // {
            mainProgram = "chromium";
          };
          passthru = {
            browser = axiumBrowser;
            sandbox = axiumSandbox;
          };
        } ''
          mkdir -p $out/bin $out/share

          # Link binaries
          for f in ${axiumBrowser}/bin/*; do
            ln -s "$f" $out/bin/
          done

          # Add 'axium' alias
          ln -s chromium $out/bin/axium

          # Copy libexec so we can strip bloat
          if [ -d "${axiumBrowser}/libexec" ]; then
            cp -r ${axiumBrowser}/libexec $out/libexec
            chmod -R u+w $out/libexec

            # Remove inspector overlay (element highlighting) - 77KB
            # NOTE: DevTools frontend is bundled in resources.pak (13MB), can't strip post-build
            rm -rf $out/libexec/chromium/resources/inspector_overlay || true

            # Strip locales - keep only fr.pak
            find $out/libexec/chromium/locales -type f ! -name 'fr.pak' -delete 2>/dev/null || true
            find $out/libexec/chromium/locales -type f -name '*.info' -delete 2>/dev/null || true

            # Remove Vulkan validation layer - debug only (~25MB)
            rm -f $out/libexec/chromium/libVkLayer_khronos_validation.so || true

            # Remove HiDPI resources if not needed (~1.2MB)
            rm -f $out/libexec/chromium/chrome_200_percent.pak || true
          fi

          # Link share
          if [ -d "${axiumBrowser}/share" ]; then
            ln -s ${axiumBrowser}/share $out/share
          fi
        '';

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
          echo "  HCLOUD_TOKEN, CACHIX_AUTH_TOKEN"
        '';
      };

      overlays.default = final: prev: {
        axium = self.packages.${system}.browser;
      };
    };
}
