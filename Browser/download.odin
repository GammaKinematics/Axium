package axium

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

Download_State :: enum {
    Active,
    Finished,
    Failed,
}

Download_Entry :: struct {
    uri:      string,
    filename: string,
    progress: f64,       // 0.0–1.0
    elapsed:  f64,       // seconds
    received: u64,       // bytes received so far
    total:    u64,       // final size (set on finish)
    state:    Download_State,
    error:    string,
    // Live UI widgets (nil when popup not showing this entry)
    arc:       ^lv_obj_t,
    pct_lbl:   ^lv_obj_t,
    speed_lbl: ^lv_obj_t,
    row:       ^lv_obj_t,
}

download_dir: string
download_entries: [dynamic]Download_Entry
download_popup_anchor: ^lv_obj_t
download_panel: ^lv_obj_t

download_init :: proc() {
    // Resolve ~ in download_dir
    dir := download_dir
    if len(dir) > 0 && dir[0] == '~' {
        home := os.get_env("HOME")
        dir = strings.concatenate({home, dir[1:]})
        download_dir = dir
    }

    // Ensure directory exists
    os.make_directory(dir)

    engine_set_download_dir(strings.clone_to_cstring(dir))
}

download_find :: proc(uri: string) -> int {
    for &entry, i in download_entries {
        if entry.uri == uri do return i
    }
    return -1
}

@(export)
download_started :: proc "c" (c_uri: cstring, c_filename: cstring) {
    context = runtime.default_context()
    uri := string(c_uri)
    filename := string(c_filename) if c_filename != nil else "download"
    entry: Download_Entry
    entry.uri = strings.clone(uri)
    entry.filename = strings.clone(filename)
    entry.state = .Active
    append(&download_entries, entry)
    download_popup_main()
}

@(export)
download_progress :: proc "c" (c_uri: cstring, c_progress: c.double, c_elapsed: c.double, c_received: c.uint64_t) {
    context = runtime.default_context()
    uri := string(c_uri)
    progress := f64(c_progress)
    elapsed := f64(c_elapsed)
    received := u64(c_received)
    idx := download_find(uri)
    if idx < 0 do return
    entry := &download_entries[idx]
    entry.progress = progress
    entry.elapsed = elapsed
    entry.received = received

    // Update live widgets if downloads popup is showing
    if popup_active == download_panel && download_panel != nil {
        pct := i32(progress * 100)
        if entry.arc != nil do lv_arc_set_value(entry.arc, pct)
        if entry.pct_lbl != nil {
            lv_label_set_text(entry.pct_lbl, strings.clone_to_cstring(fmt.tprintf("%d", int(pct))))
        }
        if entry.speed_lbl != nil {
            speed_str: string
            if elapsed > 0.5 {
                speed := u64(f64(received) / elapsed)
                speed_str = fmt.tprintf("%s/s \xc2\xb7 %s", format_bytes(speed), format_bytes(received))
            } else {
                speed_str = fmt.tprintf("%s", format_bytes(received))
            }
            lv_label_set_text(entry.speed_lbl, strings.clone_to_cstring(speed_str))
        }
    }
}

@(export)
download_finished :: proc "c" (c_uri: cstring, c_total: c.uint64_t) {
    context = runtime.default_context()
    uri := string(c_uri)
    total := u64(c_total)
    idx := download_find(uri)
    if idx < 0 do return
    entry := &download_entries[idx]
    if entry.state == .Failed do return  // cancelled/failed already handled
    entry.state = .Finished
    entry.progress = 1.0
    entry.total = total
    entry.received = total

    // Replace live row content with finished layout
    if popup_active == download_panel && download_panel != nil && entry.row != nil {
        lv_obj_clean(entry.row)
        lv_obj_set_flex_flow(entry.row, .LV_FLEX_FLOW_COLUMN)
        lv_obj_set_style_pad_row(entry.row, 2, 0)

        name_lbl := lv_label_create(entry.row)
        lv_label_set_text(name_lbl, strings.clone_to_cstring(entry.filename))
        lv_label_set_long_mode(name_lbl, .LV_LABEL_LONG_MODE_DOTS)
        lv_obj_set_width(name_lbl, lv_pct(100))

        status_lbl := lv_label_create(entry.row)
        lv_label_set_text(status_lbl, strings.clone_to_cstring(
            fmt.tprintf("Complete \xc2\xb7 %s", format_bytes(total))))
        lv_obj_set_style_text_color(status_lbl, lv_color_hex(theme_text_sec), 0)

        entry.arc = nil
        entry.pct_lbl = nil
        entry.speed_lbl = nil
    }
}

@(export)
download_failed :: proc "c" (c_uri: cstring, c_error: cstring) {
    context = runtime.default_context()
    uri := string(c_uri)
    error := string(c_error) if c_error != nil else "Unknown error"
    idx := download_find(uri)
    if idx < 0 do return
    entry := &download_entries[idx]
    entry.state = .Failed
    entry.error = strings.clone(error == "Download cancelled" ? "Cancelled" : error)

    // Replace live row content with failed layout
    if popup_active == download_panel && download_panel != nil && entry.row != nil {
        lv_obj_clean(entry.row)
        lv_obj_set_flex_flow(entry.row, .LV_FLEX_FLOW_COLUMN)
        lv_obj_set_style_pad_row(entry.row, 2, 0)

        name_lbl := lv_label_create(entry.row)
        lv_label_set_text(name_lbl, strings.clone_to_cstring(entry.filename))
        lv_label_set_long_mode(name_lbl, .LV_LABEL_LONG_MODE_DOTS)
        lv_obj_set_width(name_lbl, lv_pct(100))

        status_lbl := lv_label_create(entry.row)
        lv_label_set_text(status_lbl, strings.clone_to_cstring(
            fmt.tprintf("Failed: %s", entry.error)))
        lv_obj_set_style_text_color(status_lbl, lv_color_hex(theme_text_sec), 0)

        entry.arc = nil
        entry.pct_lbl = nil
        entry.speed_lbl = nil
    }
}

download_clear_widgets :: proc() {
    download_panel = nil
    for &entry in download_entries {
        entry.row = nil
        entry.arc = nil
        entry.pct_lbl = nil
        entry.speed_lbl = nil
    }
}

download_trigger :: proc() {
    if popup_is_active() {
        download_clear_widgets()
        popup_dismiss()
        return
    }
    download_popup_main()
}

download_popup_main :: proc() {
    download_clear_widgets()
    if popup_is_active() do popup_dismiss()

    panel := lv_obj_create(lv_layer_top())
    lv_obj_set_size(panel, 350, LV_SIZE_CONTENT)
    lv_obj_set_style_bg_color(panel, lv_color_hex(theme_bg_prim), 0)
    lv_obj_set_style_bg_opa(panel, u8(theme_bg_opacity), 0)
    lv_obj_set_style_text_color(panel, lv_color_hex(theme_text_pri), 0)
    lv_obj_set_style_radius(panel, 12, 0)
    lv_obj_set_style_pad_top(panel, theme_padding, 0)
    lv_obj_set_style_pad_bottom(panel, theme_padding, 0)
    lv_obj_set_style_pad_left(panel, theme_padding, 0)
    lv_obj_set_style_pad_right(panel, theme_padding, 0)
    lv_obj_set_style_pad_row(panel, theme_gap, 0)
    lv_obj_set_style_max_height(panel, 400, 0)
    lv_obj_set_flex_flow(panel, .LV_FLEX_FLOW_COLUMN)
    lv_obj_set_flex_align(panel, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)

    if len(download_entries) == 0 {
        lbl := lv_label_create(panel)
        lv_label_set_text(lbl, "No downloads")
    } else {
        // Show most recent first
        for i := len(download_entries) - 1; i >= 0; i -= 1 {
            entry := &download_entries[i]

            switch entry.state {
            case .Active:
                download_popup_active_row(panel, entry)
            case .Finished:
                download_popup_finished_row(panel, entry)
            case .Failed:
                download_popup_failed_row(panel, entry)
            }
        }
    }

    if download_popup_anchor != nil {
        popup_show(panel, download_popup_anchor)
        download_panel = panel
    }
}

download_popup_active_row :: proc(panel: ^lv_obj_t, entry: ^Download_Entry) {
    row := lv_obj_create(panel)
    lv_obj_set_width(row, lv_pct(100))
    lv_obj_set_height(row, LV_SIZE_CONTENT)
    lv_obj_set_flex_flow(row, .LV_FLEX_FLOW_ROW)
    lv_obj_set_flex_align(row, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
    lv_obj_set_style_pad_column(row, theme_gap, 0)
    lv_obj_remove_flag(row, .LV_OBJ_FLAG_SCROLLABLE)
    entry.row = row

    // Arc progress indicator
    arc := lv_arc_create(row)
    lv_obj_set_size(arc, 36, 36)
    lv_arc_set_range(arc, 0, 100)
    lv_arc_set_rotation(arc, 270)
    lv_arc_set_bg_angles(arc, 0, 360)
    lv_arc_set_value(arc, i32(entry.progress * 100))
    lv_obj_remove_flag(arc, .LV_OBJ_FLAG_CLICKABLE)
    entry.arc = arc

    // Percentage label centered in arc
    pct_lbl := lv_label_create(arc)
    lv_label_set_text(pct_lbl, strings.clone_to_cstring(
        fmt.tprintf("%d", int(entry.progress * 100))))
    lv_obj_center(pct_lbl)
    entry.pct_lbl = pct_lbl

    // Text column: filename + speed
    text_col := lv_obj_create(row)
    lv_obj_set_flex_grow(text_col, 1)
    lv_obj_set_height(text_col, LV_SIZE_CONTENT)
    lv_obj_set_flex_flow(text_col, .LV_FLEX_FLOW_COLUMN)
    lv_obj_set_style_pad_row(text_col, 2, 0)
    lv_obj_remove_flag(text_col, .LV_OBJ_FLAG_SCROLLABLE)

    name_lbl := lv_label_create(text_col)
    lv_label_set_text(name_lbl, strings.clone_to_cstring(entry.filename))
    lv_label_set_long_mode(name_lbl, .LV_LABEL_LONG_MODE_DOTS)
    lv_obj_set_width(name_lbl, lv_pct(100))

    // Speed + received
    speed_str: string
    if entry.elapsed > 0.5 {
        speed := u64(f64(entry.received) / entry.elapsed)
        speed_str = fmt.tprintf("%s/s \xc2\xb7 %s", format_bytes(speed), format_bytes(entry.received))
    } else {
        speed_str = fmt.tprintf("%s", format_bytes(entry.received))
    }
    speed_lbl := lv_label_create(text_col)
    lv_label_set_text(speed_lbl, strings.clone_to_cstring(speed_str))
    lv_obj_set_style_text_color(speed_lbl, lv_color_hex(theme_text_sec), 0)
    entry.speed_lbl = speed_lbl

    // Cancel button
    cancel_btn := lv_button_create(row)
    lv_obj_add_event_cb(cancel_btn, on_download_cancel, .LV_EVENT_CLICKED,
        rawptr(strings.clone_to_cstring(entry.uri)))
    cancel_lbl := lv_label_create(cancel_btn)
    lv_label_set_text(cancel_lbl, icons[.close])
    lv_obj_set_style_text_font(cancel_lbl, icon_font, 0)
}

download_popup_finished_row :: proc(panel: ^lv_obj_t, entry: ^Download_Entry) {
    row := lv_obj_create(panel)
    lv_obj_set_width(row, lv_pct(100))
    lv_obj_set_height(row, LV_SIZE_CONTENT)
    lv_obj_set_flex_flow(row, .LV_FLEX_FLOW_COLUMN)
    lv_obj_set_style_pad_row(row, 2, 0)
    lv_obj_remove_flag(row, .LV_OBJ_FLAG_SCROLLABLE)

    name_lbl := lv_label_create(row)
    lv_label_set_text(name_lbl, strings.clone_to_cstring(entry.filename))
    lv_label_set_long_mode(name_lbl, .LV_LABEL_LONG_MODE_DOTS)
    lv_obj_set_width(name_lbl, lv_pct(100))

    status_lbl := lv_label_create(row)
    lv_label_set_text(status_lbl, strings.clone_to_cstring(
        fmt.tprintf("Complete \xc2\xb7 %s", format_bytes(entry.total))))
    lv_obj_set_style_text_color(status_lbl, lv_color_hex(theme_text_sec), 0)
}

download_popup_failed_row :: proc(panel: ^lv_obj_t, entry: ^Download_Entry) {
    row := lv_obj_create(panel)
    lv_obj_set_width(row, lv_pct(100))
    lv_obj_set_height(row, LV_SIZE_CONTENT)
    lv_obj_set_flex_flow(row, .LV_FLEX_FLOW_COLUMN)
    lv_obj_set_style_pad_row(row, 2, 0)
    lv_obj_remove_flag(row, .LV_OBJ_FLAG_SCROLLABLE)

    name_lbl := lv_label_create(row)
    lv_label_set_text(name_lbl, strings.clone_to_cstring(entry.filename))
    lv_label_set_long_mode(name_lbl, .LV_LABEL_LONG_MODE_DOTS)
    lv_obj_set_width(name_lbl, lv_pct(100))

    status_lbl := lv_label_create(row)
    lv_label_set_text(status_lbl, strings.clone_to_cstring(
        fmt.tprintf("Failed: %s", entry.error)))
    lv_obj_set_style_text_color(status_lbl, lv_color_hex(theme_text_sec), 0)
}

on_download_cancel :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    uri := cstring(lv_event_get_user_data(e))
    if uri != nil {
        engine_download_cancel(uri)
    }
}

format_bytes :: proc(bytes: u64) -> string {
    if bytes < 1024 {
        return fmt.tprintf("%d B", bytes)
    } else if bytes < 1024 * 1024 {
        return fmt.tprintf("%.1f KB", f64(bytes) / 1024)
    } else if bytes < 1024 * 1024 * 1024 {
        return fmt.tprintf("%.1f MB", f64(bytes) / (1024 * 1024))
    } else {
        return fmt.tprintf("%.1f GB", f64(bytes) / (1024 * 1024 * 1024))
    }
}

// Widget factory
widget_download :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_download_widget_click, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[.download])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
    download_popup_anchor = btn
}

on_download_widget_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    download_trigger()
}
