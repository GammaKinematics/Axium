# Axium Benchmarks

Measured 2026-02-24 on NixOS x86_64, 14 GB RAM.
Both browsers open to the same single Wikipedia article (`WebKit`).

## Memory: Axium vs Zen (Firefox)

### Total RSS

| | Axium | Zen |
|---|---|---|
| **UI process** | 62 MB | 559 MB |
| **Web content** | 305 MB (1 proc) | 805 MB (7 procs) |
| **Network** | 95 MB | 152 MB (socket + rdd) |
| **Infra** | — | 137 MB (forkserver + utility) |
| **Processes** | 3 | 12 |
| **Total RSS** | **462 MB** | **1,617 MB** |

Axium uses 3.5x less memory. The UI process is 9x smaller.

Zen keeps 7 tab processes alive for session restore and preloaded new-tab
even with a single visible tab.

### Axium UI Process Breakdown (62 MB RSS, 29 MB PSS)

| Mapping | RSS | Notes |
|---|---|---|
| libWPEWebKit-2.0.so | 26.8 MB | WebKit API lib (shared with child procs) |
| WebKitSharedMemory | 6.2 MB | 2 IPC buffers to web process |
| SYSV SHM | 3.6 MB | Framebuffer (1280x720x4) |
| glib/gio/gobject | 2.3 MB | GLib runtime |
| libc + libm + ld | 2.5 MB | C runtime |
| libstdc++ | 1.7 MB | C++ runtime |
| gnutls + crypto | 2.1 MB | TLS stack |
| ICU | 2.2 MB | Unicode data |
| heap + anon + stack | 2.8 MB | Actual allocations |
| .axium-unwrapped | 1.0 MB | Odin binary (LVGL + display + chrome) |
| fontconfig caches | 0.8 MB | Font discovery |
| Everything else | ~10 MB | xcb, xkb, freetype, harfbuzz, gstreamer, etc. |

PSS (proportional share after deduplicating shared pages) is 29 MB.

### EGL Removal Impact

Dropping `eglGetDisplay`/`eglInitialize` from the WPE display (pure SHM path
doesn't need it) eliminated Mesa's software renderer from the UI process:

| | Before | After |
|---|---|---|
| RSS | 118 MB | 62 MB |
| PSS | 42 MB | 29 MB |

libLLVM.so (36 MB) and libgallium (7 MB) no longer loaded.

## CPU Usage (Idle)

Single Wikipedia tab, no interaction, measured via `top -b -n1`:

| Process | CPU |
|---|---|
| axium UI | ~4-10% |
| WPEWebProcess | ~0% |
| WPENetworkProcess | ~0% |

UI process wakes each frame for Present vsync (X11).
Web and network processes idle to 0% when page is static.

---

## 3-Tab Benchmark: Axium vs Zen

Measured 2026-03-06 on NixOS x86_64, 14 GB RAM.
Both browsers open to the same 3 tabs: Wikipedia article, CNN, YouTube search.

### Total RSS

| | Axium | Zen |
|---|---|---|
| **UI process** | 84 MB | 543 MB |
| **Web content** | 1,802 MB (3 procs) | ~1,700 MB (11 procs) |
| **Network/infra** | 114 MB (1 proc) | 361 MB (5 procs) |
| **Auxiliary web procs** | 255 MB (2 procs) | — (counted in web content) |
| **Processes** | **7** | **16** |
| **Total RSS** | **2,204 MB** | **2,568 MB** |

UI process is still 6.5x smaller. Web content memory is comparable since both
engines need similar memory to render the same pages. Overall ratio narrows to
1.2x because web content dominates at 3 tabs.

Zen spawns 11 tab processes for 3 tabs (preloaded tabs, session restore,
privileged content, WebExtensions, etc.) plus 5 infrastructure processes
(forkserver, socket, RDD, Widevine DRM plugin, utility).

### True System Cost (PSS)

RSS overcounts shared pages (libWPEWebKit, libc, ICU, etc. mapped into all
processes). PSS (proportional set size) gives the true unique cost.

| Process | RSS | PSS | Private Dirty |
|---|---|---|---|
| UI (Odin+LVGL) | 83 MB | 43 MB | 21 MB |
| NetworkProcess | 109 MB | 75 MB | 64 MB |
| WebProcess-1 (CNN) | 625 MB | 478 MB | 414 MB |
| WebProcess-2 (aux) | 139 MB | 50 MB | 31 MB |
| WebProcess-3 (YouTube) | 608 MB | 465 MB | 431 MB |
| **Sum of RSS** | **1,565 MB** | | |
| **Sum of PSS** | | **1,114 MB** | |

RSS overcounts by ~450 MB due to shared library pages across 5 processes.

### Axium UI Process Breakdown (83 MB RSS, 43 MB PSS)

| Category | RSS | PSS | Private Dirty | Notes |
|---|---|---|---|---|
| libWPEWebKit | 22.3 MB | 8.0 MB | 2.8 MB | Shared with web/network procs |
| Heap (allocs) | 12.9 MB | 12.9 MB | 12.9 MB | GLib objects, LVGL, WebKit API state |
| WebKit IPC shm | 12.2 MB | 6.1 MB | 0.0 MB | Shared buffers to web processes |
| Other shared libs | 8.0 MB | 2.4 MB | 0.9 MB | X11, freetype, harfbuzz, epoxy, etc. |
| Odin binary | 4.6 MB | 4.6 MB | 0.1 MB | Actual Axium code + LVGL |
| C/C++ runtime | 4.0 MB | 0.3 MB | 0.1 MB | libc, libm, libstdc++, ld |
| Anon + stacks | 3.4 MB | 3.4 MB | 3.4 MB | Thread stacks, mmap |
| GLib/GIO/GObject | 3.3 MB | 0.5 MB | 0.1 MB | GLib runtime |
| TLS/Crypto | 3.3 MB | 1.1 MB | 0.3 MB | gnutls, gcrypt, etc. |
| ICU | 2.2 MB | 0.4 MB | 0.2 MB | Unicode data |
| GStreamer | 1.4 MB | 0.5 MB | 0.2 MB | Media framework |
| GL/EGL | 1.4 MB | 0.4 MB | — | libepoxy, GLdispatch |
| SQLite | 1.3 MB | 0.7 MB | — | Cookie/state storage |
| Other | 3.8 MB | 1.7 MB | 0.2 MB | libsoup, XML, JIT, vDSO |

The Odin binary is 4.6 MB. The 83 MB RSS is inflated by ~34 MB of shared
library/IPC pages. Private dirty (memory uniquely written by this process)
is only 21 MB.

### WebProcess Memory Anatomy

Each WebProcess loads the full WebKit engine plus Mesa's software renderer.

**Mesa (libLLVM + libgallium) per web process:**

| Process | Mesa RSS | Mesa PSS |
|---|---|---|
| WebProcess-1 (CNN) | 75 MB | 15 MB |
| WebProcess-2 (aux) | 48 MB | 8 MB |
| WebProcess-3 (YouTube) | 74 MB | 15 MB |
| **Total** | **197 MB RSS** | **38 MB PSS** |

Mesa is loaded because WebKit's WebProcess uses EGL for layer compositing
(even though the UI process avoids it via pure SHM). This is the single
largest library besides WebKit itself in each web process.

**JavaScript memory (WebProcess-3 / YouTube — heaviest):**

| Category | Size | Notes |
|---|---|---|
| Anon (JS heap, DOM, bitmaps) | 327 MB | The web page itself |
| JIT code (rwx) | 42 MB | JavaScriptCore compiled JS |
| JS blob caches | 16 MB | JSC bytecode caches |
| Heap (C++ malloc) | 13 MB | WebCore C++ objects |

**JavaScript memory (WebProcess-1 / CNN):**

| Category | Size | Notes |
|---|---|---|
| Anon (JS heap, DOM, bitmaps) | 370 MB | Heavy ad/tracker scripts |
| JIT code (rwx) | 9 MB | Less compiled JS than YouTube |
| JS blob caches | 8 MB | JSC bytecode caches |
| Heap (C++ malloc) | 17 MB | WebCore C++ objects |

### WebProcess-2 — PSON (Process Swap On Navigation) Leftover

139 MB RSS, 50 MB PSS. This process is completely idle: no DMA buffers
(0 vs 10+ in active processes), no WebKitSharedMemory (not compositing),
no JIT code, no audio, 2.4 MB heap, 18 threads (vs 71-87 in active ones),
0.3% CPU. It loads adblock + Mesa + WebKit but renders nothing.

**Root cause:** WebKit's Process Swap On Navigation (PSON). At startup,
`engine_create_view(nil)` creates view 0 for `about:blank`, spawning this
process. When `session_restore()` then navigates the view to its actual URL
(different origin), PSON swaps the view to a new process and leaves this
one alive (back-forward cache / delayed cleanup). The 143 MB is the fixed
cost of spawning any WebProcess (Mesa ~48 MB, WebKit ~44 MB, adblock, libs)
even when it does zero work.

**Potential fix:** defer view creation until the URL is known, or navigate
the view at creation time, to avoid the blank→real-URL swap that triggers
the extra process.

### Adblock Extension

libaxium_adblock.so loads into each web process at ~2.9 MB RSS (~1 MB PSS).
Negligible overhead.

### System-Wide Memory by Category

| Category | PSS | Notes |
|---|---|---|
| Anon (JS heap, DOM, bitmaps) | ~720 MB | The web itself |
| libWPEWebKit | ~102 MB | Engine code, shared across procs |
| Heap (malloc) | ~90 MB | C++ objects (45 MB in NetworkProcess) |
| JIT (rwx) | ~51 MB | JSC compiled code |
| Mesa (LLVM+gallium) | ~38 MB | Software GL in web procs |
| All other libs | ~50 MB | ICU, GStreamer, TLS, GLib, etc. |
| WebKit IPC shm | ~18 MB | Shared memory buffers |
| Odin binary | 4.6 MB | Axium browser chrome |
| Adblock extension | ~3 MB | Rust FFI filter engine |

---

## 3-Tab Benchmark: Post-Optimization Build

Measured 2026-03-06 on NixOS x86_64, 14 GB RAM.
Same 3 tabs as above. Optimization build: Mesa eliminated from WebProcesses,
PSON ghost fixed, hardware acceleration disabled, pure Skia CPU + SHM rendering.

### Optimizations Applied

| Change | Method |
|---|---|
| Disable compositing | `setAcceleratedCompositingEnabled(false)`, `setForceCompositingMode(false)` via substituteInPlace |
| Disable hardware acceleration | `setHardwareAccelerationEnabled(false)` — SwapChain takes SharedMemoryWithoutGL path |
| Skip EGL/PlatformDisplay init | `initializePlatformDisplayIfNeeded()` returns immediately — no Mesa dlopen |
| Force CPU rendering | `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1` env var |
| Remove GPU cmake flags | `USE_GBM=OFF`, `USE_LIBDRM=OFF`, `USE_GSTREAMER_GL=OFF` |
| Remove unused features | `ENABLE_WEB_AUDIO=OFF`, `USE_LIBBACKTRACE=OFF` |
| Removed build deps | mesa, libgbm, libdrm, libbacktrace, libsecret, gst-plugins-bad |
| Fix PSON ghost | Deferred view creation in main.odin/session.odin |
| Patch unguarded code | DRM_FORMAT_XRGB8888 in AcceleratedBackingStore.cpp, memoryMappedGPUBuffer in SkiaPaintingEngine.cpp |

All WebKit changes via `substituteInPlace` in engine.nix postPatch — no patch files.

### Before vs After

| Metric | Before | After | Change |
|---|---|---|---|
| **Processes** | 7 (incl. ghost) | 5 | -2 |
| **Total RSS** | 2,204 MB | 1,162 MB | **-1,042 MB (-47%)** |
| **Total PSS** | 1,114 MB | 838 MB | **-276 MB (-25%)** |
| **Mesa in WebProcesses** | 197 MB RSS / 38 MB PSS | 0 | **eliminated** |
| **PSON ghost process** | 139 MB RSS / 50 MB PSS | 0 | **eliminated** |

### Process Summary

| Process | RSS | PSS | Private | Shared | Threads | FDs |
|---|---|---|---|---|---|---|
| Browser UI (Odin+LVGL) | 95.5 MB | 51.4 MB | 28.1 MB | 67.4 MB | 11 | 38 |
| NetworkProcess | 102.3 MB | 72.6 MB | 63.9 MB | 38.5 MB | 16 | 75 |
| WebProcess-1 (tab 1) | 359.8 MB | 276.8 MB | 226.4 MB | 132.4 MB | 13 | 35 |
| WebProcess-2 (tab 2) | 83.7 MB | 39.1 MB | 23.6 MB | 60.1 MB | 11 | 27 |
| WebProcess-3 (tab 3) | 520.5 MB | 488.3 MB | 442.3 MB | 123.4 MB | 18 | 30 |
| **Total** | **1,162 MB** | **838 MB** | **784 MB** | **422 MB** | **69** | **205** |

### Mesa Stack — Eliminated

Previously loaded in every WebProcess, now completely absent:

| Library | Was (per process) | Now |
|---|---|---|
| libLLVM.so.21.1 | ~160 MB mapped | gone |
| libgallium-25.2.6.so | ~50 MB mapped | gone |
| libEGL_mesa.so | ~1 MB | gone |
| libgbm.so | ~20 KB | gone |
| mesa_shader_cache | ~1.3 MB mmap | gone |

Only lightweight libglvnd stubs remain in 2 of 3 WebProcesses (~700 KB
total): libEGL.so, libGL.so, libGLX.so — loaded as NEEDED deps of libepoxy,
no Mesa drivers behind them. One WebProcess is completely clean (zero GL libs).

### PSON Ghost Process — Eliminated

The pre-optimization build had an extra idle WebProcess (139 MB RSS, 50 MB PSS)
caused by WebKit's Process Swap On Navigation. Creating view 0 for `about:blank`
then navigating to a real URL triggered a process swap, leaving the original
process alive.

**Fix:** deferred view creation in main.odin until URL is known (from
session_restore or default homepage), avoiding the blank-to-real-URL swap.

### Top RSS Contributors (per WebProcess)

| Library | RSS (range) | Notes |
|---|---|---|
| Anonymous mappings | 18-322 MB | JS heap, DOM, bitmaps — the web page itself |
| libWPEWebKit-2.0.so | 43-82 MB | WebKit engine, shared across processes |
| libaxium_adblock.so | 2.4-2.8 MB | Adblock filter engine (Rust FFI) |
| ICU (i18n + data + uc) | 2.0-7.1 MB | Unicode / internationalization |
| glibc | 1.7 MB | C runtime |
| gnutls | 1.7 MB | TLS stack |
| libgio | 1.7 MB | GLib I/O |
| libstdc++ | 1.6 MB | C++ runtime |
| gstreamer | 1.3 MB | Media framework |
| harfbuzz | 1.1 MB | Text shaping |
| libglib | 1.0 MB | GLib core |
| freetype | 0.8 MB | Font rasterization |
| libepoxy | 0.8 MB | EGL type headers only |

### Loaded Libraries Per WebProcess

| WebProcess | Unique .so files | GL libs loaded |
|---|---|---|
| WebProcess-1 (tab 1) | 107 | libglvnd stubs only (~700 KB) |
| WebProcess-2 (tab 2) | 73 | none |
| WebProcess-3 (tab 3) | 107 | libglvnd stubs only (~700 KB) |

---

## Binary / Distribution Size

Measured 2026-03-07 from `nix build .#browser` (dynamic build, glibc, no LTO).

### Axium Package

| Component | Size | Notes |
|---|---|---|
| `.axium-unwrapped` (Odin binary) | 13 MiB | Dynamically linked browser chrome |
| `libaxium_adblock_ext.so` | 30 KiB | Adblock extension (Rust FFI) |
| Adblock resources (filter lists) | 11 MiB | Shipped data |
| **axium-browser-0.1.0 package** | **14 MiB** | Binary + extension + wrapper |

### Key Runtime Dependencies (own size on disk)

| Library | Size |
|---|---|
| libWPEWebKit-2.0.so (+ headers, WPE procs) | 147 MiB |
| axium-translate (BLIS + model loading) | 78 MiB |
| ICU (libicudata + libicuuc + libicui18n) | 38 MiB |
| glibc | 29 MiB |
| GLib (libglib + libgio + libgobject) | 15 MiB |
| GStreamer core | 6 MiB |
| gst-plugins-base | 9 MiB |
| gst-plugins-good | 9 MiB |
| Adblock engine (libaxium_adblock) | 7.5 MiB |
| SQLite | 6 MiB |
| HarfBuzz + HarfBuzz-ICU | 6 MiB |
| libsoup3 | 1 MiB |
| Other (freetype, fontconfig, crypto, xkb, ...) | ~30 MiB |

### Nix Closure

| Metric | Value |
|---|---|
| Total closure size | 2.8 GiB |
| Packages in closure | 208 |
| Build tool leakage | ~2.1 GiB |
| Estimated runtime-only | ~630 MiB |

The closure is inflated by ~2.1 GiB of build tools (Odin compiler 170 MiB,
clang-lib 780 MiB, LLVM-lib 479 MiB, gcc 264 MiB, python 107 MiB, etc.)
whose store paths are embedded in the binary by the Odin compiler. These are
not loaded at runtime.

### Static+LTO Build

Single statically linked binary: musl libc, full LTO (Odin + deps) + thin LTO
(WebKit), gstreamer-full monolithic library. Zero shared library dependencies,
zero runtime closure.

| Metric | Value |
|---|---|
| `.axium-unwrapped` | 145 MiB |
| Shared libraries | 0 |
| Runtime dependencies | 0 |

---

## 3-Tab Benchmark: Static+LTO Build

Measured 2026-03-10 on NixOS x86_64, 14 GB RAM.
Static musl+LTO build. Single 145 MB binary, zero runtime dependencies.
Same 3 tabs: Wikipedia article, CNN, YouTube (video playing).

### Process Summary

| Process | RSS | PSS | Private | Threads | FDs |
|---|---|---|---|---|---|
| Browser UI (Odin+LVGL) | 79 MB | 46 MB | 25 MB | 11 | 45 |
| NetworkProcess | 68 MB | 48 MB | 41 MB | 16 | 77 |
| WebProcess-1 (idle) | 83 MB | 43 MB | 32 MB | 10 | 26 |
| WebProcess-2 (Wikipedia) | 175 MB | 120 MB | 97 MB | 20 | 31 |
| WebProcess-3 (CNN) | 546 MB | 485 MB | 442 MB | 32 | 52 |
| WebProcess-4 (YouTube) | 659 MB | 599 MB | 564 MB | 42 | 57 |
| **Total** | **1,609 MB** | **1,341 MB** | **1,201 MB** | **131** | **288** |

### Binary Code Sharing

All 6 processes map the same `.axium-unwrapped` file. The kernel shares
read-only code/data pages via the page cache — single-binary architecture
gets shared-library-level page deduplication for free.

| Process | Binary RSS | Binary PSS | Binary Private |
|---|---|---|---|
| Browser UI | 23 MB | 5 MB | 88 kB |
| NetworkProcess | 27 MB | 7 MB | 72 kB |
| WebProcess-1 | 50 MB | 11 MB | 100 kB |
| WebProcess-2 | 65 MB | 16 MB | 104 kB |
| WebProcess-3 | 75 MB | 21 MB | 140 kB |
| WebProcess-4 | 77 MB | 23 MB | 148 kB |
| **Total mapped** | **317 MB** | **84 MB** | **652 kB** |

317 MB of binary pages mapped across 6 processes, true cost 84 MB (PSS).
Only 652 kB of private dirty writes to the binary's pages total.

### UI Process Breakdown (79 MB RSS, 46 MB PSS)

| Mapping | RSS | PSS | Notes |
|---|---|---|---|
| .axium-unwrapped | 23 MB | 5 MB | Entire engine + browser (shared via page cache) |
| WebKitSharedMemory | 28 MB | 14 MB | IPC buffers to 3 active WebProcesses |
| [anon] heap | 26 MB | 26 MB | GLib objects, LVGL, WebKit API state |
| SYSV SHM | 3.5 MB | 1.8 MB | X11 framebuffer |

No shared libraries. No Mesa/GL. No glibc/libstdc++ .so files. Everything
is compiled into the single binary via LTO.

### JIT Memory Per WebProcess

| WebProcess | JIT (rwx) | Notes |
|---|---|---|
| WebProcess-1 (idle) | 48 kB | PSON leftover, no JS running |
| WebProcess-2 (Wikipedia) | 3.3 MB | Minimal JS |
| WebProcess-3 (CNN) | 43 MB | Heavy ad/tracker scripts |
| WebProcess-4 (YouTube) | 6.5 MB | Video player JS |

### WebProcess-1 — PSON Leftover (Still Present)

83 MB RSS, 43 MB PSS. Idle process from session restore: creating views
before navigating to the restored URL triggers a PSON (Process Swap On
Navigation) origin swap, leaving the original process alive. Same root
cause as the dynamic build's PSON ghost. Needs smarter related-view
handling at startup / session restore to avoid the blank-to-real-URL swap.

### What Changed vs Dynamic Build

| | Dynamic (post-opt) | Static LTO |
|---|---|---|
| **Binary** | 13 MB (.axium-unwrapped) | 145 MB (everything) |
| **Shared libraries per WebProcess** | ~107 .so files | 0 |
| **Mesa/GL** | eliminated | eliminated |
| **Runtime deps (nix closure)** | 208 packages / 2.8 GiB | 0 |
| **Code sharing mechanism** | Kernel page cache (per .so) | Kernel page cache (single binary) |
| **PSON ghost** | fixed (deferred view creation) | still present (session restore path) |

### ICF Bug (Resolved)

The static build originally suffered from WebProcess infinite CPU spins on
certain pages (github.com, wikipedia, youtube). Root cause: `--icf=all`
(Identical Code Folding) in the LLD linker flags. ICF merges functions with
identical machine code into a single address, breaking code that relies on
function pointer identity — WebKit/JSC uses function pointer dispatch tables,
vtables, and address-based comparisons extensively. `--icf=safe` also failed
(LTO bitcode confuses address-taken analysis). Fix: removed ICF entirely.
No measurable binary size impact (145 MB with or without).
