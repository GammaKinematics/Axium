package axium

import "base:runtime"

// FontAwesome icons
ICON_BAN     :: "\xef\x81\x9e"  // U+F05E
ICON_SHUFFLE :: "\xef\x81\xb4"  // U+F074
ICON_KEY     :: "\xef\x82\x84"  // U+F084
ICON_SAVE    :: "\xef\x83\x87"  // U+F0C7

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
    if popup_is_active() { popup_dismiss(); return }

    anchor := (^lv_obj_t)(lv_event_get_target(e))
    panel := lv_obj_create(lv_layer_top())
    lv_obj_set_size(panel, 200, 100)
    lv_obj_set_style_bg_color(panel, lv_color_hex(theme_bg_sec), 0)
    lv_obj_set_style_bg_opa(panel, LV_OPA_COVER, 0)
    lv_obj_set_style_radius(panel, theme_radius, 0)
    lv_obj_remove_flag(panel, .LV_OBJ_FLAG_SCROLLABLE)
    lbl := lv_label_create(panel)
    lv_label_set_text(lbl, "Menu placeholder")
    lv_obj_center(lbl)

    popup_show(panel, anchor)
}

widget_keepass :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_keepass_click, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, ICON_KEY)
    if icon_font != nil { lv_obj_set_style_text_font(lbl, icon_font, 0) }
    lv_obj_center(lbl)
    keepass_popup_anchor = btn
}

on_keepass_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    keepass_trigger()
}

// --- Registration ---

widgets_init :: proc() {
    edge_register_widget("back", widget_back)
    edge_register_widget("forward", widget_forward)
    edge_register_widget("reload", widget_reload)
    edge_register_widget("url", widget_url)
    edge_register_widget("copy", widget_copy_url)
    edge_register_widget("keepass", widget_keepass)
    edge_register_widget("menu", widget_menu)
    edge_register_widget("tabs", widget_tabs)
}
