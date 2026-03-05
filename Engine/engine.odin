package axium

import "base:runtime"
import "core:c"
import "core:strings"

foreign import engine "system:engine"

@(default_calling_convention = "c")
foreign engine {
    engine_init          :: proc() -> bool ---
    engine_create_view   :: proc(width, height: c.int, ephemeral: bool, related: rawptr) -> rawptr ---
    engine_destroy_view  :: proc(view: rawptr) ---
    engine_set_active_view :: proc(view: rawptr) ---
    engine_view_go_to    :: proc(view: rawptr, uri: cstring) ---
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
    engine_clipboard_notify_external :: proc(formats: [^]cstring, count: c.int) ---
    engine_set_screen_info   :: proc(
        width, height: c.int,
        phys_w_mm, phys_h_mm: c.int,
        refresh_rate_mhz: c.int,
        scale: c.double,
    ) ---
    engine_set_bg            :: proc(rgb: u32, opacity: c.int) ---
    engine_init_adblock      :: proc(ext_dir: cstring, adblock_dir: cstring) ---
    engine_adblock_set_disabled :: proc(disabled: bool) ---
    engine_run_javascript    :: proc(script: cstring) ---
    engine_evaluate_javascript :: proc(
        script: cstring,
        callback: proc "c" (result: cstring),
    ) ---
    engine_set_download_dir  :: proc(dir: cstring) ---
    engine_download_cancel   :: proc(uri: cstring) ---
    engine_history_init      :: proc(db_path: cstring) ---
    engine_set_page_theme    :: proc(css_vars: cstring) ---

    // Privacy API
    engine_configure_privacy :: proc(
        cookie_policy: c.int, itp_enabled: bool,
        tls_strict: bool, credential_persistence: bool,
    ) ---
    engine_clear_website_data :: proc(data_types: c.int, since_timestamp: c.int64_t) ---
    engine_clear_website_data_for_domain :: proc(domain: cstring, data_types: c.int) ---
    engine_configure_proxy :: proc(mode: c.int, url: cstring, ignore_hosts: cstring) ---
    engine_set_tls_allowed_hosts :: proc(hosts: [^]cstring, count: c.int) ---

    // Context menu — actions bitset indexed by WebKit stock action enum
    engine_context_menu_activate :: proc(action: c.int) ---

    engine_shutdown          :: proc() ---
}

// WebKit copy → Display-Onix
@(export)
on_clipboard_write :: proc "c" (count: c.int, mimes: [^]cstring, data: [^][^]u8, sizes: [^]c.int) -> bool {
    context = runtime.default_context()
    if count <= 0 do return false
    entries := make([]Clipboard_Entry, int(count), context.temp_allocator)
    for i in 0..<int(count) {
        entries[i] = Clipboard_Entry{
            mime = string(mimes[i]),
            data = data[i][:int(sizes[i])],
        }
    }
    return display_clipboard_set(entries)
}

// WebKit paste → Display-Onix
@(export)
on_clipboard_read :: proc "c" (mime: cstring, out_data: ^[^]u8, out_size: ^c.int) -> bool {
    context = runtime.default_context()
    if mime == nil do return false
    @static buf: []u8
    if buf != nil {
        delete(buf)
        buf = nil
    }
    buf = display_clipboard_get_data(string(mime))
    if buf == nil || len(buf) == 0 do return false
    out_data^ = raw_data(buf)
    out_size^ = c.int(len(buf))
    return true
}

// Notify WPE of external clipboard formats before paste
clipboard_notify_before_paste :: proc() {
    formats := display_clipboard_get_formats()
    if formats == nil || len(formats) == 0 do return
    defer {
        for f in formats do delete(f)
        delete(formats)
    }

    cformats := make([]cstring, len(formats), context.temp_allocator)
    for i in 0..<len(formats) {
        cformats[i] = strings.clone_to_cstring(formats[i], context.temp_allocator)
    }

    engine_clipboard_notify_external(raw_data(cformats), c.int(len(cformats)))
}
