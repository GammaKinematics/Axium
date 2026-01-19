# Axium Browser

A personal Chromium spin combining ungoogled-chromium privacy patches, Thorium performance optimizations, and a minimal UI.

## Project Goals

- **Privacy**: Leverage ungoogled-chromium's de-googling (already in nixpkgs)
- **Performance**: Cherry-pick Thorium's compiler optimizations and GN flags
- **Minimal UI**: Hide tab strip entirely (fullscreen-like experience)
- **Nix-native**: Build via nixpkgs overlay, cache via Cachix
- **Linux x86_64 only**: Simplify maintenance

---

## Architecture

```
nixpkgs ungoogled-chromium (maintained, working)
    │
    ├── + Thorium GN flags (compiler opts, SIMD, LTO)
    ├── + Thorium patches (cherry-picked, conflict-free)
    └── + Custom UI patch (hide tabstrip)
```

---

## Source Projects

### ungoogled-chromium
- **Repo**: https://github.com/ungoogled-software/ungoogled-chromium
- **In nixpkgs**: Yes, fully integrated
- **Patches**: 114 total (34 core, 74 extra) in GNU quilt format
- **Systems**: Domain substitution, binary pruning, GN flags

Key features:
- Removes Google telemetry, safe browsing, autofill phone-home
- Domain substitution (google.com → 9oo91e.qjz9zk) as fail-safe
- Manifest V2 extension support retained
- Already in `ungoogled-flags.toml` in nixpkgs

### Thorium
- **Repo**: https://github.com/AAlexLeonard/thorium
- **In nixpkgs**: No
- **Focus**: Performance, codecs, UI polish

Valuable Thorium additions:
- Compiler flags: `-O3`, ThinLTO, SIMD (AVX/AVX2)
- V8 optimizations: Maglev JIT, Turbofan, WASM SIMD256
- Codec patches: HEVC, AC3/EAC3 (if desired)
- UI flags: Custom tab width, hover cards control, etc.

---

## Nixpkgs Chromium Structure

```
pkgs/applications/networking/browsers/chromium/
├── default.nix           # Entry point, wrapper, widevine
├── common.nix            # Build derivation, GN flags, patches (THE MEAT)
├── browser.nix           # Browser-specific targets
├── ungoogled.nix         # Fetches ungoogled-chromium repo
├── ungoogled-flags.toml  # GN flags for ungoogled
├── patches/              # Nix-specific patches
└── info.json             # Version info, hashes
```

### Extension Points

**GN Flags** (common.nix:747-865):
```nix
gnFlags = mkGnFlags ({
  # ... base flags
} // lib.optionalAttrs ungoogled (lib.importTOML ./ungoogled-flags.toml)
  // (extraAttrs.gnFlags or { })  # <-- CUSTOM FLAGS HERE
);
```

**Patches** (common.nix:450-601):
```nix
patches = [
  ./patches/cross-compile.patch
  # ... existing patches
];
# Can extend via extraAttrs.patches or overrideAttrs
```

---

## Thorium GN Flags to Cherry-Pick

```nix
thoriumGnFlags = {
  # Compiler optimizations
  use_thin_lto = true;
  thin_lto_enable_optimizations = true;

  # SIMD (pick based on your CPU)
  use_sse42 = true;
  use_avx = true;
  # use_avx2 = true;    # Haswell 2013+
  # use_avx512 = false; # Skylake-X 2017+ (usually overkill)

  # V8 JavaScript engine
  v8_enable_maglev = true;
  v8_enable_turbofan = true;
  v8_enable_wasm_simd256_revec = true;

  # Build optimizations
  is_official_build = true;  # Already set by nixpkgs
  symbol_level = 0;
  blink_symbol_level = 0;
  v8_symbol_level = 0;
  enable_stripping = true;

  # Disable unused features (customize to taste)
  enable_nacl = false;        # Dead technology
  enable_remoting = false;    # Chrome Remote Desktop
  # enable_printing = false;  # Uncomment if you never print
  # enable_pdf = false;       # Careful - breaks PDF viewing
  enable_reading_list = false;

  # Media (keep these)
  use_vaapi = true;           # Hardware video decode on Linux
  proprietary_codecs = true;  # H.264 etc (already in ungoogled)
};
```

---

## Custom UI: Hide Tab Strip

### Option 1: App Mode (Zero effort, limited)
```bash
chromium --app=https://startpage.com
```
No tabs, no URL bar. Limited to single origin.

### Option 2: Custom Patch (Recommended)

Create `patches/hide-tabstrip.patch`:

```cpp
// Target: chrome/browser/ui/views/frame/browser_view.cc
// Add flag check to IsTabStripVisible() or similar

// Approach A: Command-line flag
bool BrowserView::IsTabStripVisible() const {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("hide-tabstrip"))
    return false;
  // ... original logic
}

// Approach B: Always hide (simpler, less flexible)
bool BrowserView::IsTabStripVisible() const {
  return false;  // Tabs still work via Ctrl+T/W/Tab
}
```

Tabs continue working internally - keyboard shortcuts (Ctrl+T, Ctrl+W, Ctrl+Tab, Ctrl+Shift+T) all function.

### Files to Investigate

```
chrome/browser/ui/views/frame/browser_view.cc    # Main view layout
chrome/browser/ui/views/frame/browser_view.h
chrome/browser/ui/views/tabs/tab_strip.cc        # Tab strip implementation
chrome/browser/ui/views/frame/tab_strip_region_view.cc
```

---

## Flake Structure

```
axium/
├── flake.nix
├── flake.lock
├── browser.nix           # Main derivation override
├── gn-flags.nix          # Thorium + custom GN flags
├── patches/
│   ├── hide-tabstrip.patch
│   └── (cherry-picked thorium patches)
└── README.md
```

### flake.nix

```nix
{
  description = "Axium - Personal Chromium Build";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      axiumGnFlags = import ./gn-flags.nix;
      customPatches = [
        ./patches/hide-tabstrip.patch
      ];
    in
    {
      packages.${system} = {
        browser = pkgs.ungoogled-chromium.overrideAttrs (old: {
          pname = "axium";

          patches = old.patches ++ customPatches;

          # Note: gnFlags is a string in the derivation
          # May need to use passthru.mkDerivation for cleaner flag merging
        });

        default = self.packages.${system}.browser;
      };

      # For NixOS module integration
      overlays.default = final: prev: {
        axium = self.packages.${system}.browser;
      };
    };
}
```

### gn-flags.nix

```nix
{
  # Performance
  use_thin_lto = true;
  thin_lto_enable_optimizations = true;
  use_sse42 = true;
  use_avx = true;

  # V8
  v8_enable_maglev = true;
  v8_enable_turbofan = true;

  # Strip symbols
  symbol_level = 0;
  blink_symbol_level = 0;
  v8_symbol_level = 0;

  # Disable bloat
  enable_nacl = false;
  enable_remoting = false;
  enable_reading_list = false;
}
```

---

## Build Workflow

### Local Build (if you have resources)
```bash
# Will take 6-8+ hours, needs 16-32GB RAM
nix build .#browser --cores 0 -j auto
```

### Cloud Build (Recommended)

**1. Set up Cachix**
```bash
# Create account at cachix.org
cachix generate-keypair axium
# Add signing key to your secrets
```

**2. Spin up Hetzner VM**
- CCX33: 8 vCPU, 32GB RAM (~€0.30/hr)
- CCX53: 16 vCPU, 64GB RAM (~€0.60/hr)
- Total cost: ~€3-5 per build

**3. Build on VM**
```bash
# Install Nix
sh <(curl -L https://nixos.org/nix/install) --daemon
source /etc/profile

# Enable flakes
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# Clone and build
git clone https://github.com/YOU/axium
cd axium
nix build .#browser --cores 0 -j auto

# Push to cache
cachix push axium ./result
```

**4. Use on your PC**
```bash
# Add to flake.nix inputs or just:
nix build github:YOU/axium
# Downloads from cache - instant!
```

### Nix Remote Builders (Alternative)

```nix
# configuration.nix
nix.buildMachines = [{
  hostName = "builder.example.com";
  systems = [ "x86_64-linux" ];
  maxJobs = 16;
  speedFactor = 2;
  supportedFeatures = [ "big-parallel" "kvm" ];
  sshUser = "nix";
  sshKey = "/root/.ssh/builder_key";
}];
nix.distributedBuilds = true;
```

---

## Cost Estimates

| Service | Est. Build Time | Est. Cost |
|---------|-----------------|-----------|
| Hetzner CCX33 | 8 hours | ~€2.50 |
| Hetzner CCX53 | 5 hours | ~€3.00 |
| AWS c5.4xlarge spot | 6 hours | ~$2-3 |
| Local (if possible) | 8-12 hours | Electricity |

---

## Maintenance

### Per Chromium Update (~monthly)

1. Wait for nixpkgs to update ungoogled-chromium
2. Attempt build with existing patches
3. Fix any patch conflicts (usually minor)
4. Rebuild and push to cache

### Estimated Effort

- Initial setup: 2-4 days
- Per-update: 2-4 hours (mostly waiting for builds)
- Patch conflicts: Occasional, usually trivial

---

## References

- [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium)
- [Thorium](https://github.com/AAlexLeonard/thorium)
- [Thorium GN args docs](https://github.com/AAlexLeonard/thorium/blob/main/docs/ABOUT_GN_ARGS.md)
- [nixpkgs chromium](https://github.com/NixOS/nixpkgs/tree/master/pkgs/applications/networking/browsers/chromium)
- [Cachix](https://cachix.org)
- [Hetzner Cloud](https://www.hetzner.com/cloud)

---

## TODO

- [ ] Create repo structure
- [ ] Set up Cachix cache
- [ ] Write hide-tabstrip.patch
- [ ] Test GN flag merge with nixpkgs ungoogled-chromium
- [ ] First test build (cloud VM)
- [ ] Iterate on UI patches
- [ ] Document final configuration
