package axium

import "base:runtime"
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
base_font: ^lv_font_t
pending_resize: Maybe(Resize)
last_resize_time: time.Tick

// LVGL flush callback — marks rendering complete (direct mode, no copy needed)
flush_cb :: proc "c" (disp: ^lv_display_t, area: ^lv_area_t, px: [^]u8) {
    lv_display_flush_ready(disp)
}

main :: proc() {
    // Static builds: single-binary dispatch. WPEWebProcess/WPENetworkProcess are
    // symlinks to axium — argv[0] determines which subprocess entry point to run.
    // Dynamic builds: WebKit's own executables handle subprocesses.
    when STATIC {
        args := runtime.args__
        if len(args) > 0 {
            prog := string(args[0])
            if idx := strings.last_index_byte(prog, '/'); idx >= 0 {
                prog = prog[idx+1:]
            }
            argc := c.int(len(args))
            argv := raw_data(args)
            if prog == "WPEWebProcess" {
                posix.exit(i32(axium_web_process_main(argc, argv)))
            }
            if prog == "WPENetworkProcess" {
                posix.exit(i32(axium_network_process_main(argc, argv)))
            }
        }
    }

    if display_init(.X11, "Axium", WIDTH, HEIGHT) == .Error {
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

    // Configure adblock (must be before engine_create_view)
    adblock_dir := posix.getenv("AXIUM_ADBLOCK_DIR")
    if adblock_dir != nil {
        engine_init_adblock(adblock_dir)
    }

    config_load()
    site_settings_load()
    privacy_init()

    // Initialize history DB, page theme, and internal pages (before creating views)
    {
        db_path := xdg_path(.Data, "history.db")
        engine_history_init(strings.clone_to_cstring(db_path))
    }
    engine_set_page_theme(strings.clone_to_cstring(
        fmt.tprintf(":root{{--bg:#{:06x};--text:#{:06x};--accent:#{:06x};--text-sec:#{:06x};--pad:12px;--gap:8px;--radius:6px}}",
            theme_bg_prim, theme_text_pri, theme_accent, theme_text_sec)))
    favorite_load()
    download_init()
    // Init LVGL
    lv_init()
    apply_theme()

    lv_disp = lv_display_create(i32(WIDTH), i32(HEIGHT))
    lv_display_set_color_format(lv_disp, .LV_COLOR_FORMAT_ARGB8888_PREMULTIPLIED)

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
    // Icon font (user override or embedded subset)
    if icon_font_path != "" {
        cpath := strings.clone_to_cstring(strings.concatenate({"A:", icon_font_path}))
        icon_font = lv_tiny_ttf_create_file(cpath, i32(font_size))
    } else {
        icon_font = lv_tiny_ttf_create_data(raw_data(ICON_FONT_DATA), len(ICON_FONT_DATA), i32(font_size))
    }

    // Text font (TTF via fontconfig) on active screen
    if font_path != "" {
        cpath := strings.clone_to_cstring(strings.concatenate({"A:", font_path}))
        base_font = lv_tiny_ttf_create_file(cpath, i32(font_size))
        if base_font != nil {
            lv_obj_set_style_text_font(lv_screen_active(), base_font, 0)
            lv_obj_set_style_text_font(lv_layer_top(), base_font, 0)
        }
    }

    // Tab sizing (needs fonts/theme ready)
    tab_init_sizing()

    // Build edge containers on lv_layer_top()
    keepass_init()
    translate_init()
    widgets_init()
    bounds := edge_init()
    content_area = bounds
    input_area = edge_content_widget_bounds()
    lv_refr_set_noclear_area(bounds.x, bounds.y,
        bounds.x + bounds.w - 1, bounds.y + bounds.h - 1)

    // Set WebKit background color + opacity (before creating views)
    engine_set_bg(theme_bg_prim, theme_bg_opacity if web_bg_opacity else 255)

    // Point WebKit output directly into content area of framebuffer
    engine_set_frame_target(
        ([^]u8)(raw_data(fb)),
        c.int(fb_w * 4),
        bounds.x, bounds.y,
        bounds.w, bounds.h,
    )

    // Defer view creation until URL is known to avoid PSON ghost process.
    // (Creating a view for about:blank then navigating triggers Process Swap
    // On Navigation, leaving a ~140 MB zombie process.)
    if !session_restore() {
        view := engine_create_view(bounds.w, bounds.h, false, nil)
        if view == nil {
            fmt.eprintln("Failed to create view")
            return
        }
        tab_entries[0] = Tab_Entry{ view = view }
        tab_count = 1
        active_tab = 0
        engine_set_active_view(view)
        engine_view_go_to(view, "https://www.google.com")
    }
    tab_bar_build_all()

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
            lv_refr_set_noclear_area(content_area.x, content_area.y,
                content_area.x + content_area.w - 1, content_area.y + content_area.h - 1)
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

        // Sleep until X events, keepass socket, or translate pipe data arrives
        kfd := keepass_fd()
        tfd := translate_get_fd()
        nfds: u64 = 1
        pfds: [3]posix.pollfd
        pfds[0] = {fd = posix.FD(display_fd()), events = {.IN}}
        kfd_idx: int = -1
        tfd_idx: int = -1
        if kfd >= 0 {
            kfd_idx = int(nfds)
            pfds[nfds] = {fd = posix.FD(kfd), events = {.IN}}
            nfds += 1
        }
        if tfd >= 0 {
            tfd_idx = int(nfds)
            pfds[nfds] = {fd = posix.FD(tfd), events = {.IN}}
            nfds += 1
        }
        poll_timeout: i32 = 200 if translate_poll_active else -1
        posix.poll(&pfds[0], nfds, poll_timeout)
        if kfd_idx >= 0 && .IN in pfds[kfd_idx].revents {
            keepass_on_response_ready()
        }
        if tfd_idx >= 0 && .IN in pfds[tfd_idx].revents {
            translate_on_result_ready()
        }
        if translate_poll_active do translate_poll_visible()
    }

    session_save()

    // Destroy all views before engine_shutdown (deferred above)
    for i in 0..<tab_count {
        if tab_entries[i].view != nil {
            engine_destroy_view(tab_entries[i].view)
            tab_entries[i].view = nil
        }
    }
}
