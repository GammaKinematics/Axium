package axium

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

Favorite_Node :: struct {
    name:     string,
    url:      string,                // "" = folder
    children: [dynamic]Favorite_Node,
    parent:   ^Favorite_Node,
}

favorite_root: Favorite_Node
favorite_current: ^Favorite_Node   // level being displayed (nil = root)
favorite_popup_anchor: ^lv_obj_t
favorite_folder_input: ^lv_obj_t
favorite_icon_label: ^lv_obj_t

// --- Parsing ---

favorite_parse_node :: proc(obj: json.Object, parent: ^Favorite_Node) {
    if obj == nil do return
    for key, val in obj {
        node: Favorite_Node
        node.name = strings.clone(key)
        node.parent = parent
        switch v in val {
        case json.String:
            node.url = strings.clone(v)
        case json.Object:
            favorite_parse_node(v, &node)
        case json.Null, json.Integer, json.Float, json.Boolean, json.Array:
            continue
        }
        append(&parent.children, node)
    }
}

favorite_load :: proc() {
    path := xdg_path(.Config, "favorites.sjson")
    file, ok := os.read_entire_file(path)
    if !ok do return
    defer delete(file)

    cfg, err := json.parse(file, .SJSON)
    if err != .None do return
    defer json.destroy_value(cfg)

    root, rok := cfg.(json.Object)
    if !rok do return

    favorite_parse_node(root, &favorite_root)
}

// --- Saving ---

favorite_write_node :: proc(b: ^strings.Builder, node: ^Favorite_Node, depth: int) {
    indent := strings.repeat("    ", depth)
    defer delete(indent)

    for &child in node.children {
        if child.url != "" {
            fmt.sbprintf(b, "%s\"%s\": \"%s\"\n", indent, child.name, child.url)
        } else {
            fmt.sbprintf(b, "%s\"%s\": {{\n", indent, child.name)
            favorite_write_node(b, &child, depth + 1)
            fmt.sbprintf(b, "%s}}\n", indent)
        }
    }
}

favorite_save :: proc() {
    path := xdg_path(.Config, "favorites.sjson")
    dir := path[:strings.last_index_byte(path, '/')]
    os.make_directory(dir)

    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    strings.write_string(&b, "{\n")
    favorite_write_node(&b, &favorite_root, 1)
    strings.write_string(&b, "}\n")

    os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

// --- Operations ---

favorite_get_current :: proc() -> ^Favorite_Node {
    if favorite_current == nil do return &favorite_root
    return favorite_current
}

favorite_add_bookmark :: proc(parent: ^Favorite_Node, name, url: string) {
    node: Favorite_Node
    node.name = strings.clone(name)
    node.url = strings.clone(url)
    node.parent = parent
    append(&parent.children, node)
    favorite_save()
    favorite_icon_update()
}

favorite_add_folder :: proc(parent: ^Favorite_Node, name: string) {
    node: Favorite_Node
    node.name = strings.clone(name)
    node.parent = parent
    append(&parent.children, node)
    favorite_save()
}

favorite_remove :: proc(parent: ^Favorite_Node, idx: int) {
    if idx < 0 || idx >= len(parent.children) do return
    favorite_free_node(&parent.children[idx])
    ordered_remove(&parent.children, idx)
    favorite_save()
    favorite_icon_update()
}

favorite_free_node :: proc(node: ^Favorite_Node) {
    for &child in node.children {
        favorite_free_node(&child)
    }
    delete(node.children)
    delete(node.name)
    delete(node.url)
}

// --- Trigger / Popup ---

favorite_trigger :: proc() {
    if popup_is_active() {
        popup_dismiss()
        return
    }
    favorite_current = nil
    favorite_popup_main()
}

favorite_popup_main :: proc() {
    if popup_is_active() do popup_dismiss()

    cur := favorite_get_current()

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
    lv_obj_set_style_max_height(panel, 400, 0)
    lv_obj_set_flex_flow(panel, .LV_FLEX_FLOW_COLUMN)
    lv_obj_set_flex_align(panel, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)

    // Back button (if not root)
    if cur != &favorite_root {
        back_btn := lv_button_create(panel)
        lv_obj_set_width(back_btn, lv_pct(100))
        lv_obj_add_event_cb(back_btn, on_favorite_back, .LV_EVENT_CLICKED, nil)
        back_lbl := lv_label_create(back_btn)
        lv_label_set_text(back_lbl, icons[.back])
        lv_obj_set_style_text_font(back_lbl, icon_font, 0)
    }

    // Entry list
    if len(cur.children) > 0 {
        for &child, i in cur.children {
            row := lv_obj_create(panel)
            lv_obj_set_width(row, lv_pct(100))
            lv_obj_set_height(row, LV_SIZE_CONTENT)
            lv_obj_set_flex_flow(row, .LV_FLEX_FLOW_ROW)
            lv_obj_set_flex_align(row, .LV_FLEX_ALIGN_SPACE_BETWEEN, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
            lv_obj_remove_flag(row, .LV_OBJ_FLAG_SCROLLABLE)

            // Main button (navigate or enter folder)
            btn := lv_button_create(row)
            lv_obj_set_flex_grow(btn, 1)
            lbl := lv_label_create(btn)
            lv_label_set_long_mode(lbl, .LV_LABEL_LONG_MODE_DOTS)
            lv_obj_set_width(lbl, lv_pct(100))

            if child.url != "" {
                // Bookmark
                lv_label_set_text(lbl, strings.clone_to_cstring(child.name))
                lv_obj_add_event_cb(btn, on_favorite_navigate, .LV_EVENT_CLICKED, &child)
            } else {
                // Folder
                lv_label_set_text(lbl, strings.clone_to_cstring(
                    strings.concatenate({child.name, " >"})))
                lv_obj_add_event_cb(btn, on_favorite_enter_folder, .LV_EVENT_CLICKED, &child)
            }

            // Delete button
            del_btn := lv_button_create(row)
            lv_obj_add_event_cb(del_btn, on_favorite_delete, .LV_EVENT_CLICKED, rawptr(uintptr(i)))
            del_lbl := lv_label_create(del_btn)
            lv_label_set_text(del_lbl, icons[.close])
            lv_obj_set_style_text_font(del_lbl, icon_font, 0)
        }
    } else {
        lbl := lv_label_create(panel)
        lv_label_set_text(lbl, "Empty")
    }

    // Add current page button
    add_btn := lv_button_create(panel)
    lv_obj_set_width(add_btn, lv_pct(100))
    lv_obj_add_event_cb(add_btn, on_favorite_add, .LV_EVENT_CLICKED, nil)
    add_lbl := lv_label_create(add_btn)
    lv_label_set_text(add_lbl, "Add current page")

    // New folder row
    folder_row := lv_obj_create(panel)
    lv_obj_set_width(folder_row, lv_pct(100))
    lv_obj_set_height(folder_row, LV_SIZE_CONTENT)
    lv_obj_set_flex_flow(folder_row, .LV_FLEX_FLOW_ROW)
    lv_obj_set_flex_align(folder_row, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
    lv_obj_set_style_pad_column(folder_row, theme_gap, 0)
    lv_obj_remove_flag(folder_row, .LV_OBJ_FLAG_SCROLLABLE)

    folder_input := lv_textarea_create(folder_row)
    lv_obj_set_flex_grow(folder_input, 1)
    lv_textarea_set_one_line(folder_input, true)
    lv_textarea_set_placeholder_text(folder_input, "Folder name")
    lv_group_add_obj(keyboard_group, folder_input)
    favorite_folder_input = folder_input

    folder_btn := lv_button_create(folder_row)
    lv_obj_add_event_cb(folder_btn, on_favorite_new_folder, .LV_EVENT_CLICKED, nil)
    folder_lbl := lv_label_create(folder_btn)
    lv_label_set_text(folder_lbl, icons[.add])
    lv_obj_set_style_text_font(folder_lbl, icon_font, 0)

    if favorite_popup_anchor != nil {
        popup_show(panel, favorite_popup_anchor)
    }
}

// --- Callbacks ---

on_favorite_back :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    cur := favorite_get_current()
    favorite_current = cur.parent
    favorite_popup_main()
}

on_favorite_navigate :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    node := (^Favorite_Node)(lv_event_get_user_data(e))
    if node != nil && node.url != "" {
        engine_view_go_to(tab_entries[active_tab].view, strings.clone_to_cstring(node.url))
        popup_dismiss()
        content_has_focus = true
    }
}

on_favorite_enter_folder :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    node := (^Favorite_Node)(lv_event_get_user_data(e))
    if node != nil {
        favorite_current = node
        favorite_popup_main()
    }
}

on_favorite_delete :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    idx := int(uintptr(lv_event_get_user_data(e)))
    cur := favorite_get_current()
    favorite_remove(cur, idx)
    favorite_popup_main()
}

on_favorite_add :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    if active_tab < 0 || active_tab >= tab_count do return
    tab := &tab_entries[active_tab]
    if len(tab.uri) == 0 do return

    name := tab.title if len(tab.title) > 0 else tab.uri

    cur := favorite_get_current()
    favorite_add_bookmark(cur, name, tab.uri)
    favorite_popup_main()
}

on_favorite_new_folder :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    if favorite_folder_input == nil do return
    text := lv_textarea_get_text(favorite_folder_input)
    if text == nil do return
    name := string(text)
    if name == "" do return

    cur := favorite_get_current()
    favorite_add_folder(cur, name)
    favorite_popup_main()
}

// --- Icon accent ---

favorite_contains_url :: proc(node: ^Favorite_Node, url: string) -> bool {
    for &child in node.children {
        if child.url != "" {
            if child.url == url do return true
        } else {
            if favorite_contains_url(&child, url) do return true
        }
    }
    return false
}

favorite_icon_update :: proc() {
    if favorite_icon_label == nil do return
    tab_uri := tab_entries[active_tab].uri if active_tab >= 0 && active_tab < tab_count else ""
    if len(tab_uri) > 0 && favorite_contains_url(&favorite_root, tab_uri) {
        lv_obj_set_style_text_color(favorite_icon_label, lv_color_hex(theme_accent), 0)
    } else {
        lv_obj_set_style_text_color(favorite_icon_label, lv_color_hex(theme_text_pri), 0)
    }
}

favorite_on_navigation :: proc(uri: string) {
    if favorite_icon_label == nil do return
    if favorite_contains_url(&favorite_root, uri) {
        lv_obj_set_style_text_color(favorite_icon_label, lv_color_hex(theme_accent), 0)
    } else {
        lv_obj_set_style_text_color(favorite_icon_label, lv_color_hex(theme_text_pri), 0)
    }
}

// --- Widget ---

widget_favorite :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_favorite_widget_click, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[.favorite])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
    favorite_popup_anchor = btn
    favorite_icon_label = lbl
}

on_favorite_widget_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    favorite_trigger()
}
