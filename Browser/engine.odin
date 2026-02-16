package main

// Foreign imports for the WPE2 engine C shim (wpe_shim.c)

import "core:c"

foreign import engine "system:wpe_shim"

@(default_calling_convention = "c")
foreign engine {
    axium_engine_init :: proc() -> bool ---
    axium_engine_create_view :: proc(width, height: c.int) -> bool ---
    axium_engine_load_uri :: proc(uri: cstring) ---
    axium_engine_resize :: proc(width, height: c.int) ---
    axium_engine_pump :: proc() ---
    axium_engine_has_new_frame :: proc() -> bool ---
    axium_engine_get_texture_id :: proc() -> c.uint ---
    axium_engine_get_frame_size :: proc(width, height: ^c.int) ---
    axium_engine_shutdown :: proc() ---
}
