# Menu button
{ orientation ? "horizontal" }:
import ./button.nix {
  inherit orientation;
  symbol = "BARS";
  callbackName = "on_open_menu";
  callbackImpl = ''
    on_open_menu :: proc "c" (e: ^lv_event_t) {
        context = runtime.default_context()
        // TODO: implement menu panel
    }
  '';
}
