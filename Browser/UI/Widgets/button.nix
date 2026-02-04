# Generic button widget template for LVGL
# Generates Odin code that creates an LVGL button
{ symbol         # Symbol name, e.g. "LEFT", "RIGHT", "REFRESH"
, callbackName   # Callback name, e.g. "on_navigate_back"
, callbackImpl   # Callback implementation (Odin code)
, orientation ? "horizontal"
}:
{
  callbacks = {
    ${callbackName} = {
      event = "LV_EVENT_CLICKED";
      impl = callbackImpl;
    };
  };

  render = ''
        // Button: ${symbol}
        {
            btn := lvgl.lv_button_create(edge_container)
            lvgl.lv_obj_add_event_cb(btn, ${callbackName}, .LV_EVENT_CLICKED, nil)
            lbl := lvgl.lv_label_create(btn)
            lvgl.lv_label_set_text(lbl, lvgl.LV_SYMBOL_${symbol})
            lvgl.lv_obj_center(lbl)
        }'';
}
