package main

import "lvgl"

build_ui :: proc(screen: ^lvgl.lv_obj_t) {
    if screen == nil do return

    // Dark background
    lvgl.lv_obj_set_style_bg_color(screen, lvgl.lv_color_hex(0x1a1a2e), 0)

    // Centered container
    container := lvgl.lv_obj_create(screen)
    if container != nil {
        lvgl.lv_obj_set_size(container, 400, 200)
        lvgl.lv_obj_align(container, .LV_ALIGN_CENTER, 0, 0)
        lvgl.lv_obj_set_style_bg_color(container, lvgl.lv_color_hex(0x16213e), 0)
        lvgl.lv_obj_set_style_radius(container, 20, 0)
        lvgl.lv_obj_set_style_border_width(container, 2, 0)
        lvgl.lv_obj_set_style_border_color(container, lvgl.lv_color_hex(0x0f3460), 0)

        // Title label
        label := lvgl.lv_label_create(container)
        if label != nil {
            lvgl.lv_label_set_text(label, "Axium Browser")
            lvgl.lv_obj_set_style_text_color(label, lvgl.lv_color_hex(0xe94560), 0)
            lvgl.lv_obj_align(label, .LV_ALIGN_CENTER, 0, 0)
        }
    }
}
