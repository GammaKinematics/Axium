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
