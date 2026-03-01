package axium

import "base:runtime"
import "core:encoding/json"
import "core:hash"
import "core:strings"

ICON_SHIELD :: "\xef\x8f\xad"  // U+F3ED SHIELD-HALVED

// Per-domain toggle state (session-only)
adblock_toggled_domains: [dynamic]u64
adblock_icon_label: ^lv_obj_t

// Config state
adblock_default_on: bool = true
adblock_whitelist: [dynamic]string

adblock_extract_domain :: proc(url: string) -> string {
    rest := url
    if idx := strings.index(url, "://"); idx >= 0 do rest = url[idx+3:]
    if idx := strings.index_byte(rest, '/'); idx >= 0 do rest = rest[:idx]
    if idx := strings.index_byte(rest, ':'); idx >= 0 do rest = rest[:idx]
    return rest
}

adblock_domain_hash :: proc() -> u64 {
    uri: cstring
    engine_get_uri(&uri)
    if uri == nil do return 0
    domain := adblock_extract_domain(string(uri))
    return hash.murmur64a(transmute([]byte)domain)
}

adblock_is_toggled :: proc(h: u64) -> bool {
    for v in adblock_toggled_domains {
        if v == h do return true
    }
    return false
}

adblock_is_whitelisted :: proc(domain: string) -> bool {
    for d in adblock_whitelist {
        if domain == d do return true
        suffix := strings.concatenate({".", d})
        defer delete(suffix)
        if strings.has_suffix(domain, suffix) do return true
    }
    return false
}

adblock_is_disabled :: proc() -> bool {
    uri: cstring
    engine_get_uri(&uri)
    if uri == nil do return !adblock_default_on
    domain := adblock_extract_domain(string(uri))
    if adblock_is_whitelisted(domain) do return true
    h := hash.murmur64a(transmute([]byte)domain)
    toggled := adblock_is_toggled(h)
    return adblock_default_on == toggled
}

adblock_toggle_domain :: proc() {
    h := adblock_domain_hash()
    if h == 0 do return

    if adblock_is_toggled(h) {
        for i := 0; i < len(adblock_toggled_domains); i += 1 {
            if adblock_toggled_domains[i] == h {
                ordered_remove(&adblock_toggled_domains, i)
                break
            }
        }
    } else {
        append(&adblock_toggled_domains, h)
    }
    engine_adblock_set_disabled(adblock_is_disabled())
}

// Widget factory
widget_adblock :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_adblock_click, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, ICON_SHIELD)
    if icon_font != nil { lv_obj_set_style_text_font(lbl, icon_font, 0) }
    lv_obj_center(lbl)
    adblock_icon_label = lbl
}

on_adblock_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    adblock_trigger()
}

// Trigger from click or keybinding
adblock_trigger :: proc() {
    adblock_toggle_domain()

    if adblock_is_disabled() {
        adblock_icon_clear_active()
    } else {
        adblock_icon_set_active()
    }

    engine_reload()
}

// Navigation hook — update icon color and send disabled state
adblock_on_navigation :: proc(uri: string) {
    disabled := adblock_is_disabled()
    if disabled {
        adblock_icon_clear_active()
        engine_adblock_set_disabled(true)
    } else {
        adblock_icon_set_active()
        engine_adblock_set_disabled(false)
    }
}

// Icon color: accent = adblock ON (blocking), primary = adblock off
adblock_icon_set_active :: proc() {
    if adblock_icon_label != nil {
        lv_obj_set_style_text_color(adblock_icon_label, lv_color_hex(theme_accent), 0)
    }
}

adblock_icon_clear_active :: proc() {
    if adblock_icon_label != nil {
        lv_obj_set_style_text_color(adblock_icon_label, lv_color_hex(theme_text_pri), 0)
    }
}

// --- Config parsing ---

adblock_parse_config :: proc(obj: json.Object) {
    if obj == nil do return

    if default_val, ok := obj["default"].(json.String); ok {
        adblock_default_on = default_val != "off"
    }

    if wl_arr, ok := obj["whitelist"].(json.Array); ok {
        for item in wl_arr {
            domain := item.(json.String) or_else ""
            if domain != "" do append(&adblock_whitelist, strings.clone(domain))
        }
    }
}
