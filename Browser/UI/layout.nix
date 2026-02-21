# Layout generator for LVGL
# Only generates the build_ui proc body - ui.nix handles assembly
{ ui
, widgetsDir ? ./Widgets
, theme ? {}
}:
let
  lib = builtins;
  edge = import ./edge.nix;

  # Edge data
  topContainers = ui.top or [];
  bottomContainers = ui.bottom or [];
  leftContainers = ui.left or [];
  rightContainers = ui.right or [];

  hasTop = topContainers != [];
  hasBottom = bottomContainers != [];
  hasLeft = leftContainers != [];
  hasRight = rightContainers != [];

  # Render edges
  renderEdge = container: orientation:
    edge { inherit container orientation widgetsDir theme; };

  topEdges = lib.concatStringsSep "\n" (map (c: renderEdge c "horizontal") topContainers);
  bottomEdges = lib.concatStringsSep "\n" (map (c: renderEdge c "horizontal") bottomContainers);
  leftEdges = lib.concatStringsSep "\n" (map (c: renderEdge c "vertical") leftContainers);
  rightEdges = lib.concatStringsSep "\n" (map (c: renderEdge c "vertical") rightContainers);

in
''
    // Main vertical layout
    main_container := lv_obj_create(screen)
    lv_obj_set_size(main_container, lv_pct(100), lv_pct(100))
    lv_obj_set_flex_flow(main_container, .LV_FLEX_FLOW_COLUMN)
    lv_obj_remove_flag(main_container, .LV_OBJ_FLAG_SCROLLABLE)

    parent := main_container

${if hasTop then "    // Top edge\n${topEdges}" else ""}

    // Middle section (left edge + content + right edge)
    middle := lv_obj_create(parent)
    lv_obj_set_width(middle, lv_pct(100))
    lv_obj_set_flex_grow(middle, 1)
    lv_obj_set_flex_flow(middle, .LV_FLEX_FLOW_ROW)
    lv_obj_remove_flag(middle, .LV_OBJ_FLAG_SCROLLABLE)

    {
        parent := middle
${if hasLeft then "        // Left edge\n${leftEdges}" else ""}

        // Content area — web content rendered here by WebKit
        content := lv_obj_create(parent)
        lv_obj_set_height(content, lv_pct(100))
        lv_obj_set_flex_grow(content, 1)
        lv_obj_remove_flag(content, .LV_OBJ_FLAG_SCROLLABLE)
        lv_obj_remove_flag(content, .LV_OBJ_FLAG_CLICKABLE)

        // Store for main.odin to query position/size
        content_area = content

${if hasRight then "        // Right edge\n${rightEdges}" else ""}
    }

${if hasBottom then "    // Bottom edge\n${bottomEdges}" else ""}''
