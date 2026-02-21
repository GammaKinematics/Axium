# WebKit WPE2 Build Flags & Options

Complete reference for all configurable flags when building WebKit's **WPE2** (WPEWebKit 2.0) variant from source.

## Key Configuration Files

| File | Purpose |
|------|---------|
| `Source/cmake/OptionsWPE.cmake` (69 KB) | WPE-specific options and port defaults |
| `Source/cmake/WebKitFeatures.cmake` (24 KB) | Cross-port feature definitions |
| `Source/WebKit/PlatformWPE.cmake` (27 KB) | WPE platform build targets |
| `CMakeLists.txt` | Main entry point |

## Usage

Flags are passed via CMake at configuration time:

```bash
cmake -DPORT=WPE -DCMAKE_BUILD_TYPE=RelWithDebInfo -D<FLAG>=<VALUE> ..
```

Or using the build wrapper script:

```bash
Tools/Scripts/build-webkit --wpe [--debug|--release] [options]
```

---

## WPE2-Specific Platform Options (Public)

### Core WPE Platform

| Flag | Default | Description |
|------|---------|-------------|
| `ENABLE_WPE_1_1_API` | **OFF** | Build legacy WPE 1.1 API instead of WPE 2.0. OFF = WPE2. |
| `ENABLE_WPE_PLATFORM` | `${ENABLE_DEVELOPER_MODE}` | Build the WPEPlatform library (the new WPE 2.0 abstraction) |
| `ENABLE_WPE_PLATFORM_DRM` | ON | DRM (Direct Rendering Manager) backend |
| `ENABLE_WPE_PLATFORM_HEADLESS` | ON | Headless (no display) backend |
| `ENABLE_WPE_PLATFORM_WAYLAND` | ON | Wayland display server backend |
| `ENABLE_WPE_LEGACY_API` | ON | Legacy libwpe-based API for backwards compat |
| `ENABLE_WPE_QT_API` | `${ENABLE_DEVELOPER_MODE}` | Qt/QML plugin for WPE |

### Documentation, Introspection & Logging

| Flag | Default | Description |
|------|---------|-------------|
| `ENABLE_DOCUMENTATION` | ON | Generate API docs via gi-docgen |
| `ENABLE_INTROSPECTION` | ON | GObject introspection for language bindings |
| `ENABLE_JOURNALD_LOG` | ON | systemd journald logging |

### Media & Web APIs

| Flag | Default | Description |
|------|---------|-------------|
| `ENABLE_PDFJS` | ON | PDF.js PDF rendering |
| `ENABLE_SPEECH_SYNTHESIS` | ON | Text-to-speech |
| `ENABLE_WEBDRIVER` | ON | WebDriver (browser automation) |
| `ENABLE_XSLT` | ON | XSLT stylesheet processing |
| `ENABLE_ENCRYPTED_MEDIA` | `${ENABLE_EXPERIMENTAL_FEATURES}` | Encrypted Media Extensions (DRM playback) |

### Image Formats & Fonts

| Flag | Default | Description |
|------|---------|-------------|
| `USE_AVIF` | ON | AVIF image support |
| `USE_JPEGXL` | ON | JPEG XL image support |
| `USE_LCMS` | ON | Color management (libcms2) |
| `USE_WOFF2` | ON | WOFF2 web font support |
| `USE_LIBHYPHEN` | ON | Automatic hyphenation |
| `USE_SKIA_OPENTYPE_SVG` | ON | Skia OpenType SVG font rendering |

### Accessibility & Input

| Flag | Default | Description |
|------|---------|-------------|
| `USE_ATK` | ON | ATK accessibility toolkit |
| `USE_FLITE` | ON | Flite speech synthesis engine |

### Graphics & System

| Flag | Default | Description |
|------|---------|-------------|
| `USE_GBM` | ON | Generic Buffer Management |
| `USE_LIBDRM` | ON | libdrm for DRM support |
| `USE_LIBBACKTRACE` | ON | Better crash traces |

### Linux-Only

| Flag | Default | Description |
|------|---------|-------------|
| `ENABLE_BUBBLEWRAP_SANDBOX` | ON (Linux) | Bubblewrap process sandboxing |
| `ENABLE_MEMORY_SAMPLER` | ON (Linux) | Memory profiling sampler |
| `ENABLE_RESOURCE_USAGE` | ON (Linux) | Resource usage monitoring |

---

## WPE2-Specific Options (Private / Advanced)

| Flag | Default | Description |
|------|---------|-------------|
| `ENABLE_ASYNC_SCROLLING` | ON | Asynchronous (threaded) scrolling |
| `ENABLE_AUTOCAPITALIZE` | ON | Text autocapitalization |
| `ENABLE_CONTENT_EXTENSIONS` | ON | Content filtering/ad blocking engine |
| `ENABLE_CURSOR_VISIBILITY` | ON | Cursor show/hide support |
| `ENABLE_DARK_MODE_CSS` | ON | `prefers-color-scheme` dark mode |
| `ENABLE_DRAG_SUPPORT` | ON | Drag-and-drop |
| `ENABLE_FTPDIR` | **OFF** | FTP directory listings |
| `ENABLE_GAMEPAD` | ON | Gamepad API |
| `ENABLE_GPU_PROCESS` | ON | Separate GPU process for rendering |
| `ENABLE_MEDIA_CONTROLS_CONTEXT_MENUS` | ON | Context menus on media controls |
| `ENABLE_MEDIA_RECORDER` | ON | MediaRecorder API |
| `ENABLE_MEDIA_SESSION` | ON | Media Session API |
| `ENABLE_MEDIA_SESSION_PLAYLIST` | **OFF** | Media Session playlist extensions |
| `ENABLE_MEDIA_STREAM` | ON | getUserMedia / MediaStream API |
| `ENABLE_MOUSE_CURSOR_SCALE` | ON | HiDPI cursor scaling |
| `ENABLE_MHTML` | ON | MHTML web archives |
| `ENABLE_NOTIFICATIONS` | ON | Web Notifications API |
| `ENABLE_OFFSCREEN_CANVAS` | ON | OffscreenCanvas API |
| `ENABLE_OFFSCREEN_CANVAS_IN_WORKERS` | ON | OffscreenCanvas in Web Workers |
| `ENABLE_PERIODIC_MEMORY_MONITOR` | ON | Periodic memory monitor |
| `ENABLE_SHAREABLE_RESOURCE` | ON | Network shareable resources |
| `ENABLE_THUNDER` | `${ENABLE_DEVELOPER_MODE}` | Thunder CDM (DRM plugin) |
| `ENABLE_TOUCH_EVENTS` | ON | Touch events |
| `ENABLE_VARIATION_FONTS` | ON | Variable/OpenType variation fonts |
| `ENABLE_WEB_CODECS` | ON | WebCodecs API |
| `ENABLE_WEB_RTC` | `${ENABLE_EXPERIMENTAL_FEATURES}` | WebRTC peer-to-peer |
| `ENABLE_WEBDRIVER_BIDI` | `${ENABLE_EXPERIMENTAL_FEATURES}` | WebDriver BiDi protocol |
| `ENABLE_WK_WEB_EXTENSIONS` | `${ENABLE_EXPERIMENTAL_FEATURES}` | WebKit Web Extensions |
| `ENABLE_WEBXR` | `${ENABLE_EXPERIMENTAL_FEATURES}` | WebXR immersive web |
| `ENABLE_WEBXR_HIT_TEST` | `${ENABLE_EXPERIMENTAL_FEATURES}` | WebXR hit testing |
| `ENABLE_WEBXR_LAYERS` | `${ENABLE_EXPERIMENTAL_FEATURES}` | WebXR layers |
| `ENABLE_API_TESTS` | `${ENABLE_DEVELOPER_MODE}` | Public API unit tests |
| `ENABLE_LAYOUT_TESTS` | `${ENABLE_DEVELOPER_MODE}` | Layout/regression tests |
| `ENABLE_MINIBROWSER` | developer-mode dependent | MiniBrowser test app |
| `ENABLE_COG` | **OFF** | Cog launcher/browser |
| `ENABLE_JSC_RESTRICTED_OPTIONS_BY_DEFAULT` | developer-mode dependent | Dangerous JSC dev options |
| `USE_EXTERNAL_HOLEPUNCH` | **OFF** | External holepunch (media) |
| `USE_SPIEL` | **OFF** | LibSpiel speech synthesis (alt to Flite) |
| `USE_SYSPROF_CAPTURE` | ON | sysprof performance tracing |
| `USE_SYSTEM_SYSPROF_CAPTURE` | ON | Use system sysprof (vs bundled) |
| `USE_SYSTEM_UNIFDEF` | ON | Use system unifdef tool |

---

## General WebKit Feature Flags (Architecture-Dependent)

### JIT & WebAssembly

| Flag | Default (x86_64/arm64) | Default (other) | Description |
|------|------------------------|-----------------|-------------|
| `ENABLE_JIT` | ON | OFF | JIT JavaScript compilation |
| `ENABLE_DFG_JIT` | ON | OFF | DFG optimization tier |
| `ENABLE_FTL_JIT` | ON | OFF | FTL top-tier optimizing JIT |
| `ENABLE_C_LOOP` | OFF | ON | C-interpreter fallback (conflicts with JIT) |
| `ENABLE_WEBASSEMBLY` | ON | OFF | WebAssembly support |
| `ENABLE_WEBASSEMBLY_BBQJIT` | ON (FTL-capable) | OFF | Wasm BBQ JIT tier |
| `ENABLE_WEBASSEMBLY_OMGJIT` | ON (FTL-capable) | OFF | Wasm OMG JIT tier |
| `ENABLE_SAMPLING_PROFILER` | ON | OFF | Sampling-based JS profiler |

### Memory Allocators

| Flag | Default (x86_64/arm64) | Default (other) | Description |
|------|------------------------|-----------------|-------------|
| `USE_SYSTEM_MALLOC` | OFF | ON | Use system malloc vs. bmalloc |
| `USE_MIMALLOC` | OFF (x86_64/arm64) | ON (arm/mips) | Use mimalloc allocator |
| `USE_ISO_MALLOC` | ON (non-Apple) | -- | IsoMalloc heap isolation |
| `USE_64KB_PAGE_BLOCK` | OFF | -- | 64KB page size (aarch64-specific) |

### Core Web Standards

| Flag | Default | Description |
|------|---------|-------------|
| `ENABLE_VIDEO` | ON | HTML5 `<video>` |
| `ENABLE_WEB_AUDIO` | ON | Web Audio API |
| `ENABLE_WEBGL` | ON | WebGL |
| `ENABLE_WEBGPU` | **OFF** | WebGPU (experimental) |
| `ENABLE_MEDIA_SOURCE` | **OFF** | Media Source Extensions |
| `ENABLE_MATHML` | ON | MathML |
| `ENABLE_FULLSCREEN_API` | ON | Fullscreen API |
| `ENABLE_GEOLOCATION` | ON | Geolocation API |
| `ENABLE_REMOTE_INSPECTOR` | ON | Remote Web Inspector |
| `ENABLE_SMOOTH_SCROLLING` | ON | Smooth scrolling |
| `ENABLE_CONTEXT_MENUS` | ON | Context menus |

### DevTools & Debugging

| Flag | Default | Description |
|------|---------|-------------|
| `ENABLE_REMOTE_INSPECTOR` | ON | Remote web inspector |
| `ENABLE_INSPECTOR_EXTENSIONS` | OFF | Inspector web extensions |
| `ENABLE_INSPECTOR_ALTERNATE_DISPATCHERS` | OFF | Alternate inspector dispatchers |
| `ENABLE_INSPECTOR_TELEMETRY` | OFF | Inspector telemetry |
| `ENABLE_RELEASE_LOG` | OFF | Release log statements |

### DOM & Web Standards (Additional)

| Flag | Default | Description |
|------|---------|-------------|
| `ENABLE_PAYMENT_REQUEST` | OFF | Payment Request API |
| `ENABLE_POINTER_LOCK` | OFF | Pointer Lock API |
| `ENABLE_DEVICE_ORIENTATION` | OFF | Device Orientation API |
| `ENABLE_WEB_AUTHN` | OFF | WebAuthn (FIDO2) authentication |
| `ENABLE_TEXT_AUTOSIZING` | OFF | Automatic text size adjustment |
| `ENABLE_USER_MESSAGE_HANDLERS` | ON | User script message handlers |
| `ENABLE_NAVIGATOR_STANDALONE` | OFF | Standalone navigator mode |
| `ENABLE_VIDEO_PRESENTATION_MODE` | OFF | Video fullscreen presentation mode |
| `ENABLE_VIDEO_USES_ELEMENT_FULLSCREEN` | ON | Video element fullscreen |
| `ENABLE_CACHE_PARTITIONING` | OFF | Cache partitioning for privacy |
| `ENABLE_APPLICATION_MANIFEST` | OFF | Web application manifest support |

### Build System

| Flag | Default | Description |
|------|---------|-------------|
| `ENABLE_UNIFIED_BUILDS` | ON | Unified (jumbo) source builds for speed |
| `ENABLE_JAVASCRIPT_SHELL` | ON | Build `jsc` shell |
| `ENABLE_IMAGE_DIFF` | ON | Image diff for layout tests |
| `ENABLE_DEVELOPER_MODE` | OFF | Master developer toggle |
| `ENABLE_EXPERIMENTAL_FEATURES` | OFF | Master experimental toggle |
| `ENABLE_LLVM_PROFILE_GENERATION` | OFF | PGO profile generation |
| `ENABLE_BREAKPAD` | OFF | Breakpad crash reporting |
| `ENABLE_MALLOC_HEAP_BREAKDOWN` | OFF | Malloc heap breakdown tracking |
| `ENABLE_REFTRACKER` | OFF | RAII object tracking for debugging |

---

## Critical Conflicts (Mutually Exclusive)

```
ENABLE_WPE_PLATFORM  <-->  ENABLE_WPE_1_1_API
ENABLE_JIT           <-->  ENABLE_C_LOOP
ENABLE_SAMPLING_PROFILER  <-->  ENABLE_C_LOOP
ENABLE_WEBASSEMBLY   <-->  ENABLE_C_LOOP
USE_FLITE            <-->  USE_SPIEL
```

## Key Dependency Chains

```
ENABLE_FTL_JIT --> ENABLE_DFG_JIT --> ENABLE_JIT
ENABLE_WEBASSEMBLY_OMGJIT --> ENABLE_FTL_JIT
ENABLE_WEBASSEMBLY_BBQJIT --> ENABLE_FTL_JIT
ENABLE_WPE_PLATFORM_DRM --> USE_GBM --> USE_LIBDRM
ENABLE_GPU_PROCESS --> USE_GBM
ENABLE_WPE_QT_API --> ENABLE_WPE_PLATFORM
ENABLE_COG --> ENABLE_WPE_LEGACY_API
ENABLE_DOCUMENTATION --> ENABLE_INTROSPECTION
USE_SYSTEM_SYSPROF_CAPTURE --> USE_SYSPROF_CAPTURE
ENABLE_WEB_RTC --> ENABLE_MEDIA_STREAM
ENABLE_ENCRYPTED_MEDIA --> ENABLE_VIDEO
ENABLE_WEBXR --> ENABLE_GAMEPAD
ENABLE_WEBXR_HIT_TEST --> ENABLE_WEBXR
ENABLE_WEBXR_LAYERS --> ENABLE_WEBXR
ENABLE_MEDIA_RECORDER --> ENABLE_MEDIA_STREAM
ENABLE_MEDIA_CONTROLS_CONTEXT_MENUS --> ENABLE_VIDEO
ENABLE_MEDIA_SESSION --> ENABLE_VIDEO
ENABLE_MEDIA_SOURCE --> ENABLE_VIDEO
ENABLE_VIDEO_PRESENTATION_MODE --> ENABLE_VIDEO
ENABLE_VIDEO_USES_ELEMENT_FULLSCREEN --> ENABLE_VIDEO
```

## Developer Mode Cascade

Setting `ENABLE_DEVELOPER_MODE=ON` auto-enables:

- `ENABLE_API_TESTS`
- `ENABLE_LAYOUT_TESTS`
- `ENABLE_MINIBROWSER`
- `ENABLE_WPE_PLATFORM`
- `ENABLE_WPE_QT_API`
- `ENABLE_THUNDER`
- `ENABLE_JSC_RESTRICTED_OPTIONS_BY_DEFAULT`

---

## Example Build Commands

### Minimal WPE2 Build (Production)

```bash
cmake -DPORT=WPE -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_WPE_1_1_API=OFF \
  -DENABLE_WPE_PLATFORM=ON \
  -DENABLE_WPE_LEGACY_API=OFF \
  ..
```

### Full-Featured WPE2 Build (Development)

```bash
cmake -DPORT=WPE -DCMAKE_BUILD_TYPE=Debug \
  -DENABLE_DEVELOPER_MODE=ON \
  -DENABLE_WPE_1_1_API=OFF \
  -DENABLE_WPE_PLATFORM=ON \
  -DENABLE_WPE_PLATFORM_DRM=ON \
  -DENABLE_WPE_PLATFORM_WAYLAND=ON \
  -DENABLE_WPE_PLATFORM_HEADLESS=ON \
  -DENABLE_WPE_LEGACY_API=ON \
  -DENABLE_WPE_QT_API=OFF \
  -DENABLE_DOCUMENTATION=ON \
  -DENABLE_INTROSPECTION=ON \
  -DENABLE_EXPERIMENTAL_FEATURES=ON \
  ..
```

### Headless Only Build

```bash
cmake -DPORT=WPE -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_WPE_1_1_API=OFF \
  -DENABLE_WPE_PLATFORM=ON \
  -DENABLE_WPE_PLATFORM_DRM=OFF \
  -DENABLE_WPE_PLATFORM_WAYLAND=OFF \
  -DENABLE_WPE_PLATFORM_HEADLESS=ON \
  -DENABLE_WPE_LEGACY_API=OFF \
  ..
```

### Wayland + DRM Display Support

```bash
cmake -DPORT=WPE -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_WPE_1_1_API=OFF \
  -DENABLE_WPE_PLATFORM=ON \
  -DENABLE_WPE_PLATFORM_DRM=ON \
  -DENABLE_WPE_PLATFORM_WAYLAND=ON \
  -DENABLE_WPE_PLATFORM_HEADLESS=OFF \
  ..
```

---

## Summary

- **WPE-Specific Defined Options:** 21 (public)
- **WPE-Specific Port Value Overrides:** 44 (private/advanced)
- **General WebKit Features:** 122+
- **Total Configurable Options:** ~187+
