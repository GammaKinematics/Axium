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

    fmt.println("Starting main loop...")

    for {
        check_resize(&window)
        lvgl.lv_timer_handler()
        time.sleep(16 * time.Millisecond)
    }
}
