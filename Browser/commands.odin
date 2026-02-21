package axium

import "core:strings"

execute_command :: proc(cmd: string) {
    switch cmd {
    case "copy":        engine_editing_command("Copy", nil)
    case "cut":         engine_editing_command("Cut", nil)
    case "paste":       engine_editing_command("Paste", nil)
    case "paste_plain": engine_editing_command("PasteAsPlainText", nil)
    case "select_all":  engine_editing_command("SelectAll", nil)
    case "undo":        engine_editing_command("Undo", nil)
    case "redo":        engine_editing_command("Redo", nil)
    case "back":        engine_go_back()
    case "forward":     engine_go_forward()
    case "reload":      engine_reload()
    case:
        // Dynamic edge commands: toggle_edge_top_0, etc.
        if strings.has_prefix(cmd, "toggle_") {
            if e := find_edge(cmd[len("toggle_"):]); e != nil {
                edge_toggle(e)
            }
        }
    }
}

// Check if a command is a hold-mode edge command
is_hold_command :: proc(cmd: string) -> bool {
    return strings.has_prefix(cmd, "hold_")
}

// Get the edge for a hold command
get_hold_edge :: proc(cmd: string) -> ^Edge_Info {
    if strings.has_prefix(cmd, "hold_") {
        return find_edge(cmd[len("hold_"):])
    }
    return nil
}
