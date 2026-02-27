package axium

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"

WIDTH  :: 1280
HEIGHT :: 720

// Display state
lv_disp: ^lv_display_t
keyboard_group: ^lv_group_t
icon_font: ^lv_font_t
pending_resize: Maybe(Resize)
last_resize_time: time.Tick

// LVGL flush callback — marks rendering complete (direct mode, no copy needed)
flush_cb :: proc "c" (disp: ^lv_display_t, area: ^lv_area_t, px: [^]u8) {
    lv_display_flush_ready(disp)
}

main :: proc() {
    if !display_init("Axium", WIDTH, HEIGHT) {
        fmt.eprintln("Failed to create window")
        return
    }
    defer display_destroy()

    if !engine_init() {
        fmt.eprintln("Failed to init engine")
        return
    }
    defer engine_shutdown()

    // Set screen properties from RANDR so WebKit knows DPI, scale, refresh rate
    screen_info := display_screen_info()
    engine_set_screen_info(
        c.int(screen_info.width), c.int(screen_info.height),
        c.int(screen_info.physical_width_mm), c.int(screen_info.physical_height_mm),
        c.int(screen_info.refresh_rate_mhz), c.double(screen_info.scale),
    )

    // Configure adblock web process extension (must be before engine_create_view)
    ext_dir := posix.getenv("AXIUM_EXT_DIR")
    adblock_dir := posix.getenv("AXIUM_ADBLOCK_DIR")
    if ext_dir != nil && adblock_dir != nil {
        engine_init_adblock(ext_dir, adblock_dir)
    }

    engine_init_clipboard()
    engine_init_navigation()
    config_load()
    resolve_font()

    // Init LVGL
    lv_init()
    apply_theme()

    lv_disp = lv_display_create(i32(WIDTH), i32(HEIGHT))
    lv_display_set_color_format(lv_disp, .LV_COLOR_FORMAT_ARGB8888)

    fb, fb_w, fb_h := display_framebuffer()
    lv_display_set_buffers(lv_disp, raw_data(fb), nil, u32(len(fb) * 4), .LV_DISPLAY_RENDER_MODE_DIRECT)
    lv_display_set_flush_cb(lv_disp, flush_cb)

    // Input devices for LVGL
    mouse_indev := lv_indev_create()
    lv_indev_set_type(mouse_indev, .LV_INDEV_TYPE_POINTER)
    lv_indev_set_read_cb(mouse_indev, mouse_read_cb)

    kb_indev := lv_indev_create()
    lv_indev_set_type(kb_indev, .LV_INDEV_TYPE_KEYPAD)
    lv_indev_set_read_cb(kb_indev, keyboard_read_cb)

    // Set Edge-Onix globals before init
    kb_group := lv_group_create()
    lv_indev_set_group(kb_indev, kb_group)
    keyboard_group = kb_group
    icon_font = lv_onix_icons_get(font_size_base)

    // Font setup (TTF) on active screen
    if font_path != "" {
        cpath := strings.clone_to_cstring(strings.concatenate({"A:", font_path}))
        base_font := lv_tiny_ttf_create_file(cpath, font_size_base)
        if base_font != nil {
            lv_obj_set_style_text_font(lv_screen_active(), base_font, 0)
        }
    }

    // Build edge containers on lv_layer_top()
    keepass_init()
    widgets_init()
    bounds := edge_init()
    content_area = bounds
    input_area = edge_content_widget_bounds()

    // Create first WebKit view sized to content area
    first_view := engine_create_view(bounds.w, bounds.h)
    if first_view < 0 {
        fmt.eprintln("Failed to create view")
        return
    }
    engine_set_active_view(0)
    active_tab = 0
    tab_count = 1

    // Point WebKit output directly into content area of framebuffer
    engine_set_frame_target(
        ([^]u8)(raw_data(fb)),
        c.int(fb_w * 4),
        bounds.x, bounds.y,
        bounds.w, bounds.h,
    )

    engine_load_uri("https://www.google.com")
    tab_bar_rebuild()

    // Main loop
    last_tick := time.now()
    for !display_should_close() {
        now := time.now()
        delta := time.duration_milliseconds(time.diff(last_tick, now))
        if delta > 0 {
            lv_tick_inc(u32(delta))
            last_tick = now
        }

        poll_events()

        // Check hover edges each frame
        new_bounds := edge_check_hover(mouse_screen_x, mouse_screen_y)
        if new_bounds != content_area {
            content_area = new_bounds
            input_area = edge_content_widget_bounds()
            update_engine_bounds()
        }

        // Apply pending resize after debounce
        if r, ok := pending_resize.?; ok {
            elapsed := time.tick_diff(last_resize_time, time.tick_now())
            if elapsed >= 50 * time.Millisecond {
                handle_resize(lv_disp)
                pending_resize = nil
            }
            engine_pump()
            pfd := posix.pollfd{fd = posix.FD(display_fd()), events = {.IN}}
            posix.poll(&pfd, 1, 5)
            continue  // Skip rendering while framebuffer is being resized
        }

        engine_pump()

        // Don't touch the framebuffer while X server is still reading it
        if display_present_pending() {
            pfd := posix.pollfd{fd = posix.FD(display_fd()), events = {.IN}}
            posix.poll(&pfd, 1, 5)
            continue
        }

        lv_timer_handler()        // Step LVGL internal state (animations, cursor blink)
        engine_grab_frame()       // Copy WebKit frame to framebuffer
        edge_invalidate_overlays()
        popup_invalidate()
        lv_refr_now(lv_disp)     // Redraw overlay edges on top of WebKit

        // Update cursor if WebKit changed it
        cursor := engine_get_cursor()
        if cursor >= 0 {
            display_cursor_set(Cursor(cursor))
        }

        display_present()

        // Sleep until X events or keepass socket data arrives
        kfd := keepass_fd()
        if kfd >= 0 {
            pfds: [2]posix.pollfd
            pfds[0] = {fd = posix.FD(display_fd()), events = {.IN}}
            pfds[1] = {fd = posix.FD(kfd), events = {.IN}}
            posix.poll(&pfds[0], 2, -1)
            if .IN in pfds[1].revents {
                keepass_on_response_ready()
            }
        } else {
            pfd := posix.pollfd{fd = posix.FD(display_fd()), events = {.IN}}
            posix.poll(&pfd, 1, -1)
        }
    }
}
