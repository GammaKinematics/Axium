package axium

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:strings"
import "display"

foreign import engine "system:wpe_shim"

@(default_calling_convention = "c")
foreign engine {
    engine_init          :: proc() -> bool ---
    engine_create_view   :: proc(width, height: c.int) -> bool ---
    engine_load_uri      :: proc(uri: cstring) ---
    engine_resize        :: proc(width, height: c.int) ---
    engine_pump          :: proc() ---
    engine_has_new_frame :: proc() -> bool ---
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
    engine_set_clipboard_callbacks :: proc(
        set_fn: proc "c" (text: cstring) -> bool,
        get_fn: proc "c" () -> cstring,
    ) ---
    engine_shutdown          :: proc() ---
}

// Clipboard callbacks bridging WPE ↔ Display-Onix
engine_init_clipboard :: proc() {
    clipboard_set :: proc "c" (text: cstring) -> bool {
        context = runtime.default_context()
        if text == nil do return false
        return display.display_clipboard_set(string(text))
    }

    clipboard_get :: proc "c" () -> cstring {
        context = runtime.default_context()
        @static buf: cstring
        if buf != nil {
            libc.free(rawptr(buf))
            buf = nil
        }
        s := display.display_clipboard_get()
        if len(s) == 0 do return nil
        buf = strings.clone_to_cstring(s)
        delete(s)
        return buf
    }

    engine_set_clipboard_callbacks(clipboard_set, clipboard_get)
}
