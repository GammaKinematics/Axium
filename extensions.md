# Axium Extension System Design

## Overview

Adblock is baked into the binary as core browser infrastructure — it runs compiled
code in the web process for per-request filtering performance. Everything else
(Translate, Keepass, third-party extensions) becomes an optional, droppable
extension loaded at runtime.

Extensions use the standard WebExtensions manifest format, making Axium compatible
with Firefox (.xpi) and Chrome (.crx) extensions out of the box.


## dlopen in Static Builds

musl libc defines `dlopen`, `dlsym`, `dlclose`, and `dlerror` as weak stubs in
static builds (they compile and link but return NULL at runtime). Override them
with strong definitions that delegate to detour's `DTLinker`:

```c
static DTLinker *g_linker = NULL;

void detour_dl_init(DTLinker *linker) { g_linker = linker; }

void *dlopen(const char *file, int mode) {
    if (!g_linker) return NULL;
    return g_linker->dlopen(file, mode);
}

void *dlsym(void *handle, const char *symbol) {
    if (!g_linker) return NULL;
    return g_linker->dlsym(handle, symbol);
}

int dlclose(void *handle) {
    if (!g_linker) return -1;
    return g_linker->dlclose(handle);
}

char *dlerror(void) {
    if (!g_linker) return "detour not initialized";
    return (char *)g_linker->dlerror();
}
```

At link time these override musl's weak stubs globally. All dlopen callers in
the binary — GLib's `g_module_open`, WebKit's extension loader, GIO TLS modules,
GStreamer plugin loading — get working dynamic loading for free.

Requires `detour_init()` called early in both UI process and web process
(subprocess.cpp) paths before anything calls dlopen.

Eliminates the current surgical WebKit patches for static extension loading
(weak symbol hack in WebProcessExtensionManager, g_module_open bypass in
InjectedBundleGlib.cpp).


## Extension Architecture

### Web process side: JS/CSS only

No compiled code in the web process for extensions (same model as Chrome, Firefox,
Safari). A single built-in content script loader in the web process handles
injection for all extensions:

1. On `page-created`, check URL against each extension's `content_scripts[].matches`
2. On match, inject JS and CSS into the page via the JSC context
3. Use WebKit's script world isolation to prevent collision with page scripts

The content script loader is part of Axium, not an extension itself.

### UI process side: optional native code

Extensions that need native functionality (translation engine, password manager IPC)
include a `extension.so` in their archive. Loaded once by Axium's own dlopen in the UI
process, shared across all tabs. Never duplicated per web process.

Examples:
- Translate: Bergamot engine lives in extension.so (loaded once), DOM text
  extraction/injection is JS content scripts (per page)
- Keepass: libsodium crypto + KeePassXC Unix socket IPC in extension.so,
  form detection is JS content scripts (per page)

### Communication

WebKit's built-in async message passing between content scripts (web process)
and extension.so code (UI process):

- Content script -> UI: `webkit_web_page_send_message_to_view()`
- UI -> Content script: `user-message-received` signal
- GVariant-based structured messages with async reply support


## Extension Formats

### .axe (Axium native)

A plain zip archive:

```
manifest.json       # standard WebExtensions format + optional "axium" key
content.js          # web process: injected into matching pages
styles.css          # web process: injected styles
extension.so               # UI process: optional native code
resources/          # data files (models, filter lists, etc.)
```

The `manifest.json` follows the WebExtensions standard with an optional
Axium-specific key:

```json
{
  "name": "Translate",
  "version": "1.2.0",
  "content_scripts": [{
    "matches": ["<all_urls>"],
    "js": ["content.js"],
    "run_at": "document_end"
  }],
  "axium": {
    "update_url": "https://axium.dev/extensions/translate.json",
    "has_native": true
  }
}
```

### .xpi (Firefox)

Plain zip. Same manifest.json / content_scripts structure. Load directly.
Extensions from Firefox AMO work as-is for content-script-only extensions.

### .crx (Chrome)

Zip with a binary header:

```
[4 bytes: "Cr24" magic]
[4 bytes: version (3)]
[4 bytes: header_length]
[header_length bytes: protobuf signing proofs]
[rest: standard zip payload]
```

Skip 12 + header_length bytes to reach the zip. Same manifest.json inside.
Chrome extensions include `update_url` and `version` in their manifest for
auto-update.

### Format detection

On load, check first 4 bytes:
- `Cr24` -> .crx, skip header, extract zip
- `PK\x03\x04` -> zip (.axe or .xpi), extract directly

All three formats contain a standard `manifest.json` with `content_scripts`.


## Loading Flow

On startup:

1. Read `extensions.sjson` registry
2. Scan `~/.config/axium/extensions/` for .axe/.xpi/.crx files
3. Reconcile: new file on disk -> add registry entry, deleted file -> remove entry
4. For each enabled extension:
   a. Detect format, extract zip to `~/.cache/axium/extensions/<name>/`
   b. Parse `manifest.json`
   c. Register content script rules (URL patterns, JS/CSS files, run_at timing)
   d. If `extension.so` exists, dlopen it from cache dir, call init symbol
5. Content script loader in web process injects JS/CSS on matching page loads


## Extension Registry — extensions.sjson

Lives in `~/.config/axium/extensions/` alongside extension archives. Machine-managed
but user-editable for declarative setup. Parallel structure to settings.sjson /
setting.odin.

```sjson
// Stock Axium extension
translate: {
  type: axe
  version: 1.2.0
  url: https://axium.dev/extensions/translate-1.2.0.axe
  auto_update: true
  enabled: true
}

// Installed from Firefox AMO
refined-github: {
  type: xpi
  version: 26.3.3
  id: {a4c4eda4-fb84-4a84-b4a1-f7c1cbf2a1ad}
  auto_update: true
  enabled: true
}

// Manually added Chrome extension
github-file-icons: {
  type: crx
  version: 1.6.0
  id: ficfmibkjjnpogdcfhfokmihanoldbfe
  update_url: https://clients2.google.com/service/update2/crx
  auto_update: true
  enabled: false
}

// Local custom extension, no auto-update
my-custom-thing: {
  type: axe
  version: 0.1.0
  auto_update: false
  enabled: true
}
```


## Auto-Update

### Stock Axium extensions
Own repo metadata JSON fetched periodically:
```json
{"version": "1.3.0", "url": "https://..../translate-1.3.0.axe", "hash": "sha256:..."}
```
Compare local version against remote, download if newer.

### Firefox extensions
AMO public REST API by extension GUID:
```
GET https://addons.mozilla.org/api/v5/addons/addon/<slug-or-guid>/
```
Returns `current_version.version`, `current_version.file.url`,
`current_version.file.hash` (sha256).

### Chrome extensions
Google's update service via `update_url` + extension ID from the .crx manifest.
The extension ID is derivable from the signing key in the Cr24 header.
```
GET https://clients2.google.com/service/update2/crx?response=redirect&prodversion=120.0&x=id%3D<ID>%26installsource%3Dondemand%26uc
```

### Custom/local extensions
No auto-update. User manages manually by replacing the file. Setting
`auto_update: false` in the registry.


## Extension Manager UI

No store. Simple built-in management:

- Search Firefox catalog via AMO API (`/api/v5/addons/search/?q=<query>&type=extension`)
- Stock extensions listed from Axium's own repo metadata
- Chrome extensions: manual install only (no public search API), auto-update works after install
- Settings page shows installed extensions with enable/disable toggle and update status
- User can hand-edit extensions.sjson for declarative setup


## WebKit Web Process Extension Capabilities

Available to the built-in content script loader and any future compiled
web process code:

- **Page lifecycle**: page-created, didFinishDocumentLoad, didClearWindowObjectForFrame
- **Network interception**: willSendRequestForFrame (modify/block/redirect requests)
- **DOM access**: full JSC context per frame, WKBundleNodeHandle API
- **Script world isolation**: named isolated worlds for injected scripts
- **Form introspection**: didFocusTextField, willSubmitForm, didAssociateFormControls
- **Autofill support**: SetHTMLInputElementValueForUser, SetAutoFilled
- **Navigation policy**: decidePolicyForNavigationAction (block/allow)
- **Context menus**: getContextMenuFromDefaultMenu (modify right-click menu)
- **Bidirectional messaging**: async GVariant messages between web and UI process
- **Content editing**: editor client callbacks for contenteditable elements
- **Console access**: willAddMessageToConsole


## Current Implementation (Phase 1)

### Files

| File | Role |
|------|------|
| `Browser/extension.odin` | Registry, loader, zip reader, polyfill, storage, page serving, popup UI |
| `Engine/engine.c` | `engine_add_user_script/style`, `engine_remove_all_user_content`, `_axium_ext` message routing, `ext/` URI scheme handler |
| `Engine/engine.odin` | FFI declarations for the above |
| `Browser/command.odin` | `"extensions"` command → `extension_trigger()` |
| `Browser/main.odin` | `extension_init()` call at startup |

### What works

- **Registry**: `~/.config/axium/extensions/extensions.sjson` — auto-reconciled with
  files on disk at startup. Tracks name, version, type, enabled, id, urls.
- **Format detection**: PK magic → zip, Cr24 magic → CRX3 (skip header), then zip.
- **Zip caching**: Raw archive bytes + parsed central directory index kept on
  `Ext_Entry` at load time. Content scripts extracted on demand for WebKit
  registration, pages extracted on demand for serving. Freed on unload.
- **Manifest parsing**: Standard JSON. Reads `name`, `version`, `content_scripts`,
  `options_ui`/`options_page`, `browser_specific_settings.gecko.id`,
  `applications.gecko.id`, `update_url`.
- **Content script injection**: Via WebKit `UserContentManager` in an isolated
  `"axium-ext"` script world. JS via `webkit_user_script_new_for_world`, CSS via
  `webkit_user_style_sheet_new_for_world`. Match patterns from manifest.
- **Per-extension polyfill**: `browser.*`/`chrome.*` shim injected per extension with
  baked `ext_id`. Provides `runtime.id`, `runtime.getURL()`, `runtime.sendMessage()`,
  `storage.local.get/set`, `i18n.getMessage()`.
- **Message handling**: Content script `postMessage` → engine.c `_axium_ext` routing →
  Odin `extension_handle_message` export. Dispatches `storage.get`, `storage.set`,
  `sendMessage`.
- **Storage**: Per-extension JSON files at
  `~/.config/axium/extensions/storage/{id}.json`. Supports full WebExtension
  `storage.local` semantics: null→all, string→single key, array→multiple keys,
  object→keys with defaults.
- **Extension pages**: Served via `axium://ext/{id}/{path}`. engine.c checks
  `ext/` prefix in `on_axium_uri_scheme`, calls Odin `extension_serve_file` which
  extracts from cached zip. MIME detection from file extension.
- **Options page**: Parsed from `options_ui.page` or `options_page` in manifest.
  Gear button in popup navigates to `axium://ext/{id}/{options_page}`.
- **Popup UI**: Toggle ON/OFF per extension, settings gear button, name+version display.
- **Enable/disable**: Full re-registration cycle — `engine_remove_all_user_content`
  then re-register all remaining loaded extensions (WebKit has no per-script removal).

### Data model

```odin
Ext_Content_Script :: struct {
    matches:   [dynamic]string,
    js_files:  [dynamic]string,    // file paths within zip
    css_files: [dynamic]string,    // file paths within zip
    run_at:    Ext_Run_At,         // Document_Start or Document_End
}

Ext_Entry :: struct {
    // Persisted
    name, version, id, url, update_url, filename: string,
    type_: Ext_Type,  // Axe, Xpi, Crx
    enabled, auto_update: bool,

    // Runtime
    content_scripts: [dynamic]Ext_Content_Script,
    options_page: string,
    loaded: bool,

    // Cached archive
    archive:     []u8,        // raw file bytes
    zip_entries: []Zip_Entry, // parsed central directory
    zip_offset:  int,         // where zip starts (0 for PK, 12+header for CRX)
}
```

### What's NOT implemented

- **Background scripts / service workers** — `runtime.sendMessage` returns null
  (no listener). See "WebKit Stock Extension System" section below for analysis.
- **extension.so native code loading** — fully designed (see "Native Code Loading" section), not built
- **Auto-update** — designed (AMO API, Chrome update service, custom repo) but not built
- **Extension manager / search UI** — not built
- **tabs, windows, webRequest, commands, menus, notifications APIs** — not shimmed
- **Permission system** — all extensions get full access


## WebKit Stock Extension System — Analysis & Decision

WebKit has a complete built-in browser extension framework
(`Source/WebKit/UIProcess/Extensions/`) originally built for Safari. We investigated
using it instead of our custom system. Below are the findings for future reference.

### Architecture

Three-tier: `WebExtensionController` manages `WebExtensionContext` instances (one per
extension) which coordinate between UIProcess (lifecycle, permissions, storage) and
WebProcess (JS API bindings, content script injection).

```
UIProcess                        WebProcess
WebExtensionController    <-->   WebExtensionControllerProxy
├─ WebExtensionContext    <-->   WebExtensionContextProxy
│  └─ background WKWebView        └─ browser.* JS API bindings
└─ WebExtension (manifest)         └─ content script injection
```

### API coverage

The WebProcess JS bindings implement nearly the full WebExtensions API:
`runtime`, `tabs`, `windows`, `storage`, `scripting`, `action`, `alarms`,
`cookies`, `menus`, `commands`, `permissions`, `webNavigation`, `webRequest`,
`declarativeNetRequest`, `notifications`, `bookmarks`, `devtools`, `sidebar`.
Supports both MV2 and MV3 manifests including service workers.

### Platform status

- **Feature flag**: `ENABLE(WK_WEB_EXTENSIONS)`, default OFF, tied to
  `ENABLE_EXPERIMENTAL_FEATURES` on WPE/GTK.
- **License**: BSD 2-Clause (Apple core) + LGPL v2 (Igalia GLib bindings). Fully open.
- **WebProcess side**: 100% cross-platform C++. All JS API bindings work on any platform.
- **UIProcess side**: Core logic (IPC, permissions, SQLite storage, manifest parsing,
  event system) is cross-platform C++. But the orchestration layer
  (`WebExtensionContextCocoa.mm` etc.) is Cocoa-only — uses `WKWebView`, ObjC delegate
  protocols, `NSFileCoordinator`, etc.
- **GLib API**: Igalia started porting in late 2024. As of 2025, only manifest parsing
  is exposed (`webkit_web_extension_new()`, metadata getters). The runtime
  (loading/running extensions) has no GLib API yet.

### Porting assessment

Three approaches were evaluated:

**1. Full GLib rewrite** (~11,600 lines) — Rewrite all Cocoa .mm files as GLib C++.
Clean but massive effort (6-7 weeks). Rejected.

**2. Surgical patching** (~25 patch points, ~500 lines) — Add `#if PLATFORM(WPE)`
blocks at each WKWebView/delegate call site. Works but scattered across 8 files,
creates merge conflict surface with upstream WebKit updates.

**3. Compat shim** (~500-600 lines in 1-2 files) — Provide a thin `WKWebView` ObjC
class on Linux (via GNUstep Foundation + GCC ObjC) that wraps `WebKitWebView` (GLib)
internally. Extension .mm files compile unmodified. Cleanest approach if we ever need it.

Key findings for the shim approach:
- WKWebView is a thin ObjC wrapper around C++ `WebPageProxy` — for headless background
  pages, none of the UI/rendering code is needed
- ~15-20 actual Apple-specific API calls in the critical path (WKWebView creation,
  `_loadServiceWorker:`, `NSFileCoordinator`, `SecStaticCode`, `NSDistributedNotificationCenter`)
- GNUstep Foundation covers all NSString/NSDictionary/NSArray usage
- The shim needs: `WKWebView` (~250 lines), `WKWebViewConfiguration` (~120 lines),
  `WKPreferences` (~50 lines), protocol stubs (~50 lines)

### Decision: stick with custom system

Rationale:
- Adblock, Translate (Bergamot), and KeePass are already baked in natively — these are
  the primary reasons people install extensions on other browsers
- Phase 1 content script injection covers the remaining common use cases: Dark Reader,
  Stylus, Vimium-type tools, cosmetic tweaks
- The WebKit port adds background scripts/service workers and full API surface, but
  the extensions that need those (ad blockers, password managers, privacy tools) are
  already handled natively
- Engine patches mean expensive rebuilds and ongoing maintenance across WebKit updates
- GNUstep becomes a build dependency
- Igalia is actively porting this upstream — if/when they finish, we get it for free

The compat shim approach remains viable if a compelling use case emerges that needs
background scripts. The analysis above provides the full roadmap.


## Future Phases

### Phase 2 (if needed): background scripts via hidden WebView
If a specific popular extension requires a background script, the pragmatic path is:
- Create a hidden `WebKitWebView` from the Odin/engine side
- Load `axium://ext/{id}/_background` with the extension's background script
- Inject the `browser.*` polyfill with full messaging bridge
- Wire `runtime.onMessage` to actually deliver messages from content scripts
- Per-extension, on demand — not a full framework

### Phase 3: extension.so native code

See "Native Code Loading (extension.so)" section below for full design.

### Phase 4: auto-update
- AMO REST API for Firefox extensions
- Chrome update service for CRX extensions
- Custom repo metadata for Axium-native extensions
- Version comparison + download + hot-reload

### Phase 5: extension manager UI
- AMO search integration
- Installed extensions management page (`axium://extensions`)
- Install from URL / drag-and-drop


## Native Code Loading (extension.so)

### Trust model — ed25519 code signing

Extensions with `extension.so` are only loaded if signed by a trusted key.

**Keys:**
- **First-party key**: Ed25519 public key hardcoded in the browser binary. Used to sign
  Axium's own extensions (Translate, KeePass). Always trusted.
- **User-added keys**: Additional public keys via env var (`AXIUM_EXT_PUBKEYS`) or config
  file (`~/.config/axium/trusted_pubkeys/`). User explicitly opts in to trusting
  third-party developers. At their own responsibility.

**Build-time signing flow:**
1. Build `extension.so`
2. Sign with private key: `sign(private_key, extension.so bytes)` → `extension.so.sig` (64 bytes)
3. Bundle both `extension.so` + `extension.so.sig` in the `.axe` zip

**Runtime verification flow:**
1. Extract `extension.so` bytes + `extension.so.sig` from cached zip (already in memory)
2. Verify signature against all trusted public keys (`core:crypto/ed25519`)
3. **Valid** → load with full access
4. **Invalid / unsigned** → .so not loaded, extension limited to JS/CSS content scripts

The private key never leaves the developer's machine. The public key is safe to embed
and distribute — you cannot derive the private key from it (elliptic curve discrete
logarithm). Same principle as SSH keys, HTTPS, git commit signing.

### Loading pipeline — memfd + detour + dynlib

No disk extraction. The archive is already cached in memory on `Ext_Entry`:

1. Extract `extension.so` bytes from cached zip index (`ext_extract_file`)
2. Verify ed25519 signature (see above)
3. `memfd_create("ext-<id>", 0)` → anonymous in-memory file descriptor
4. `write(fd, so_bytes, len)` → write .so content to memfd
5. `dynlib.load_library("/proc/self/fd/<N>")` → Odin's `core:dynlib` calls `posix.dlopen`
6. Detour's strong `dlopen` override delegates to real glibc `dlopen` captured from ld-linux.so
7. .so is loaded from memory, never touches disk

### Symbol access — version script

Instead of `-rdynamic` (exports all ~50-100K symbols), use a linker version script to
export only the symbols extensions need:

```
# export_syms.ld
{
  global:
    lv_*;          # LVGL widget toolkit
    popup_*;       # popup system
    engine_*;      # engine bridge (view, scripts, navigation)
    theme_*;       # theme variables
    tab_*;         # tab state
    xdg_path;      # XDG path helper
    # grows as needed when porting translate/keepass
  local:
    *;             # hide everything else
};
```

Link with `--export-dynamic-symbol-list=export_syms.ld` instead of `-rdynamic`.

**Effect**: Signed extensions resolve symbols directly against the main binary's dynamic
symbol table at dlopen time. Direct function calls, no vtable indirection, zero runtime
overhead. The .so compiles against LVGL/Axium headers normally — undefined symbols are
resolved at load time, same as if compiled together.

**API surface control**: Even for trusted extensions, only exported symbols are callable.
If an extension tries to use something not in the export list, dlopen fails. The list
grows organically as extensions need more APIs.

### .axe archive layout with native code

```
manifest.json           # standard WebExtensions + optional "axium" key
content.js              # web process: injected into matching pages
styles.css              # web process: injected styles
extension.so            # UI process: native code (Odin -build-mode:dll)
extension.so.sig        # ed25519 signature (64 bytes)
resources/              # data files (models, filter lists, etc.)
```

### Security summary

| Layer | What it does |
|-------|-------------|
| Ed25519 signature | Only code blessed by a trusted key is loaded |
| Version script | Controls which host symbols are visible to the .so |
| Unsigned fallback | Extensions without valid signature get JS/CSS only |
| User-added keys | Explicit opt-in, env var or config, user's responsibility |
