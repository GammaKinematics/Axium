package axium

import "core:c"
import "core:time"
import "display"

// Input state tracked via generated Bind bit_set
held: Bind

// LVGL input state — read by mouse_read_cb / keyboard_read_cb
input_mouse_x, input_mouse_y: i32
input_mouse_pressed: bool
input_last_key: u32
input_key_pressed: bool

// Focus tracking: true = web content has focus, false = chrome (URL bar etc.)
content_has_focus: bool = true

// Content area bounds (set by main.odin after layout)
content_x, content_y, content_w, content_h: int

// URL bar widget reference (set by generated UI code)
url_input: ^lv_obj_t

// Returns true if point (px, py) is inside the content area
in_content_area :: proc(px, py: int) -> bool {
    return px >= content_x && px < content_x + content_w &&
           py >= content_y && py < content_y + content_h
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
    for ev in display.display_poll() {
        switch e in ev {
        case display.Key:
            // Track held keys for keybinding system
            if k, ok := to_keyboard(u32(e.code)).?; ok {
                if e.action == .Press {
                    held += {k}
                    for bind, cmd in bindings {
                        if held >= bind {
                            execute_command(cmd)
                            return
                        }
                    }
                } else {
                    held -= {k}
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

        case display.Mouse:
            // Track held buttons for bindings
            if k, ok := to_mouse(u32(e.button)).?; ok {
                if e.pressed {
                    held += {k}
                } else {
                    held -= {k}
                }
            }

            px, py := int(e.x), int(e.y)

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
                        f64(px - content_x), f64(py - content_y),
                        dx, dy,
                    )
                }
            } else if in_content_area(px, py) {
                // Click in content area → focus content, forward to WebKit
                content_has_focus = true
                engine_send_mouse_button(
                    c.uint32_t(e.button), e.pressed,
                    f64(px - content_x), f64(py - content_y),
                )
            } else {
                // Click in chrome → focus chrome, update LVGL state
                content_has_focus = false
                input_mouse_x = i32(px)
                input_mouse_y = i32(py)
                input_mouse_pressed = e.pressed
            }

        case display.Mouse_Move:
            px, py := int(e.x), int(e.y)
            if content_has_focus && in_content_area(px, py) {
                engine_send_mouse_move(
                    f64(px - content_x), f64(py - content_y),
                )
            } else {
                // Update LVGL pointer position
                input_mouse_x = i32(px)
                input_mouse_y = i32(py)
            }

        case display.Focus:
            engine_send_focus(e.focused)

        case display.Resize:
            pending_resize = e
            last_resize_time = time.tick_now()

        case display.Close:
            // Handled by display_should_close()
        }
    }
}

// Get absolute screen position of content_area via lv_obj_get_coords
query_content_bounds :: proc() {
    coords: lv_area_t
    lv_obj_get_coords(content_area, &coords)
    content_x = int(coords.x1)
    content_y = int(coords.y1)
    content_w = int(coords.x2 - coords.x1 + 1)
    content_h = int(coords.y2 - coords.y1 + 1)
}

handle_resize :: proc(lv_disp: ^lv_display_t) {
    fb, fb_w, fb_h := display.display_framebuffer()
    if fb == nil do return

    // Update LVGL display
    lv_display_set_resolution(lv_disp, i32(fb_w), i32(fb_h))
    lv_display_set_buffers(
        lv_disp,
        raw_data(fb), nil,
        u32(len(fb) * 4),
        .LV_DISPLAY_RENDER_MODE_DIRECT,
    )

    // Re-layout and query content area
    lv_obj_update_layout(lv_screen_active())
    query_content_bounds()

    // Update WebKit view size
    engine_resize(c.int(content_w), c.int(content_h))

    // Update frame target
    engine_set_frame_target(
        ([^]u8)(raw_data(fb)),
        c.int(fb_w * 4),
        c.int(content_x), c.int(content_y),
        c.int(content_w), c.int(content_h),
    )
}

