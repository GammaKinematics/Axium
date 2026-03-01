package axium

import "core:strings"
import "core:strconv"

execute_command :: proc(cmd: string, pressed: bool = true) {
    switch cmd {
    case "copy":        if pressed do engine_editing_command("Copy", nil)
    case "cut":         if pressed do engine_editing_command("Cut", nil)
    case "paste":       if pressed do engine_editing_command("Paste", nil)
    case "paste_plain": if pressed do engine_editing_command("PasteAsPlainText", nil)
    case "select_all":  if pressed do engine_editing_command("SelectAll", nil)
    case "undo":        if pressed do engine_editing_command("Undo", nil)
    case "redo":        if pressed do engine_editing_command("Redo", nil)
    case "back":        if pressed do engine_go_back()
    case "forward":     if pressed do engine_go_forward()
    case "reload":      if pressed do engine_reload()
    case "tab_new":     if pressed do tab_new()
    case "tab_close":   if pressed do tab_close(active_tab)
    case "tab_next":    if pressed do tab_next()
    case "tab_prev":    if pressed do tab_prev()
    case "adblock":     if pressed do adblock_trigger()
    case "keepass":     if pressed do keepass_trigger()
    case "translate":        if pressed do translate_trigger()
    case "translate_toggle":       if pressed do translate_toggle()
    case "translate_toggle_theme": if pressed do translate_toggle_theme()
    case "translate_block":  if pressed do translate_block_trigger()
    case:
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
