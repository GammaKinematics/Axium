package axium

import "core:c"
import "core:time"

// Input state tracked via generated Bind bit_set
held: Bind

// LVGL input state — read by mouse_read_cb / keyboard_read_cb
input_mouse_x, input_mouse_y: i32
input_mouse_pressed: bool
input_last_key: u32
input_key_pressed: bool

// Focus tracking: true = web content has focus, false = chrome (URL bar etc.)
content_has_focus: bool = true

// Content area bounds (set by edge_init, updated by edge_set_visible / resize)
content_area: Content_Bounds  // WebKit rendering bounds (expanded for overlay)
input_area:   Content_Bounds  // Raw content widget bounds (for input routing)

// Raw mouse screen position for hover edge detection
mouse_screen_x, mouse_screen_y: i32


// Returns true if point (px, py) is inside the input area
in_content_area :: proc(px, py: i32) -> bool {
    return px >= input_area.x && px < input_area.x + input_area.w &&
           py >= input_area.y && py < input_area.y + input_area.h
}

// LVGL mouse input device callback
mouse_read_cb :: proc "c" (indev: ^lv_indev_t, data: ^lv_indev_data_t) {
    data.point.x = input_mouse_x
    data.point.y = input_mouse_y
    data.state = .LV_INDEV_STATE_PRESSED if input_mouse_pressed else .LV_INDEV_STATE_RELEASED
}

// LVGL keyboard input device callback
keyboard_read_cb :: proc "c" (indev: ^lv_indev_t, data: ^lv_indev_data_t) {
    data.key = input_last_key
    data.state = .LV_INDEV_STATE_PRESSED if input_key_pressed else .LV_INDEV_STATE_RELEASED
}

// Poll display events and route between LVGL and WebKit
poll_events :: proc() {
    for ev in display_poll() {
        switch e in ev {
        case Key:
            // Track held keys for keybinding system
            if k, ok := to_keyboard(u32(e.code)).?; ok {
                if e.action == .Press {
                    held += {k}
                    if cmd, ok := match_binding(held).?; ok {
                        execute_command(cmd)
                        return
                    }
                } else {
                    held -= {k}
                    for bind, cmd in bindings {
                        if held >= bind do continue
                        execute_command(cmd, false)
                    }
                }
            }

            if content_has_focus {
                engine_send_key(c.uint32_t(e.code), e.action == .Press)
            } else if e.action == .Release {
                input_key_pressed = false
            } else {
                // Use text rune for printable + control chars (Enter, Backspace, etc.)
                // Only arrows need keysym conversion
                key: u32
                if e.text == '\r' {
                    key = 10  // LV_KEY_ENTER
                } else if e.text != 0 {
                    key = u32(e.text)
                } else {
                    switch e.code {
                    case 0xff51: key = 20  // LV_KEY_LEFT
                    case 0xff52: key = 17  // LV_KEY_UP
                    case 0xff53: key = 19  // LV_KEY_RIGHT
                    case 0xff54: key = 18  // LV_KEY_DOWN
                    }
                }
                if key != 0 {
                    input_last_key = key
                    input_key_pressed = true
                }
            }

        case Mouse:
            // Always track raw screen position for hover edge detection
            mouse_screen_x = i32(e.x)
            mouse_screen_y = i32(e.y)

            // Track held buttons for bindings
            if k, ok := to_mouse(u32(e.button)).?; ok {
                if e.pressed {
                    held += {k}
                } else {
                    held -= {k}
                }
            }

            px, py := i32(e.x), i32(e.y)

            // Popup intercept: clicks go to popup or dismiss it
            if e.button >= 1 && e.button <= 3 && popup_is_active() {
                hit := popup_hit_test(px, py)
                if hit {
                    content_has_focus = false
                    input_mouse_x = px
                    input_mouse_y = py
                    input_mouse_pressed = e.pressed
                } else if e.pressed {
                    popup_dismiss()
                }
                continue
            }

            // Scroll events (buttons 4-7) always go to WebKit if in content
            if e.button >= 4 && e.button <= 7 {
                if e.pressed && in_content_area(px, py) {
                    dx, dy: f64
                    switch e.button {
                    case 4: dy =  1
                    case 5: dy = -1
                    case 6: dx =  1
                    case 7: dx = -1
                    }
                    engine_send_scroll(
                        f64(px - content_area.x), f64(py - content_area.y),
                        dx, dy,
                    )
                }
            } else if in_content_area(px, py) {
                // Click in content area → focus content, forward to WebKit
                content_has_focus = true
                engine_send_mouse_button(
                    c.uint32_t(e.button), e.pressed,
                    f64(px - content_area.x), f64(py - content_area.y),
                )
            } else {
                // Click in chrome → focus chrome, update LVGL state
                content_has_focus = false
                input_mouse_x = px
                input_mouse_y = py
                input_mouse_pressed = e.pressed
            }

        case Mouse_Move:
            // Always track raw screen position for hover edge detection
            mouse_screen_x = i32(e.x)
            mouse_screen_y = i32(e.y)

            px, py := i32(e.x), i32(e.y)
            if popup_is_active() {
                // When popup is active, LVGL needs pointer tracking for button hit detection
                input_mouse_x = px
                input_mouse_y = py
            } else if content_has_focus && in_content_area(px, py) {
                engine_send_mouse_move(
                    f64(px - content_area.x), f64(py - content_area.y),
                )
            } else {
                // Update LVGL pointer position
                input_mouse_x = px
                input_mouse_y = py
            }

        case Focus:
            engine_send_focus(e.focused)

        case Resize:
            pending_resize = e
            last_resize_time = time.tick_now()

        case Close:
            // Handled by display_should_close()
        }
    }
}


handle_resize :: proc(lv_disp: ^lv_display_t) {
    w, h := display_size()

    lv_display_set_resolution(lv_disp, i32(w), i32(h))
    if gpu_active {
        tex := lv_display_get_driver_data(lv_disp)
        lv_opengles_texture_reshape(tex, lv_disp, i32(w), i32(h))
    } else {
        fb, fb_w, _ := display_get_framebuffer()
        if fb == nil do return
        lv_display_set_buffers(lv_disp, raw_data(fb), nil, u32(len(fb) * 4), .LV_DISPLAY_RENDER_MODE_DIRECT)
    }

    // Re-layout and query content area
    lv_obj_update_layout(lv_layer_top())
    content_area = edge_query_bounds()
    input_area = edge_content_widget_bounds()
    lv_refr_set_noclear_area(content_area.x, content_area.y,
        content_area.x + content_area.w - 1, content_area.y + content_area.h - 1)

    // Update WebKit view size and frame target
    if gpu_active {
        engine_resize(content_area.w, content_area.h,
            content_area.x, content_area.y, nil, 0)
    } else {
        fb, fb_w, _ := display_get_framebuffer()
        engine_resize(content_area.w, content_area.h,
            content_area.x, content_area.y,
            ([^]u8)(raw_data(fb)), c.int(fb_w * 4))
    }
}

// Relayout helper — updates WebKit engine bounds after edge show/hide
update_engine_bounds :: proc() {
    if gpu_active {
        engine_resize(content_area.w, content_area.h,
            content_area.x, content_area.y, nil, 0)
    } else {
        fb, fb_w, _ := display_get_framebuffer()
        engine_resize(content_area.w, content_area.h,
            content_area.x, content_area.y,
            ([^]u8)(raw_data(fb)), c.int(fb_w * 4))
    }
}
