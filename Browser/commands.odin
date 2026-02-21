package axium

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
    }
}
