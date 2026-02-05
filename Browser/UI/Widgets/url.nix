# URL input widget for LVGL
{ orientation ? "horizontal" }:
{
  callbacks = {
    on_url_submit = {
      event = "LV_EVENT_READY";
      impl = ''
        on_url_submit :: proc "c" (e: ^lvgl.lv_event_t) {
            context = {}
            fmt.println("URL submitted")
        }
      '';
    };
    on_url_focus = {
      event = "LV_EVENT_FOCUSED";
      impl = ''
        on_url_focus :: proc "c" (e: ^lvgl.lv_event_t) {
            context = {}
            fmt.println("URL bar focused")
        }
      '';
    };
  };

  render = ''
        // URL bar
        {
            url_bar := lvgl.lv_textarea_create(edge_container)
            lvgl.lv_obj_set_flex_grow(url_bar, 1)
            lvgl.lv_textarea_set_one_line(url_bar, true)
            lvgl.lv_textarea_set_placeholder_text(url_bar, "Enter URL...")
            lvgl.lv_obj_add_event_cb(url_bar, on_url_submit, .LV_EVENT_READY, nil)
            lvgl.lv_obj_add_event_cb(url_bar, on_url_focus, .LV_EVENT_FOCUSED, nil)
            lvgl.lv_group_add_obj(keyboard_group, url_bar)
            state.url_input = url_bar
        }'';
}
