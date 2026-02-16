package main

import "core:fmt"
import "core:time"
import "lvgl"

WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720
WINDOW_TITLE  :: "Axium Browser"

main :: proc() {
    lvgl.lv_init()

    window: WindowState
    if !init_window(&window, WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE) {
        fmt.eprintln("Failed to initialize window")
        return
    }

    build_ui(&window)

    // Load a default page if engine is ready
    if window.engine_ready {
        axium_engine_load_uri("data:text/html,<body style='background:red'><h1 style='color:white;font-size:72px'>HELLO AXIUM</h1></body>")
    }

    fmt.println("Starting main loop...")

    for {
        check_resize(&window)
        update_web_texture(&window)
        lvgl.lv_timer_handler()
        time.sleep(16 * time.Millisecond)
    }
}
