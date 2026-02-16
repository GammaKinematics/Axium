{ pkgs, webkit,
  # Compiler optimizations
  optimize ? false,        # -O3 (disabled for debug build)
  lto ? false,             # -flto (warning: very slow for WebKit)
  march ? null,            # "native", "x86-64-v3", etc.
  fastMath ? false,        # -ffast-math
}:

let
  optFlags = pkgs.lib.optionals optimize [ "-O3" ]
    ++ pkgs.lib.optionals (march != null) [ "-march=${march}" ]
    ++ pkgs.lib.optionals fastMath [ "-ffast-math" ]
    ++ pkgs.lib.optionals lto [ "-flto" ];
  optFlagsStr = builtins.concatStringsSep " " optFlags;
in

pkgs.stdenv.mkDerivation {
  pname = "axium-engine";
  version = "2.53.0";

  src = webkit;

  nativeBuildInputs = with pkgs; [
    cmake
    ninja
    pkg-config
    perl
    python3
    ruby
    gperf
    unifdef
    glib
    wayland-scanner
  ];

  buildInputs = with pkgs; [
    # Core (from OptionsWPE.cmake)
    glib
    harfbuzzFull
    icu
    libjpeg
    libepoxy
    libgcrypt
    libgpg-error
    libsoup_3
    libtasn1
    libxkbcommon
    libxml2
    libpng
    sqlite
    zlib
    libwebp

    # GStreamer
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad

    # Wayland (WPE Platform Wayland backend)
    wayland
    wayland-protocols

    # DRM/GBM (WPE Platform DRM backend + GPU buffer export)
    libdrm
    mesa
    libgbm
    libinput
    udev

    # Sandbox
    bubblewrap
    libseccomp
    xdg-dbus-proxy

    # Required by glib's pkg-config
    sysprof

    # Graphics
    libGL
    freetype
    fontconfig

    # X11/XCB
    xorg.libX11
    xorg.libxcb
    xorg.libXext

    # Image formats
    libavif
    libjxl
    lcms2

    # Misc
    libxslt
    woff2
    at-spi2-atk
    atk
    hyphen
    libbacktrace
    libsecret
  ];

  env = pkgs.lib.optionalAttrs (optFlagsStr != "") {
    NIX_CFLAGS_COMPILE = optFlagsStr;
  };

  cmakeFlags = [
    "-DPORT=WPE"
    "-DCMAKE_BUILD_TYPE=RelWithDebInfo"
    "-DENABLE_ASSERTS=ON"

    # WPE2 Platform API only (no legacy)
    "-DENABLE_WPE_PLATFORM=ON"
    "-DENABLE_WPE_PLATFORM_DRM=ON"
    "-DENABLE_WPE_PLATFORM_HEADLESS=ON"
    "-DENABLE_WPE_PLATFORM_WAYLAND=ON"
    "-DENABLE_WPE_LEGACY_API=OFF"

    # Disable everything we don't need
    "-DENABLE_GAMEPAD=OFF"
    "-DENABLE_MEDIA_STREAM=OFF"
    "-DENABLE_WEB_RTC=OFF"
    "-DENABLE_NOTIFICATIONS=OFF"
    "-DENABLE_SPEECH_SYNTHESIS=OFF"
    "-DENABLE_WEBXR=OFF"
    "-DENABLE_DOCUMENTATION=OFF"
    "-DENABLE_INTROSPECTION=OFF"
    "-DENABLE_WPE_QT_API=OFF"
    "-DENABLE_MINIBROWSER=OFF"
    "-DENABLE_API_TESTS=OFF"
    "-DENABLE_LAYOUT_TESTS=OFF"
    "-DENABLE_WEBDRIVER=OFF"
    "-DENABLE_BUBBLEWRAP_SANDBOX=ON"
    "-DENABLE_JOURNALD_LOG=OFF"
    "-DUSE_SYSPROF_CAPTURE=OFF"
  ];

  enableParallelBuilding = true;

  meta = {
    description = "Axium Engine - WebKit WPE2 web engine";
    homepage = "https://wpewebkit.org/";
    license = pkgs.lib.licenses.lgpl21Plus;
    platforms = [ "x86_64-linux" ];
  };
}
