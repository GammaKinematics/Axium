package axium

import "core:c"
import "core:strings"
import "display"

// Global hover distance (configurable via config)
hover_distance: i32 = 5

// Raw mouse screen position for hover edge detection
mouse_screen_x, mouse_screen_y: i32

// Set edge visibility, triggering relayout for non-overlay edges
edge_set_visible :: proc(edge: ^Edge_Info, visible: bool) {
    if edge.visible == visible do return
    edge.visible = visible
    if visible {
        lv_obj_remove_flag(edge.obj, .LV_OBJ_FLAG_HIDDEN)
    } else {
        lv_obj_add_flag(edge.obj, .LV_OBJ_FLAG_HIDDEN)
    }
    if !edge.overlay {
        lv_obj_update_layout(lv_screen_active())
        query_content_bounds()
        update_engine_bounds()
    }
}

edge_show :: proc(edge: ^Edge_Info) { edge_set_visible(edge, true) }
edge_hide :: proc(edge: ^Edge_Info) { edge_set_visible(edge, false) }
edge_toggle :: proc(edge: ^Edge_Info) { edge_set_visible(edge, !edge.visible) }

// Find an edge by name (e.g. "edge_top_0")
find_edge :: proc(name: string) -> ^Edge_Info {
    for &e in edges {
        if e.name == name do return &e
    }
    return nil
}

// Called each frame from main loop for hover edges
check_hover_edges :: proc() {
    fb_w, fb_h := display.display_size()
    mx, my := mouse_screen_x, mouse_screen_y
    for &e in edges {
        if e.show != .hover do continue
        near := false
        switch e.side {
        case .top:    near = my < hover_distance
        case .bottom: near = my >= i32(fb_h) - hover_distance
        case .left:   near = mx < hover_distance
        case .right:  near = mx >= i32(fb_w) - hover_distance
        }
        edge_set_visible(&e, near)
    }
}

// Relayout helper — updates WebKit engine bounds after edge show/hide
update_engine_bounds :: proc() {
    engine_resize(c.int(content_w), c.int(content_h))
    fb, fb_w, _ := display.display_framebuffer()
    engine_set_frame_target(
        ([^]u8)(raw_data(fb)),
        c.int(fb_w * 4),
        c.int(content_x), c.int(content_y),
        c.int(content_w), c.int(content_h),
    )
}
