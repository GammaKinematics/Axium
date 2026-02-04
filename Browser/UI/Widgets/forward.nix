# Forward navigation button
{ orientation ? "horizontal" }:
import ./button.nix {
  inherit orientation;
  symbol = "RIGHT";
  callbackName = "on_navigate_forward";
  callbackImpl = ''
    on_navigate_forward :: proc "c" (e: ^lvgl.lv_event_t) {
        context = {}
        fmt.println("Navigate forward")
    }
  '';
}
