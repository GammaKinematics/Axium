package axium

import "core:strings"
import "core:strconv"

command_registry: map[string]proc()

register_command :: proc(name: string, callback: proc()) {
    command_registry[name] = callback
}

// --- Shell clipboard: paste into LVGL textarea when chrome has focus ---

shell_paste :: proc() {
    focused := lv_group_get_focused(keyboard_group)
    if focused == nil do return
    data := display_clipboard_get_data("text/plain;charset=utf-8")
    if data == nil do data = display_clipboard_get_data("text/plain")
    if data == nil do return
    defer delete(data)
    cstr := strings.clone_to_cstring(string(data))
    defer delete(cstr)
    lv_textarea_add_text(focused, cstr)
}

shell_copy :: proc() {
    focused := lv_group_get_focused(keyboard_group)
    if focused == nil do return
    ctext := lv_textarea_get_text(focused)
    if ctext == nil do return
    text := string(ctext)
    if len(text) == 0 do return
    raw := transmute([]u8)text
    entries := []Clipboard_Entry{{ mime = "text/plain;charset=utf-8", data = raw }}
    display_clipboard_set(entries)
}

execute_command :: proc(cmd: string, pressed: bool = true) {
    switch cmd {
    case "copy":        if pressed { if content_has_focus do engine_editing_command("Copy", nil); else do shell_copy() }
    case "cut":         if pressed { if content_has_focus do engine_editing_command("Cut", nil); else do shell_copy() }
    case "paste":       if pressed { if content_has_focus { clipboard_notify_before_paste(); engine_editing_command("Paste", nil) } else do shell_paste() }
    case "paste_plain": if pressed { if content_has_focus { clipboard_notify_before_paste(); engine_editing_command("Paste", nil) } else do shell_paste() }
    case "select_all":  if pressed do engine_editing_command("SelectAll", nil)
    case "undo":        if pressed do engine_editing_command("Undo", nil)
    case "redo":        if pressed do engine_editing_command("Redo", nil)
    case "back":        if pressed do engine_go_back()
    case "forward":     if pressed do engine_go_forward()
    case "reload":      if pressed do engine_reload()
    case "tab_new":         if pressed do tab_new()
    case "tab_new_private": if pressed do tab_new(ephemeral = true)
    case "tab_close":   if pressed do tab_close(active_tab)
    case "tab_next":    if pressed do tab_next()
    case "tab_prev":    if pressed do tab_prev()
    case "adblock":     if pressed do adblock_toggle()
    case "settings":    if pressed do settings_trigger()
    case "favorites":   if pressed do favorite_trigger()
    case "history":     if pressed do engine_view_go_to(tab_entries[active_tab].view, "axium://history")
    case "downloads":   if pressed do download_trigger()
    case "extensions":       if pressed do extension_trigger()
    case:
        if cb, ok := command_registry[cmd]; ok {
            if pressed do cb()
            return
        }

        idx := strings.index_byte(cmd, ' ')
        name := cmd[:idx] if idx >= 0 else cmd
        args := cmd[idx+1:] if idx >= 0 else ""

        if name == "tab_select" {
            if pressed {
                tab_idx, ok := strconv.parse_int(args)
                if ok {
                    tab_switch(tab_idx)
                }
            }
        } else if name == "edge" {
            side, index, ok := parse_edge_ref(args)
            if !ok do return
            e := edges[side][index]
            visible: bool
            switch e.show {
            case .toggle:
                if !pressed do return
                visible = !e.visible
            case .hold:   visible = pressed
            case .always, .hover: return
            }
            new_bounds := edge_set_visible(side, index, visible)
            if new_bounds != content_area {
                content_area = new_bounds
                input_area = edge_content_widget_bounds()
                update_engine_bounds()
            }
        }
    }
}
