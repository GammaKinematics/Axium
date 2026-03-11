package axium

import "base:runtime"
import "core:c"
import "core:strings"

// --- Tab entry: per-tab data structure (source of truth) ---

Tab_Entry :: struct {
    view:      rawptr,        // opaque WebKitWebView* from engine
    btn:       ^lv_obj_t,    // tab button widget
    title_lbl: ^lv_obj_t,    // title label inside btn
    close_btn: ^lv_obj_t,    // close button inside btn
    eph_lbl:   ^lv_obj_t,    // incognito icon (nil if not ephemeral)
    separator: ^lv_obj_t,    // separator to the RIGHT of this tab
    title:     string,        // heap-allocated clone (empty = no title yet)
    uri:       string,        // heap-allocated clone (empty = no uri yet)
    ephemeral: bool,
    natural_w: i32,
    display_w: i32,
}

MAX_TABS :: 32
tab_entries: [MAX_TABS]Tab_Entry
tab_count: int = 0
active_tab: int = -1
next_tab_ephemeral: bool = false

// Tab bar container and action widgets
tab_bar_container: ^lv_obj_t
new_tab_btn:  ^lv_obj_t
incog_btn:    ^lv_obj_t
incog_lbl:    ^lv_obj_t

// Tab sizing (computed once at init)
tab_min_title_w: i32
tab_overhead: i32      // per-tab non-title cost (close btn + padding + gaps)
tab_btn_size: i32      // size of a single icon button (+ btn, incognito toggle)
tab_line_h: i32        // single line height for title label

// --- Tab sizing init (call after fonts/theme are ready) ---

tab_init_sizing :: proc() {
    icon_h := icon_font != nil ? lv_font_get_line_height(icon_font) : lv_theme_onix_dpx(14)
    base_h := base_font != nil ? lv_font_get_line_height(base_font) : lv_theme_onix_dpx(14)
    tab_line_h = max(icon_h, base_h)

    tab_min_title_w = lv_theme_onix_dpx(20)

    // Per-tab overhead: DPI-scaled padding (left+right) + 2 column gaps + close btn (icon_h + padding * 2)
    pad := lv_theme_onix_dpx(theme_padding)
    gap := lv_theme_onix_dpx(theme_gap)
    tab_overhead = pad * 2 + gap * 2 + icon_h + pad * 2

    // Icon button size: icon + DPI-scaled padding * 2 (from btn style)
    tab_btn_size = icon_h + pad * 2
}

// --- String ownership helpers (all stored strings are heap clones) ---

tab_set_title :: proc(idx: int, s: string) {
    e := &tab_entries[idx]
    if len(e.title) > 0 do delete(e.title)
    e.title = strings.clone(s) if len(s) > 0 else ""
}

tab_set_uri :: proc(idx: int, s: string) {
    e := &tab_entries[idx]
    if len(e.uri) > 0 do delete(e.uri)
    e.uri = strings.clone(s) if len(s) > 0 else ""
}

// Display text for a tab: prefer title, fall back to URI, then "New Tab"
tab_display_text :: proc(e: ^Tab_Entry) -> string {
    if len(e.title) > 0 do return e.title
    if len(e.uri) > 0 do return e.uri
    return "New Tab"
}

// --- Public API ---

tab_new :: proc(ephemeral: bool = false) {
    if tab_count >= MAX_TABS do return
    eph := ephemeral || next_tab_ephemeral
    view := engine_create_view(content_area.w, content_area.h, eph, nil)
    if view == nil do return

    idx := tab_count
    tab_entries[idx] = Tab_Entry{
        view      = view,
        ephemeral = eph,
    }
    tab_count += 1

    tab_bar_add(idx)
    tab_switch(idx)
}

tab_close :: proc(idx: int) {
    if idx < 0 || idx >= tab_count do return

    // Closing last tab — exit browser
    if tab_count == 1 {
        closed = true
        return
    }

    // Free owned strings
    e := &tab_entries[idx]
    if len(e.title) > 0 do delete(e.title)
    if len(e.uri) > 0 do delete(e.uri)

    // Remove LVGL widgets
    tab_bar_remove(idx)

    // Destroy engine view
    engine_destroy_view(e.view)

    // Compact tab_entries array
    for i in idx..<tab_count - 1 {
        tab_entries[i] = tab_entries[i + 1]
    }
    tab_count -= 1
    tab_entries[tab_count] = {}

    // Reindex user data on remaining buttons and recalculate widths
    tab_bar_reindex(idx)
    tab_bar_refresh_widths()

    // Pick neighbor tab
    new_active: int
    if idx >= tab_count {
        new_active = tab_count - 1
    } else {
        new_active = idx
    }

    // Adjust active_tab before tab_switch since the active entry may have shifted
    if active_tab == idx {
        active_tab = -1  // force tab_switch to apply highlight
    } else if active_tab > idx {
        active_tab -= 1
    }

    tab_switch(new_active)
}

tab_switch :: proc(idx: int) {
    if idx < 0 || idx >= tab_count do return
    old := active_tab
    active_tab = idx
    engine_set_active_view(tab_entries[idx].view)

    // Update tab bar highlight
    tab_bar_set_active(old, idx)

    // Update URL bar and display title from cached entry
    e := &tab_entries[idx]
    if url_input != nil {
        lv_textarea_set_text(url_input,
            strings.clone_to_cstring(e.uri, context.temp_allocator) if len(e.uri) > 0 else "")
    }
    if len(e.title) > 0 {
        display_set_title(e.title)
    }
    if len(e.uri) > 0 {
        translate_on_navigation(e.uri)
        favorite_on_navigation(e.uri)
        site_settings_update_icon(e.uri)
    }
}

tab_next :: proc() {
    if tab_count <= 1 do return
    tab_switch((active_tab + 1) %% tab_count)
}

tab_prev :: proc() {
    if tab_count <= 1 do return
    tab_switch((active_tab - 1 + tab_count) %% tab_count)
}

// --- Engine callbacks (dispatched from engine.odin) ---

// Find tab index by view pointer (-1 if not found)
@(private="file")
tab_find_view :: proc(view: rawptr) -> int {
    for i in 0..<tab_count {
        if tab_entries[i].view == view do return i
    }
    return -1
}

@(export)
tab_on_uri :: proc "c" (view: rawptr, c_uri: cstring) -> Engine_Nav_Response {
    context = runtime.default_context()
    uri := string(c_uri) if c_uri != nil else ""
    idx := tab_find_view(view)
    if idx < 0 do return {}
    tab_set_uri(idx, uri)
    if idx == active_tab {
        if url_input != nil {
            lv_textarea_set_text(url_input,
                strings.clone_to_cstring(uri, context.temp_allocator) if len(uri) > 0 else "")
        }
        if len(uri) > 0 {
            translate_on_navigation(uri)
            favorite_on_navigation(uri)
            site_settings_update_icon(uri)
        }
    }
    if len(uri) > 0 {
        return pack_nav_response(uri)
    }
    return {}
}

@(export)
tab_on_title :: proc "c" (view: rawptr, c_title: cstring) {
    context = runtime.default_context()
    title := string(c_title) if c_title != nil else ""
    idx := tab_find_view(view)
    if idx < 0 do return
    tab_set_title(idx, title)

    e := &tab_entries[idx]

    // Update LVGL label text
    if e.title_lbl != nil {
        display_text := tab_display_text(e)
        lv_label_set_text(e.title_lbl,
            strings.clone_to_cstring(display_text, context.temp_allocator))
    }

    // Refresh widths since natural width may have changed
    tab_bar_refresh_widths()

    // Update window title if this is the active tab
    if idx == active_tab && len(title) > 0 {
        display_set_title(title)
    }
}

// --- Tab bar widget factory (registered as "tabs") ---

widget_tabs :: proc(parent: ^lv_obj_t) {
    container := lv_obj_create(parent)
    lv_obj_set_height(container, LV_SIZE_CONTENT)
    lv_obj_set_flex_grow(container, 1)
    lv_obj_set_flex_flow(container, .LV_FLEX_FLOW_ROW)
    lv_obj_set_flex_align(container, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
    lv_obj_set_style_pad_top(container, 0, 0)
    lv_obj_set_style_pad_bottom(container, 0, 0)
    lv_obj_set_style_pad_left(container, 0, 0)
    lv_obj_set_style_pad_right(container, 0, 0)
    lv_obj_set_style_pad_column(container, 0, 0)
    lv_obj_set_scrollbar_mode(container, .LV_SCROLLBAR_MODE_OFF)
    lv_obj_set_style_bg_opa(container, LV_OPA_TRANSP, 0)
    lv_obj_set_style_border_width(container, 0, 0)
    lv_obj_set_style_radius(container, 0, 0)
    tab_bar_container = container
    tab_bar_build_all()
}

// --- Internal: create widgets for a single tab entry ---

@(private="file")
tab_bar_create_tab :: proc(idx: int) {
    e := &tab_entries[idx]

    // Tab button
    btn := lv_button_create(tab_bar_container)
    lv_obj_set_height(btn, LV_SIZE_CONTENT)
    lv_obj_set_flex_flow(btn, .LV_FLEX_FLOW_ROW)
    lv_obj_set_flex_align(btn, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
    lv_obj_set_style_radius(btn, 0, 0)
    lv_obj_set_user_data(btn, rawptr(uintptr(idx)))
    lv_obj_add_event_cb(btn, on_tab_click, .LV_EVENT_CLICKED, nil)
    e.btn = btn

    // Active tab highlight
    if idx == active_tab {
        lv_obj_set_style_bg_color(btn, lv_color_hex(theme_accent), 0)
        lv_obj_set_style_bg_opa(btn, u8(theme_bg_opacity), 0)
        lv_obj_set_style_blend_mode(btn, LV_BLEND_MODE_REPLACE, 0)
    }

    // Incognito indicator
    if e.ephemeral {
        eph := lv_label_create(btn)
        lv_label_set_text(eph, icons[.incognito])
        lv_obj_set_style_text_font(eph, icon_font, 0)
        lv_obj_set_style_text_color(eph, lv_color_hex(theme_text_sec), 0)
        e.eph_lbl = eph
    }

    // Title label
    title_label := lv_label_create(btn)
    lv_obj_set_height(title_label, tab_line_h)
    lv_label_set_long_mode(title_label, .LV_LABEL_LONG_MODE_DOTS)

    display_text := tab_display_text(e)
    lv_label_set_text(title_label,
        strings.clone_to_cstring(display_text, context.temp_allocator))
    e.title_lbl = title_label

    // Close button
    close := lv_button_create(btn)
    lv_obj_add_event_cb(close, on_tab_close_click, .LV_EVENT_CLICKED, nil)
    close_lbl := lv_label_create(close)
    lv_label_set_text(close_lbl, icons[.close])
    lv_obj_set_style_text_font(close_lbl, icon_font, 0)
    lv_obj_center(close_lbl)
    e.close_btn = close

    // Separator to the right of this tab
    sep := lv_obj_create(tab_bar_container)
    lv_obj_set_size(sep, lv_theme_onix_dpx(2), lv_pct(75))
    lv_obj_set_style_bg_color(sep, lv_color_hex(theme_bg_ter), 0)
    lv_obj_set_style_bg_opa(sep, LV_OPA_COVER, 0)
    lv_obj_remove_flag(sep, .LV_OBJ_FLAG_SCROLLABLE)
    e.separator = sep
}

// --- Internal: create action buttons (new tab + incognito) ---

@(private="file")
tab_bar_create_action_btns :: proc() {
    // New tab button
    nb := lv_button_create(tab_bar_container)
    lv_obj_add_event_cb(nb, on_new_tab_click, .LV_EVENT_CLICKED, nil)
    new_lbl := lv_label_create(nb)
    lv_label_set_text(new_lbl, icons[.add])
    lv_obj_set_style_text_font(new_lbl, icon_font, 0)
    lv_obj_center(new_lbl)
    new_tab_btn = nb

    // Incognito toggle
    ib := lv_button_create(tab_bar_container)
    lv_obj_add_event_cb(ib, on_incognito_toggle, .LV_EVENT_CLICKED, nil)
    il := lv_label_create(ib)
    lv_label_set_text(il, icons[.incognito])
    lv_obj_set_style_text_font(il, icon_font, 0)
    if next_tab_ephemeral {
        lv_obj_set_style_text_color(il, lv_color_hex(theme_accent), 0)
    }
    lv_obj_center(il)
    incog_btn = ib
    incog_lbl = il
}

// --- Internal: full build from tab_entries (init / rebuild) ---

tab_bar_build_all :: proc() {
    if tab_bar_container == nil do return
    lv_obj_clean(tab_bar_container)

    for i in 0..<tab_count {
        tab_bar_create_tab(i)
    }
    tab_bar_create_action_btns()
    tab_bar_refresh_widths()
}

// --- Internal: add a single tab at the end ---

tab_bar_add :: proc(idx: int) {
    if tab_bar_container == nil do return

    // Delete action buttons so new tab appears before them
    if new_tab_btn != nil {
        lv_obj_delete(new_tab_btn)
        new_tab_btn = nil
    }
    if incog_btn != nil {
        lv_obj_delete(incog_btn)
        incog_btn = nil
        incog_lbl = nil
    }

    tab_bar_create_tab(idx)
    tab_bar_create_action_btns()
    tab_bar_refresh_widths()
}

// --- Internal: remove a single tab's widgets ---

tab_bar_remove :: proc(idx: int) {
    e := &tab_entries[idx]
    if e.separator != nil {
        lv_obj_delete(e.separator)
        e.separator = nil
    }
    if e.btn != nil {
        lv_obj_delete(e.btn)
        e.btn = nil
    }
}

// --- Internal: update active tab highlight ---

tab_bar_set_active :: proc(old_idx, new_idx: int) {
    if tab_bar_container == nil do return

    // Remove highlight from old tab
    if old_idx >= 0 && old_idx < tab_count {
        old_btn := tab_entries[old_idx].btn
        if old_btn != nil {
            lv_obj_set_style_bg_opa(old_btn, LV_OPA_TRANSP, 0)
        }
    }

    // Apply highlight to new tab
    if new_idx >= 0 && new_idx < tab_count {
        new_btn := tab_entries[new_idx].btn
        if new_btn != nil {
            lv_obj_set_style_bg_color(new_btn, lv_color_hex(theme_accent), 0)
            lv_obj_set_style_bg_opa(new_btn, u8(theme_bg_opacity), 0)
            lv_obj_set_style_blend_mode(new_btn, LV_BLEND_MODE_REPLACE, 0)
        }
    }
}

// --- Internal: water-fill width distribution ---

tab_bar_refresh_widths :: proc() {
    if tab_bar_container == nil || tab_count == 0 do return

    container_w := lv_obj_get_content_width(tab_bar_container)
    if container_w <= 0 do return

    sep_w := lv_theme_onix_dpx(2)
    // Fixed costs: action buttons (new + incognito) + one separator per tab
    fixed := tab_btn_size * 2 + sep_w * i32(tab_count)
    available := container_w - fixed

    // Measure natural widths
    for i in 0..<tab_count {
        e := &tab_entries[i]
        if e.title_lbl == nil do continue
        // Temporarily set to content size to measure natural width
        lv_obj_set_width(e.title_lbl, LV_SIZE_CONTENT)
        e.natural_w = lv_obj_get_self_width(e.title_lbl)
    }

    // Water-fill algorithm
    settled := [MAX_TABS]bool{}
    remaining := available
    remaining_count := i32(tab_count)

    for {
        if remaining_count <= 0 do break
        fair_share := (remaining - remaining_count * tab_overhead) / remaining_count
        if fair_share < tab_min_title_w do fair_share = tab_min_title_w

        changed := false
        for i in 0..<tab_count {
            if settled[i] do continue
            e := &tab_entries[i]
            natural := max(e.natural_w, tab_min_title_w)
            if natural <= fair_share {
                e.display_w = natural
                settled[i] = true
                remaining -= natural + tab_overhead
                remaining_count -= 1
                changed = true
            }
        }
        if !changed {
            // Remaining unsettled tabs all get fair_share
            for i in 0..<tab_count {
                if settled[i] do continue
                tab_entries[i].display_w = max(fair_share, tab_min_title_w)
            }
            break
        }
    }

    // Apply widths
    for i in 0..<tab_count {
        e := &tab_entries[i]
        if e.title_lbl != nil {
            lv_obj_set_width(e.title_lbl, e.display_w)
        }
    }
}

// --- Internal: reindex user data on buttons after compaction ---

tab_bar_reindex :: proc(from: int) {
    for i in from..<tab_count {
        e := &tab_entries[i]
        if e.btn != nil {
            lv_obj_set_user_data(e.btn, rawptr(uintptr(i)))
        }
    }
}

// --- Event callbacks ---

on_tab_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    target := (^lv_obj_t)(lv_event_get_target(e))
    idx := int(uintptr(lv_obj_get_user_data(target)))
    tab_switch(idx)
}

on_tab_close_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    lv_event_stop_bubbling(e)
    target := (^lv_obj_t)(lv_event_get_target(e))
    parent := lv_obj_get_parent(target)
    idx := int(uintptr(lv_obj_get_user_data(parent)))
    tab_close(idx)
}

on_new_tab_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    tab_new()
}

on_incognito_toggle :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    next_tab_ephemeral = !next_tab_ephemeral
    if incog_lbl != nil {
        if next_tab_ephemeral {
            lv_obj_set_style_text_color(incog_lbl, lv_color_hex(theme_accent), 0)
        } else {
            lv_obj_set_style_text_color(incog_lbl, lv_color_hex(theme_text_pri), 0)
        }
    }
}
