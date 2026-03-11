package axium

import "base:runtime"
import "core:c"

// ---------------------------------------------------------------------------
// Icons
// ---------------------------------------------------------------------------

// Icon identifiers — names match dotfile keys for automatic override parsing
Icon :: enum {
    back, forward, reload, stop, close, add, menu,
    copy, cut, paste, favorite, download, save,
    settings, keepass, translate, incognito, external,
    link, bold, italic, underline,
    play, pause, mute, fullscreen,
    ban, shuffle, shield, clock,
}

// Default codepoints (FontAwesome)
icons: [Icon]cstring = {
    .back       = "\xef\x81\x93",  // U+F053
    .forward    = "\xef\x81\x94",  // U+F054
    .reload     = "\xef\x80\xa1",  // U+F021
    .stop       = "\xef\x81\x8d",  // U+F04D
    .close      = "\xef\x80\x8d",  // U+F00D
    .add        = "\xef\x81\xa7",  // U+F067
    .menu       = "\xef\x83\x89",  // U+F0C9
    .copy       = "\xef\x83\x85",  // U+F0C5
    .cut        = "\xef\x83\x84",  // U+F0C4
    .paste      = "\xef\x83\xaa",  // U+F0EA
    .favorite   = "\xef\x80\x85",  // U+F005
    .download   = "\xef\x80\x99",  // U+F019
    .save       = "\xef\x83\x87",  // U+F0C7
    .settings   = "\xef\x80\x93",  // U+F013
    .keepass    = "\xef\x82\x84",  // U+F084
    .translate  = "\xef\x86\xab",  // U+F1AB
    .incognito  = "\xef\x9b\xba",  // U+F6FA
    .external   = "\xef\x8d\x9d",  // U+F35D
    .link       = "\xef\x83\x81",  // U+F0C1
    .bold       = "\xef\x80\xb2",  // U+F032
    .italic     = "\xef\x80\xb3",  // U+F033
    .underline  = "\xef\x83\x8d",  // U+F0CD
    .play       = "\xef\x81\x8b",  // U+F04B
    .pause      = "\xef\x81\x8c",  // U+F04C
    .mute       = "\xef\x9a\xa9",  // U+F6A9
    .fullscreen = "\xef\x81\xa5",  // U+F065
    .ban        = "\xef\x81\x9e",  // U+F05E
    .shuffle    = "\xef\x81\xb4",  // U+F074
    .shield     = "\xef\x8f\xad",  // U+F3ED
    .clock      = "\xef\x80\x97",  // U+F017
}

// ---------------------------------------------------------------------------
// Toolbar widgets
// ---------------------------------------------------------------------------

url_input: ^lv_obj_t

widget_back :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_navigate_back, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[.back])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
}

on_navigate_back :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    execute_command("back")
}

widget_forward :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_navigate_forward, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[.forward])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
}

on_navigate_forward :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    execute_command("forward")
}

widget_reload :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_reload_page, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[.reload])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
}

on_reload_page :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    execute_command("reload")
}

widget_url :: proc(parent: ^lv_obj_t) {
    url_bar := lv_textarea_create(parent)
    lv_obj_set_flex_grow(url_bar, 1)
    lv_textarea_set_one_line(url_bar, true)
    lv_textarea_set_placeholder_text(url_bar, "Enter URL...")
    lv_obj_add_event_cb(url_bar, on_url_submit, .LV_EVENT_READY, nil)
    lv_obj_add_event_cb(url_bar, on_url_clicked, .LV_EVENT_CLICKED, nil)
    lv_obj_add_event_cb(url_bar, on_url_leave, .LV_EVENT_HOVER_LEAVE, nil)
    lv_group_add_obj(keyboard_group, url_bar)
    url_input = url_bar
}

widget_copy :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_copy_url, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[.copy])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
}

on_url_submit :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    text := lv_textarea_get_text(url_input)
    if text != nil {
        engine_view_go_to(tab_entries[active_tab].view, text)
        content_has_focus = true
    }
}

url_select_all :: proc() {
    if url_input == nil do return
    ctext := lv_textarea_get_text(url_input)
    if ctext == nil do return
    text := string(ctext)
    if len(text) == 0 do return
    lv_textarea_set_text_selection(url_input, true)
    label := lv_textarea_get_label(url_input)
    lv_label_set_text_selection_start(label, 0)
    lv_label_set_text_selection_end(label, u32(len(text)))
}

on_url_clicked :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    content_has_focus = false
    lv_obj_add_state(url_input, .LV_STATE_FOCUSED)
    url_select_all()
}

on_url_leave :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    if url_input == nil do return
    lv_textarea_clear_selection(url_input)
    lv_obj_remove_state(url_input, .LV_STATE_FOCUSED)
}

on_copy_url :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    execute_command("copy")
}

widget_menu :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_open_menu, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[.menu])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
}

on_open_menu :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    if popup_is_active() { popup_dismiss(); return }

    anchor := (^lv_obj_t)(lv_event_get_target(e))
    panel := lv_obj_create(lv_layer_top())
    lv_obj_set_size(panel, 200, 100)
    lv_obj_set_style_bg_color(panel, lv_color_hex(theme_bg_sec), 0)
    lv_obj_set_style_bg_opa(panel, u8(theme_bg_opacity), 0)
    lv_obj_set_style_radius(panel, theme_radius, 0)
    lv_obj_remove_flag(panel, .LV_OBJ_FLAG_SCROLLABLE)
    lbl := lv_label_create(panel)
    lv_label_set_text(lbl, "Menu placeholder")
    lv_obj_center(lbl)

    popup_show(panel, anchor)
}

widget_keepass :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_keepass_click, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[.keepass])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
    keepass_popup_anchor = btn
}

on_keepass_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    keepass_trigger()
}

widget_translate :: proc(parent: ^lv_obj_t) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_translate_click, .LV_EVENT_CLICKED, nil)
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[.translate])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
    translate_popup_anchor = btn
    translate_icon_label = lbl
}

on_translate_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    translate_trigger()
}

// ---------------------------------------------------------------------------
// Widget registration
// ---------------------------------------------------------------------------

widgets_init :: proc() {
    edge_register_widget("back", widget_back)
    edge_register_widget("forward", widget_forward)
    edge_register_widget("reload", widget_reload)
    edge_register_widget("url", widget_url)
    edge_register_widget("copy", widget_copy)
    edge_register_widget("keepass", widget_keepass)
    edge_register_widget("settings", widget_settings)
    edge_register_widget("translate", widget_translate)
    edge_register_widget("favorites", widget_favorite)
    edge_register_widget("downloads", widget_download)
    edge_register_widget("menu", widget_menu)
    edge_register_widget("tabs", widget_tabs)
}

@(export)
onix_cursor_set :: proc "c" (shape: i32) {
    context = runtime.default_context()
    display_cursor_set(Cursor(shape))
}

// ---------------------------------------------------------------------------
// Context menu
// ---------------------------------------------------------------------------

Ctx_Action :: enum u64 {
    OPEN_LINK_NEW_WINDOW   = 2,
    DOWNLOAD_LINK          = 3,
    COPY_LINK              = 4,
    OPEN_IMAGE_NEW_WINDOW  = 5,
    DOWNLOAD_IMAGE         = 6,
    COPY_IMAGE             = 7,
    BACK                   = 9,
    FORWARD                = 10,
    STOP                   = 11,
    RELOAD                 = 12,
    COPY                   = 13,
    CUT                    = 14,
    PASTE                  = 15,
    BOLD                   = 22,
    ITALIC                 = 23,
    UNDERLINE              = 24,
    OPEN_VIDEO_NEW_WINDOW  = 27,
    OPEN_AUDIO_NEW_WINDOW  = 28,
    COPY_VIDEO_LINK        = 29,
    COPY_AUDIO_LINK        = 30,
    ENTER_VIDEO_FULLSCREEN = 33,
    MEDIA_PLAY             = 34,
    MEDIA_PAUSE            = 35,
    MEDIA_MUTE             = 36,
    DOWNLOAD_VIDEO         = 37,
    DOWNLOAD_AUDIO         = 38,
}

Ctx_Actions :: bit_set[Ctx_Action; u64]

Ctx_Btn :: struct {
    icon:   Icon,
    action: Ctx_Action,
}

ctx_row_link := [?]Ctx_Btn{
    {.external, .OPEN_LINK_NEW_WINDOW},
    {.download, .DOWNLOAD_LINK},
    {.link,     .COPY_LINK},
}

ctx_row_content := [?]Ctx_Btn{
    {.external, .OPEN_IMAGE_NEW_WINDOW},
    {.external, .OPEN_VIDEO_NEW_WINDOW},
    {.external, .OPEN_AUDIO_NEW_WINDOW},
    {.download, .DOWNLOAD_IMAGE},
    {.download, .DOWNLOAD_VIDEO},
    {.download, .DOWNLOAD_AUDIO},
    {.copy,     .COPY_IMAGE},
    {.link,     .COPY_VIDEO_LINK},
    {.link,     .COPY_AUDIO_LINK},
}

ctx_row_media := [?]Ctx_Btn{
    {.play,       .MEDIA_PLAY},
    {.pause,      .MEDIA_PAUSE},
    {.mute,       .MEDIA_MUTE},
    {.fullscreen, .ENTER_VIDEO_FULLSCREEN},
}

ctx_row_edit := [?]Ctx_Btn{
    {.cut,   .CUT},
    {.copy,  .COPY},
    {.paste, .PASTE},
}

ctx_row_text := [?]Ctx_Btn{
    {.bold,      .BOLD},
    {.italic,    .ITALIC},
    {.underline, .UNDERLINE},
}

ctx_row_nav := [?]Ctx_Btn{
    {.back,    .BACK},
    {.forward, .FORWARD},
    {.stop,    .STOP},
    {.reload,  .RELOAD},
}

Ctx_Row :: struct {
    name: string,
    btns: []Ctx_Btn,
}

ctx_rows := [?]Ctx_Row{
    {"link",    ctx_row_link[:]},
    {"content", ctx_row_content[:]},
    {"media",   ctx_row_media[:]},
    {"edit",    ctx_row_edit[:]},
    {"text",    ctx_row_text[:]},
    {"nav",     ctx_row_nav[:]},
}

ctx_menu_layout: []int

@(export)
on_context_menu_event :: proc "c" (actions_raw: c.uint64_t, x: c.int, y: c.int) {
    context = runtime.default_context()
    actions := transmute(Ctx_Actions)u64(actions_raw)
    context_menu_show(actions, i32(x), i32(y))
}

context_menu_show :: proc(actions: Ctx_Actions, sx, sy: i32) {
    if popup_is_active() do popup_dismiss()
    if actions == {} do return

    panel := lv_obj_create(lv_layer_top())
    lv_obj_set_size(panel, LV_SIZE_CONTENT, LV_SIZE_CONTENT)
    lv_obj_set_style_bg_color(panel, lv_color_hex(theme_bg_prim), 0)
    lv_obj_set_style_bg_opa(panel, u8(theme_bg_opacity), 0)
    lv_obj_set_style_text_color(panel, lv_color_hex(theme_text_pri), 0)
    lv_obj_set_style_radius(panel, theme_radius, 0)
    lv_obj_set_style_pad_top(panel, theme_padding, 0)
    lv_obj_set_style_pad_bottom(panel, theme_padding, 0)
    lv_obj_set_style_pad_left(panel, theme_padding, 0)
    lv_obj_set_style_pad_right(panel, theme_padding, 0)
    lv_obj_set_style_pad_row(panel, theme_gap, 0)
    lv_obj_set_style_max_height(panel, 500, 0)
    lv_obj_set_flex_flow(panel, .LV_FLEX_FLOW_COLUMN)
    lv_obj_set_flex_align(panel, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)

    row_count := 0
    for idx in ctx_menu_layout {
        if idx < 0 || idx >= len(ctx_rows) do continue
        row_def := ctx_rows[idx]

        btn_count := 0
        row: ^lv_obj_t
        for btn in row_def.btns {
            if btn.action in actions {
                if btn_count == 0 {
                    if row_count > 0 do ctx_separator(panel)
                    row = ctx_icon_row(panel)
                }
                ctx_icon_btn(row, btn.icon, btn.action)
                btn_count += 1
            }
        }

        if btn_count > 0 do row_count += 1
    }

    if row_count == 0 {
        lv_obj_delete(panel)
        return
    }

    popup_show(panel, x = sx, y = sy)
}

ctx_icon_row :: proc(parent: ^lv_obj_t) -> ^lv_obj_t {
    row := lv_obj_create(parent)
    lv_obj_set_width(row, LV_SIZE_CONTENT)
    lv_obj_set_height(row, LV_SIZE_CONTENT)
    lv_obj_set_flex_flow(row, .LV_FLEX_FLOW_ROW)
    lv_obj_set_flex_align(row, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
    lv_obj_set_style_pad_column(row, theme_gap, 0)
    lv_obj_set_style_pad_top(row, 0, 0)
    lv_obj_set_style_pad_bottom(row, 0, 0)
    lv_obj_set_style_pad_left(row, 0, 0)
    lv_obj_set_style_pad_right(row, 0, 0)
    lv_obj_remove_flag(row, .LV_OBJ_FLAG_SCROLLABLE)
    return row
}

ctx_icon_btn :: proc(parent: ^lv_obj_t, icon: Icon, action: Ctx_Action) {
    btn := lv_button_create(parent)
    lv_obj_add_event_cb(btn, on_ctx_action, .LV_EVENT_CLICKED, rawptr(uintptr(u64(action))))
    lbl := lv_label_create(btn)
    lv_label_set_text(lbl, icons[icon])
    lv_obj_set_style_text_font(lbl, icon_font, 0)
    lv_obj_center(lbl)
}

ctx_separator :: proc(parent: ^lv_obj_t) {
    sep := lv_obj_create(parent)
    lv_obj_set_width(sep, lv_pct(100))
    lv_obj_set_height(sep, 1)
    lv_obj_set_style_bg_color(sep, lv_color_hex(theme_text_sec), 0)
    lv_obj_set_style_bg_opa(sep, 80, 0)
    lv_obj_remove_flag(sep, .LV_OBJ_FLAG_SCROLLABLE)
}

on_ctx_action :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    action := Ctx_Action(uintptr(lv_event_get_user_data(e)))

    if action == .PASTE do clipboard_notify_before_paste()
    engine_context_menu_activate(c.int(action))

    popup_dismiss()
}
