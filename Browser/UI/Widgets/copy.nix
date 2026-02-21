# Copy URL button
{ orientation ? "horizontal" }:
import ./button.nix {
  inherit orientation;
  symbol = "COPY";
  callbackName = "on_copy_url";
  callbackImpl = ''
    on_copy_url :: proc "c" (e: ^lv_event_t) {
        context = runtime.default_context()
        execute_command("copy")
    }
  '';
}
