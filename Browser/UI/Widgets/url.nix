# URL input widget for LVGL
{ orientation ? "horizontal" }:
{
  callbacks = {
    on_url_submit = {
      event = "LV_EVENT_READY";
      impl = ''
        on_url_submit :: proc "c" (e: ^lv_event_t) {
            context = runtime.default_context()
            text := lv_textarea_get_text(url_input)
            if text != nil {
                engine_load_uri(text)
                content_has_focus = true
            }
        }
      '';
    };
    on_url_focus = {
      event = "LV_EVENT_FOCUSED";
      impl = ''
        on_url_focus :: proc "c" (e: ^lv_event_t) {
            context = runtime.default_context()
            content_has_focus = false
        }
      '';
    };
  };

  render = ''
        // URL bar
        {
            url_bar := lv_textarea_create(edge_container)
            lv_obj_set_flex_grow(url_bar, 1)
            lv_textarea_set_one_line(url_bar, true)
            lv_textarea_set_placeholder_text(url_bar, "Enter URL...")
            lv_obj_add_event_cb(url_bar, on_url_submit, .LV_EVENT_READY, nil)
            lv_obj_add_event_cb(url_bar, on_url_focus, .LV_EVENT_FOCUSED, nil)
            lv_group_add_obj(keyboard_group, url_bar)
            url_input = url_bar
        }'';
}
