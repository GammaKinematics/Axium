package main

import "core:c"
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

    // Web content texture (engine renders behind UI)
    web_tex_id: c.uint,
    web_texture: ^lvgl.lv_opengles_window_texture_t,

    // Engine initialized
    engine_ready: bool,

    // UI state (preserved across resizes)
    ui_state: UI.State,

    // Keyboard input
    keyboard: KeyboardState,
}

// Initialize window - creates GLFW window and initial texture
init_window :: proc(state: ^WindowState, width, height: i32, title: cstring) -> bool {
    // Tell GLFW to use EGL instead of GLX, so we share the EGL display with WebKit
    glfw.Init()
    glfw.WindowHint(glfw.CONTEXT_CREATION_API, glfw.EGL_CONTEXT_API)

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

    // Create UI texture (top layer)
    if !create_ui_texture(state, state.width, state.height) {
        return false
    }

    // Initialize keyboard input
    if !init_keyboard(&state.keyboard, state.glfw_window, state.ui_disp) {
        return false
    }

    // Initialize the web engine
    if axium_engine_init() {
        // Create web view sized to full window (content area geometry applied later)
        if axium_engine_create_view(state.width, state.height) {
            state.engine_ready = true
            fmt.println("Engine initialized")
        } else {
            fmt.eprintln("Failed to create engine view")
        }
    } else {
        fmt.eprintln("Failed to initialize engine")
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
    // Use ARGB8888 so transparent areas have alpha=0 (web content shows through)
    lvgl.lv_display_set_color_format(state.ui_disp, .LV_COLOR_FORMAT_ARGB8888)
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

// Update web content texture from engine frame
update_web_texture :: proc(state: ^WindowState) {
    if !state.engine_ready do return

    // Pump GLib event loop so WebKit can process
    axium_engine_pump()

    // Check for new frame
    if !axium_engine_has_new_frame() do return

    // Get the GL texture ID from the engine (imports DMA-BUF → EGLImage → GL texture)
    tex_id := axium_engine_get_texture_id()
    if tex_id == 0 do return

    // First frame or texture changed: add/replace in compositor
    if state.web_tex_id != tex_id {
        fmt.printf("Adding web texture to compositor: tex_id=%d (old=%d)\n", tex_id, state.web_tex_id)

        // Remove old web texture from compositor
        if state.web_texture != nil {
            lvgl.lv_opengles_window_texture_remove(state.web_texture)
            state.web_texture = nil
        }

        // Remove UI texture temporarily so we can add web texture first (bottom)
        if state.ui_texture != nil {
            lvgl.lv_opengles_window_texture_remove(state.ui_texture)
            state.ui_texture = nil
        }

        // Get frame dimensions
        fw, fh: c.int
        axium_engine_get_frame_size(&fw, &fh)
        if fw == 0 || fh == 0 {
            fw = cast(c.int)state.width
            fh = cast(c.int)state.height
        }

        fmt.printf("Web texture dimensions: %dx%d, window: %dx%d\n",
            fw, fh, state.width, state.height)

        // Add web texture first (bottom layer)
        state.web_tex_id = tex_id
        state.web_texture = lvgl.lv_opengles_window_add_texture(
            state.window, tex_id, cast(i32)fw, cast(i32)fh)
        fmt.printf("Web texture added: %v\n", state.web_texture != nil)

        // Re-add UI texture (top layer)
        ui_tex_id := lvgl.lv_opengles_texture_get_texture_id(state.ui_disp)
        state.ui_texture = lvgl.lv_opengles_window_add_texture(
            state.window, ui_tex_id, state.width, state.height)
        fmt.printf("UI texture re-added: %v (ui_tex=%d)\n", state.ui_texture != nil, ui_tex_id)
    } else {
        fmt.println("Web texture updated in-place (same tex_id)")
    }
}

// Build UI on current display
build_ui :: proc(state: ^WindowState) {
    screen := lvgl.lv_display_get_screen_active(state.ui_disp)
    if screen != nil {
        UI.build_ui(screen, state.keyboard.group, &state.ui_state)
    }
}

// Check for resize and handle it
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

    // Remove old textures from compositor
    if state.ui_texture != nil {
        lvgl.lv_opengles_window_texture_remove(state.ui_texture)
        state.ui_texture = nil
    }
    if state.web_texture != nil {
        lvgl.lv_opengles_window_texture_remove(state.web_texture)
        state.web_texture = nil
    }
    // Don't delete the engine's GL texture — the engine owns it
    state.web_tex_id = 0

    // Delete old display
    if state.ui_disp != nil {
        lvgl.lv_display_delete(state.ui_disp)
        state.ui_disp = nil
    }

    // Update dimensions
    state.width = new_width
    state.height = new_height

    // Recreate UI texture
    if !create_ui_texture(state, new_width, new_height) {
        fmt.eprintln("Failed to recreate texture after resize")
        return false
    }

    // Resize engine view
    if state.engine_ready {
        axium_engine_resize(new_width, new_height)
    }

    // Rebuild UI
    build_ui(state)

    return true
}
