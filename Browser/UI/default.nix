# Default UI layout configuration for Axium Browser
{
  # Navigation bar at top
  top = [
    {
      height = 40;
      overlay = false;
      show = "always";  # or { hover = 5; } for hover trigger
      left = [ "back" "forward" "reload" ];
      center = [ "url" "copy" ];
      right = [ "menu" ];
    }
  ];

  # No bottom bar by default
  bottom = [];

  # No side panels by default
  left = [];
  right = [];
}
