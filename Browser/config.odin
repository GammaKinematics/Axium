package axium

import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "core:encoding/json"

XDG_Dir :: enum { Config, Data, State }

xdg_path :: proc(kind: XDG_Dir, subpath: string) -> string {
    env, fallback: string
    switch kind {
    case .Config: env = "XDG_CONFIG_HOME"; fallback = "/.config"
    case .Data:   env = "XDG_DATA_HOME";   fallback = "/.local/share"
    case .State:  env = "XDG_STATE_HOME";  fallback = "/.local/state"
    }
    base := os.get_env(env)
    if base == "" {
        home := os.get_env("HOME")
        base = strings.concatenate({home, fallback})
    }
    return strings.concatenate({base, "/axium/", subpath})
}

CONFIG_PATH :: #config(CONFIG_PATH, "")
BUNDLED_CONFIG :: #load("config.sjson")

web_bg_opacity: bool

// Font config
font_name: string
font_path: string
font_size: u8

// Embedded icon font subset
ICON_FONT_DATA :: #load("icons.ttf")

// Icon font override
icon_font_name: string
icon_font_path: string

apply_config :: proc(data: []u8) {
    cfg, err := json.parse(data, .SJSON)
    if err != .None do return
    defer json.destroy_value(cfg)

    root, rok := cfg.(json.Object)
    if !rok do return

    parse_bindings(root["keybindings"].(json.Object) or_else nil, &bindings)
    parse_theme(root["theme"].(json.Object) or_else nil)
    if theme_obj, tok := root["theme"].(json.Object); tok {
        if v, vok := theme_obj["web_bg_opacity"].(json.Boolean); vok do web_bg_opacity = v
    }
    if font, fok := root["font"].(json.Object); fok {
        if s, ok := font["name"].(json.String); ok do font_name = strings.clone(s)
        if s, ok := font["path"].(json.String); ok do font_path = strings.clone(s)
        if v, ok := font["size"].(json.Float); ok do font_size = u8(v)
    }
    if icon_obj, iok := root["icons"].(json.Object); iok {
        if s, ok := icon_obj["font"].(json.String); ok do icon_font_name = strings.clone(s)
        if s, ok := icon_obj["path"].(json.String); ok do icon_font_path = strings.clone(s)
        for key, val in icon_obj {
            if s, ok := val.(json.String); ok {
                if ic, eok := reflect.enum_from_name(Icon, key); eok {
                    if cp, cpok := strconv.parse_uint(s, 16); cpok {
                        encoded, n := utf8.encode_rune(rune(cp))
                        icons[ic] = strings.clone_to_cstring(string(encoded[:n]))
                    }
                }
            }
        }
    }
    edge_parse_config(root["edges"].(json.Object) or_else nil)
    translate_parse_config(root["translate"].(json.Object) or_else nil)

    if v, vok := root["restore"].(json.Boolean); vok do session_enabled = v
    if v, vok := root["download_dir"].(json.String); vok do download_dir = strings.clone(v)

    if cm_arr, cmok := root["context_menu"].(json.Array); cmok {
        layout := make([dynamic]int)
        for item in cm_arr {
            name, nok := item.(json.String)
            if !nok do continue
            for ri in 0..<len(ctx_rows) {
                if ctx_rows[ri].name == name {
                    append(&layout, ri)
                    break
                }
            }
        }
        if len(layout) > 0 {
            ctx_menu_layout = layout[:]
        } else {
            delete(layout)
        }
    }
}

config_load :: proc() {
    apply_config(BUNDLED_CONFIG)
    path := CONFIG_PATH if CONFIG_PATH != "" else xdg_path(.Config, "config.sjson")
    if file, ok := os.read_entire_file(path); ok {
        apply_config(file)
        delete(file)
    }
    if font_path == "" && font_name != "" do font_path = find_font(font_name)
    if icon_font_path == "" && icon_font_name != "" do icon_font_path = find_font(icon_font_name)
}
