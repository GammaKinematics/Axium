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
