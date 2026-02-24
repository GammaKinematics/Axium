package axium

import "base:runtime"

url_input: ^lv_obj_t

// --- Widget factories ---

widget_back :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_navigate_back, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, LV_SYMBOL_LEFT)
    if icon_font != nil { lv_obj_set_style_text_font(lbl, icon_font, 0) }
    lv_obj_center(lbl)
}

on_navigate_back :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    execute_command("back")
}

widget_forward :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_navigate_forward, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, LV_SYMBOL_RIGHT)
    if icon_font != nil { lv_obj_set_style_text_font(lbl, icon_font, 0) }
    lv_obj_center(lbl)
}

on_navigate_forward :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    execute_command("forward")
}

widget_reload :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_reload_page, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, LV_SYMBOL_REFRESH)
    if icon_font != nil { lv_obj_set_style_text_font(lbl, icon_font, 0) }
    lv_obj_center(lbl)
}

on_reload_page :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    execute_command("reload")
}

widget_url :: proc(parent: ^lv_obj_t) {
    url_bar := lv_textarea_create(parent)
    lv_obj_set_flex_grow(url_bar, 1)
    lv_textarea_set_one_line(url_bar, true)
    lv_textarea_set_placeholder_text(url_bar, "Enter URL...")
    lv_obj_add_event_cb(url_bar, on_url_submit, .LV_EVENT_READY, nil)
    lv_obj_add_event_cb(url_bar, on_url_focus, .LV_EVENT_FOCUSED, nil)
    lv_group_add_obj(keyboard_group, url_bar)
    url_input = url_bar
}

on_url_submit :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    text := lv_textarea_get_text(url_input)
    if text != nil {
        engine_load_uri(text)
        content_has_focus = true
    }
}

on_url_focus :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    content_has_focus = false
}

widget_copy_url :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_copy_url, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, LV_SYMBOL_COPY)
    if icon_font != nil { lv_obj_set_style_text_font(lbl, icon_font, 0) }
    lv_obj_center(lbl)
}

on_copy_url :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    execute_command("copy")
}

widget_menu :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_open_menu, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, LV_SYMBOL_BARS)
    if icon_font != nil { lv_obj_set_style_text_font(lbl, icon_font, 0) }
    lv_obj_center(lbl)
}

on_open_menu :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    // TODO: implement menu panel
}

// --- Registration ---

widgets_init :: proc() {
    edge_register_widget("back", widget_back)
    edge_register_widget("forward", widget_forward)
    edge_register_widget("reload", widget_reload)
    edge_register_widget("url", widget_url)
    edge_register_widget("copy", widget_copy_url)
    edge_register_widget("menu", widget_menu)
    edge_register_widget("tabs", widget_tabs)
}
