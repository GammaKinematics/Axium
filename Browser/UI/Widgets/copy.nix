# Copy URL button
{ orientation ? "horizontal" }:
import ./button.nix {
  inherit orientation;
  symbol = "COPY";
  callbackName = "on_copy_url";
  callbackImpl = ''
    on_copy_url :: proc "c" (e: ^lvgl.lv_event_t) {
        context = {}
        fmt.println("Copy URL")
    }
  '';
}
