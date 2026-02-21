# Forward navigation button
{ orientation ? "horizontal" }:
import ./button.nix {
  inherit orientation;
  symbol = "RIGHT";
  callbackName = "on_navigate_forward";
  callbackImpl = ''
    on_navigate_forward :: proc "c" (e: ^lv_event_t) {
        context = runtime.default_context()
        execute_command("forward")
    }
  '';
}
