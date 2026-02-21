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
            btn := lv_button_create(edge_container)
            lv_obj_add_event_cb(btn, ${callbackName}, .LV_EVENT_CLICKED, nil)
            lbl := lv_label_create(btn)
            lv_label_set_text(lbl, LV_SYMBOL_${symbol})
            if icon_font != nil { lv_obj_set_style_text_font(lbl, icon_font, 0) }
            lv_obj_center(lbl)
        }'';
}
