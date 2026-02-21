# Edge container generator for LVGL
# Generates Odin code for a single edge (top/bottom/left/right)
{ container
, orientation ? "horizontal"
, widgetsDir ? ./Widgets
, theme ? {}
}:
let
  lib = builtins;
  colors = theme.colors or {};
  edgeBg = colors.bg_prim or "282b30";

  # Import widget by name: "back" → Widgets/back.nix
  # Widgets return { callbacks, render }, we extract render
  renderWidget = name:
    let widget = import (widgetsDir + "/${name}.nix");
    in (widget { inherit orientation; }).render;

  # Render a list of widgets
  renderZone = widgetList:
    let renders = map renderWidget widgetList;
    in lib.concatStringsSep "\n" renders;

  # Size property and value based on orientation
  sizeProp = if orientation == "horizontal" then "height" else "width";
  sizeValue = if orientation == "horizontal"
              then container.height or 40
              else container.width or 40;

  # Flex direction
  flexFlow = if orientation == "horizontal"
             then ".LV_FLEX_FLOW_ROW"
             else ".LV_FLEX_FLOW_COLUMN";

  # Zone keys differ by orientation
  startZone = if orientation == "horizontal"
              then container.left or []
              else container.top or [];
  centerZone = container.center or [];
  endZone = if orientation == "horizontal"
            then container.right or []
            else container.bottom or [];

  hasStart = startZone != [];
  hasCenter = centerZone != [];
  hasEnd = endZone != [];

  # Generate spacer (flex_grow object)
  spacer = ''
        {
            spacer := lv_obj_create(edge_container)
            lv_obj_set_height(spacer, lv_pct(100))
            lv_obj_set_flex_grow(spacer, 1)
        }'';

in
''
    // Edge container (${orientation})
    {
        edge_container := lv_obj_create(parent)
        lv_obj_set_width(edge_container, ${if orientation == "horizontal" then "lv_pct(100)" else toString sizeValue})
        lv_obj_set_height(edge_container, ${if orientation == "horizontal" then toString sizeValue else "lv_pct(100)"})
        lv_obj_set_flex_flow(edge_container, ${flexFlow})
        lv_obj_set_flex_align(edge_container, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)
        lv_obj_set_style_pad_left(edge_container, 10, 0)
        lv_obj_set_style_pad_right(edge_container, 10, 0)
        lv_obj_set_style_pad_column(edge_container, 10, 0)
        lv_obj_set_style_bg_color(edge_container, lv_color_hex(0x${edgeBg}), 0)
        lv_obj_set_style_bg_opa(edge_container, LV_OPA_COVER, 0)
        lv_obj_remove_flag(edge_container, .LV_OBJ_FLAG_SCROLLABLE)

${if hasStart then renderZone startZone else ""}
${spacer}
${if hasCenter then renderZone centerZone else ""}
${spacer}
${if hasEnd then renderZone endZone else ""}
    }''
