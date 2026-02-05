package main

import "core:fmt"
import "vendor:glfw"
import "lvgl"

// Keyboard state - manages input device and group
// Designed to be extended for vim-style modes later
KeyboardState :: struct {
    group: ^lvgl.lv_group_t,     // LVGL group for focusable widgets
    indev: ^lvgl.lv_indev_t,     // Keyboard input device

    // Input state for LVGL indev callback
    last_key: u32,
    key_state: lvgl.lv_indev_state_t,

    // Future: mode (normal/insert/command), key sequence buffer, etc.
}

// Global keyboard state (needed for GLFW callbacks)
g_keyboard: ^KeyboardState

// Initialize keyboard input
init_keyboard :: proc(state: ^KeyboardState, glfw_window: glfw.WindowHandle, display: ^lvgl.lv_display_t) -> bool {
    g_keyboard = state

    // Create LVGL group for focusable widgets
    state.group = lvgl.lv_group_create()
    if state.group == nil {
        fmt.eprintln("Failed to create LVGL group")
        return false
    }

    // Create keyboard input device
    state.indev = lvgl.lv_indev_create()
    if state.indev == nil {
        fmt.eprintln("Failed to create keyboard indev")
        return false
    }

    lvgl.lv_indev_set_type(state.indev, .LV_INDEV_TYPE_KEYPAD)
    lvgl.lv_indev_set_read_cb(state.indev, keyboard_read_cb)
    lvgl.lv_indev_set_driver_data(state.indev, state)
    lvgl.lv_indev_set_display(state.indev, display)
    lvgl.lv_indev_set_group(state.indev, state.group)
    lvgl.lv_indev_set_mode(state.indev, .LV_INDEV_MODE_EVENT)

    // Set up GLFW callbacks
    glfw.SetCharCallback(glfw_window, char_callback)
    glfw.SetKeyCallback(glfw_window, key_callback)

    // Start in editing mode (direct text input)
    lvgl.lv_group_set_editing(state.group, true)

    return true
}

// Add a widget to the keyboard group
add_to_keyboard_group :: proc(state: ^KeyboardState, obj: ^lvgl.lv_obj_t) {
    lvgl.lv_group_add_obj(state.group, obj)
}

// Focus a specific widget
focus_widget :: proc(state: ^KeyboardState, obj: ^lvgl.lv_obj_t) {
    lvgl.lv_group_focus_obj(obj)
}

// LVGL indev read callback
keyboard_read_cb :: proc "c" (indev: ^lvgl.lv_indev_t, data: ^lvgl.lv_indev_data_t) {
    context = {}
    state := cast(^KeyboardState)lvgl.lv_indev_get_driver_data(indev)
    if state == nil do return

    data.key = state.last_key
    data.state = state.key_state

    // Reset after read
    state.key_state = .LV_INDEV_STATE_RELEASED
}

// Send a key to LVGL
send_key :: proc(state: ^KeyboardState, key: u32, pressed: bool) {
    state.last_key = key
    state.key_state = pressed ? .LV_INDEV_STATE_PRESSED : .LV_INDEV_STATE_RELEASED
    lvgl.lv_indev_read(state.indev)
}

// GLFW character callback - for text input
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
    context = {}
    if g_keyboard == nil do return

    // Send character directly to LVGL group
    lvgl.lv_group_send_data(g_keyboard.group, cast(u32)codepoint)
}

// GLFW key callback - for special keys
key_callback :: proc "c" (window: glfw.WindowHandle, key: i32, scancode: i32, action: i32, mods: i32) {
    context = {}
    if g_keyboard == nil do return

    // Only handle press and repeat
    if action == glfw.RELEASE do return

    // Map GLFW keys to LVGL keys
    lv_key: u32 = 0

    switch key {
    case glfw.KEY_BACKSPACE:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_BACKSPACE
    case glfw.KEY_DELETE:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_DEL
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_ENTER
    case glfw.KEY_ESCAPE:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_ESC
    case glfw.KEY_LEFT:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_LEFT
    case glfw.KEY_RIGHT:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_RIGHT
    case glfw.KEY_UP:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_UP
    case glfw.KEY_DOWN:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_DOWN
    case glfw.KEY_HOME:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_HOME
    case glfw.KEY_END:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_END
    case glfw.KEY_TAB:
        lv_key = cast(u32)lvgl.lv_key_t.LV_KEY_NEXT
    }

    if lv_key != 0 {
        lvgl.lv_group_send_data(g_keyboard.group, lv_key)
    }

    // Future: vim mode handling would go here
    // e.g., if in normal mode, intercept j/k for scrolling, etc.
}
