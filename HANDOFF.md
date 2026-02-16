# Axium Browser - WPE2 Integration Handoff

## Project Overview

Axium is a minimal privacy-focused browser built with:
- **Odin** language for the main application
- **LVGL** (via Nix-generated bindings) for the UI chrome
- **WPE2 WebKit** for the web engine (multi-process)
- **GLFW + EGL** for the window and GL context
- **Nix** for the build system and code generation

The architecture composites two GL textures in a GLFW window:
1. **Bottom layer**: Web content texture (from WebKit)
2. **Top layer**: LVGL UI chrome with transparent content area (ARGB8888)

## Current State: THE PROBLEM

**Web content buffers from the WebKit web process are ALL ZEROS.**

Pages load successfully (load-changed events fire: STARTED → COMMITTED → FINISHED), the multi-process IPC works, buffers arrive at the correct dimensions (1280x720), but every single byte of pixel data is zero. This has been confirmed across **two completely independent rendering paths**:

### DMA-BUF Path (default)
- Web process uses `PlatformDisplayGBM` + `SwapChain::Type::EGLImage`
- Allocates GBM buffer objects, renders via GPU, exports as DMA-BUF FDs
- UI process imports via `wpe_buffer_import_to_egl_image()` → `eglCreateImageKHR` → GL texture
- GL readback (`glGetTexImage` after `glFinish`): **ALL ZEROS**
- CPU cross-validation (`wpe_buffer_import_to_pixels`): fails with "unsupported buffer format"
- Buffer modifier is always `DRM_FORMAT_MOD_INVALID` (0x00FFFFFFFFFFFFFF)

### SharedMemory Path (forced via `FORCE_SHM_MODE 1`)
- Web process uses `PlatformDisplaySurfaceless` + `SwapChain::Type::SharedMemory`
- Renders to GL renderbuffer, reads back via `glReadPixels` into shared memory
- UI process receives `WPEBufferSHM`, calls `wpe_buffer_import_to_pixels()` → gets `GBytes`
- Pixel data (3,686,400 bytes = 1280*720*4, correct size): **ALL ZEROS**

**Since both paths produce identical zeros, the issue is in the web process's rendering pipeline itself**, not in buffer transport or import.

## What Has Been Ruled Out

| Hypothesis | How Tested | Result |
|---|---|---|
| DMA-BUF tiling mismatch (tiled BO imported as LINEAR) | Tried LINEAR-only, real EGL modifiers, MAPPING+INVALID | Still zeros |
| GPU sync (reading before GPU finishes) | Added `glFinish()` before readback | Still zeros |
| EGLImage import wrong | Forced SharedMemory (bypasses DMA-BUF entirely) | Still zeros |
| ActivityState not set (WebKit won't paint if not visible) | Fixed signal ordering - ACTIVE/focus set after view-toplevel connection | Confirmed signals fire (`view mapped: 1`, `toplevel state set to ACTIVE`, `view focused: 1`) but still zeros |
| Buffer format mismatch | Printed format as hex; both paths produce correct buffer dimensions | N/A for SHM path |

## What The Problem Likely Is

The web process's **ThreadedCompositor renders frames but the layer tree is empty**. Evidence:

1. We receive exactly 2 frames, both post-`LOAD_FINISHED`, both all zeros, both with **0 damage rects**
2. The compositor runs (it produces frames) but paints nothing into them
3. `WEBKIT_DEBUG=Compositing` produces **zero output** from the web process (may indicate LOG macros compiled out in release build, or compositor code path differs for WPE2)
4. The `AcceleratedSurface::clear()` function only clears for transparent backgrounds or async scrolling — for opaque backgrounds (default white), it doesn't clear, leaving newly-allocated renderbuffers as zeros
5. If `TextureMapper::paintLayers()` has no committed layers, nothing gets rendered on top of those zeros

### Root Cause Hypotheses (ranked by likelihood)

1. **Main thread rendering update never executes** — The `DrawingAreaCoordinatedGraphics::scheduleRenderingUpdate()` might not trigger because some precondition isn't met in the WPE2 code path. The rendering update is what commits layers from the main thread to the compositor thread.

2. **Display refresh / frame scheduling not working** — WebKit's rendering update is triggered by `requestCompositionForRenderingUpdate()` which uses a one-shot timer on the compositor thread. The compositor then calls back to the main thread. If this callback mechanism doesn't work with our GLib event pump, layers are never committed.

3. **Web process GL context silently broken** — `PlatformDisplaySurfaceless` or `PlatformDisplayGBM` creates a GL context, but it might not actually render on this system (Mesa 25.2.6, Intel?). The FBO is "complete" (no errors reported), but `glReadPixels`/rendering produces empty content.

4. **Missing virtual method or signal** — Our GObject subclasses (`AxiumDisplay`, `AxiumView`, `AxiumToplevel`) might be missing a virtual method that WebKit's internal `AcceleratedBackingStore` depends on for proper frame scheduling.

## Investigations NOT YET Done

- **Verify our display pipeline works**: Inject a test pattern (solid red) into the GL texture after receiving zeros. If red shows on screen, the LVGL compositor + GLFW display path is confirmed working.
- **Check if web process GL context actually renders**: Could try attaching GDB to the WPEWebProcess and breaking on `glReadPixels` or `renderLayerTree`.
- **Try `WEBKIT_DEBUG=all`** or other channels to get web process compositor output.
- **Check DrawingArea rendering update flow**: Whether `scheduleRenderingUpdate()` is ever called, whether `m_isVisible` is true in the web process.
- **Try a WebKit debug build**: The Nix `engine` package might not have LOG macros enabled. Building with `-DCMAKE_BUILD_TYPE=Debug` or `RelWithDebInfo` would enable `WEBKIT_DEBUG` output.

## Architecture Details

### Process Model
```
┌─────────────────────────────────────┐
│ UI Process (our Odin + C shim)      │
│                                     │
│ GLFW Window (EGL context)           │
│ ├── LVGL UI chrome (SW rendered)    │
│ └── Web texture (from engine)       │
│                                     │
│ Main loop:                          │
│   check_resize()                    │
│   axium_engine_pump()     ← GLib    │
│   update_web_texture()    ← import  │
│   lv_timer_handler()      ← LVGL   │
│   sleep(16ms)                       │
│                                     │
│ WPE2 GObject subclasses:           │
│   AxiumDisplay (WPEDisplay)         │
│   AxiumView (WPEView)              │
│   AxiumToplevel (WPEToplevel)      │
└──────────────┬──────────────────────┘
               │ IPC (Unix socket)
┌──────────────┴──────────────────────┐
│ WPEWebProcess (spawned by WebKit)   │
│                                     │
│ PlatformDisplayGBM (or Surfaceless) │
│ ThreadedCompositor (own GL context) │
│ AcceleratedSurface + SwapChain      │
│                                     │
│ Rendering flow:                     │
│   Main thread: parse, layout, paint │
│   → commit layer tree to compositor │
│   Compositor thread: render layers  │
│   → didRenderFrame → send to UI    │
└─────────────────────────────────────┘
```

### Buffer Lifecycle (DMA-BUF path)
```
Web process:
  1. GBM BO allocated (gbm_bo_create)
  2. GL renders into BO (via EGLImage-backed FBO)
  3. DMA-BUF FD exported, sent to UI process via IPC

UI process (AcceleratedBackingStore → our render_buffer):
  4. render_buffer() called with WPEBufferDMABuf
  5. We store buffer as pending_buffer
  6. Main loop calls get_texture_id():
     a. wpe_buffer_import_to_egl_image() → EGLImage
     b. glEGLImageTargetTexture2DOES() → GL texture
     c. wpe_view_buffer_rendered() → tells web process we displayed it
     d. wpe_view_buffer_released() → web process can reuse the buffer
```

### Buffer Lifecycle (SHM path)
```
Web process:
  1. ShareableBitmap allocated (shared memory)
  2. GL renderbuffer + FBO created
  3. Render into FBO, glReadPixels into SharedMemory
  4. Send via IPC

UI process:
  4. render_buffer() called with WPEBufferSHM
  5. wpe_buffer_import_to_pixels() → GBytes with pixel data
  6. glTexImage2D() uploads to GL texture
```

### ActivityState Flow
```
ViewPlatform (WebKit internal, created when WebKitWebView is constructed):
  Connects signals on WPEView:
    notify::mapped         → IsVisible
    notify::toplevel       → IsInWindow
    notify::has-focus      → IsFocused
    toplevel-state-changed → WindowIsActive

  Calls page().activityStateDidChange() → IPC to web process
  Web process: WebPage::setActivityState() → DrawingArea::visibilityDidChange()

CRITICAL: wpe_toplevel_state_changed() must be called AFTER view-toplevel
connection exists, otherwise the view's toplevel-state-changed signal never
fires and WindowIsActive is never set. This was fixed (moved from
axium_toplevel_constructed to on_toplevel_changed).
```

## Key WebKit Source Locations

All under `/data/Browser/WebKit/Source/WebKit/`:

### Web Process Rendering
- `WebProcess/WebPage/CoordinatedGraphics/AcceleratedSurface.cpp`
  - SwapChain constructor (line ~699): selects EGLImage vs SharedMemory
  - `setupBufferFormat()` (line ~742): intersects UI formats with GPU formats
  - `RenderTargetEGLImage::create()` (line ~294): GBM BO allocation
  - `RenderTargetSHMImage` (line ~499): FBO + glReadPixels path
  - `clear()` (line ~1088): only clears for transparent bg or async scroll
- `WebProcess/WebPage/CoordinatedGraphics/ThreadedCompositor.cpp`
  - `renderLayerTree()` (line ~341): main render function, early returns if suspended/no context/empty viewport
  - `requestComposition()` (line ~437): schedules render via one-shot timer
  - Suspension: `m_suspendedCount > 0` skips rendering
- `WebProcess/glib/WebProcessGLib.cpp`
  - `initializePlatformDisplayIfNeeded()`: creates PlatformDisplayGBM or Surfaceless
  - Transport mode determines which: `RendererBufferTransportMode::Hardware` → GBM

### UI Process (WebKit internal)
- `UIProcess/API/wpe/WPEWebViewPlatform.cpp`
  - ActivityState signal handlers (lines ~53-118)
  - `activityStateChanged()` (line ~270): sends to web process
- `UIProcess/wpe/AcceleratedBackingStore.cpp`
  - `frame()` (line ~198): receives buffer from web process
  - `renderPendingBuffer()` (line ~283): calls `wpe_view_render_buffer()`
- `UIProcess/glib/WebProcessPoolGLib.cpp` (line ~179)
  - WPE2: Hardware mode added if `drmDevice` is non-null; SharedMemory always added

### WPE Platform (buffer import)
- `WPEPlatform/wpe/WPEBufferDMABuf.cpp`
  - `wpeBufferDMABufImportToEGLImage()` (line ~103): creates EGLImage from DMA-BUF FDs
    - Skips modifier attributes when modifier == `((1ULL << 56) - 1)` (DRM_FORMAT_MOD_INVALID)
  - `wpeBufferDMABufImportToPixels()` (line ~212): GBM import + map
    - **Only supports DRM_FORMAT_ARGB8888 and DRM_FORMAT_XRGB8888** (line ~224)
- `WPEPlatform/wpe/WPEBufferSHM.cpp`
  - `import_to_pixels`: just returns stored pixel data directly

## Current File State

### `wpe_shim.c` — HEAVILY MODIFIED (needs cleanup)
Current state has diagnostic cruft:
- `FORCE_SHM_MODE 1` define (line 51) — forces SharedMemory mode
- `g_frame_count`, `g_page_loaded`, `g_pump_count`, `g_first_content_frame` — diagnostic globals
- `CHECK_CONTENT` macro in `get_texture_id()` — scans first 4096 bytes for non-zero
- `get_texture_id()` has extensive diagnostic readback/logging
- Buffer format logging with hex format identifiers
- Periodic STATUS logging in `axium_engine_pump()`

Key architectural decisions that ARE correct:
- `on_toplevel_changed`: sets ACTIVE state and focus AFTER view-toplevel connection
- `axium_toplevel_constructed`: does NOT set ACTIVE (deferred to on_toplevel_changed)
- `get_preferred_buffer_formats`: MAPPING usage + INVALID modifier (for DMA-BUF mode)
- `render_buffer`: stores pending buffer, returns TRUE
- `get_texture_id`: imports buffer, signals buffer_rendered/released

### What a clean `wpe_shim.c` should look like
Strip all diagnostic code. The core GObject subclass structure is sound:
- AxiumDisplay: connect (EGL), get_egl_display, create_view, create_toplevel, get_drm_device, get_preferred_buffer_formats
- AxiumView: render_buffer, notify::toplevel handler
- AxiumToplevel: resize, state management
- Public API: init, create_view, load_uri, resize, pump, has_new_frame, get_texture_id, get_frame_size, shutdown

The DMA-BUF import path (EGLImage → GL texture) and the SHM fallback path (import_to_pixels → glTexImage2D) are both implemented and structurally correct.

## How to Build and Test

```bash
cd /data/Browser/Axium

# Build and run (Nix handles all deps)
WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 nix run .#browser 2>&1

# With debug output
WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
  WEBKIT_DEBUG=Compositing \
  G_MESSAGES_DEBUG=all \
  MESA_DEBUG=1 \
  nix run .#browser 2>&1

# Key Nix packages
# nix build .#lvgl     — LVGL library + Odin bindings
# nix build .#engine   — WebKit WPE2 (from source)
# nix build .#browser  — Axium browser
```

## Remaining Tasks (beyond the rendering fix)

1. **Fix resize storm** — Window resize causes cascade; needs debounce/threshold
2. **Fix buffer double-release** — Align buffer lifecycle (rendered vs released ordering)
3. **Wire up navigation widgets** — back/forward/reload/URL bar callbacks to engine
4. **Mouse input routing** — GLFW mouse events to engine for content area
5. **Keyboard routing** — Content-focused key events to engine
6. **Clean up wpe_shim.c** — Remove all diagnostic code once rendering works

## Suggested Next Steps for Rendering Fix

1. **Inject test pattern** — In `get_texture_id`, after uploading zero pixels, overwrite with solid red via `glTexImage2D`. Confirms display pipeline works.

2. **Try WebKit debug build** — Modify `Engine/default.nix` to build with `-DCMAKE_BUILD_TYPE=RelWithDebInfo` so `WEBKIT_DEBUG` channels produce output. Then run with `WEBKIT_DEBUG=Compositing,Layers,Layout` to see what the web process compositor is doing.

3. **Check rendering update scheduling** — The critical path is: page loads → `scheduleRenderingUpdate()` → compositor requests composition → compositor calls back to main thread → `flushPendingLayerChanges()` → layers committed → compositor renders. If `scheduleRenderingUpdate()` never fires (because `m_isVisible` was false in the web process's DrawingArea at the critical moment), layers never commit.

4. **Investigate FrameDone/buffer_rendered timing** — The web process may use `buffer_rendered` (FrameDone IPC) as a signal to schedule the next rendering update. If our `buffer_rendered` call timing doesn't match what WebKit expects, it might prevent the rendering update from running.

5. **Try calling `webkit_web_view_evaluate_javascript()`** after load to trigger a DOM change, forcing a new rendering update. If THIS produces a non-zero frame, the initial rendering update is the problem.
