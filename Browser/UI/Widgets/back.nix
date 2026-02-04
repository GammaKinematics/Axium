# Back navigation button
{ orientation ? "horizontal" }:
import ./button.nix {
  inherit orientation;
  symbol = "LEFT";
  callbackName = "on_navigate_back";
  callbackImpl = ''
    on_navigate_back :: proc "c" (e: ^lvgl.lv_event_t) {
        context = {}
        fmt.println("Navigate back")
    }
  '';
}
