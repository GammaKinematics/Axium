package axium

import "core:c"
import "core:fmt"
import "core:sys/posix"
import "core:time"
import "display"

WIDTH  :: 1280
HEIGHT :: 720

// Display state
lv_disp: ^lv_display_t
pending_resize: Maybe(display.Resize)
last_resize_time: time.Tick

// LVGL flush callback — marks rendering complete (direct mode, no copy needed)
flush_cb :: proc "c" (disp: ^lv_display_t, area: ^lv_area_t, px: [^]u8) {
    lv_display_flush_ready(disp)
}

main :: proc() {
    if !display.display_init("Axium", WIDTH, HEIGHT) {
        fmt.eprintln("Failed to create window")
        return
    }
    defer display.display_destroy()

    if !engine_init() {
        fmt.eprintln("Failed to init engine")
        return
    }
    defer engine_shutdown()

    engine_init_clipboard()
    config_load()
    resolve_font()

    // Init LVGL
    lv_init()
    apply_theme()

    lv_disp = lv_display_create(i32(WIDTH), i32(HEIGHT))
    lv_display_set_color_format(lv_disp, .LV_COLOR_FORMAT_ARGB8888)

    fb, fb_w, fb_h := display.display_framebuffer()
    lv_display_set_buffers(lv_disp, raw_data(fb), nil, u32(len(fb) * 4), .LV_DISPLAY_RENDER_MODE_DIRECT)
    lv_display_set_flush_cb(lv_disp, flush_cb)

    // Input devices for LVGL
    mouse_indev := lv_indev_create()
    lv_indev_set_type(mouse_indev, .LV_INDEV_TYPE_POINTER)
    lv_indev_set_read_cb(mouse_indev, mouse_read_cb)

    kb_indev := lv_indev_create()
    lv_indev_set_type(kb_indev, .LV_INDEV_TYPE_KEYPAD)
    lv_indev_set_read_cb(kb_indev, keyboard_read_cb)

    // Build UI
    screen := lv_screen_active()
    kb_group := lv_group_create()
    lv_indev_set_group(kb_indev, kb_group)
    build_ui(screen, kb_group)

    // Force layout pass so content_area has valid coordinates
    lv_obj_update_layout(screen)
    query_content_bounds()

    // Create WebKit view sized to content area
    if !engine_create_view(c.int(content_w), c.int(content_h)) {
        fmt.eprintln("Failed to create view")
        return
    }

    // Point WebKit output directly into content area of framebuffer
    engine_set_frame_target(
        ([^]u8)(raw_data(fb)),
        c.int(fb_w * 4),
        c.int(content_x), c.int(content_y),
        c.int(content_w), c.int(content_h),
    )

    engine_load_uri("https://en.wikipedia.org/wiki/WebKit")

    // Main loop
    last_tick := time.now()
    for !display.display_should_close() {
        now := time.now()
        delta := time.duration_milliseconds(time.diff(last_tick, now))
        if delta > 0 {
            lv_tick_inc(u32(delta))
            last_tick = now
        }

        poll_events()
        check_hover_edges()

        // Apply pending resize after debounce
        if r, ok := pending_resize.?; ok {
            elapsed := time.tick_diff(last_resize_time, time.tick_now())
            if elapsed >= 50 * time.Millisecond {
                handle_resize(lv_disp)
                pending_resize = nil
            }
            continue  // Skip rendering while framebuffer is being resized
        }

        engine_pump()       // WebKit renders → copies directly to fb content area

        // Sync URL bar and window title from WebKit
        uri: cstring
        engine_get_uri(&uri)
        if uri != nil && uri != lv_textarea_get_text(url_input) {
            lv_textarea_set_text(url_input, uri)
        }

        title: cstring
        engine_get_title(&title)
        if title != nil {
            display.display_set_title(string(title))
        }

        ms := lv_timer_handler()  // LVGL renders chrome to fb
        if ms == 0xFFFFFFFF {
            ms = 5
        }

        // Update cursor if WebKit changed it
        cursor := engine_get_cursor()
        if cursor >= 0 {
            display.display_cursor_set(display.Cursor(cursor))
        }

        display.display_present()

        // Idle until input arrives or LVGL timer fires
        pfd := posix.pollfd{fd = posix.FD(display.display_fd()), events = {.IN}}
        posix.poll(&pfd, 1, c.int(ms))
    }
}
