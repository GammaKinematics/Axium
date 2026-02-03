package main

import "core:fmt"
import "core:time"
import "core:c"
import "lvgl"

import glfw "vendor:glfw"

WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720
WINDOW_TITLE  :: "Axium Browser"

// Global state for resize handling
State :: struct {
    window:         ^lvgl.lv_opengles_window_t,
    glfw_window:    glfw.WindowHandle,
    display:        ^lvgl.lv_display_t,
    window_texture: ^lvgl.lv_opengles_window_texture_t,
    fb_width:       c.int,
    fb_height:      c.int,
}

create_display :: proc(state: ^State) -> bool {
    // Create texture-based display at framebuffer size
    state.display = lvgl.lv_opengles_texture_create(i32(state.fb_width), i32(state.fb_height))
    if state.display == nil {
        fmt.eprintln("Failed to create texture display")
        return false
    }
    lvgl.lv_display_set_default(state.display)

    // Get texture ID and add to window
    texture_id := lvgl.lv_opengles_texture_get_texture_id(state.display)
    state.window_texture = lvgl.lv_opengles_window_add_texture(
        state.window, texture_id, i32(state.fb_width), i32(state.fb_height))
    if state.window_texture == nil {
        fmt.eprintln("Failed to add texture to window")
        return false
    }

    // Build UI on the new screen
    screen := lvgl.lv_display_get_screen_active(state.display)
    if screen != nil {
        build_ui(screen)
    }

    return true
}

destroy_display :: proc(state: ^State) {
    if state.window_texture != nil {
        lvgl.lv_opengles_window_texture_remove(state.window_texture)
        state.window_texture = nil
    }
    if state.display != nil {
        lvgl.lv_display_delete(state.display)
        state.display = nil
    }
}

handle_resize :: proc(state: ^State) -> bool {
    new_width, new_height := glfw.GetFramebufferSize(state.glfw_window)

    if new_width != state.fb_width || new_height != state.fb_height {
        fmt.println("Resize:", state.fb_width, "x", state.fb_height, "->", new_width, "x", new_height)

        // Update stored size
        state.fb_width = new_width
        state.fb_height = new_height

        // Recreate display at new size
        destroy_display(state)
        if !create_display(state) {
            return false
        }
    }
    return true
}

main :: proc() {
    lvgl.lv_init()

    state: State

    // Create GLFW window
    state.window = lvgl.lv_opengles_glfw_window_create(WINDOW_WIDTH, WINDOW_HEIGHT, false)
    if state.window == nil {
        fmt.eprintln("Failed to create GLFW window")
        return
    }
    lvgl.lv_opengles_glfw_window_set_title(state.window, WINDOW_TITLE)

    // Get GLFW handle and initial framebuffer size
    state.glfw_window = cast(glfw.WindowHandle)lvgl.lv_opengles_glfw_window_get_glfw_window(state.window)
    state.fb_width, state.fb_height = glfw.GetFramebufferSize(state.glfw_window)
    fmt.println("Initial framebuffer size:", state.fb_width, "x", state.fb_height)

    // Create initial display
    if !create_display(&state) {
        return
    }

    // Main loop
    for {
        // Check for resize
        if !handle_resize(&state) {
            fmt.eprintln("Resize failed")
            return
        }

        lvgl.lv_timer_handler()
        time.sleep(16 * time.Millisecond)  // ~60fps
    }
}
