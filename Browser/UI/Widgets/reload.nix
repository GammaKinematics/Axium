# Reload page button
{ orientation ? "horizontal" }:
import ./button.nix {
  inherit orientation;
  symbol = "REFRESH";
  callbackName = "on_reload_page";
  callbackImpl = ''
    on_reload_page :: proc "c" (e: ^lvgl.lv_event_t) {
        context = {}
        fmt.println("Reload page")
    }
  '';
}
