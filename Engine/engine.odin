package axium

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:strings"

foreign import engine "system:engine"

@(default_calling_convention = "c")
foreign engine {
    engine_init          :: proc() -> bool ---
    engine_create_view   :: proc(width, height: c.int) -> c.int ---
    engine_destroy_view  :: proc(index: c.int) ---
    engine_set_active_view :: proc(index: c.int) ---
    engine_view_get_uri  :: proc(index: c.int, uri: ^cstring) ---
    engine_view_get_title :: proc(index: c.int, title: ^cstring) ---
    engine_view_count    :: proc() -> c.int ---
    engine_active_view   :: proc() -> c.int ---
    engine_load_uri      :: proc(uri: cstring) ---
    engine_resize        :: proc(width, height: c.int) ---
    engine_pump          :: proc() ---
    engine_grab_frame    :: proc() ---
    engine_set_frame_target :: proc(
        buffer: [^]u8, buf_stride: c.int,
        x, y, w, h: c.int,
    ) ---
    engine_send_key          :: proc(keyval: c.uint32_t, pressed: bool) ---
    engine_send_mouse_button :: proc(button: c.uint32_t, pressed: bool, x, y: c.double) ---
    engine_send_mouse_move   :: proc(x, y: c.double) ---
    engine_send_scroll       :: proc(x, y, delta_x, delta_y: c.double) ---
    engine_send_focus        :: proc(focused: bool) ---
    engine_get_cursor        :: proc() -> c.int ---
    engine_editing_command   :: proc(command: cstring, argument: cstring) ---
    engine_go_back           :: proc() ---
    engine_go_forward        :: proc() ---
    engine_reload            :: proc() ---
    engine_get_uri           :: proc(uri: ^cstring) ---
    engine_get_title         :: proc(title: ^cstring) ---
    engine_set_clipboard_callbacks :: proc(
        set_fn: proc "c" (text: cstring) -> bool,
        get_fn: proc "c" () -> cstring,
    ) ---
    engine_set_navigation_callbacks :: proc(
        uri_fn: proc "c" (uri: cstring),
        title_fn: proc "c" (title: cstring),
    ) ---
    engine_set_screen_info   :: proc(
        width, height: c.int,
        phys_w_mm, phys_h_mm: c.int,
        refresh_rate_mhz: c.int,
        scale: c.double,
    ) ---
    engine_init_adblock      :: proc(ext_dir: cstring, adblock_dir: cstring) ---
    engine_run_javascript    :: proc(script: cstring) ---
    engine_evaluate_javascript :: proc(
        script: cstring,
        callback: proc "c" (result: cstring),
    ) ---
    engine_shutdown          :: proc() ---
}

// Navigation callbacks — URI and title changes from WebKit
engine_init_navigation :: proc() {
    on_uri :: proc "c" (uri: cstring) {
        context = runtime.default_context()
        if url_input != nil {
            lv_textarea_set_text(url_input, uri if uri != nil else "")
        }
        tab_bar_rebuild()
    }

    on_title :: proc "c" (title: cstring) {
        context = runtime.default_context()
        if title != nil {
            display_set_title(string(title))
        }
        tab_bar_rebuild()
    }

    engine_set_navigation_callbacks(on_uri, on_title)
}

// Clipboard callbacks bridging WPE ↔ Display-Onix
engine_init_clipboard :: proc() {
    clipboard_set :: proc "c" (text: cstring) -> bool {
        context = runtime.default_context()
        if text == nil do return false
        return display_clipboard_set(string(text))
    }

    clipboard_get :: proc "c" () -> cstring {
        context = runtime.default_context()
        @static buf: cstring
        if buf != nil {
            libc.free(rawptr(buf))
            buf = nil
        }
        s := display_clipboard_get()
        if len(s) == 0 do return nil
        buf = strings.clone_to_cstring(s)
        delete(s)
        return buf
    }

    engine_set_clipboard_callbacks(clipboard_set, clipboard_get)
}
