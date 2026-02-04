# Menu button
{ orientation ? "horizontal" }:
import ./button.nix {
  inherit orientation;
  symbol = "BARS";
  callbackName = "on_open_menu";
  callbackImpl = ''
    on_open_menu :: proc "c" (e: ^lvgl.lv_event_t) {
        context = {}
        fmt.println("Open menu")
    }
  '';
}
