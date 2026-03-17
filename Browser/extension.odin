package axium

import "base:runtime"
import "core:c"
import "core:crypto/ed25519"
import "core:dynlib"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

Ext_Type :: enum u8 { Axe, Xpi, Crx }

Ext_Run_At :: enum u8 { Document_Start, Document_End }

Ext_Content_Script :: struct {
    matches:   [dynamic]string,
    js_files:  [dynamic]string,    // file paths within zip
    css_files: [dynamic]string,    // file paths within zip
    run_at:    Ext_Run_At,
}

Ext_Entry :: struct {
    // Persisted in extensions.sjson
    name:        string,
    version:     string,
    type_:       Ext_Type,
    enabled:     bool,
    auto_update: bool,
    id:          string,
    url:         string,
    update_url:  string,
    filename:    string,

    // Runtime state (not persisted)
    content_scripts:  [dynamic]Ext_Content_Script,
    options_page:     string,
    default_locale:   string,
    loaded:           bool,

    // Cached archive (raw bytes + parsed index for on-demand extraction)
    archive:     []u8,
    zip_entries: []Zip_Entry,
    zip_offset:  int,           // byte offset where zip data starts within archive

    // Native code (.so loaded from signed extension archives)
    native_lib:            dynlib.Library,
    native_init:           proc "c" (),
    native_shutdown:       proc "c" (),
    native_handle_message: proc(payload: cstring, reply: rawptr, ctx: rawptr),
}

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

extensions: [dynamic]Ext_Entry
ext_popup_anchor: ^lv_obj_t

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

extension_get_id :: proc(ext: Ext_Entry) -> string {
    if ext.id != "" do return ext.id
    if idx := strings.last_index_byte(ext.filename, '.'); idx >= 0 {
        return ext.filename[:idx]
    }
    return ext.filename
}

// ---------------------------------------------------------------------------
// browser.* polyfill — built per-extension with baked ext_id + i18n messages
// ---------------------------------------------------------------------------

// Split into two halves so _msgs JSON can be injected between them.
// POLYFILL_PRE: IIFE open + _msgs placeholder (caller writes `var _msgs={...};`)
// POLYFILL_POST: rest of polyfill (uses _ext_id and _msgs)

POLYFILL_PRE  :: "(function(){\n"
POLYFILL_POST :: `var browser={
runtime:{
id:_ext_id,
sendMessage:function(msg){
return window.webkit.messageHandlers.axium.postMessage(
JSON.stringify({_axium_ext:true,ext_id:_ext_id,action:"sendMessage",data:msg})
).then(function(r){try{return JSON.parse(r)}catch(e){return r}});
},
onMessage:{
_l:[],
addListener:function(fn){this._l.push(fn)},
removeListener:function(fn){this._l=this._l.filter(function(f){return f!==fn})},
hasListener:function(fn){return this._l.indexOf(fn)>=0}
},
getURL:function(p){return "axium://ext/"+_ext_id+"/"+p}
},
storage:{local:{
get:function(keys){
return window.webkit.messageHandlers.axium.postMessage(
JSON.stringify({_axium_ext:true,ext_id:_ext_id,action:"storage.get",keys:keys})
).then(function(r){try{return JSON.parse(r)}catch(e){return{}}});
},
set:function(items){
return window.webkit.messageHandlers.axium.postMessage(
JSON.stringify({_axium_ext:true,ext_id:_ext_id,action:"storage.set",items:items})
);
},
remove:function(keys){
return window.webkit.messageHandlers.axium.postMessage(
JSON.stringify({_axium_ext:true,ext_id:_ext_id,action:"storage.remove",keys:typeof keys==="string"?[keys]:keys})
);
}
}},
tabs:{
sendMessage:function(tabId,msg){
return window.webkit.messageHandlers.axium.postMessage(
JSON.stringify({_axium_ext:true,ext_id:_ext_id,action:"tabs.sendMessage",tabId:tabId,data:msg})
);
}
},
i18n:{getMessage:function(id,subs){
var m=_msgs[id];if(!m)return id;
if(subs){if(typeof subs==="string")subs=[subs];
for(var i=0;i<subs.length;i++)m=m.replace("$"+(i+1),subs[i]);}
return m;
}},
commands:{getAll:function(){return Promise.resolve([])},update:function(){return Promise.resolve()},reset:function(){return Promise.resolve()}}
};
window.browser=browser;
window.chrome=browser;
window.__axium_dispatch=function(msg){
var ls=browser.runtime.onMessage._l;
for(var i=0;i<ls.length;i++)ls[i](msg,{},{});
};
window.addEventListener('error',function(e){
window.webkit.messageHandlers.axium.postMessage(
JSON.stringify({_axium_ext:true,ext_id:_ext_id,action:"_js_error",msg:e.message,file:e.filename,line:e.lineno}));
});
})();`

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

extension_init :: proc() {
    extension_load_registry()
    extension_scan_dir()
    for i in 0..<len(extensions) {
        if extensions[i].enabled {
            extension_load(i)
        }
    }
}

// ---------------------------------------------------------------------------
// Registry persistence (extensions.sjson)
// ---------------------------------------------------------------------------

extension_registry_path :: proc() -> string {
    return xdg_path(.Config, "extensions/extensions.sjson")
}

extension_dir_path :: proc() -> string {
    return xdg_path(.Config, "extensions/")
}

extension_load_registry :: proc() {
    path := extension_registry_path()
    file, ok := os.read_entire_file(path)
    if !ok do return
    defer delete(file)

    cfg, err := json.parse(file, .SJSON)
    if err != .None do return
    defer json.destroy_value(cfg)

    root, rok := cfg.(json.Object)
    if !rok do return

    arr, aok := root["extensions"].(json.Array)
    if !aok do return

    for item in arr {
        obj, ook := item.(json.Object)
        if !ook do continue

        entry: Ext_Entry
        if v, vok := obj["name"].(json.String);        vok do entry.name = strings.clone(v)
        if v, vok := obj["version"].(json.String);     vok do entry.version = strings.clone(v)
        if v, vok := obj["filename"].(json.String);    vok do entry.filename = strings.clone(v)
        if v, vok := obj["enabled"].(json.Boolean);    vok do entry.enabled = v
        if v, vok := obj["auto_update"].(json.Boolean); vok do entry.auto_update = v
        if v, vok := obj["id"].(json.String);          vok do entry.id = strings.clone(v)
        if v, vok := obj["url"].(json.String);         vok do entry.url = strings.clone(v)
        if v, vok := obj["update_url"].(json.String);  vok do entry.update_url = strings.clone(v)
        if v, vok := obj["type"].(json.String); vok {
            switch v {
            case "axe": entry.type_ = .Axe
            case "xpi": entry.type_ = .Xpi
            case "crx": entry.type_ = .Crx
            }
        }
        append(&extensions, entry)
    }
}

extension_save_registry :: proc() {
    path := extension_registry_path()
    dir := path[:strings.last_index_byte(path, '/')]
    os.make_directory(dir)

    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    strings.write_string(&b, "{\n    extensions: [\n")
    for entry, i in extensions {
        if i > 0 do strings.write_string(&b, "\n")
        type_str: string
        switch entry.type_ {
        case .Axe: type_str = "axe"
        case .Xpi: type_str = "xpi"
        case .Crx: type_str = "crx"
        }
        fmt.sbprintf(&b, "        {{\n")
        fmt.sbprintf(&b, "            name: \"%s\"\n", entry.name)
        fmt.sbprintf(&b, "            version: \"%s\"\n", entry.version)
        fmt.sbprintf(&b, "            type: \"%s\"\n", type_str)
        fmt.sbprintf(&b, "            filename: \"%s\"\n", entry.filename)
        fmt.sbprintf(&b, "            enabled: %s\n", entry.enabled ? "true" : "false")
        fmt.sbprintf(&b, "            auto_update: %s\n", entry.auto_update ? "true" : "false")
        if entry.id != "" do fmt.sbprintf(&b, "            id: \"%s\"\n", entry.id)
        if entry.url != "" do fmt.sbprintf(&b, "            url: \"%s\"\n", entry.url)
        if entry.update_url != "" do fmt.sbprintf(&b, "            update_url: \"%s\"\n", entry.update_url)
        fmt.sbprintf(&b, "        }}")
    }
    strings.write_string(&b, "\n    ]\n}\n")

    os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

// ---------------------------------------------------------------------------
// Directory scanning
// ---------------------------------------------------------------------------

extension_scan_dir :: proc() {
    dir_path := extension_dir_path()
    os.make_directory(dir_path)

    dh, err := os.open(dir_path)
    if err != nil do return
    defer os.close(dh)

    entries, rerr := os.read_dir(dh, -1)
    if rerr != nil do return
    defer delete(entries)

    // Track which filenames exist on disk
    disk_files := make(map[string]bool)
    defer delete(disk_files)

    for entry in entries {
        name := entry.name
        is_ext := strings.has_suffix(name, ".axe") ||
                  strings.has_suffix(name, ".xpi") ||
                  strings.has_suffix(name, ".crx")
        if !is_ext do continue
        disk_files[name] = true

        // Check if already in registry
        found := false
        for ext in extensions {
            if ext.filename == name {
                found = true
                break
            }
        }
        if found do continue

        // Detect type from extension
        type_: Ext_Type
        if strings.has_suffix(name, ".axe") {
            type_ = .Axe
        } else if strings.has_suffix(name, ".xpi") {
            type_ = .Xpi
        } else if strings.has_suffix(name, ".crx") {
            type_ = .Crx
        }

        new_entry := Ext_Entry{
            filename    = strings.clone(name),
            name        = strings.clone(name[:strings.last_index_byte(name, '.')]),
            type_       = type_,
            enabled     = true,
            auto_update = false,
        }
        append(&extensions, new_entry)
    }

    // Remove entries whose files no longer exist
    i := 0
    for i < len(extensions) {
        if extensions[i].filename not_in disk_files {
            ordered_remove(&extensions, i)
        } else {
            i += 1
        }
    }

    extension_save_registry()
}

// ---------------------------------------------------------------------------
// Polyfill injection (per-extension with baked id)
// ---------------------------------------------------------------------------

// Build polyfill JS string with baked ext_id and i18n messages.
// Caller must delete the returned string.
ext_build_polyfill :: proc(ext_id: string, msgs_json: string) -> string {
    b := strings.builder_make()
    defer strings.builder_destroy(&b)
    strings.write_string(&b, POLYFILL_PRE)
    strings.write_string(&b, `var _msgs=`)
    strings.write_string(&b, msgs_json if len(msgs_json) > 0 else "{}")
    strings.write_string(&b, ";\n")
    strings.write_string(&b, `var _ext_id="`)
    strings.write_string(&b, ext_id)
    strings.write_string(&b, "\";\n")
    strings.write_string(&b, POLYFILL_POST)
    return strings.clone(strings.to_string(b))
}

extension_inject_polyfill :: proc(ext_id: string, allow: []cstring, msgs_json: string, world: cstring) {
    src := ext_build_polyfill(ext_id, msgs_json)
    defer delete(src)
    cstr := strings.clone_to_cstring(src)
    defer delete(cstr)

    allow_ptr: [^]cstring = nil
    if len(allow) > 0 do allow_ptr = raw_data(allow)

    engine_add_user_script(cstr,
        1,  // WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES
        0,  // WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START
        allow_ptr, c.int(len(allow)), world)
}

// ---------------------------------------------------------------------------
// Extension loading
// ---------------------------------------------------------------------------

extension_load :: proc(idx: int) {
    if idx < 0 || idx >= len(extensions) do return
    ext := &extensions[idx]
    if ext.loaded do return

    filepath := strings.concatenate({extension_dir_path(), ext.filename})
    defer delete(filepath)

    archive, ok := os.read_entire_file(filepath)
    if !ok {
        fmt.eprintln("[ext] failed to read:", ext.filename)
        return
    }

    // Detect format + find zip start offset
    zip_offset := 0
    zip_data: []u8
    if len(archive) >= 4 && string(archive[:2]) == "PK" {
        zip_data = archive
    } else if len(archive) >= 12 &&
              archive[0] == 'C' && archive[1] == 'r' &&
              archive[2] == '2' && archive[3] == '4' {
        // CRX3 header
        header_len := read_u32_le(archive[8:12])
        zip_offset = 12 + int(header_len)
        if zip_offset < len(archive) {
            zip_data = archive[zip_offset:]
        }
    }

    if zip_data == nil {
        fmt.eprintln("[ext] unknown archive format:", ext.filename)
        delete(archive)
        return
    }

    // Parse zip central directory
    zip_entries, zok := zip_parse_central_dir(zip_data)
    if !zok {
        fmt.eprintln("[ext] failed to parse zip:", ext.filename)
        delete(archive)
        return
    }

    // Extract and parse manifest
    manifest_data: []u8
    for &ze in zip_entries {
        if ze.name == "manifest.json" {
            manifest_data = zip_extract_entry(zip_data, ze)
            break
        }
    }

    if manifest_data == nil {
        fmt.eprintln("[ext] no manifest.json in:", ext.filename)
        delete(archive)
        delete(zip_entries)
        return
    }
    defer delete(manifest_data)

    manifest, merr := json.parse(manifest_data)
    if merr != .None {
        fmt.eprintln("[ext] failed to parse manifest.json in:", ext.filename)
        delete(archive)
        delete(zip_entries)
        return
    }
    defer json.destroy_value(manifest)

    mobj, mok := manifest.(json.Object)
    if !mok {
        delete(archive)
        delete(zip_entries)
        return
    }

    // Cache archive + index on the entry
    ext.archive = archive
    ext.zip_entries = zip_entries
    ext.zip_offset = zip_offset

    // Update name/version from manifest
    if v, vok := mobj["name"].(json.String); vok {
        if ext.name == "" || ext.name == ext.filename[:strings.last_index_byte(ext.filename, '.')] {
            ext.name = strings.clone(v)
        }
    }
    if v, vok := mobj["version"].(json.String); vok do ext.version = strings.clone(v)
    if v, vok := mobj["update_url"].(json.String); vok do ext.update_url = strings.clone(v)
    if v, vok := mobj["default_locale"].(json.String); vok do ext.default_locale = strings.clone(v)

    // Firefox GUID
    if bss, bok := mobj["browser_specific_settings"].(json.Object); bok {
        if gecko, gok := bss["gecko"].(json.Object); gok {
            if id, iok := gecko["id"].(json.String); iok do ext.id = strings.clone(id)
        }
    }
    // Chrome applications.gecko.id fallback
    if ext.id == "" {
        if apps, aok := mobj["applications"].(json.Object); aok {
            if gecko, gok := apps["gecko"].(json.Object); gok {
                if id, iok := gecko["id"].(json.String); iok do ext.id = strings.clone(id)
            }
        }
    }

    // Parse options page
    if v, vok := mobj["options_ui"].(json.Object); vok {
        if p, pok := v["page"].(json.String); pok do ext.options_page = strings.clone(p)
    }
    if ext.options_page == "" {
        if v, vok := mobj["options_page"].(json.String); vok do ext.options_page = strings.clone(v)
    }

    // Parse content_scripts — store file names only, extract on demand from cached zip
    cs_arr, csok := mobj["content_scripts"].(json.Array)
    if !csok {
        ext_try_load_native(ext, zip_data, zip_entries)
        ext.loaded = true
        extension_save_registry()
        return
    }

    for cs_val in cs_arr {
        cs_obj, cok := cs_val.(json.Object)
        if !cok do continue

        cs: Ext_Content_Script
        cs.run_at = .Document_End  // default

        if ra, raok := cs_obj["run_at"].(json.String); raok {
            if ra == "document_start" do cs.run_at = .Document_Start
        }

        if matches, maok := cs_obj["matches"].(json.Array); maok {
            for m in matches {
                if s, sok := m.(json.String); sok {
                    append(&cs.matches, strings.clone(s))
                }
            }
        }

        if js_arr, jaok := cs_obj["js"].(json.Array); jaok {
            for js_val in js_arr {
                if js_name, jok := js_val.(json.String); jok {
                    append(&cs.js_files, strings.clone(js_name))
                }
            }
        }

        if css_arr, caok := cs_obj["css"].(json.Array); caok {
            for css_val in css_arr {
                if css_name, cok2 := css_val.(json.String); cok2 {
                    append(&cs.css_files, strings.clone(css_name))
                }
            }
        }

        append(&ext.content_scripts, cs)
    }

    fmt.eprintln("[ext]", ext.name, "— parsed", len(ext.content_scripts), "content script groups")
    for cs, idx in ext.content_scripts {
        fmt.eprintln("[ext]   group", idx, ":", len(cs.js_files), "js,", len(cs.css_files), "css,", len(cs.matches), "matches, run_at =", cs.run_at)
    }

    // Register all content scripts + polyfill with engine
    extension_register_ext_scripts(ext)

    ext_try_load_native(ext, zip_data, zip_entries)
    ext.loaded = true
    extension_save_registry()
}

// Load i18n messages from extension archive.
// Tries _locales/{language}/messages.json first, falls back to default_locale.
// Returns a compact JSON object string: {"key":"message",...}
// Caller must delete the returned string.
ext_load_i18n_messages :: proc(ext: ^Ext_Entry) -> string {
    if ext.archive == nil do return ""
    zip_data := ext.archive[ext.zip_offset:]

    // Try configured language first, then default_locale from manifest
    langs: [2]string
    lang_count := 0
    if language != "" {
        langs[lang_count] = language
        lang_count += 1
    }
    if ext.default_locale != "" && ext.default_locale != language {
        langs[lang_count] = ext.default_locale
        lang_count += 1
    }

    raw: []u8
    for i in 0..<lang_count {
        path := fmt.tprintf("_locales/%s/messages.json", langs[i])
        raw = ext_extract_file(zip_data, ext.zip_entries, path)
        if raw != nil do break
    }
    if raw == nil do return ""
    defer delete(raw)

    parsed, err := json.parse(raw)
    if err != .None do return ""
    defer json.destroy_value(parsed)

    obj, ok := parsed.(json.Object)
    if !ok do return ""

    // Build compact {key:"message",...} object
    b := strings.builder_make()
    defer strings.builder_destroy(&b)
    strings.write_byte(&b, '{')
    first := true
    for key, val in obj {
        entry, eok := val.(json.Object)
        if !eok do continue
        msg, mok := entry["message"].(json.String)
        if !mok do continue

        // Write key and message as JSON strings
        key_json, kerr := json.marshal(key)
        if kerr != nil do continue
        msg_json, merr := json.marshal(msg)
        if merr != nil { delete(key_json); continue }

        if !first do strings.write_byte(&b, ',')
        first = false
        strings.write_string(&b, string(key_json))
        delete(key_json)
        strings.write_byte(&b, ':')
        strings.write_string(&b, string(msg_json))
        delete(msg_json)
    }
    strings.write_byte(&b, '}')
    return strings.clone(strings.to_string(b))
}

extension_register_ext_scripts :: proc(ext: ^Ext_Entry) {
    ext_id := extension_get_id(ext^)
    zip_data := ext.archive[ext.zip_offset:]

    // Each extension gets its own script world to avoid polyfill collisions
    world_name := strings.clone_to_cstring(fmt.tprintf("axium-ext-%s", ext_id))
    defer delete(world_name)
    engine_register_ext_world(world_name)

    // Collect all unique match patterns across content scripts for the polyfill
    all_allow: [dynamic]cstring
    defer {
        for a in all_allow do delete(a)
        delete(all_allow)
    }
    polyfill_all_urls := false
    for cs in ext.content_scripts {
        for m in cs.matches {
            if m == "<all_urls>" { polyfill_all_urls = true; break }
            append(&all_allow, strings.clone_to_cstring(m))
        }
        if polyfill_all_urls do break
    }

    // Load i18n messages from archive and inject polyfill
    msgs_json := ext_load_i18n_messages(ext)
    defer delete(msgs_json)
    polyfill_allow := all_allow[:] if !polyfill_all_urls else []cstring{}
    extension_inject_polyfill(ext_id, polyfill_allow, msgs_json, world_name)

    // Register each content script — extract JS/CSS from cached zip on the fly
    for cs in ext.content_scripts {
        allow: [dynamic]cstring
        defer {
            for a in allow do delete(a)
            delete(allow)
        }
        all_urls := false
        for m in cs.matches {
            if m == "<all_urls>" { all_urls = true; break }
            append(&allow, strings.clone_to_cstring(m))
        }

        allow_ptr: [^]cstring = nil
        if !all_urls && len(allow) > 0 do allow_ptr = raw_data(allow[:])

        inject_time: c.int = 1  // WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END
        if cs.run_at == .Document_Start do inject_time = 0

        for js_file in cs.js_files {
            src := ext_extract_file(zip_data, ext.zip_entries, js_file)
            if src == nil {
                fmt.eprintln("[ext]   MISSING js file:", js_file)
                continue
            }
            fmt.eprintln("[ext]   injecting js:", js_file, "len=", len(src))
            cstr := strings.clone_to_cstring(string(src))
            delete(src)
            allow_count := c.int(0) if all_urls else c.int(len(allow))
            engine_add_user_script(cstr,
                1,  // WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES
                inject_time,
                allow_ptr, allow_count, world_name)
            delete(cstr)
        }

        for css_file in cs.css_files {
            src := ext_extract_file(zip_data, ext.zip_entries, css_file)
            if src == nil do continue
            cstr := strings.clone_to_cstring(string(src))
            delete(src)
            allow_count := c.int(0) if all_urls else c.int(len(allow))
            engine_add_user_style(cstr,
                1,  // WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES
                allow_ptr, allow_count, world_name)
            delete(cstr)
        }
    }
}

// Extract a file from a cached zip by name
ext_extract_file :: proc(zip_data: []u8, entries: []Zip_Entry, name: string) -> []u8 {
    for &ze in entries {
        if ze.name == name {
            return zip_extract_entry(zip_data, ze)
        }
    }
    return nil
}

// ---------------------------------------------------------------------------
// Ed25519 signature verification
// ---------------------------------------------------------------------------

ext_verify_signature :: proc(data: []u8, sig_bytes: []u8) -> bool {
    if len(sig_bytes) != 64 do return false

    for key in ext_trusted_pubkeys {
        k := key
        pk: ed25519.Public_Key
        if !ed25519.public_key_set_bytes(&pk, k[:]) do continue
        if ed25519.verify(&pk, data, sig_bytes) do return true
    }
    return false
}

// ---------------------------------------------------------------------------
// Native .so loading (memfd + dlopen)
// ---------------------------------------------------------------------------

ext_try_load_native :: proc(ext: ^Ext_Entry, zip_data: []u8, entries: []Zip_Entry) {
    so_bytes := ext_extract_file(zip_data, entries, "extension.so")
    if so_bytes == nil do return   // no native code in this extension

    sig_bytes := ext_extract_file(zip_data, entries, "extension.so.sig")
    if sig_bytes == nil {
        fmt.eprintln("[ext]", ext.name, "— extension.so present but no signature, skipping native load")
        delete(so_bytes)
        return
    }
    defer delete(sig_bytes)

    if !ext_verify_signature(so_bytes, sig_bytes) {
        fmt.eprintln("[ext]", ext.name, "— signature verification failed, skipping native load")
        delete(so_bytes)
        return
    }

    ext_id := extension_get_id(ext^)
    fd_name := strings.clone_to_cstring(fmt.tprintf("ext-%s", ext_id))
    defer delete(fd_name)

    fd, errno := linux.memfd_create(fd_name, {.CLOEXEC})
    if errno != .NONE {
        fmt.eprintln("[ext]", ext.name, "— memfd_create failed:", errno)
        delete(so_bytes)
        return
    }

    linux.write(fd, so_bytes)
    delete(so_bytes)

    fd_path := fmt.tprintf("/proc/self/fd/%d", fd)
    lib, lok := dynlib.load_library(fd_path)
    linux.close(fd)

    if !lok {
        fmt.eprintln("[ext]", ext.name, "— failed to dlopen native library")
        return
    }

    ext.native_lib = lib
    ext.native_init = auto_cast dynlib.symbol_address(lib, "extension_init")
    ext.native_shutdown = auto_cast dynlib.symbol_address(lib, "extension_shutdown")
    ext.native_handle_message = auto_cast dynlib.symbol_address(lib, "native_handle_message")

    if ext.native_init != nil do ext.native_init()
    fmt.eprintln("[ext]", ext.name, "— loaded native code")
}

// ---------------------------------------------------------------------------
// Extension unload / enable / disable
// ---------------------------------------------------------------------------

extension_unload :: proc(idx: int) {
    if idx < 0 || idx >= len(extensions) do return
    ext := &extensions[idx]
    if !ext.loaded do return

    // Clear all user content and re-register everything
    engine_remove_all_user_content()

    // Shut down native code
    if ext.native_shutdown != nil do ext.native_shutdown()
    if ext.native_lib != nil do dynlib.unload_library(ext.native_lib)
    ext.native_lib = nil
    ext.native_init = nil
    ext.native_shutdown = nil
    ext.native_handle_message = nil

    ext.loaded = false
    clear(&ext.content_scripts)

    // Free cached archive
    if ext.archive != nil {
        // Free cloned zip entry names
        for &ze in ext.zip_entries {
            delete(ze.name)
        }
        delete(ext.zip_entries)
        delete(ext.archive)
        ext.archive = nil
        ext.zip_entries = nil
        ext.zip_offset = 0
    }

    // Re-register all other loaded extensions' polyfills + scripts
    for i in 0..<len(extensions) {
        if i == idx do continue
        if extensions[i].loaded {
            extension_register_ext_scripts(&extensions[i])
        }
    }
}

extension_enable :: proc(idx: int) {
    if idx < 0 || idx >= len(extensions) do return
    extensions[idx].enabled = true
    extension_load(idx)
    extension_save_registry()
}

extension_disable :: proc(idx: int) {
    if idx < 0 || idx >= len(extensions) do return
    extensions[idx].enabled = false
    extension_unload(idx)
    extension_save_registry()
}

// ---------------------------------------------------------------------------
// Message handler (called from engine.c via _axium_ext routing)
// ---------------------------------------------------------------------------

@(export)
extension_handle_message :: proc "c" (c_payload: cstring, reply: rawptr, ctx: rawptr) {
    context = runtime.default_context()
    if c_payload == nil {
        engine_extension_reply(reply, ctx, nil)
        return
    }

    data, err := json.parse(transmute([]u8)string(c_payload))
    if err != .None {
        engine_extension_reply(reply, ctx, nil)
        return
    }
    defer json.destroy_value(data)

    obj, ok := data.(json.Object)
    if !ok {
        engine_extension_reply(reply, ctx, nil)
        return
    }

    action, aok := obj["action"].(json.String)
    if !aok {
        engine_extension_reply(reply, ctx, nil)
        return
    }
    fmt.eprintln("[ext-msg] action:", action)

    switch action {
    case "storage.get":
        result := extension_storage_get(obj)
        engine_extension_reply(reply, ctx, result)
        delete(result)
    case "storage.set":
        result := extension_storage_set(obj)
        engine_extension_reply(reply, ctx, result)
        delete(result)
    case "storage.remove":
        result := extension_storage_remove(obj)
        engine_extension_reply(reply, ctx, result)
        delete(result)
    case "sendMessage":
        ext_id, eok := obj["ext_id"].(json.String)
        if !eok {
            fmt.eprintln("[ext-msg] sendMessage: no ext_id")
            engine_extension_reply(reply, ctx, nil)
            return
        }
        for &ext in extensions {
            if extension_get_id(ext) != ext_id do continue
            if ext.native_handle_message != nil {
                data_json, merr := json.marshal(obj["data"])
                if merr != nil {
                    fmt.eprintln("[ext-msg] sendMessage: marshal failed for", ext_id)
                    engine_extension_reply(reply, ctx, nil)
                    return
                }
                data_cstr := strings.clone_to_cstring(string(data_json))
                delete(data_json)
                fmt.eprintln("[ext-msg] ->", ext_id, "native:", string(data_cstr)[:min(len(string(data_cstr)), 120)])
                ext.native_handle_message(data_cstr, reply, ctx)
                fmt.eprintln("[ext-msg] <- native returned")
                delete(data_cstr)
                return  // .so owns reply+ctx now
            }
            break
        }
        engine_extension_reply(reply, ctx, nil)
    case "tabs.sendMessage":
        tab_id_f, tok := obj["tabId"].(json.Float)
        if !tok {
            engine_extension_reply(reply, ctx, nil)
            return
        }
        data_val := obj["data"]
        data_json, merr := json.marshal(data_val)
        if merr != nil {
            engine_extension_reply(reply, ctx, nil)
            return
        }
        data_cstr := strings.clone_to_cstring(string(data_json))
        delete(data_json)
        extension_send_tab_message(int(tab_id_f), data_cstr)
        delete(data_cstr)
        engine_extension_reply(reply, ctx, nil)
    case:
        engine_extension_reply(reply, ctx, nil)
    }
}

// ---------------------------------------------------------------------------
// Send message to content script in a specific tab
// ---------------------------------------------------------------------------

extension_send_tab_message :: proc(tab_id: int, json_msg: cstring) {
    if tab_id < 0 || tab_id >= tab_count do return
    view := tab_entries[tab_id].view
    if view == nil do return
    js := fmt.tprintf("window.__axium_dispatch&&window.__axium_dispatch(%s)", json_msg)
    cstr := strings.clone_to_cstring(js)
    engine_run_javascript(view, cstr)
    delete(cstr)
}

extension_broadcast_message :: proc(json_msg: cstring) {
    for i in 0..<tab_count {
        extension_send_tab_message(i, json_msg)
    }
}

// ---------------------------------------------------------------------------
// Extension storage (per-extension JSON files)
// ---------------------------------------------------------------------------

extension_storage_path :: proc(ext_id: string) -> string {
    return xdg_path(.Config, fmt.tprintf("extensions/storage/%s.json", ext_id))
}

extension_storage_read :: proc(ext_id: string) -> (json.Object, json.Value, bool) {
    path := extension_storage_path(ext_id)
    file, ok := os.read_entire_file(path)
    if !ok do return nil, nil, false
    defer delete(file)

    val, err := json.parse(file)
    if err != .None do return nil, nil, false

    obj, ook := val.(json.Object)
    if !ook {
        json.destroy_value(val)
        return nil, nil, false
    }
    return obj, val, true
}

extension_storage_write :: proc(ext_id: string, obj: json.Object) {
    path := extension_storage_path(ext_id)
    dir := path[:strings.last_index_byte(path, '/')]
    os.make_directory(dir)

    data, err := json.marshal(obj)
    if err == nil {
        os.write_entire_file(path, data)
        delete(data)
    }
}

extension_storage_get :: proc(obj: json.Object) -> cstring {
    ext_id, eok := obj["ext_id"].(json.String)
    if !eok do return strings.clone_to_cstring("{}")

    storage, storage_val, sok := extension_storage_read(ext_id)
    if !sok do return strings.clone_to_cstring("{}")
    defer json.destroy_value(storage_val)

    keys := obj["keys"]
    result: json.Value

    #partial switch k in keys {
    case json.Null:
        // Return entire storage
        result = storage_val
    case json.String:
        // Single key
        out := json.Object{}
        if val, vok := storage[k]; vok do out[k] = val
        result = out
    case json.Array:
        // Array of key strings
        out := json.Object{}
        for item in k {
            if key, kok := item.(json.String); kok {
                if val, vok := storage[key]; vok do out[key] = val
            }
        }
        result = out
    case json.Object:
        // Object with default values
        out := json.Object{}
        for key, default_val in k {
            if val, vok := storage[key]; vok {
                out[key] = val
            } else {
                out[key] = default_val
            }
        }
        result = out
    case:
        result = storage_val
    }

    data, err := json.marshal(result)
    if err != nil do return strings.clone_to_cstring("{}")
    defer delete(data)
    return strings.clone_to_cstring(string(data))
}

extension_storage_set :: proc(obj: json.Object) -> cstring {
    ext_id, eok := obj["ext_id"].(json.String)
    if !eok do return strings.clone_to_cstring("{\"ok\":false}")

    items, iok := obj["items"].(json.Object)
    if !iok do return strings.clone_to_cstring("{\"ok\":false}")

    // Read existing storage or start fresh
    storage, storage_val, sok := extension_storage_read(ext_id)
    if !sok {
        // Create new empty storage — we need a mutable json.Object
        // Since we can't easily build one from scratch with Odin's json lib,
        // parse an empty object
        empty_val, _ := json.parse(transmute([]u8)string("{}"))
        storage_val = empty_val
        storage = storage_val.(json.Object)
    }
    defer json.destroy_value(storage_val)

    // Merge items into storage
    for key, val in items {
        storage[key] = val
    }

    extension_storage_write(ext_id, storage)
    return strings.clone_to_cstring("{\"ok\":true}")
}

extension_storage_remove :: proc(obj: json.Object) -> cstring {
    ext_id, eok := obj["ext_id"].(json.String)
    if !eok do return strings.clone_to_cstring("{\"ok\":false}")

    storage, storage_val, sok := extension_storage_read(ext_id)
    if !sok do return strings.clone_to_cstring("{\"ok\":true}")
    defer json.destroy_value(storage_val)

    keys, kok := obj["keys"].(json.Array)
    if !kok do return strings.clone_to_cstring("{\"ok\":true}")

    for item in keys {
        if key, skok := item.(json.String); skok {
            delete_key(&storage, key)
        }
    }

    extension_storage_write(ext_id, storage)
    return strings.clone_to_cstring("{\"ok\":true}")
}

// ---------------------------------------------------------------------------
// Extension page serving (axium://ext/{id}/{path})
// ---------------------------------------------------------------------------

// Buffer for last-served file (freed on next call)
_serve_buf: []u8
_serve_mime: cstring

mime_from_ext :: proc(path: string) -> cstring {
    if strings.has_suffix(path, ".html") do return "text/html"
    if strings.has_suffix(path, ".htm")  do return "text/html"
    if strings.has_suffix(path, ".css")  do return "text/css"
    if strings.has_suffix(path, ".js")   do return "application/javascript"
    if strings.has_suffix(path, ".json") do return "application/json"
    if strings.has_suffix(path, ".png")  do return "image/png"
    if strings.has_suffix(path, ".svg")  do return "image/svg+xml"
    if strings.has_suffix(path, ".jpg")  do return "image/jpeg"
    if strings.has_suffix(path, ".jpeg") do return "image/jpeg"
    if strings.has_suffix(path, ".gif")  do return "image/gif"
    if strings.has_suffix(path, ".woff") do return "font/woff"
    if strings.has_suffix(path, ".woff2") do return "font/woff2"
    if strings.has_suffix(path, ".ttf")  do return "font/ttf"
    return "application/octet-stream"
}

@(export)
extension_serve_file :: proc "c" (c_path: cstring, out_size: ^c.int, out_mime: ^cstring) -> [^]u8 {
    context = runtime.default_context()

    // Free previous serve buffer
    if _serve_buf != nil {
        delete(_serve_buf)
        _serve_buf = nil
    }

    if c_path == nil do return nil
    path := string(c_path)

    // Split on first '/' → ext_id / subpath
    slash := strings.index_byte(path, '/')
    if slash < 0 do return nil
    req_id := path[:slash]
    subpath := path[slash+1:]
    if req_id == "" || subpath == "" do return nil

    // Find loaded extension by id
    for &ext in extensions {
        if extension_get_id(ext) != req_id do continue
        if ext.archive == nil do return nil

        zip_data := ext.archive[ext.zip_offset:]
        data := ext_extract_file(zip_data, ext.zip_entries, subpath)
        if data == nil do return nil

        // Inject polyfill into HTML pages so extension pages get browser.*
        if strings.has_suffix(subpath, ".html") || strings.has_suffix(subpath, ".htm") {
            msgs_json := ext_load_i18n_messages(&ext)
            polyfill := ext_build_polyfill(req_id, msgs_json)
            delete(msgs_json)

            b := strings.builder_make()
            strings.write_string(&b, "<script>")
            strings.write_string(&b, polyfill)
            strings.write_string(&b, "</script>")
            strings.write_string(&b, string(data))
            delete(polyfill)
            delete(data)

            result := transmute([]u8)strings.clone(strings.to_string(b))
            strings.builder_destroy(&b)
            _serve_buf = result
            out_size^ = c.int(len(result))
            out_mime^ = mime_from_ext(subpath)
            return raw_data(result)
        }

        _serve_buf = data
        out_size^ = c.int(len(data))
        out_mime^ = mime_from_ext(subpath)
        return raw_data(data)
    }
    return nil
}

// ---------------------------------------------------------------------------
// Zip reader (in-memory)
// ---------------------------------------------------------------------------

Zip_Entry :: struct {
    name:              string,
    compression:       u16,
    compressed_size:   u32,
    uncompressed_size: u32,
    local_offset:      u32,
}

read_u16_le :: proc(b: []u8) -> u16 {
    return u16(b[0]) | (u16(b[1]) << 8)
}

read_u32_le :: proc(b: []u8) -> u32 {
    return u32(b[0]) | (u32(b[1]) << 8) | (u32(b[2]) << 16) | (u32(b[3]) << 24)
}

zip_parse_central_dir :: proc(data: []u8) -> ([]Zip_Entry, bool) {
    // Find EOCD by scanning backwards
    eocd_off := -1
    search_start := max(0, len(data) - 65557)  // max comment = 65535
    for i := len(data) - 22; i >= search_start; i -= 1 {
        if data[i] == 0x50 && data[i+1] == 0x4b &&
           data[i+2] == 0x05 && data[i+3] == 0x06 {
            eocd_off = i
            break
        }
    }
    if eocd_off < 0 do return nil, false

    num_entries := int(read_u16_le(data[eocd_off+10:]))
    cd_offset := int(read_u32_le(data[eocd_off+16:]))

    if cd_offset >= len(data) do return nil, false

    entries := make([dynamic]Zip_Entry)
    off := cd_offset

    for i in 0..<num_entries {
        if off + 46 > len(data) do break
        // Verify central dir signature
        if data[off] != 0x50 || data[off+1] != 0x4b ||
           data[off+2] != 0x01 || data[off+3] != 0x02 { break }

        compression := read_u16_le(data[off+10:])
        comp_size := read_u32_le(data[off+20:])
        uncomp_size := read_u32_le(data[off+24:])
        fname_len := int(read_u16_le(data[off+28:]))
        extra_len := int(read_u16_le(data[off+30:]))
        comment_len := int(read_u16_le(data[off+32:]))
        local_offset := read_u32_le(data[off+42:])

        if off + 46 + fname_len > len(data) do break

        name := strings.clone(string(data[off+46:][:fname_len]))

        append(&entries, Zip_Entry{
            name              = name,
            compression       = compression,
            compressed_size   = comp_size,
            uncompressed_size = uncomp_size,
            local_offset      = local_offset,
        })

        off += 46 + fname_len + extra_len + comment_len
    }

    return entries[:], true
}

zip_extract_entry :: proc(data: []u8, entry: Zip_Entry) -> []u8 {
    off := int(entry.local_offset)
    if off + 30 > len(data) do return nil

    // Verify local file header signature
    if data[off] != 0x50 || data[off+1] != 0x4b ||
       data[off+2] != 0x03 || data[off+3] != 0x04 { return nil }

    local_fname_len := int(read_u16_le(data[off+26:]))
    local_extra_len := int(read_u16_le(data[off+28:]))
    file_data_off := off + 30 + local_fname_len + local_extra_len

    comp_size := int(entry.compressed_size)
    uncomp_size := int(entry.uncompressed_size)

    if file_data_off + comp_size > len(data) do return nil

    if entry.compression == 0 {
        // Stored — copy directly
        result := make([]u8, comp_size)
        mem.copy(raw_data(result), &data[file_data_off], comp_size)
        return result
    } else if entry.compression == 8 {
        // Deflate — use zlib
        compressed := data[file_data_off:][:comp_size]
        return zlib_inflate_raw(compressed, uncomp_size)
    }

    return nil
}

// ---------------------------------------------------------------------------
// Zlib FFI (raw deflate)
// ---------------------------------------------------------------------------

z_stream :: struct {
    next_in:   [^]u8,
    avail_in:  c.uint,
    total_in:  c.ulong,
    next_out:  [^]u8,
    avail_out: c.uint,
    total_out: c.ulong,
    msg:       cstring,
    state:     rawptr,
    zalloc:    rawptr,
    zfree:     rawptr,
    opaque:    rawptr,
    data_type: c.int,
    adler:     c.ulong,
    reserved:  c.ulong,
}

Z_OK            :: 0
Z_STREAM_END    :: 1
Z_NO_FLUSH      :: 0
ZLIB_VERSION    :: "1.3.1"

foreign import zlib "system:z"

@(default_calling_convention = "c")
foreign zlib {
    inflateInit2_ :: proc(strm: ^z_stream, windowBits: c.int,
                          version: cstring, stream_size: c.int) -> c.int ---
    inflate       :: proc(strm: ^z_stream, flush: c.int) -> c.int ---
    inflateEnd    :: proc(strm: ^z_stream) -> c.int ---
}

zlib_inflate_raw :: proc(compressed: []u8, expected_size: int) -> []u8 {
    out_size := expected_size if expected_size > 0 else len(compressed) * 4
    output := make([]u8, out_size)

    strm: z_stream
    strm.next_in = raw_data(compressed)
    strm.avail_in = c.uint(len(compressed))
    strm.next_out = raw_data(output)
    strm.avail_out = c.uint(out_size)

    // wbits = -15 for raw deflate (no header)
    ret := inflateInit2_(&strm, -15, ZLIB_VERSION, c.int(size_of(z_stream)))
    if ret != Z_OK {
        delete(output)
        return nil
    }

    ret = inflate(&strm, Z_NO_FLUSH)
    inflateEnd(&strm)

    if ret != Z_OK && ret != Z_STREAM_END {
        delete(output)
        return nil
    }

    actual := int(strm.total_out)
    if actual < out_size {
        // Shrink to actual size
        result := make([]u8, actual)
        mem.copy(raw_data(result), raw_data(output), actual)
        delete(output)
        return result
    }
    return output
}

// ---------------------------------------------------------------------------
// Trigger / Popup UI
// ---------------------------------------------------------------------------

extension_trigger :: proc() {
    if popup_is_active() {
        popup_dismiss()
        return
    }
    extension_popup_main()
}

extension_popup_main :: proc() {
    if popup_is_active() do popup_dismiss()

    panel := lv_obj_create(lv_layer_top())
    lv_obj_set_size(panel, 300, LV_SIZE_CONTENT)
    lv_obj_set_style_bg_color(panel, lv_color_hex(theme_bg_prim), 0)
    lv_obj_set_style_bg_opa(panel, u8(theme_bg_opacity), 0)
    lv_obj_set_style_text_color(panel, lv_color_hex(theme_text_pri), 0)
    lv_obj_set_style_radius(panel, 12, 0)
    lv_obj_set_style_pad_top(panel, theme_padding, 0)
    lv_obj_set_style_pad_bottom(panel, theme_padding, 0)
    lv_obj_set_style_pad_left(panel, theme_padding, 0)
    lv_obj_set_style_pad_right(panel, theme_padding, 0)
    lv_obj_set_style_pad_row(panel, theme_gap, 0)
    lv_obj_set_style_max_height(panel, 500, 0)
    lv_obj_set_flex_flow(panel, .LV_FLEX_FLOW_COLUMN)
    lv_obj_set_flex_align(panel, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)

    // Header
    header := lv_label_create(panel)
    lv_label_set_text(header, "Extensions")

    if len(extensions) == 0 {
        empty := lv_label_create(panel)
        lv_label_set_text(empty, "No extensions installed")
        lv_obj_set_style_text_color(empty, lv_color_hex(theme_text_sec), 0)
    }

    for ext, i in extensions {
        row := lv_obj_create(panel)
        lv_obj_set_width(row, lv_pct(100))
        lv_obj_set_height(row, LV_SIZE_CONTENT)
        lv_obj_set_flex_flow(row, .LV_FLEX_FLOW_ROW)
        lv_obj_set_flex_align(row, .LV_FLEX_ALIGN_SPACE_BETWEEN, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
        lv_obj_remove_flag(row, .LV_OBJ_FLAG_SCROLLABLE)
        lv_obj_set_style_pad_top(row, 2, 0)
        lv_obj_set_style_pad_bottom(row, 2, 0)

        // Name + version label
        lbl := lv_label_create(row)
        label_text: string
        if ext.version != "" {
            label_text = fmt.tprintf("%s v%s", ext.name, ext.version)
        } else {
            label_text = ext.name
        }
        lv_label_set_text(lbl, strings.clone_to_cstring(label_text))
        lv_label_set_long_mode(lbl, .LV_LABEL_LONG_MODE_DOTS)
        lv_obj_set_flex_grow(lbl, 1)
        if !ext.enabled {
            lv_obj_set_style_text_color(lbl, lv_color_hex(theme_text_sec), 0)
        }

        // Settings button (if extension has options page)
        if ext.options_page != "" {
            cfg_btn := lv_button_create(row)
            lv_obj_set_style_pad_top(cfg_btn, 4, 0)
            lv_obj_set_style_pad_bottom(cfg_btn, 4, 0)
            lv_obj_set_style_pad_left(cfg_btn, 8, 0)
            lv_obj_set_style_pad_right(cfg_btn, 8, 0)
            lv_obj_add_event_cb(cfg_btn, on_ext_settings, .LV_EVENT_CLICKED, rawptr(uintptr(i)))
            cfg_lbl := lv_label_create(cfg_btn)
            lv_label_set_text(cfg_lbl, icons[.settings])
            lv_obj_set_style_text_font(cfg_lbl, icon_font, 0)
        }

        // Enable/disable toggle button
        btn := lv_button_create(row)
        lv_obj_add_event_cb(btn, on_ext_toggle, .LV_EVENT_CLICKED, rawptr(uintptr(i)))
        btn_lbl := lv_label_create(btn)
        lv_label_set_text(btn_lbl, ext.enabled ? "ON" : "OFF")
    }

    if ext_popup_anchor != nil {
        popup_show(panel, ext_popup_anchor)
    } else if settings_popup_anchor != nil {
        popup_show(panel, settings_popup_anchor)
    }
}

on_ext_toggle :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    idx := int(uintptr(lv_event_get_user_data(e)))
    if idx < 0 || idx >= len(extensions) do return

    if extensions[idx].enabled {
        extension_disable(idx)
    } else {
        extension_enable(idx)
    }
    extension_popup_main()
}

on_ext_settings :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    idx := int(uintptr(lv_event_get_user_data(e)))
    if idx < 0 || idx >= len(extensions) do return

    ext := extensions[idx]
    if ext.options_page == "" do return

    ext_id := extension_get_id(ext)
    url := fmt.tprintf("axium://ext/%s/%s", ext_id, ext.options_page)
    engine_view_go_to(tab_entries[active_tab].view, strings.clone_to_cstring(url))
    content_has_focus = true
    popup_dismiss()
}
