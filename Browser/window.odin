package main

import "core:fmt"
import "vendor:glfw"
import "lvgl"
import "UI"

// Window state - manages GLFW window, textures, and resize handling
WindowState :: struct {
    // LVGL window (manages OpenGL context and compositing)
    window: ^lvgl.lv_opengles_window_t,

    // Underlying GLFW window (for framebuffer queries)
    glfw_window: glfw.WindowHandle,

    // Current framebuffer dimensions
    width: i32,
    height: i32,

    // LVGL UI texture display
    ui_disp: ^lvgl.lv_display_t,
    ui_texture: ^lvgl.lv_opengles_window_texture_t,

    // UI state (preserved across resizes)
    ui_state: UI.State,
}

// Initialize window - creates GLFW window and initial texture
init_window :: proc(state: ^WindowState, width, height: i32, title: cstring) -> bool {
    // Create GLFW window with OpenGL context (true = enable mouse input)
    state.window = lvgl.lv_opengles_glfw_window_create(width, height, true)
    if state.window == nil {
        fmt.eprintln("Failed to create GLFW window")
        return false
    }

    // Set window title
    lvgl.lv_opengles_glfw_window_set_title(state.window, title)

    // Get underlying GLFW window handle for framebuffer queries
    state.glfw_window = cast(glfw.WindowHandle)lvgl.lv_opengles_glfw_window_get_glfw_window(state.window)
    if state.glfw_window == nil {
        fmt.eprintln("Failed to get GLFW window handle")
        return false
    }

    // Get actual framebuffer size (handles HiDPI displays)
    state.width, state.height = glfw.GetFramebufferSize(state.glfw_window)
    fmt.printf("Initial framebuffer size: %dx%d\n", state.width, state.height)

    // Create UI texture with actual framebuffer dimensions
    if !create_ui_texture(state, state.width, state.height) {
        return false
    }

    return true
}

// Create or recreate UI texture display
create_ui_texture :: proc(state: ^WindowState, width, height: i32) -> bool {
    // Create texture display (SW renderer draws to this texture)
    state.ui_disp = lvgl.lv_opengles_texture_create(width, height)
    if state.ui_disp == nil {
        fmt.eprintln("Failed to create texture display")
        return false
    }
    lvgl.lv_display_set_default(state.ui_disp)

    // Add texture to window for GPU compositing
    texture_id := lvgl.lv_opengles_texture_get_texture_id(state.ui_disp)
    state.ui_texture = lvgl.lv_opengles_window_add_texture(state.window, texture_id, width, height)
    if state.ui_texture == nil {
        fmt.eprintln("Failed to add texture to window")
        return false
    }

    return true
}

// Build UI on current display
build_ui :: proc(state: ^WindowState) {
    screen := lvgl.lv_display_get_screen_active(state.ui_disp)
    if screen != nil {
        UI.build_ui(screen, &state.ui_state)
    }
}

// Check for resize and handle it
// Returns true if resize occurred
check_resize :: proc(state: ^WindowState) -> bool {
    new_width, new_height := glfw.GetFramebufferSize(state.glfw_window)

    // No change
    if new_width == state.width && new_height == state.height {
        return false
    }

    // Skip if minimized (zero size)
    if new_width == 0 || new_height == 0 {
        return false
    }

    fmt.printf("Resize detected: %dx%d -> %dx%d\n", state.width, state.height, new_width, new_height)

    // Remove old texture from window
    if state.ui_texture != nil {
        lvgl.lv_opengles_window_texture_remove(state.ui_texture)
        state.ui_texture = nil
    }

    // Delete old display
    if state.ui_disp != nil {
        lvgl.lv_display_delete(state.ui_disp)
        state.ui_disp = nil
    }

    // Update dimensions
    state.width = new_width
    state.height = new_height

    // Create new texture with new dimensions
    if !create_ui_texture(state, new_width, new_height) {
        fmt.eprintln("Failed to recreate texture after resize")
        return false
    }

    // Rebuild UI
    build_ui(state)

    return true
}
