package axium

import "base:runtime"
import "core:c"
import "core:strings"

// Tab state — all tab management logic lives here
active_tab: int = -1
tab_count: int = 0
tab_bar_container: ^lv_obj_t

// --- Tab operations ---

tab_new :: proc() {
    idx := int(engine_create_view(content_area.w, content_area.h))
    if idx < 0 do return
    tab_count = int(engine_view_count())
    tab_switch(idx)
}

tab_close :: proc(idx: int) {
    if idx < 0 || idx >= tab_count do return

    // Closing last tab — exit browser
    if tab_count == 1 {
        closed = true
        return
    }

    engine_destroy_view(c.int(idx))
    tab_count = int(engine_view_count())

    // Pick neighbor tab
    new_active: int
    if idx >= tab_count {
        new_active = tab_count - 1
    } else {
        new_active = idx
    }
    tab_switch(new_active)
}

tab_switch :: proc(idx: int) {
    if idx < 0 || idx >= tab_count do return
    active_tab = idx
    engine_set_active_view(c.int(idx))  // fires URI + title callbacks
    tab_bar_rebuild()
}

tab_next :: proc() {
    if tab_count <= 1 do return
    tab_switch((active_tab + 1) %% tab_count)
}

tab_prev :: proc() {
    if tab_count <= 1 do return
    tab_switch((active_tab - 1 + tab_count) %% tab_count)
}

// --- Tab bar widget factory (registered as "tabs") ---

widget_tabs :: proc(parent: ^lv_obj_t) {
    container := lv_obj_create(parent)
    lv_obj_set_height(container, LV_SIZE_CONTENT)
    lv_obj_set_flex_grow(container, 1)
    lv_obj_set_flex_flow(container, .LV_FLEX_FLOW_ROW)
    lv_obj_set_flex_align(container, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
    lv_obj_set_style_pad_top(container, 0, 0)
    lv_obj_set_style_pad_bottom(container, 0, 0)
    lv_obj_set_style_pad_left(container, 0, 0)
    lv_obj_set_style_pad_right(container, 0, 0)
    lv_obj_set_style_pad_column(container, 2, 0)
    lv_obj_set_scrollbar_mode(container, .LV_SCROLLBAR_MODE_OFF)
    lv_obj_set_style_bg_opa(container, LV_OPA_TRANSP, 0)
    lv_obj_set_style_border_width(container, 0, 0)
    tab_bar_container = container
    tab_bar_rebuild()
}

// --- Rebuild tab bar LVGL objects ---

tab_bar_rebuild :: proc() {
    if tab_bar_container == nil do return
    lv_obj_clean(tab_bar_container)

    count := int(engine_view_count())
    for i in 0..<count {
        // Tab button (row flex: title + close, single line)
        tab_btn := lv_button_create(tab_bar_container)
        lv_obj_set_width(tab_btn, 180)
        lv_obj_set_height(tab_btn, LV_SIZE_CONTENT)
        lv_obj_set_flex_flow(tab_btn, .LV_FLEX_FLOW_ROW)
        lv_obj_set_flex_align(tab_btn, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
        lv_obj_set_style_pad_top(tab_btn, 4, 0)
        lv_obj_set_style_pad_bottom(tab_btn, 4, 0)
        lv_obj_set_style_pad_left(tab_btn, 8, 0)
        lv_obj_set_style_pad_right(tab_btn, 4, 0)
        lv_obj_set_style_pad_column(tab_btn, 4, 0)
        lv_obj_set_user_data(tab_btn, rawptr(uintptr(i)))
        lv_obj_add_event_cb(tab_btn, on_tab_click, .LV_EVENT_CLICKED, rawptr(uintptr(i)))

        // Active tab highlight
        if i == active_tab {
            lv_obj_set_style_bg_color(tab_btn, lv_color_hex(theme_accent), 0)
            lv_obj_set_style_bg_opa(tab_btn, LV_OPA_COVER, 0)
        }

        // Title label — fixed size so DOTS truncation works on a single line
        title_label := lv_label_create(tab_btn)
        lv_obj_set_size(title_label, 130, font_size_base)
        lv_label_set_long_mode(title_label, .LV_LABEL_LONG_MODE_DOTS)

        title: cstring
        engine_view_get_title(c.int(i), &title)
        if title != nil && title != "" {
            lv_label_set_text(title_label, title)
        } else {
            uri: cstring
            engine_view_get_uri(c.int(i), &uri)
            if uri != nil && uri != "" {
                lv_label_set_text(title_label, uri)
            } else {
                lv_label_set_text(title_label, "New Tab")
            }
        }

        // Close button
        close_btn := lv_button_create(tab_btn)
        lv_obj_set_style_pad_top(close_btn, 2, 0)
        lv_obj_set_style_pad_bottom(close_btn, 2, 0)
        lv_obj_set_style_pad_left(close_btn, 4, 0)
        lv_obj_set_style_pad_right(close_btn, 4, 0)
        lv_obj_set_style_bg_opa(close_btn, LV_OPA_TRANSP, 0)
        lv_obj_add_event_cb(close_btn, on_tab_close_click, .LV_EVENT_CLICKED, rawptr(uintptr(i)))
        close_lbl := lv_label_create(close_btn)
        lv_label_set_text(close_lbl, LV_SYMBOL_CLOSE)
        if icon_font != nil { lv_obj_set_style_text_font(close_lbl, icon_font, 0) }
        lv_obj_center(close_lbl)
    }

    // New tab button
    new_btn := lv_button_create(tab_bar_container)
    lv_obj_set_style_pad_top(new_btn, 4, 0)
    lv_obj_set_style_pad_bottom(new_btn, 4, 0)
    lv_obj_set_style_pad_left(new_btn, 8, 0)
    lv_obj_set_style_pad_right(new_btn, 8, 0)
    lv_obj_add_event_cb(new_btn, on_new_tab_click, .LV_EVENT_CLICKED, nil)
    new_lbl := lv_label_create(new_btn)
    lv_label_set_text(new_lbl, LV_SYMBOL_PLUS)
    if icon_font != nil { lv_obj_set_style_text_font(new_lbl, icon_font, 0) }
    lv_obj_center(new_lbl)
}

// --- Event callbacks ---

on_tab_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    idx := int(uintptr(lv_event_get_user_data(e)))
    tab_switch(idx)
}

on_tab_close_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    lv_event_stop_bubbling(e)
    idx := int(uintptr(lv_event_get_user_data(e)))
    tab_close(idx)
}

on_new_tab_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    tab_new()
}
