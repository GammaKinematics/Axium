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
        ./patches/compiler-optimizations.patch
        ./patches/disable-default-browser-prompt.patch
      ];

      # Cloud build script - autonomous with tmux for monitoring
      cloudBuildScript = pkgs.writeShellScriptBin "axium-cloud-build" ''
        set -euo pipefail

        : "''${HCLOUD_TOKEN:?Set HCLOUD_TOKEN}"
        : "''${CACHIX_AUTH_TOKEN:?Set CACHIX_AUTH_TOKEN}"

        REPO_URL="https://github.com/GammaKinematics/Axium.git"
        SERVER_TYPE="''${SERVER_TYPE:-ccx33}"
        SERVER_NAME="axium-builder-$(date +%s)"

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

        log "Cloning repository..."
        ${pkgs.openssh}/bin/ssh $SSH_OPTS root@"$SERVER_IP" "source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh && git clone $REPO_URL /build/axium"

        # Create the build script on the remote server
        ${pkgs.openssh}/bin/ssh $SSH_OPTS root@"$SERVER_IP" cat > /build/run-build.sh <<BUILDSCRIPT
#!/usr/bin/env bash
set -euo pipefail
source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
cd /build/axium

export HCLOUD_TOKEN="''${HCLOUD_TOKEN}"
export CACHIX_AUTH_TOKEN="''${CACHIX_AUTH_TOKEN}"
SERVER_ID="''${SERVER_ID}"

echo ""
echo "=========================================="
echo "  AXIUM BUILD - AUTONOMOUS MODE"
echo "=========================================="
echo ""
echo "Build started at \$(date)"
echo "Server will self-destruct when done."
echo ""

if nix build .#browser --cores 0 -j auto -L 2>&1 | tee build.log; then
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
echo "Deleting server in 30 seconds... (Ctrl+C to cancel)"
sleep 30
hcloud server delete "\$SERVER_ID" --yes
BUILDSCRIPT
        ${pkgs.openssh}/bin/ssh $SSH_OPTS root@"$SERVER_IP" chmod +x /build/run-build.sh

        log ""
        log "============================================"
        log "  SERVER READY - STARTING BUILD"
        log "============================================"
        log ""
        log "Server: $SERVER_IP (ID: $SERVER_ID)"
        log ""
        log "Build will run in tmux. When complete:"
        log "  - On success: pushes to cachix"
        log "  - Then: server self-destructs (30s delay)"
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

      # Runtime libraries needed by Chromium (mirrors nixpkgs)
      runtimeLibs = with pkgs; [
        libva        # Hardware video acceleration
        pipewire     # Audio
        wayland      # Wayland support
        gtk3         # GTK3 integration
        gtk4         # GTK4 integration
        libkrb5      # Kerberos authentication
      ];

      # XDG data directories for desktop integration
      xdgDataDirs = with pkgs; [
        cups
        gtk3
        gtk4
        adwaita-icon-theme
        hicolor-icon-theme
        gsettings-desktop-schemas
      ];

    in
    {
      packages.${system} = {
        # Build browser with custom GN flags and patches using mkDerivation
        browser = let
          # Use mkDerivation to properly pass GN flags as attrset (gets merged with base)
          axiumBrowser = pkgs.ungoogled-chromium.passthru.mkDerivation (base: {
            packageName = "axium-browser";

            # IMPORTANT: Explicitly set outputs to include sandbox
            # (mkDerivation doesn't inherit this from base automatically)
            outputs = [ "out" "sandbox" ];

            # Add our patches on top of ungoogled-chromium patches
            patches = base.patches ++ customPatches;

            # Pass GN flags as attrset - mkDerivation merges with base flags
            # Our flags override base flags due to attrset merge behavior
            gnFlags = axiumGnFlags;

            # Keep same build targets
            buildTargets = base.buildTargets or [ "chrome" "chrome_sandbox" ];
          });

          # Sandbox executable name (matches nixpkgs)
          sandboxExecutableName = "__chromium-suid-sandbox";

          # Library path for runtime dependencies
          libPath = pkgs.lib.makeLibraryPath runtimeLibs;

          # XDG paths including gsettings schemas (hardcoded like nixpkgs)
          xdgPaths = pkgs.lib.concatStringsSep ":" [
            "${pkgs.cups}/share"
            "${pkgs.gtk3}/share"
            "${pkgs.gtk4}/share"
            "${pkgs.adwaita-icon-theme}/share"
            "${pkgs.hicolor-icon-theme}/share"
            "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}"
            "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}"
            "${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name}"
          ];

        in pkgs.stdenv.mkDerivation {
          pname = "axium";
          version = axiumBrowser.version;

          # Two outputs: main package and sandbox (mirrors nixpkgs)
          outputs = [ "out" "sandbox" ];

          dontUnpack = true;
          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin $out/share
            mkdir -p $sandbox/bin

            # Link sandbox from browser's sandbox output
            ln -s ${axiumBrowser.sandbox}/bin/${sandboxExecutableName} $sandbox/bin/${sandboxExecutableName}

            # Link share resources
            ln -s ${axiumBrowser}/share/* $out/share/ 2>/dev/null || true

            # Create wrapper script (mirrors nixpkgs ungoogled-chromium exactly)
            # Note: ''$ escapes $ in Nix strings, \$ escapes in bash heredoc
            cat > $out/bin/chromium <<WRAPPER_END
#!${pkgs.bash}/bin/bash -e

if [ -x "/run/wrappers/bin/${sandboxExecutableName}" ]
then
  export CHROME_DEVEL_SANDBOX="/run/wrappers/bin/${sandboxExecutableName}"
else
  export CHROME_DEVEL_SANDBOX="${axiumBrowser.sandbox}/bin/${sandboxExecutableName}"
fi

export CHROME_WRAPPER='chromium'
export LD_LIBRARY_PATH="\$LD_LIBRARY_PATH\''${LD_LIBRARY_PATH:+:}${libPath}"
export LD_PRELOAD="\$(echo -n "\$LD_PRELOAD" | ${pkgs.coreutils}/bin/tr ':' '\n' | ${pkgs.gnugrep}/bin/grep -v /lib/libredirect\\.so\$ | ${pkgs.coreutils}/bin/tr '\n' ':')"
export XDG_DATA_DIRS=${xdgPaths}\''${XDG_DATA_DIRS:+:}\$XDG_DATA_DIRS
export PATH="\$PATH\''${PATH:+:}${pkgs.xdg-utils}/bin"

exec "${axiumBrowser}/libexec/chromium/chromium" \''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}} "\$@"
WRAPPER_END
            chmod +x $out/bin/chromium

            # Add 'axium' alias
            ln -s chromium $out/bin/axium

            runHook postInstall
          '';

          passthru = {
            browser = axiumBrowser;
            sandbox = axiumBrowser.sandbox;
            inherit sandboxExecutableName;
            mkDerivation = pkgs.ungoogled-chromium.passthru.mkDerivation;
          };

          meta = axiumBrowser.meta // {
            mainProgram = "chromium";
            description = "Axium - Custom Chromium Build based on ungoogled-chromium";
          };
        };

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
