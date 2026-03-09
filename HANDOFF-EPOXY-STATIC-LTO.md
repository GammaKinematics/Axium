# Handoff: Axium Browser — Static+LTO libepoxy Crash

## Context

Axium is a custom browser built on WebKit WPE2 (Odin frontend, C engine shim, C++ subprocess bridge). It builds as a **single 159MB static musl+LTO binary** where WPEWebProcess and WPENetworkProcess are symlinks to the same executable, dispatched via argv[0] in main.odin.

The UI shell (LVGL) works. **The web process crashes immediately** with SIGSEGV when trying to render any web content.

## Build Configuration

- **Cross system**: `x86_64-unknown-linux-musl`, `isStatic = true`, `useLLVM = true`
- **LTO**: Full LTO for deps via crossOverlay, Thin LTO for WebKit via `-DLTO_MODE=thin`
- **No dynamic linking**: musl's `dlopen()` is stubbed — returns NULL, prints "Dynamic loading not supported"
- **No EGL/GL at runtime**: Compositing disabled, CPU-only rendering via Skia NonCompositedFrameRenderer
- **Engine rebuild is expensive**: Hours on Hetzner remote builder, costs real money. Avoid unless necessary.

## Architecture: Single-Binary Subprocess Dispatch

```
.axium-unwrapped (static binary, ~159MB)
├── WPEWebProcess -> .axium-unwrapped (symlink)
└── WPENetworkProcess -> .axium-unwrapped (symlink)
```

**main.odin** checks `argv[0]`:
- `"WPEWebProcess"` → calls `axium_web_process_main()` (subprocess.cpp) → `WebKit::WebProcessMain()`
- `"WPENetworkProcess"` → calls `axium_network_process_main()` (subprocess.cpp) → `WebKit::NetworkProcessMain()`
- Otherwise → normal browser UI (calls `engine_init()` in engine.c, then LVGL loop)

**Key**: `engine_init()` only runs in the UI process. The web process goes directly through subprocess.cpp → WebKit. They are separate processes.

## The Problem: libepoxy

WebKit unconditionally depends on libepoxy (GL/EGL function loader). Libepoxy uses `dlopen("libEGL.so.1")` at runtime to resolve EGL functions. On static musl, dlopen is stubbed → resolution fails.

### How libepoxy dispatch works

1. Each EGL function (e.g. `eglGetDisplay`) gets a **global function pointer** initialized to a resolver thunk
2. On first call, the thunk calls the resolver, stores the result in the global, then calls through it
3. The resolver tries providers (dlopen + dlsym), and if all fail, checks `epoxy_resolver_failure_handler`
4. If the handler is set, the resolver calls `handler(function_name)` which returns a function pointer to use as a stub
5. If the handler is NULL, the resolver prints an error and calls `abort()`

**Thunk macro** (from `dispatch_common.h`):
```c
#define GEN_GLOBAL_REWRITE_PTR(name, args, passthrough)          \
    static void EPOXY_CALLSPEC                                   \
    name##_global_rewrite_ptr args                               \
    {                                                            \
        if (name == (void *)name##_global_rewrite_ptr)           \
            name = (void *)name##_resolver();                    \
        name passthrough;                                        \
    }
```

**Resolver failure handler** (from `gen_dispatch.py`, lines 730-746 — generated per-target):
```c
    if (epoxy_resolver_failure_handler)
        return epoxy_resolver_failure_handler(name);

    fprintf(stderr, "No provider of %s found.  Requires one of:\n", name);
    // ... print providers ...
    abort();
```

**Handler type** (from `dispatch_common.h`):
```c
typedef void (*(*epoxy_resolver_failure_handler_t)(const char *))(void);
```
Takes a function name string, returns a `void (*)(void)` function pointer.

**Setter function** (from `dispatch_common.c`):
```c
epoxy_resolver_failure_handler_t
epoxy_set_resolver_failure_handler(epoxy_resolver_failure_handler_t handler)
{
    // mutex-protected swap of the global
    old = epoxy_resolver_failure_handler;
    epoxy_resolver_failure_handler = handler;
    return old;
}
```

### What we did

#### 1. libepoxy override in flake.nix (lines 194-220)

In the `crossOverlays` for `pkgsLto`:

- **eglStub** (lines 173-193): Provides EGL headers + empty `.a` + pkg-config so libepoxy's meson build enables EGL support without real libglvnd
- **libepoxy override** (lines 194-220):
  - `x11Support = false` (drops libglvnd, libGL, libX11)
  - Adds eglStub to buildInputs
  - Changes meson flag `-Degl=no` → `-Degl=yes`
  - **postPatch**:
    - Replaces all `abort();` with `(void)0;` in `dispatch_common.c`
    - Adds `epoxy_stub_` (void function) and `epoxy_stub_handler_` (returns `epoxy_stub_`)
    - Sets `epoxy_resolver_failure_handler = epoxy_stub_handler_` in the `library_init()` constructor

#### 2. Runtime handler override in subprocess.cpp and engine.c

Added `epoxy_ret0_handler_` that returns address of `epoxy_ret0_` (a `long` function returning 0), and calls `epoxy_set_resolver_failure_handler()` before WebKit starts. The intent: all stubbed EGL functions return 0 (EGL_FALSE/NULL/EGL_NO_DISPLAY) instead of garbage.

## What We Found: TWO Critical Issues

### Issue 1: `.init_array` is completely dead

The binary's `.init_array` section (0x348 bytes = 105 entries) is **entirely zeros**. No relocations exist in the binary either. This means:

- **No constructors run** — not libepoxy's `library_init()`, not glib's, not WebKit's
- `epoxy_resolver_failure_handler` (in BSS) stays at 0 — the constructor-based stub is never installed
- This is likely a linker/LTO issue with static musl + LLVM

### Issue 2: LTO broke the connection between setter and resolver

Even with our explicit `epoxy_set_resolver_failure_handler()` call in subprocess.cpp (which DOES run before WebKit), the resolver in the binary reads from a **different address** than where the setter writes:

- `epoxy_resolver_failure_handler` global is in **`.bss`** (starts at `0x87f1000`) — this is where `epoxy_set_resolver_failure_handler()` writes
- The generated resolver code in the binary checks address **`0x87b8168`** which is in **`.data`** (starts at `0x87b1680`) — a different global

LTO appears to have optimized the generated dispatch code so it no longer references the same `epoxy_resolver_failure_handler` symbol that the setter function writes to. The resolver reads from a dispatch pointer in `.data`; the setter writes to the real handler in `.bss`. They don't communicate.

**Evidence**: No `[epoxy-stub]` debug output appears even though `epoxy_ret0_handler_` prints to stderr. The handler function is never called by the resolver.

### Crash sequence

1. Web process starts → subprocess.cpp sets handler (writes to BSS global — correct but pointless)
2. WebKit init calls an EGL function through epoxy
3. Epoxy thunk calls the resolver
4. Resolver tries dlopen("libEGL.so.1") → fails (static musl)
5. Resolver checks its copy of the handler at `0x87b8168` (.data) → reads 0 (NULL, because the setter wrote to a different address in .bss)
6. Handler is NULL → generated code either aborts (we patched abort in dispatch_common.c but NOT in the generated dispatch files) or returns NULL
7. Thunk stores NULL in the dispatch global
8. Next call through the dispatch global → `call *0x0` → **SIGSEGV**

### Core dump confirmation

```
Signal: 11 (SEGV)
Frame #0: 0x0000000000000000  ← jumped to NULL
Registers: rax = 0

Runtime value at 0x87b8168: 0x0000000000000000
Binary value at 0x87b8168: 0x0000000005101160 (was the resolver thunk address)
```

The dispatch global was overwritten from the resolver address to NULL by the thunk after the resolver returned NULL.

## What Needs to Happen

The runtime `epoxy_set_resolver_failure_handler` approach is broken by LTO. The fix must happen **at compile time inside libepoxy**, before LTO can split globals. Options:

### Option A: Patch gen_dispatch.py (recommended)

Modify the generated resolver to never abort/return-NULL when resolution fails. Instead of checking `epoxy_resolver_failure_handler`, unconditionally return a stub. This changes the generated C code BEFORE compilation/LTO, so there's no global mismatch.

In `gen_dispatch.py`, the `write_provider_resolver()` method (around line 730) generates:
```python
self.outln('    if (epoxy_resolver_failure_handler)')
self.outln('        return epoxy_resolver_failure_handler(name);')
# ... fprintf + abort ...
```

This could be changed to always return a static stub function pointer, eliminating the handler global entirely.

### Option B: Patch the generated .c files post-meson

After meson generates `dispatch_egl.c` etc., post-patch them to replace the abort/handler logic. Fragile but doesn't require modifying gen_dispatch.py.

### Option C: Patch the thunk macros in dispatch_common.h

Change `GEN_GLOBAL_REWRITE_PTR` / `GEN_GLOBAL_REWRITE_PTR_RET` to handle NULL resolver return (return 0 instead of calling through NULL). This doesn't fix the root cause (resolver still returns NULL) but prevents the crash.

### Important considerations

- **Engine rebuild required** — any libepoxy change triggers a full WebKit rebuild (hours, Hetzner builder)
- The `abort()` calls in the generated dispatch files (NOT dispatch_common.c) were **never patched** — only dispatch_common.c was patched
- The `epoxy_stub_` in the constructor is `void` return — if it somehow runs, it leaves rax indeterminate. The correct stub must return `long 0`
- All three processes (UI, Web, Network) must be covered by whatever fix is applied

## Current File State

### `/data/Browser/Axium/flake.nix` (lines 194-220)
Current libepoxy override with postPatch that:
- Removes `abort()` from dispatch_common.c only
- Installs void stub handler in constructor (dead — constructors don't run)

### `/data/Browser/Axium/Engine/subprocess.cpp`
Has `epoxy_ret0_handler_` + `epoxy_set_resolver_failure_handler()` call before WebProcessMain/NetworkProcessMain. Currently broken due to LTO global mismatch. Has debug fprintf that never fires.

### `/data/Browser/Axium/Engine/engine.c` (around line 1940)
Same handler override for the UI process (engine_init). Also broken for the same reason. Should be cleaned up once a proper fix is in place.

### `/data/Browser/Axium/Engine/engine.nix`
WebKit build with all static/LTO patches. libepoxy is in buildInputs (line 187) — changing libepoxy triggers engine rebuild.

### `/data/Browser/libepoxy/` (local clone)
Unmodified upstream libepoxy source for reference. Key files:
- `src/dispatch_common.c` — dlopen/dlsym logic, handler global, setter
- `src/dispatch_common.h` — GEN_GLOBAL_REWRITE_PTR thunk macros
- `src/gen_dispatch.py` — generates resolver + thunk code per EGL/GL function

## Rules

- **NEVER scan /nix/store** with find/glob
- **NEVER pipe nix commands** through grep/tr/etc — run clean, redirect to file, then search
- **Always discuss/validate approach** before implementing — especially before triggering engine rebuilds
- **Engine builds are expensive** — verify patches against source BEFORE building. Catch errors early.
- **Don't remove existing functionality** without explicit permission
