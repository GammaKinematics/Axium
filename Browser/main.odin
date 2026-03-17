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

// Generic poll fd registration (used by display, keepass, translate, extensions)
poll_callbacks: [dynamic]proc()
poll_pfds: [dynamic]posix.pollfd

register_poll_fd :: proc(fd: i32, callback: proc()) {
    append(&poll_callbacks, callback)
    append(&poll_pfds, posix.pollfd{fd = posix.FD(fd), events = {.IN}})
}

unregister_poll_fd :: proc(fd: i32) {
    for i in 0..<len(poll_pfds) {
        if poll_pfds[i].fd == posix.FD(fd) {
            unordered_remove(&poll_callbacks, i)
            unordered_remove(&poll_pfds, i)
            return
        }
    }
}

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

    if display_init(.X11, "Axium", WIDTH, HEIGHT, gpu = GPU) == .Error {
        fmt.eprintln("Failed to create window")
        return
    }
    defer display_destroy()
    register_poll_fd(i32(display_fd()), proc() {})

    // GPU negotiation: engine + GLAD, fallback if either fails
    screen := display_screen_info()
    egl_image: rawptr
    egl_disp: rawptr
    when GPU {
        if gpu_active do egl_disp = display_get_egl_display()
    }
    engine_result := engine_init(
        egl_disp, &egl_image,
        c.int(screen.width), c.int(screen.height),
        c.int(screen.physical_width_mm), c.int(screen.physical_height_mm),
        c.int(screen.refresh_rate_mhz), c.double(screen.scale),
    )
    if engine_result == ENGINE_INIT_ERROR {
        fmt.eprintln("Failed to init engine")
        return
    }
    defer engine_shutdown()

    glad_ok := false
    when GPU {
        fmt.eprintln("GPU: gpu_active =", gpu_active, "engine_result =", engine_result)
        if gpu_active do glad_ok = gladLoadGL(egl.GetProcAddress) > 0
        fmt.eprintln("GPU: glad_ok =", glad_ok)
    }
    if gpu_active && (!glad_ok || engine_result == ENGINE_INIT_CPU_ONLY) {
        fmt.eprintln("GPU: falling back to CPU")
        display_fallback_cpu()
    }

    if gpu_active {
        lv_opengles_init()
    }

    // Configure adblock (must be before engine_create_view)
    adblock_dir := posix.getenv("AXIUM_ADBLOCK_DIR")
    if adblock_dir != nil {
        engine_init_adblock(adblock_dir)
    }

    config_load()
    site_settings_load()
    extension_init()
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

    if gpu_active {
        lv_disp = lv_opengles_texture_create(i32(WIDTH), i32(HEIGHT))
        lv_display_set_color_format(lv_disp, .LV_COLOR_FORMAT_ARGB8888)
    } else {
        lv_disp = lv_display_create(i32(WIDTH), i32(HEIGHT))
        lv_display_set_color_format(lv_disp, .LV_COLOR_FORMAT_ARGB8888_PREMULTIPLIED)
        fb, fb_w, _ := display_get_framebuffer()
        lv_display_set_buffers(lv_disp, raw_data(fb), nil, u32(len(fb) * 4), .LV_DISPLAY_RENDER_MODE_DIRECT)
        lv_display_set_flush_cb(lv_disp, flush_cb)
    }

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
    widgets_init()
    bounds := edge_init()
    content_area = bounds
    input_area = edge_content_widget_bounds()
    lv_refr_set_noclear_area(bounds.x, bounds.y,
        bounds.x + bounds.w - 1, bounds.y + bounds.h - 1)

    // Set WebKit background color + opacity (before creating views)
    engine_set_bg(theme_bg_prim, theme_bg_opacity if web_bg_opacity else 255)

    // Set WebKit rendering bounds and framebuffer
    if gpu_active {
        engine_resize(bounds.w, bounds.h, 0, 0, nil, 0)
    } else {
        fb, fb_w, _ := display_get_framebuffer()
        engine_resize(bounds.w, bounds.h, bounds.x, bounds.y,
            ([^]u8)(raw_data(fb)), c.int(fb_w * 4))
    }

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

        engine_grab_frame()       // GPU: updates EGLImage; CPU: blits to SHM

        lv_timer_handler()        // Step LVGL internal state (animations, cursor blink)
        edge_invalidate_overlays()
        popup_invalidate()
        lv_refr_now(lv_disp)     // GPU: GL draw to texture; CPU: SW draw to SHM

        if gpu_active {
            w, h := display_size()
            lvgl_tex := Texture(lv_opengles_texture_get_texture_id(lv_disp))
            gpu_present({
                {image = egl_image,
                 x = int(content_area.x), y = int(content_area.y),
                 w = int(content_area.w), h = int(content_area.h),
                 blend = .None},
                {texture = lvgl_tex,
                 x = 0, y = 0, w = w, h = h,
                 blend = .Premultiplied, flip_v = true, bgra = true},
            }, w, h)
        }

        // Update cursor if WebKit changed it
        cursor := engine_get_cursor()
        if cursor >= 0 {
            display_set_cursor(Cursor(cursor))
        }

        display_present()         // GPU: SwapBuffers; CPU: SHM present

        // Sleep until any registered fd has activity
        posix.poll(raw_data(poll_pfds), u64(len(poll_pfds)), -1)
        for i in 0..<len(poll_pfds) {
            if .IN in poll_pfds[i].revents {
                poll_callbacks[i]()
            }
        }
    }

    session_save()
    extension_shutdown()

    // Destroy all views before engine_shutdown (deferred above)
    for i in 0..<tab_count {
        if tab_entries[i].view != nil {
            engine_destroy_view(tab_entries[i].view)
            tab_entries[i].view = nil
        }
    }
}
