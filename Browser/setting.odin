package axium

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

Content :: enum u8 {
    Javascript,   // bit 0
    Popups,       // bit 1
    Webrtc,       // bit 2
    Webgl,        // bit 3
    Media_Stream, // bit 4
    Adblock,      // bit 5
    Autoplay_0,   // bit 6  \  2-bit autoplay: 0=deny 1=muted 2=allow
    Autoplay_1,   // bit 7  /
}

Permission :: enum u8 {
    Geolocation,  // 0
    Notifications,// 1
    Camera,       // 2
    Microphone,   // 3
    Clipboard,    // 4
    Device_Info,  // 5
    Media_Keys,   // 6
    Data_Access,  // 7
}

Site_Settings :: struct {
    domain:      string,                 // empty for defaults
    content:     bit_set[Content; u8],
    permissions: bit_set[Permission; u8],
    user_agent:  string,                 // "" = use default
}

// Autoplay helpers — encode/decode 2-bit value from Autoplay_0/Autoplay_1

content_get_autoplay :: proc(c: bit_set[Content; u8]) -> int {
    return (1 if .Autoplay_0 in c else 0) | (2 if .Autoplay_1 in c else 0)
}

content_set_autoplay :: proc(c: ^bit_set[Content; u8], val: int) {
    c^ -= {.Autoplay_0, .Autoplay_1}
    if val & 1 != 0 do c^ += {.Autoplay_0}
    if val & 2 != 0 do c^ += {.Autoplay_1}
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

default_settings: Site_Settings
site_overrides:   map[u64]Site_Settings  // key = hash.murmur64a(domain)

// Session-only globals (not per-site)
privacy_cookie_policy: c.int = 1         // 0=always, 1=no-third-party, 2=never
privacy_itp_enabled: bool = true
privacy_credential_persistence: bool = true
privacy_proxy_mode: c.int = 0            // 0=default, 1=none, 2=custom
privacy_proxy_url: string = ""
privacy_proxy_ignore: string = ""

// TLS whitelist (session-level, passed to engine once at startup)
tls_allowed_hosts: [dynamic]string

// UI anchors
settings_popup_anchor: ^lv_obj_t
settings_icon_label: ^lv_obj_t

// ---------------------------------------------------------------------------
// Default initialization
// ---------------------------------------------------------------------------

settings_init_defaults :: proc() {
    default_settings.content = {.Javascript, .Webgl, .Media_Stream, .Adblock}
    // autoplay default = 0 (deny) → no Autoplay bits set
    // permissions default = all false → empty set
    default_settings.permissions = {}
    default_settings.user_agent = ""
}

// ---------------------------------------------------------------------------
// Domain helpers
// ---------------------------------------------------------------------------

site_settings_extract_domain :: proc(url: string) -> string {
    rest := url
    if idx := strings.index(url, "://"); idx >= 0 do rest = url[idx+3:]
    if idx := strings.index_byte(rest, '/'); idx >= 0 do rest = rest[:idx]
    if idx := strings.index_byte(rest, ':'); idx >= 0 do rest = rest[:idx]
    return rest
}

domain_hash :: proc(domain: string) -> u64 {
    return hash.murmur64a(transmute([]u8)domain)
}

// ---------------------------------------------------------------------------
// Core API
// ---------------------------------------------------------------------------

site_settings_get :: proc(domain: string) -> (Site_Settings, bool) {
    // Direct lookup
    if s, ok := site_overrides[domain_hash(domain)]; ok {
        return s, true
    }
    // Subdomain fallback
    rest := domain
    for {
        idx := strings.index_byte(rest, '.')
        if idx < 0 do break
        rest = rest[idx+1:]
        if s, ok := site_overrides[domain_hash(rest)]; ok {
            return s, true
        }
    }
    return default_settings, false
}

site_settings_set :: proc(domain: string, s: Site_Settings) {
    h := domain_hash(domain)
    // If identical to defaults, remove override
    if s.content == default_settings.content &&
       s.permissions == default_settings.permissions &&
       s.user_agent == default_settings.user_agent {
        delete_key(&site_overrides, h)
    } else {
        entry := s
        // Ensure domain is stored for serialization
        if entry.domain == "" || entry.domain != domain {
            entry.domain = strings.clone(domain) if h not_in site_overrides else site_overrides[h].domain
        }
        site_overrides[h] = entry
    }
    site_settings_save()
}

// ---------------------------------------------------------------------------
// Navigation response
// ---------------------------------------------------------------------------

Engine_Nav_Response :: struct {
    user_agent: cstring,
    flags:      u8,
}

pack_nav_response :: proc(uri: string) -> Engine_Nav_Response {
    domain := site_settings_extract_domain(uri)
    s, _ := site_settings_get(domain)

    ua_cstr: cstring = nil
    if s.user_agent != "" {
        ua_cstr = strings.clone_to_cstring(s.user_agent)
    } else if default_settings.user_agent != "" {
        ua_cstr = strings.clone_to_cstring(default_settings.user_agent)
    }

    return Engine_Nav_Response{ user_agent = ua_cstr, flags = transmute(u8)s.content }
}

site_settings_update_icon :: proc(uri: string) {
    if uri == "" do return
    domain := site_settings_extract_domain(uri)
    _, has_override := site_settings_get(domain)
    site_settings_icon_update(has_override)
}

// ---------------------------------------------------------------------------
// Permission callback
// ---------------------------------------------------------------------------

@(export)
permission_query :: proc "c" (origin: cstring, perm_type: c.int) -> c.int {
    context = runtime.default_context()
    if origin == nil do return 0
    domain := site_settings_extract_domain(string(origin))
    s, has := site_settings_get(domain)
    if !has do return 0

    perm := Permission(perm_type)
    if perm in s.permissions != perm in default_settings.permissions {
        return 1 if perm in s.permissions else -1
    }
    if perm in default_settings.permissions {
        return 1
    }
    return 0
}

// ---------------------------------------------------------------------------
// Privacy init
// ---------------------------------------------------------------------------

privacy_init :: proc() {
    engine_configure_privacy(
        privacy_cookie_policy,
        privacy_itp_enabled,
        true,  // tls_strict — always true at session level now
        privacy_credential_persistence,
    )

    if privacy_proxy_mode != 0 || privacy_proxy_url != "" {
        engine_configure_proxy(
            privacy_proxy_mode,
            strings.clone_to_cstring(privacy_proxy_url) if privacy_proxy_url != "" else nil,
            strings.clone_to_cstring(privacy_proxy_ignore) if privacy_proxy_ignore != "" else nil,
        )
    }

    // TLS allowed hosts
    if len(tls_allowed_hosts) > 0 {
        hosts := make([dynamic]cstring)
        defer {
            for h in hosts do delete(h)
            delete(hosts)
        }
        for h in tls_allowed_hosts {
            append(&hosts, strings.clone_to_cstring(h))
        }
        engine_set_tls_allowed_hosts(raw_data(hosts[:]), c.int(len(hosts)))
    }
}

// ---------------------------------------------------------------------------
// Persistence (settings.sjson)
// ---------------------------------------------------------------------------

site_settings_path :: proc() -> string {
    return xdg_path(.Config, "settings.sjson")
}

// Ensure a domain entry exists in site_overrides, starting from defaults.
settings_ensure_override :: proc(domain: string) -> u64 {
    h := domain_hash(domain)
    if h not_in site_overrides {
        entry := default_settings
        entry.domain = strings.clone(domain)
        site_overrides[h] = entry
    }
    return h
}

site_settings_load :: proc() {
    settings_init_defaults()

    path := site_settings_path()
    file, ok := os.read_entire_file(path)
    if !ok {
        site_settings_save()
        return
    }
    defer delete(file)

    cfg, err := json.parse(file, .SJSON)
    if err != .None do return
    defer json.destroy_value(cfg)

    root, rok := cfg.(json.Object)
    if !rok do return

    // --- Session-scope ---
    if v, vok := root["itp"].(json.Boolean); vok do privacy_itp_enabled = v
    if v, vok := root["credential_persistence"].(json.Boolean); vok do privacy_credential_persistence = v

    if proxy, pok := root["proxy"].(json.Object); pok {
        if m, mok := proxy["mode"].(json.String); mok {
            switch m {
            case "default": privacy_proxy_mode = 0
            case "none":    privacy_proxy_mode = 1
            case "custom":  privacy_proxy_mode = 2
            }
        }
        if u, uok := proxy["url"].(json.String); uok do privacy_proxy_url = strings.clone(u)
        if ig, iok := proxy["ignore"].(json.String); iok do privacy_proxy_ignore = strings.clone(ig)
    }

    // --- Build default_settings from SJSON ---
    Content_Field :: struct { key: string, flag: Content }
    content_fields := [?]Content_Field{
        {"javascript",   .Javascript},
        {"popups",       .Popups},
        {"webrtc",       .Webrtc},
        {"webgl",        .Webgl},
        {"media_stream", .Media_Stream},
        {"adblock",      .Adblock},
    }

    for f in content_fields {
        if obj, bok := root[f.key].(json.Object); bok {
            if def, dok := obj["default"].(json.Boolean); dok {
                if def {
                    default_settings.content += {f.flag}
                } else {
                    default_settings.content -= {f.flag}
                }
            }
            // Exceptions: each domain gets a copy of defaults with this bit flipped
            if arr, aok := obj["exceptions"].(json.Array); aok {
                for item in arr {
                    if d, sok := item.(json.String); sok {
                        h := settings_ensure_override(d)
                        s := site_overrides[h]
                        s.content ~= {f.flag}  // flip the bit
                        site_overrides[h] = s
                    }
                }
            }
        }
    }

    Permission_Field :: struct { key: string, flag: Permission }
    perm_fields := [?]Permission_Field{
        {"geolocation",   .Geolocation},
        {"notifications", .Notifications},
        {"camera",        .Camera},
        {"microphone",    .Microphone},
        {"clipboard",     .Clipboard},
        {"device_info",   .Device_Info},
        {"media_keys",    .Media_Keys},
        {"data_access",   .Data_Access},
    }

    for f in perm_fields {
        if obj, bok := root[f.key].(json.Object); bok {
            if def, dok := obj["default"].(json.Boolean); dok {
                if def {
                    default_settings.permissions += {f.flag}
                } else {
                    default_settings.permissions -= {f.flag}
                }
            }
            if arr, aok := obj["exceptions"].(json.Array); aok {
                for item in arr {
                    if d, sok := item.(json.String); sok {
                        h := settings_ensure_override(d)
                        s := site_overrides[h]
                        s.permissions ~= {f.flag}
                        site_overrides[h] = s
                    }
                }
            }
        }
    }

    // --- Autoplay ---
    if obj, aok := root["autoplay"].(json.Object); aok {
        if def, dok := obj["default"].(json.String); dok {
            switch def {
            case "deny":  content_set_autoplay(&default_settings.content, 0)
            case "muted": content_set_autoplay(&default_settings.content, 1)
            case "allow": content_set_autoplay(&default_settings.content, 2)
            }
        }
        if exc, eok := obj["exceptions"].(json.Object); eok {
            for domain, val in exc {
                if v, vok := val.(json.String); vok {
                    h := settings_ensure_override(domain)
                    s := site_overrides[h]
                    switch v {
                    case "deny":  content_set_autoplay(&s.content, 0)
                    case "muted": content_set_autoplay(&s.content, 1)
                    case "allow": content_set_autoplay(&s.content, 2)
                    }
                    site_overrides[h] = s
                }
            }
        }
    }

    // --- Cookies (session-level only) ---
    if v, cok := root["cookie_policy"].(json.String); cok {
        switch v {
        case "always":         privacy_cookie_policy = 0
        case "no_third_party": privacy_cookie_policy = 1
        case "never":          privacy_cookie_policy = 2
        }
    }

    // --- User agent ---
    if obj, uok := root["user_agent"].(json.Object); uok {
        if def, dok := obj["default"].(json.String); dok {
            default_settings.user_agent = strings.clone(def)
        }
        if exc, eok := obj["exceptions"].(json.Object); eok {
            for domain, val in exc {
                if v, vok := val.(json.String); vok {
                    h := settings_ensure_override(domain)
                    s := site_overrides[h]
                    s.user_agent = strings.clone(v)
                    site_overrides[h] = s
                }
            }
        }
    }

    // --- TLS allowed hosts ---
    if obj, tok := root["tls_enforce"].(json.Object); tok {
        if arr, aok := obj["exceptions"].(json.Array); aok {
            for item in arr {
                if d, sok := item.(json.String); sok {
                    append(&tls_allowed_hosts, strings.clone(d))
                }
            }
        }
    }
}

site_settings_save :: proc() {
    path := site_settings_path()
    dir := path[:strings.last_index_byte(path, '/')]
    os.make_directory(dir)

    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    strings.write_string(&b, "{\n")

    // --- Session-scope ---
    fmt.sbprintf(&b, "    itp: %s\n", privacy_itp_enabled ? "true" : "false")
    fmt.sbprintf(&b, "    credential_persistence: %s\n", privacy_credential_persistence ? "true" : "false")

    proxy_modes := [3]string{"default", "none", "custom"}
    fmt.sbprintf(&b, "    proxy: {{ mode: \"%s\"  url: \"%s\"  ignore: \"%s\" }}\n",
        proxy_modes[privacy_proxy_mode], privacy_proxy_url, privacy_proxy_ignore)

    // --- Content booleans (diff overrides against defaults per-bit) ---
    Content_Field :: struct { key: string, flag: Content }
    content_fields := [?]Content_Field{
        {"javascript",   .Javascript},
        {"popups",       .Popups},
        {"adblock",      .Adblock},
        {"webrtc",       .Webrtc},
        {"webgl",        .Webgl},
        {"media_stream", .Media_Stream},
    }

    for f in content_fields {
        def_on := f.flag in default_settings.content
        fmt.sbprintf(&b, "    %s: {{ default: %s  exceptions: [", f.key, def_on ? "true" : "false")
        first := true
        for _, entry in site_overrides {
            if (f.flag in entry.content) != def_on {
                if !first do strings.write_byte(&b, ' ')
                fmt.sbprintf(&b, "\"%s\"", entry.domain)
                first = false
            }
        }
        strings.write_string(&b, "] }\n")
    }

    // --- Permission booleans ---
    Permission_Field :: struct { key: string, flag: Permission }
    perm_fields := [?]Permission_Field{
        {"geolocation",   .Geolocation},
        {"notifications", .Notifications},
        {"camera",        .Camera},
        {"microphone",    .Microphone},
        {"clipboard",     .Clipboard},
        {"device_info",   .Device_Info},
        {"media_keys",    .Media_Keys},
        {"data_access",   .Data_Access},
    }

    for f in perm_fields {
        def_on := f.flag in default_settings.permissions
        fmt.sbprintf(&b, "    %s: {{ default: %s  exceptions: [", f.key, def_on ? "true" : "false")
        first := true
        for _, entry in site_overrides {
            if (f.flag in entry.permissions) != def_on {
                if !first do strings.write_byte(&b, ' ')
                fmt.sbprintf(&b, "\"%s\"", entry.domain)
                first = false
            }
        }
        strings.write_string(&b, "] }\n")
    }

    // --- TLS (session-level whitelist) ---
    fmt.sbprintf(&b, "    tls_enforce: {{ default: true  exceptions: [")
    {
        first := true
        for h in tls_allowed_hosts {
            if !first do strings.write_byte(&b, ' ')
            fmt.sbprintf(&b, "\"%s\"", h)
            first = false
        }
    }
    strings.write_string(&b, "] }\n")

    // --- Cookies ---
    cookie_names := [3]string{"always", "no_third_party", "never"}
    fmt.sbprintf(&b, "    cookie_policy: \"%s\"\n", cookie_names[privacy_cookie_policy])

    // --- Autoplay ---
    autoplay_names := [3]string{"deny", "muted", "allow"}
    def_autoplay := content_get_autoplay(default_settings.content)
    fmt.sbprintf(&b, "    autoplay: {{ default: \"%s\"  exceptions: {{", autoplay_names[def_autoplay])
    {
        first := true
        for _, entry in site_overrides {
            ap := content_get_autoplay(entry.content)
            if ap != def_autoplay {
                if !first do strings.write_byte(&b, ' ')
                fmt.sbprintf(&b, " \"%s\": \"%s\"", entry.domain, autoplay_names[ap])
                first = false
            }
        }
    }
    strings.write_string(&b, " } }\n")

    // --- User agent ---
    fmt.sbprintf(&b, "    user_agent: {{ default: \"%s\"  exceptions: {{", default_settings.user_agent)
    {
        first := true
        for _, entry in site_overrides {
            if entry.user_agent != default_settings.user_agent {
                if !first do strings.write_byte(&b, ' ')
                fmt.sbprintf(&b, " \"%s\": \"%s\"", entry.domain, entry.user_agent)
                first = false
            }
        }
    }
    strings.write_string(&b, " } }\n")

    strings.write_string(&b, "}\n")

    os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

// ---------------------------------------------------------------------------
// Settings page message handlers
// ---------------------------------------------------------------------------

@(export)
setting_handle_message :: proc "c" (c_payload: cstring) -> cstring {
    context = runtime.default_context()
    if c_payload == nil do return nil

    data, err := json.parse(transmute([]u8)string(c_payload))
    if err != .None do return nil
    defer json.destroy_value(data)

    obj, ok := data.(json.Object)
    if !ok do return nil

    action, aok := obj["action"].(json.String)
    if !aok do return nil

    switch action {
    case "get-defaults": return settings_get_defaults()
    case "set-defaults": return settings_set_defaults(data)
    case "get-domains":  return settings_get_domains()
    case "get-site":     return settings_get_site(data)
    case "set-site":     return settings_set_site(data)
    }
    return nil
}

@(private="file")
settings_clone_result :: proc(b: ^strings.Builder) -> cstring {
    result := strings.clone_to_cstring(strings.to_string(b^))
    strings.builder_destroy(b)
    return result
}

settings_get_defaults :: proc() -> cstring {
    b := strings.builder_make()
    strings.write_byte(&b, '{')

    write_bool :: proc(b: ^strings.Builder, key: string, val: bool, first: ^bool) {
        if !first^ do strings.write_byte(b, ',')
        first^ = false
        fmt.sbprintf(b, "\"%s\":%s", key, val ? "true" : "false")
    }
    write_int :: proc(b: ^strings.Builder, key: string, val: int, first: ^bool) {
        if !first^ do strings.write_byte(b, ',')
        first^ = false
        fmt.sbprintf(b, "\"%s\":%d", key, val)
    }
    write_str :: proc(b: ^strings.Builder, key: string, val: string, first: ^bool) {
        if !first^ do strings.write_byte(b, ',')
        first^ = false
        fmt.sbprintf(b, "\"%s\":\"%s\"", key, val)
    }

    first := true
    dc := default_settings.content
    dp := default_settings.permissions

    write_bool(&b, "javascript",    .Javascript   in dc, &first)
    write_bool(&b, "popups",        .Popups       in dc, &first)
    write_bool(&b, "adblock",       .Adblock      in dc, &first)
    write_bool(&b, "webrtc",        .Webrtc       in dc, &first)
    write_bool(&b, "webgl",         .Webgl        in dc, &first)
    write_bool(&b, "media_stream",  .Media_Stream in dc, &first)
    write_int(&b,  "autoplay",      content_get_autoplay(dc), &first)
    write_str(&b,  "user_agent",    default_settings.user_agent, &first)
    write_bool(&b, "geolocation",   .Geolocation   in dp, &first)
    write_bool(&b, "notifications", .Notifications in dp, &first)
    write_bool(&b, "camera",        .Camera        in dp, &first)
    write_bool(&b, "microphone",    .Microphone    in dp, &first)
    write_bool(&b, "clipboard",     .Clipboard     in dp, &first)
    write_bool(&b, "device_info",   .Device_Info   in dp, &first)
    write_bool(&b, "media_keys",    .Media_Keys    in dp, &first)
    write_bool(&b, "data_access",   .Data_Access   in dp, &first)

    // Session-only
    write_int(&b,  "cookie_policy", int(privacy_cookie_policy),  &first)
    write_bool(&b, "itp",          privacy_itp_enabled,          &first)
    write_bool(&b, "credential_persistence", privacy_credential_persistence, &first)
    write_int(&b,  "proxy_mode",   int(privacy_proxy_mode),      &first)
    write_str(&b,  "proxy_url",    privacy_proxy_url,            &first)
    write_str(&b,  "proxy_ignore", privacy_proxy_ignore,         &first)

    strings.write_byte(&b, '}')
    return settings_clone_result(&b)
}

settings_set_defaults :: proc(payload: json.Value) -> cstring {
    obj, ok := payload.(json.Object)
    if !ok do return "{\"ok\":false}"
    data, dok := obj["data"].(json.Object)
    if !dok do return "{\"ok\":false}"

    // Helper to set/clear a content bit from JSON bool
    set_content_bool :: proc(data: json.Object, key: string, flag: Content) {
        if v, vok := data[key].(json.Boolean); vok {
            if v {
                default_settings.content += {flag}
            } else {
                default_settings.content -= {flag}
            }
        }
    }
    set_perm_bool :: proc(data: json.Object, key: string, flag: Permission) {
        if v, vok := data[key].(json.Boolean); vok {
            if v {
                default_settings.permissions += {flag}
            } else {
                default_settings.permissions -= {flag}
            }
        }
    }

    set_content_bool(data, "javascript",   .Javascript)
    set_content_bool(data, "popups",       .Popups)
    set_content_bool(data, "adblock",      .Adblock)
    set_content_bool(data, "webrtc",       .Webrtc)
    set_content_bool(data, "webgl",        .Webgl)
    set_content_bool(data, "media_stream", .Media_Stream)

    set_perm_bool(data, "geolocation",   .Geolocation)
    set_perm_bool(data, "notifications", .Notifications)
    set_perm_bool(data, "camera",        .Camera)
    set_perm_bool(data, "microphone",    .Microphone)
    set_perm_bool(data, "clipboard",     .Clipboard)
    set_perm_bool(data, "device_info",   .Device_Info)
    set_perm_bool(data, "media_keys",    .Media_Keys)
    set_perm_bool(data, "data_access",   .Data_Access)

    if v, vok := data["autoplay"].(json.Float); vok {
        content_set_autoplay(&default_settings.content, int(v))
    }
    if v, vok := data["user_agent"].(json.String); vok {
        if default_settings.user_agent != "" do delete(default_settings.user_agent)
        default_settings.user_agent = strings.clone(v)
    }

    // Session-only
    if v, vok := data["itp"].(json.Boolean);                   vok do privacy_itp_enabled          = v
    if v, vok := data["credential_persistence"].(json.Boolean); vok do privacy_credential_persistence = v
    if v, vok := data["cookie_policy"].(json.Float);           vok do privacy_cookie_policy = c.int(v)
    if v, vok := data["proxy_mode"].(json.Float);              vok do privacy_proxy_mode = c.int(v)
    if v, vok := data["proxy_url"].(json.String); vok {
        if privacy_proxy_url != "" do delete(privacy_proxy_url)
        privacy_proxy_url = strings.clone(v)
    }
    if v, vok := data["proxy_ignore"].(json.String); vok {
        if privacy_proxy_ignore != "" do delete(privacy_proxy_ignore)
        privacy_proxy_ignore = strings.clone(v)
    }

    // Re-apply to engine
    engine_configure_privacy(
        privacy_cookie_policy,
        privacy_itp_enabled,
        true,
        privacy_credential_persistence,
    )
    if privacy_proxy_mode != 0 || privacy_proxy_url != "" {
        engine_configure_proxy(
            privacy_proxy_mode,
            strings.clone_to_cstring(privacy_proxy_url) if privacy_proxy_url != "" else nil,
            strings.clone_to_cstring(privacy_proxy_ignore) if privacy_proxy_ignore != "" else nil,
        )
    }

    site_settings_save()
    return "{\"ok\":true}"
}

settings_get_domains :: proc() -> cstring {
    b := strings.builder_make()
    strings.write_byte(&b, '[')
    first := true
    for _, entry in site_overrides {
        if !first do strings.write_byte(&b, ',')
        first = false
        fmt.sbprintf(&b, "\"%s\"", entry.domain)
    }
    strings.write_byte(&b, ']')
    return settings_clone_result(&b)
}

settings_get_site :: proc(payload: json.Value) -> cstring {
    obj, ok := payload.(json.Object)
    if !ok do return "{}"
    domain_val, dok := obj["domain"].(json.String)
    if !dok do return "{}"

    s, _ := site_settings_get(domain_val)

    b := strings.builder_make()
    strings.write_byte(&b, '{')

    write_bool :: proc(b: ^strings.Builder, key: string, val: bool, first: ^bool) {
        if !first^ do strings.write_byte(b, ',')
        first^ = false
        fmt.sbprintf(b, "\"%s\":%s", key, val ? "true" : "false")
    }
    write_int :: proc(b: ^strings.Builder, key: string, val: int, first: ^bool) {
        if !first^ do strings.write_byte(b, ',')
        first^ = false
        fmt.sbprintf(b, "\"%s\":%d", key, val)
    }
    write_str :: proc(b: ^strings.Builder, key: string, val: string, first: ^bool) {
        if !first^ do strings.write_byte(b, ',')
        first^ = false
        fmt.sbprintf(b, "\"%s\":\"%s\"", key, val)
    }

    first := true
    write_bool(&b, "javascript",    .Javascript   in s.content,     &first)
    write_bool(&b, "popups",        .Popups       in s.content,     &first)
    write_bool(&b, "adblock",       .Adblock      in s.content,     &first)
    write_bool(&b, "webrtc",        .Webrtc       in s.content,     &first)
    write_bool(&b, "webgl",         .Webgl        in s.content,     &first)
    write_bool(&b, "media_stream",  .Media_Stream in s.content,     &first)
    write_int(&b,  "autoplay",      content_get_autoplay(s.content), &first)
    write_str(&b,  "user_agent",    s.user_agent,                    &first)
    write_bool(&b, "geolocation",   .Geolocation   in s.permissions, &first)
    write_bool(&b, "notifications", .Notifications in s.permissions, &first)
    write_bool(&b, "camera",        .Camera        in s.permissions, &first)
    write_bool(&b, "microphone",    .Microphone    in s.permissions, &first)
    write_bool(&b, "clipboard",     .Clipboard     in s.permissions, &first)
    write_bool(&b, "device_info",   .Device_Info   in s.permissions, &first)
    write_bool(&b, "media_keys",    .Media_Keys    in s.permissions, &first)
    write_bool(&b, "data_access",   .Data_Access   in s.permissions, &first)

    strings.write_byte(&b, '}')
    return settings_clone_result(&b)
}

settings_set_site :: proc(payload: json.Value) -> cstring {
    obj, ok := payload.(json.Object)
    if !ok do return "{\"ok\":false}"
    domain_val, dok := obj["domain"].(json.String)
    if !dok do return "{\"ok\":false}"
    data, daok := obj["data"].(json.Object)
    if !daok do return "{\"ok\":false}"

    // Start from defaults, apply JSON values to build fully resolved settings
    s := default_settings
    s.domain = domain_val

    set_content :: proc(data: json.Object, key: string, flag: Content, c: ^bit_set[Content; u8]) {
        if v, vok := data[key].(json.Boolean); vok {
            if v { c^ += {flag} } else { c^ -= {flag} }
        }
    }
    set_perm :: proc(data: json.Object, key: string, flag: Permission, p: ^bit_set[Permission; u8]) {
        if v, vok := data[key].(json.Boolean); vok {
            if v { p^ += {flag} } else { p^ -= {flag} }
        }
    }

    set_content(data, "javascript",   .Javascript,   &s.content)
    set_content(data, "popups",       .Popups,       &s.content)
    set_content(data, "adblock",      .Adblock,      &s.content)
    set_content(data, "webrtc",       .Webrtc,       &s.content)
    set_content(data, "webgl",        .Webgl,        &s.content)
    set_content(data, "media_stream", .Media_Stream, &s.content)

    set_perm(data, "geolocation",   .Geolocation,   &s.permissions)
    set_perm(data, "notifications", .Notifications, &s.permissions)
    set_perm(data, "camera",        .Camera,        &s.permissions)
    set_perm(data, "microphone",    .Microphone,    &s.permissions)
    set_perm(data, "clipboard",     .Clipboard,     &s.permissions)
    set_perm(data, "device_info",   .Device_Info,   &s.permissions)
    set_perm(data, "media_keys",    .Media_Keys,    &s.permissions)
    set_perm(data, "data_access",   .Data_Access,   &s.permissions)

    if v, vok := data["autoplay"].(json.Float); vok {
        content_set_autoplay(&s.content, int(v))
    }
    if v, vok := data["user_agent"].(json.String); vok {
        s.user_agent = strings.clone(v)
    }

    site_settings_set(domain_val, s)
    return "{\"ok\":true}"
}

// ---------------------------------------------------------------------------
// Adblock toggle (keybinding / command)
// ---------------------------------------------------------------------------

adblock_toggle :: proc() {
    if active_tab < 0 || active_tab >= tab_count do return
    tab_uri := tab_entries[active_tab].uri
    if len(tab_uri) == 0 do return
    domain := site_settings_extract_domain(tab_uri)

    s, _ := site_settings_get(domain)
    s.content ~= {.Adblock}
    site_settings_set(domain, s)
    engine_reload()
}

// ---------------------------------------------------------------------------
// Icon state
// ---------------------------------------------------------------------------

site_settings_icon_update :: proc(has_override: bool) {
    if settings_icon_label == nil do return
    if has_override {
        lv_obj_set_style_text_color(settings_icon_label, lv_color_hex(theme_accent), 0)
    } else {
        lv_obj_set_style_text_color(settings_icon_label, lv_color_hex(theme_text_pri), 0)
    }
}

// ---------------------------------------------------------------------------
// Widget factory
// ---------------------------------------------------------------------------

widget_settings :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_settings_widget_click, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[.settings])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
    settings_popup_anchor = btn
    settings_icon_label = lbl
}

on_settings_widget_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    settings_trigger()
}

// ---------------------------------------------------------------------------
// Trigger
// ---------------------------------------------------------------------------

settings_trigger :: proc() {
    if popup_is_active() {
        popup_dismiss()
        return
    }
    settings_popup_main()
}

// ---------------------------------------------------------------------------
// Section label helper
// ---------------------------------------------------------------------------

settings_section_label :: proc(parent: ^lv_obj_t, text: cstring) {
    sep := lv_obj_create(parent)
    lv_obj_set_width(sep, lv_pct(100))
    lv_obj_set_height(sep, 1)
    lv_obj_set_style_bg_color(sep, lv_color_hex(theme_text_sec), 0)
    lv_obj_set_style_bg_opa(sep, 80, 0)
    lv_obj_remove_flag(sep, .LV_OBJ_FLAG_SCROLLABLE)

    lbl := lv_label_create(parent)
    lv_label_set_text(lbl, text)
    lv_obj_set_style_text_color(lbl, lv_color_hex(theme_text_sec), 0)
}

// ---------------------------------------------------------------------------
// Popup
// ---------------------------------------------------------------------------

// Field IDs encode the type and bit position:
//   0..7  = Content enum value
//   8..15 = Permission enum value (offset by 8)
FIELD_PERM_OFFSET :: 8

@(thread_local) settings_popup_domain: string

settings_popup_main :: proc() {
    if popup_is_active() do popup_dismiss()

    domain: string
    if active_tab >= 0 && active_tab < tab_count && len(tab_entries[active_tab].uri) > 0 {
        domain = site_settings_extract_domain(tab_entries[active_tab].uri)
    }
    settings_popup_domain = domain

    s, has_override := site_settings_get(domain)
    dc := default_settings.content
    dp := default_settings.permissions

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
    if domain != "" {
        lv_label_set_text(header, strings.clone_to_cstring(domain))
    } else {
        lv_label_set_text(header, "No page loaded")
    }
    lv_label_set_long_mode(header, .LV_LABEL_LONG_MODE_DOTS)
    lv_obj_set_width(header, lv_pct(100))
    lv_obj_set_style_text_color(header, lv_color_hex(theme_text_sec), 0)

    if domain != "" {
        // Content section
        settings_section_label(panel, "Content")

        settings_toggle_row(panel, "JavaScript",
            .Javascript in s.content, .Javascript in s.content != .Javascript in dc,
            int(Content.Javascript))
        settings_toggle_row(panel, "Popups",
            .Popups in s.content, .Popups in s.content != .Popups in dc,
            int(Content.Popups))
        settings_toggle_row(panel, "Adblock",
            .Adblock in s.content, .Adblock in s.content != .Adblock in dc,
            int(Content.Adblock))

        autoplay_val := content_get_autoplay(s.content)
        autoplay_labels := [3]string{"Deny", "Muted", "Allow"}
        settings_cycle_row(panel, "Autoplay",
            autoplay_labels[autoplay_val],
            autoplay_val != content_get_autoplay(dc),
            int(Content.Autoplay_0))  // special: cycle handler knows this means autoplay

        // Web APIs section
        settings_section_label(panel, "Web APIs")

        settings_toggle_row(panel, "WebRTC",
            .Webrtc in s.content, .Webrtc in s.content != .Webrtc in dc,
            int(Content.Webrtc))
        settings_toggle_row(panel, "WebGL",
            .Webgl in s.content, .Webgl in s.content != .Webgl in dc,
            int(Content.Webgl))
        settings_toggle_row(panel, "Media Stream",
            .Media_Stream in s.content, .Media_Stream in s.content != .Media_Stream in dc,
            int(Content.Media_Stream))

        // Permissions section
        settings_section_label(panel, "Permissions")

        settings_toggle_row(panel, "Geolocation",
            .Geolocation in s.permissions, .Geolocation in s.permissions != .Geolocation in dp,
            int(Permission.Geolocation) + FIELD_PERM_OFFSET)
        settings_toggle_row(panel, "Notifications",
            .Notifications in s.permissions, .Notifications in s.permissions != .Notifications in dp,
            int(Permission.Notifications) + FIELD_PERM_OFFSET)
        settings_toggle_row(panel, "Camera",
            .Camera in s.permissions, .Camera in s.permissions != .Camera in dp,
            int(Permission.Camera) + FIELD_PERM_OFFSET)
        settings_toggle_row(panel, "Microphone",
            .Microphone in s.permissions, .Microphone in s.permissions != .Microphone in dp,
            int(Permission.Microphone) + FIELD_PERM_OFFSET)
        settings_toggle_row(panel, "Clipboard",
            .Clipboard in s.permissions, .Clipboard in s.permissions != .Clipboard in dp,
            int(Permission.Clipboard) + FIELD_PERM_OFFSET)
        settings_toggle_row(panel, "Device Info",
            .Device_Info in s.permissions, .Device_Info in s.permissions != .Device_Info in dp,
            int(Permission.Device_Info) + FIELD_PERM_OFFSET)
        settings_toggle_row(panel, "Media Keys",
            .Media_Keys in s.permissions, .Media_Keys in s.permissions != .Media_Keys in dp,
            int(Permission.Media_Keys) + FIELD_PERM_OFFSET)
        settings_toggle_row(panel, "Data Access",
            .Data_Access in s.permissions, .Data_Access in s.permissions != .Data_Access in dp,
            int(Permission.Data_Access) + FIELD_PERM_OFFSET)

        // Bottom separator
        sep := lv_obj_create(panel)
        lv_obj_set_width(sep, lv_pct(100))
        lv_obj_set_height(sep, 1)
        lv_obj_set_style_bg_color(sep, lv_color_hex(theme_text_sec), 0)
        lv_obj_set_style_bg_opa(sep, 80, 0)
        lv_obj_remove_flag(sep, .LV_OBJ_FLAG_SCROLLABLE)

        // All Settings button
        all_btn := lv_button_create(panel)
        lv_obj_set_width(all_btn, lv_pct(100))
        lv_obj_add_event_cb(all_btn, on_settings_all, .LV_EVENT_CLICKED, nil)
        all_lbl := lv_label_create(all_btn)
        lv_label_set_text(all_lbl, "All Settings")
    }

    if settings_popup_anchor != nil {
        popup_show(panel, settings_popup_anchor)
    }
}

// ---------------------------------------------------------------------------
// Toggle row helper
// ---------------------------------------------------------------------------

settings_toggle_row :: proc(parent: ^lv_obj_t, label: cstring, current: bool, overridden: bool, field_id: int) {
    row := lv_obj_create(parent)
    lv_obj_set_width(row, lv_pct(100))
    lv_obj_set_height(row, LV_SIZE_CONTENT)
    lv_obj_set_flex_flow(row, .LV_FLEX_FLOW_ROW)
    lv_obj_set_flex_align(row, .LV_FLEX_ALIGN_SPACE_BETWEEN, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
    lv_obj_remove_flag(row, .LV_OBJ_FLAG_SCROLLABLE)
    lv_obj_set_style_pad_top(row, 2, 0)
    lv_obj_set_style_pad_bottom(row, 2, 0)

    lbl := lv_label_create(row)
    lv_label_set_text(lbl, label)
    if overridden {
        lv_obj_set_style_text_color(lbl, lv_color_hex(theme_accent), 0)
    }

    btn := lv_button_create(row)
    lv_obj_set_style_pad_top(btn, 4, 0)
    lv_obj_set_style_pad_bottom(btn, 4, 0)
    lv_obj_set_style_pad_left(btn, 10, 0)
    lv_obj_set_style_pad_right(btn, 10, 0)
    lv_obj_add_event_cb(btn, on_settings_toggle, .LV_EVENT_CLICKED, rawptr(uintptr(field_id)))
    btn_lbl := lv_label_create(btn)
    lv_label_set_text(btn_lbl, current ? "ON" : "OFF")
}

// ---------------------------------------------------------------------------
// Cycle row helper
// ---------------------------------------------------------------------------

settings_cycle_row :: proc(parent: ^lv_obj_t, label: cstring, value: string, overridden: bool, field_id: int) {
    row := lv_obj_create(parent)
    lv_obj_set_width(row, lv_pct(100))
    lv_obj_set_height(row, LV_SIZE_CONTENT)
    lv_obj_set_flex_flow(row, .LV_FLEX_FLOW_ROW)
    lv_obj_set_flex_align(row, .LV_FLEX_ALIGN_SPACE_BETWEEN, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
    lv_obj_remove_flag(row, .LV_OBJ_FLAG_SCROLLABLE)
    lv_obj_set_style_pad_top(row, 2, 0)
    lv_obj_set_style_pad_bottom(row, 2, 0)

    lbl := lv_label_create(row)
    lv_label_set_text(lbl, label)
    if overridden {
        lv_obj_set_style_text_color(lbl, lv_color_hex(theme_accent), 0)
    }

    btn := lv_button_create(row)
    lv_obj_set_style_pad_top(btn, 4, 0)
    lv_obj_set_style_pad_bottom(btn, 4, 0)
    lv_obj_set_style_pad_left(btn, 10, 0)
    lv_obj_set_style_pad_right(btn, 10, 0)
    lv_obj_add_event_cb(btn, on_settings_cycle, .LV_EVENT_CLICKED, rawptr(uintptr(field_id)))
    btn_lbl := lv_label_create(btn)
    lv_label_set_text(btn_lbl, strings.clone_to_cstring(value))
}

// ---------------------------------------------------------------------------
// Popup callbacks
// ---------------------------------------------------------------------------

on_settings_toggle :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    field_id := int(uintptr(lv_event_get_user_data(e)))
    domain := settings_popup_domain
    if domain == "" do return

    s, _ := site_settings_get(domain)

    if field_id < FIELD_PERM_OFFSET {
        // Content toggle — XOR the bit
        flag := Content(field_id)
        s.content ~= {flag}
    } else {
        // Permission toggle
        flag := Permission(field_id - FIELD_PERM_OFFSET)
        s.permissions ~= {flag}
    }

    site_settings_set(domain, s)
    engine_reload()
    settings_popup_main()
}

on_settings_cycle :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    field_id := int(uintptr(lv_event_get_user_data(e)))
    domain := settings_popup_domain
    if domain == "" do return

    s, _ := site_settings_get(domain)

    // Autoplay cycle: 0->1->2->0
    if field_id == int(Content.Autoplay_0) {
        cur := content_get_autoplay(s.content)
        content_set_autoplay(&s.content, (cur + 1) % 3)
    }

    site_settings_set(domain, s)
    engine_reload()
    settings_popup_main()
}

on_settings_all :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    popup_dismiss()
    engine_view_go_to(tab_entries[active_tab].view, "axium://settings")
    content_has_focus = true
}
