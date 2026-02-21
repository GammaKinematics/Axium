package axium

import "core:os"
import "core:strings"
import "core:encoding/json"

CONFIG_PATH :: #config(CONFIG_PATH, "~/.config/axium/config.sjson")

config_load :: proc() {
    path := CONFIG_PATH
    if len(path) > 0 && path[0] == '~' {
        home := os.get_env("HOME")
        path = strings.concatenate({home, path[1:]})
    }
    file, ok := os.read_entire_file(path)
    if !ok do return
    defer delete(file)

    cfg, err := json.parse(file, .SJSON)
    if err != .None do return
    defer json.destroy_value(cfg)

    root, rok := cfg.(json.Object)
    if !rok do return

    parse_bindings(root["keybindings"].(json.Object) or_else nil, &bindings)
}
