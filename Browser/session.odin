package axium

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:fmt"

session_enabled: bool

// Restore tabs from session file. Returns true if session was restored.
session_restore :: proc() -> bool {
    if !session_enabled do return false

    path := xdg_path(.State, "session.sjson")
    file, ok := os.read_entire_file(path)
    if !ok do return false
    defer delete(file)

    // Delete session file immediately (one-shot restore)
    os.remove(path)

    cfg, err := json.parse(file, .SJSON)
    if err != .None do return false
    defer json.destroy_value(cfg)

    root, rok := cfg.(json.Object)
    if !rok do return false

    tabs_arr, tok := root["tabs"].(json.Array)
    if !tok || len(tabs_arr) == 0 do return false

    active_val := root["active"].(json.Float) or_else 0
    active_idx := int(active_val)

    // Load first tab into existing view (view 0 already created)
    first_url := tabs_arr[0].(json.String) or_else ""
    if first_url != "" {
        engine_view_go_to(tab_entries[0].view, strings.clone_to_cstring(first_url))
        tab_set_uri(0, first_url)
    }

    // Create additional tabs
    for i in 1..<len(tabs_arr) {
        url := tabs_arr[i].(json.String) or_else ""
        if url == "" do continue
        if tab_count >= MAX_TABS do break
        related := tab_entries[0].view
        view := engine_create_view(content_area.w, content_area.h, false, related)
        if view == nil do continue
        idx := tab_count
        tab_entries[idx] = Tab_Entry{ view = view }
        tab_count += 1
        engine_view_go_to(view, strings.clone_to_cstring(url))
        tab_set_uri(idx, url)
    }

    // Set active tab directly (no tab_switch — widgets don't exist yet)
    if active_idx >= 0 && active_idx < tab_count {
        active_tab = active_idx
        engine_set_active_view(tab_entries[active_idx].view)
    } else {
        active_tab = 0
        engine_set_active_view(tab_entries[0].view)
    }

    return true
}

// Save current tabs to session file.
session_save :: proc() {
    if !session_enabled do return
    if tab_count == 0 do return

    path := xdg_path(.State, "session.sjson")
    dir := path[:strings.last_index_byte(path, '/')]
    os.make_directory(dir)

    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    strings.write_string(&b, "{\n")
    fmt.sbprintf(&b, "    active: %d\n", active_tab)
    strings.write_string(&b, "    tabs: [\n")

    for i in 0..<tab_count {
        // Skip ephemeral (incognito) tabs
        if tab_entries[i].ephemeral do continue
        url := tab_entries[i].uri
        if len(url) > 0 {
            fmt.sbprintf(&b, "        \"%s\"\n", url)
        }
    }

    strings.write_string(&b, "    ]\n")
    strings.write_string(&b, "}\n")

    os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}
