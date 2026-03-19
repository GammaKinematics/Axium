package axium

import "base:runtime"
import "core:c"
import "core:crypto/ed25519"
import "core:dynlib"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:bytes"
import compress_zlib "core:compress/zlib"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

Ext_Entry :: struct {
    name:    string,
    id:      string,

    // Native code (.so loaded from signed extension archives)
    native_lib:            dynlib.Library,
    native_init:           proc "c" (),
    native_shutdown:       proc "c" (),
    native_handle_message: proc(payload: cstring, reply: rawptr, ctx: rawptr),
}

extensions: [dynamic]Ext_Entry

// ---------------------------------------------------------------------------
// Adblock content script (embedded, registered in isolated world)
// ---------------------------------------------------------------------------

_adblock_js := #load("../Adblock/adblock.js")

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

extension_init :: proc() {
    // Register adblock content script in isolated "adblock" world
    adblock_js := strings.clone_to_cstring(string(_adblock_js))
    defer delete(adblock_js)
    engine_add_user_script(adblock_js, 1, 1, nil, 0, "adblock")  // all frames, document_end

    dir_path := xdg_path(.Config, "extensions/")
    os.make_directory(dir_path)

    dh, err := os.open(dir_path)
    if err != nil do return
    defer os.close(dh)

    dir_entries, rerr := os.read_dir(dh, -1)
    if rerr != nil do return
    defer delete(dir_entries)

    for entry in dir_entries {
        name := entry.name
        if strings.has_suffix(name, ".axe") ||
           strings.has_suffix(name, ".xpi") ||
           strings.has_suffix(name, ".crx") {
            extension_load(strings.concatenate({dir_path, name}))
        }
    }
    fmt.eprintln("[ext] init:", len(extensions), "extension(s)")
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ext_war_match :: proc(war: json.Array, name: string) -> bool {
    for item in war {
        if pat, sok := item.(json.String); sok {
            if ext_glob(pat, name) do return true
        }
        if obj, ook := item.(json.Object); ook {
            if res, rok := obj["resources"].(json.Array); rok {
                for r in res {
                    if pat, sok := r.(json.String); sok {
                        if ext_glob(pat, name) do return true
                    }
                }
            }
        }
    }
    return false
}

ext_glob :: proc(pattern: string, name: string) -> bool {
    star := strings.index_byte(pattern, '*')
    if star < 0 do return pattern == name
    return strings.has_prefix(name, pattern[:star]) && strings.has_suffix(name, pattern[star+1:])
}

ext_mime :: proc(name: string) -> string {
    if strings.has_suffix(name, ".png")  do return "image/png"
    if strings.has_suffix(name, ".jpg") || strings.has_suffix(name, ".jpeg") do return "image/jpeg"
    if strings.has_suffix(name, ".gif")  do return "image/gif"
    if strings.has_suffix(name, ".webp") do return "image/webp"
    if strings.has_suffix(name, ".svg")  do return "image/svg+xml"
    if strings.has_suffix(name, ".css")  do return "text/css"
    if strings.has_suffix(name, ".js")   do return "text/javascript"
    if strings.has_suffix(name, ".json") do return "application/json"
    if strings.has_suffix(name, ".html") || strings.has_suffix(name, ".htm") do return "text/html"
    if strings.has_suffix(name, ".woff") do return "font/woff"
    if strings.has_suffix(name, ".woff2") do return "font/woff2"
    if strings.has_suffix(name, ".ttf")  do return "font/ttf"
    return "application/octet-stream"
}

// ---------------------------------------------------------------------------
// __MSG_key__ substitution (used for CSS + extension name)
// ---------------------------------------------------------------------------

ext_substitute_messages :: proc(text: string, msgs: map[string]string) -> string {
    if !strings.contains(text, "__MSG_") do return strings.clone(text)

    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    rest := text
    for {
        idx := strings.index(rest, "__MSG_")
        if idx < 0 {
            strings.write_string(&b, rest)
            break
        }
        strings.write_string(&b, rest[:idx])
        rest = rest[idx + 6:]

        end := strings.index(rest, "__")
        if end < 0 {
            strings.write_string(&b, "__MSG_")
            strings.write_string(&b, rest)
            break
        }

        key := strings.to_lower(rest[:end], context.temp_allocator)
        if msg, ok := msgs[key]; ok {
            strings.write_string(&b, msg)
        } else {
            strings.write_string(&b, "__MSG_")
            strings.write_string(&b, key)
            strings.write_string(&b, "__")
        }
        rest = rest[end + 2:]
    }

    return strings.clone(strings.to_string(b))
}

// ---------------------------------------------------------------------------
// Extension loading — read zip, parse manifest, register, optionally load .so
// ---------------------------------------------------------------------------

extension_load :: proc(filepath: string) {
    defer delete(filepath)

    archive, ok := os.read_entire_file(filepath)
    if !ok {
        fmt.eprintln("[ext] failed to read:", filepath)
        return
    }
    defer delete(archive)

    // Detect format + find zip start
    zip_data: []u8
    if len(archive) >= 4 && string(archive[:2]) == "PK" {
        zip_data = archive
    } else if len(archive) >= 12 &&
              archive[0] == 'C' && archive[1] == 'r' &&
              archive[2] == '2' && archive[3] == '4' {
        header_len := read_u32_le(archive[8:12])
        zip_offset := 12 + int(header_len)
        if zip_offset < len(archive) do zip_data = archive[zip_offset:]
    }

    if zip_data == nil {
        fmt.eprintln("[ext] unknown format:", filepath)
        return
    }

    zip_entries, zok := zip_parse_central_dir(zip_data)
    if !zok {
        fmt.eprintln("[ext] bad zip:", filepath)
        return
    }
    defer { for &ze in zip_entries do delete(ze.name); delete(zip_entries) }

    manifest_data := ext_extract_file(zip_data, zip_entries, "manifest.json")
    if manifest_data == nil {
        fmt.eprintln("[ext] no manifest:", filepath)
        return
    }
    defer delete(manifest_data)

    manifest, merr := json.parse(manifest_data)
    if merr != .None do return
    defer json.destroy_value(manifest)

    mobj, mok := manifest.(json.Object)
    if !mok do return

    // --- Build Ext_Entry ---

    ext_entry: Ext_Entry
    if v, vok := mobj["name"].(json.String); vok do ext_entry.name = strings.clone(v)

    // ID: browser_specific_settings.gecko.id → applications.gecko.id → filename stem
    if bss, bok := mobj["browser_specific_settings"].(json.Object); bok {
        if gecko, gok := bss["gecko"].(json.Object); gok {
            if id, iok := gecko["id"].(json.String); iok do ext_entry.id = strings.clone(id)
        }
    }
    if ext_entry.id == "" {
        if apps, aok := mobj["applications"].(json.Object); aok {
            if gecko, gok := apps["gecko"].(json.Object); gok {
                if id, iok := gecko["id"].(json.String); iok do ext_entry.id = strings.clone(id)
            }
        }
    }
    if ext_entry.id == "" {
        stem := filepath
        if idx := strings.last_index_byte(filepath, '/'); idx >= 0 do stem = filepath[idx+1:]
        if idx := strings.last_index_byte(stem, '.'); idx >= 0 do stem = stem[:idx]
        ext_entry.id = strings.clone(stem)
    }

    // --- Load i18n ---

    msgs: map[string]string
    defer {
        for k, v in msgs { delete(k); delete(v) }
        delete(msgs)
    }
    {
        default_locale: string
        if v, vok := mobj["default_locale"].(json.String); vok do default_locale = v
        for lang in ([2]string{language, default_locale}) {
            if lang == "" do continue
            raw := ext_extract_file(zip_data, zip_entries, fmt.tprintf("_locales/%s/messages.json", lang))
            if raw == nil do continue
            defer delete(raw)
            parsed, perr := json.parse(raw)
            if perr != .None do continue
            defer json.destroy_value(parsed)
            if obj, ok2 := parsed.(json.Object); ok2 {
                for key, val in obj {
                    if entry, eok := val.(json.Object); eok {
                        if msg, mok2 := entry["message"].(json.String); mok2 {
                            msgs[strings.clone(strings.to_lower(key, context.temp_allocator))] = strings.clone(msg)
                        }
                    }
                }
            }
            break
        }
    }

    if strings.contains(ext_entry.name, "__MSG_") {
        new_name := ext_substitute_messages(ext_entry.name, msgs)
        delete(ext_entry.name)
        ext_entry.name = new_name
    }

    append(&extensions, ext_entry)
    ext := &extensions[len(extensions) - 1]

    // --- Register message handler in engine.c (ext_id as handler name) ---

    ext_id_c := strings.clone_to_cstring(ext.id)
    defer delete(ext_id_c)
    engine_register_ext_handler(ext_id_c)

    // --- Register script world + shim + content scripts ---

    cs_arr := mobj["content_scripts"].(json.Array) or_else nil
    war_arr := mobj["web_accessible_resources"].(json.Array) or_else nil

    world_name := strings.clone_to_cstring(fmt.tprintf("axium-ext-%s", ext.id))
    defer delete(world_name)

    // Build polyfill shim
    shim: strings.Builder
    strings.builder_init(&shim)
    defer strings.builder_destroy(&shim)

    strings.write_string(&shim, "(function(){\n")
    fmt.sbprintf(&shim, "var _ext_id=\"%s\";\n", ext.id)

    // Bake i18n
    strings.write_string(&shim, "var _msgs={")
    {
        first := true
        for key, msg in msgs {
            if !first do strings.write_byte(&shim, ',')
            first = false
            key_j, _ := json.marshal(key);  strings.write_string(&shim, string(key_j)); delete(key_j)
            strings.write_byte(&shim, ':')
            msg_j, _ := json.marshal(msg);  strings.write_string(&shim, string(msg_j)); delete(msg_j)
        }
    }
    strings.write_string(&shim, "};\n")

    // Bake web_accessible_resources as data URIs
    strings.write_string(&shim, "var _assets={")
    if war_arr != nil {
        first := true
        for &ze in zip_entries {
            if strings.has_suffix(ze.name, "/") do continue
            if !ext_war_match(war_arr, ze.name) do continue
            data := zip_extract_entry(zip_data, ze)
            if data == nil do continue
            encoded := base64.encode(data)
            delete(data)
            if !first do strings.write_byte(&shim, ',')
            first = false
            key_j, _ := json.marshal(ze.name); strings.write_string(&shim, string(key_j)); delete(key_j)
            fmt.sbprintf(&shim, ":\"data:%s;base64,", ext_mime(ze.name))
            strings.write_string(&shim, encoded)
            delete(encoded)
            strings.write_byte(&shim, '"')
        }
    }
    strings.write_string(&shim, "};\n")

    // Polyfill: messaging via stock WebKit UIProcess↔WebProcess path.
    // All browser.* API calls collapse into the same postMessage pipe.
    // The .so extension receives raw JSON and handles it however it wants.
    strings.write_string(&shim,
`var browser=window.browser||{};
browser.runtime=browser.runtime||{};
browser.runtime.id=_ext_id;
browser.runtime.getURL=function(p){return _assets[p]||p};
browser.runtime.sendMessage=function(msg){
return window.webkit.messageHandlers[_ext_id].postMessage(
JSON.stringify(msg)
).then(function(r){try{return JSON.parse(r)}catch(e){return r}});
};
browser.runtime.onMessage={_ls:[],addListener:function(fn){this._ls.push(fn);},
removeListener:function(fn){var i=this._ls.indexOf(fn);if(i>=0)this._ls.splice(i,1);}};
window.__axium_dispatch=function(msg){
try{var m=typeof msg==="string"?JSON.parse(msg):msg;}catch(e){return;}
browser.runtime.onMessage._ls.forEach(function(fn){fn(m);});
};
browser.storage={local:{
get:function(keys){return browser.runtime.sendMessage({_a:"storage.get",keys:keys})},
set:function(items){return browser.runtime.sendMessage({_a:"storage.set",items:items})},
remove:function(keys){return browser.runtime.sendMessage({_a:"storage.remove",keys:typeof keys==="string"?[keys]:keys})}
}};
browser.tabs={sendMessage:function(tabId,msg){
return browser.runtime.sendMessage({_a:"tabs.sendMessage",tabId:tabId,data:msg});
}};
browser.i18n={getMessage:function(id,subs){
var m=_msgs[id.toLowerCase()];if(!m)return id;
if(subs){if(typeof subs==="string")subs=[subs];
for(var i=0;i<subs.length;i++)m=m.replaceAll("$"+(i+1),subs[i]);}
return m;
}};
window.browser=browser;
window.chrome=browser;
`)
    strings.write_string(&shim, "})();\n")

    shim_cstr := strings.clone_to_cstring(strings.to_string(shim))
    defer delete(shim_cstr)
    engine_add_user_script(shim_cstr, 1, 0, nil, 0, world_name)

    // Register each content script group
    for cs_val in cs_arr {
        cs_obj := cs_val.(json.Object) or_else nil
        if cs_obj == nil do continue

        allow: [dynamic]cstring
        defer { for a in allow do delete(a); delete(allow) }
        all_urls := false
        if matches, maok := cs_obj["matches"].(json.Array); maok {
            for m in matches {
                if s, sok := m.(json.String); sok {
                    if s == "<all_urls>" { all_urls = true; break }
                    append(&allow, strings.clone_to_cstring(s))
                }
            }
        }
        allow_ptr: [^]cstring = nil
        if !all_urls && len(allow) > 0 do allow_ptr = raw_data(allow[:])
        allow_count := c.int(0) if all_urls else c.int(len(allow))

        run_at := cs_obj["run_at"].(json.String) or_else "document_end"
        inject_time: c.int = 0 if run_at == "document_start" else 1

        if js_arr, jaok := cs_obj["js"].(json.Array); jaok {
            for js_val in js_arr {
                js_file := js_val.(json.String) or_else ""
                if js_file == "" do continue
                src := ext_extract_file(zip_data, zip_entries, js_file)
                if src == nil { fmt.eprintln("[ext]   MISSING js:", js_file); continue }
                cstr := strings.clone_to_cstring(string(src)); delete(src)
                engine_add_user_script(cstr, 1, inject_time, allow_ptr, allow_count, world_name)
                delete(cstr)
            }
        }
        if css_arr, caok := cs_obj["css"].(json.Array); caok {
            for css_val in css_arr {
                css_file := css_val.(json.String) or_else ""
                if css_file == "" do continue
                src := ext_extract_file(zip_data, zip_entries, css_file)
                if src == nil do continue
                css_str := ext_substitute_messages(string(src), msgs); delete(src)
                cstr := strings.clone_to_cstring(css_str); delete(css_str)
                engine_add_user_style(cstr, 1, allow_ptr, allow_count, world_name)
                delete(cstr)
            }
        }
    }

    // Load native .so from archive (if present)
    ext_try_load_native(ext, zip_data, zip_entries)
}

// ---------------------------------------------------------------------------
// Native .so loading (memfd + dlopen)
// ---------------------------------------------------------------------------

ext_try_load_native :: proc(ext: ^Ext_Entry, zip_data: []u8, entries: []Zip_Entry) {
    so_bytes := ext_extract_file(zip_data, entries, "extension.so")
    if so_bytes == nil do return

    sig_bytes := ext_extract_file(zip_data, entries, "extension.so.sig")
    if sig_bytes == nil {
        fmt.eprintln("[ext]", ext.name, "— extension.so present but no signature, skipping")
        delete(so_bytes)
        return
    }
    defer delete(sig_bytes)

    if !ext_verify_signature(so_bytes, sig_bytes) {
        fmt.eprintln("[ext]", ext.name, "— signature verification failed, skipping")
        delete(so_bytes)
        return
    }

    fd_name := strings.clone_to_cstring(fmt.tprintf("ext-%s", ext.id))
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
// Message routing — called from engine.c per-extension handler
// ---------------------------------------------------------------------------

@(export)
extension_handle_message :: proc "c" (c_ext_id: cstring, c_payload: cstring, reply: rawptr, ctx: rawptr) {
    context = runtime.default_context()

    if c_ext_id == nil || c_payload == nil {
        engine_extension_reply(reply, ctx, nil)
        return
    }

    ext_id := string(c_ext_id)
    for &ext in extensions {
        if ext.id != ext_id do continue
        if ext.native_handle_message != nil {
            ext.native_handle_message(c_payload, reply, ctx)
            return  // .so owns reply+ctx — calls engine_extension_reply when done
        }
        break
    }

    // No native handler — reply with null
    engine_extension_reply(reply, ctx, nil)
}

// ---------------------------------------------------------------------------
// Push messages — .so calls these via dlsym
// ---------------------------------------------------------------------------

@(export)
extension_send_tab_message :: proc(ext_id: string, tab_id: int, json_msg: string) {
    if tab_id < 0 || tab_id >= tab_count do return
    view := tab_entries[tab_id].view
    if view == nil do return
    world := strings.clone_to_cstring(fmt.tprintf("axium-ext-%s", ext_id))
    defer delete(world)
    js := strings.clone_to_cstring(
        fmt.tprintf("window.__axium_dispatch&&window.__axium_dispatch(%s)", json_msg))
    defer delete(js)
    engine_run_javascript_in_world(view, js, world)
}

@(export)
extension_broadcast_message :: proc(ext_id: string, json_msg: string) {
    for i in 0..<tab_count {
        extension_send_tab_message(ext_id, i, json_msg)
    }
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
// Shutdown
// ---------------------------------------------------------------------------

extension_shutdown :: proc() {
    for &ext in extensions {
        if ext.native_shutdown != nil do ext.native_shutdown()
        if ext.native_lib != nil do dynlib.unload_library(ext.native_lib)
        delete(ext.name)
        delete(ext.id)
    }
    clear(&extensions)
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

ext_extract_file :: proc(zip_data: []u8, entries: []Zip_Entry, name: string) -> []u8 {
    for &ze in entries {
        if ze.name == name {
            return zip_extract_entry(zip_data, ze)
        }
    }
    return nil
}

zip_parse_central_dir :: proc(data: []u8) -> ([]Zip_Entry, bool) {
    eocd_off := -1
    search_start := max(0, len(data) - 65557)
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

    if data[off] != 0x50 || data[off+1] != 0x4b ||
       data[off+2] != 0x03 || data[off+3] != 0x04 { return nil }

    local_fname_len := int(read_u16_le(data[off+26:]))
    local_extra_len := int(read_u16_le(data[off+28:]))
    file_data_off := off + 30 + local_fname_len + local_extra_len

    comp_size := int(entry.compressed_size)
    uncomp_size := int(entry.uncompressed_size)

    if file_data_off + comp_size > len(data) do return nil

    if entry.compression == 0 {
        result := make([]u8, comp_size)
        mem.copy(raw_data(result), &data[file_data_off], comp_size)
        return result
    } else if entry.compression == 8 {
        compressed := data[file_data_off:][:comp_size]
        buf: bytes.Buffer
        err := compress_zlib.inflate_from_byte_array_raw(compressed, &buf, raw = true, expected_output_size = uncomp_size)
        if err != nil {
            bytes.buffer_destroy(&buf)
            return nil
        }
        return buf.buf[:]
    }

    return nil
}
