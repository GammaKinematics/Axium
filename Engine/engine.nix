{ pkgs, webkit, pages,
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

  webkitEngine = pkgs.stdenv.mkDerivation {
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
    ];

    buildInputs = with pkgs; [
      # Core
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

      # GStreamer (video/audio playback)
      gst_all_1.gstreamer
      gst_all_1.gst-plugins-base
      gst_all_1.gst-plugins-good
      gst_all_1.gst-plugins-bad

      # Graphics (mesa for EGL — required by WPE2 platform API)
      mesa
      libdrm          # drm_fourcc.h pixel format constants (used by DMA-BUF code paths)
      libgbm          # GBM — AcceleratedSurface.cpp assumes USE(GBM) unconditionally
      freetype
      fontconfig
      expat

      # Misc
      libbacktrace
      libsecret
    ];

    env = {
      NIX_CFLAGS_COMPILE = pkgs.lib.concatStringsSep " " optFlags;
    };

    cmakeFlags = [
      "-DPORT=WPE"
      "-DCMAKE_BUILD_TYPE=Release"

      # WPE2 platform base classes only — no built-in backends.
      # Axium provides its own WPEDisplay/View/Toplevel via engine.c
      # and renders to a framebuffer through Display-Onix (X11).
      "-DENABLE_WPE_PLATFORM=ON"
      "-DENABLE_WPE_PLATFORM_DRM=OFF"
      "-DENABLE_WPE_PLATFORM_HEADLESS=OFF"
      "-DENABLE_WPE_PLATFORM_WAYLAND=OFF"
      "-DENABLE_WPE_LEGACY_API=OFF"

      # No GPU process — we force the SHM pixel path
      "-DENABLE_GPU_PROCESS=OFF"

      # Media — keep video/audio (required by Quirks.cpp, useful anyway)
      "-DENABLE_MEDIA_STREAM=OFF"
      "-DENABLE_MEDIA_RECORDER=OFF"
      "-DENABLE_ENCRYPTED_MEDIA=OFF"
      "-DENABLE_WEB_CODECS=OFF"

      # Graphics features
      "-DENABLE_WEBGL=OFF"

      # Web APIs not needed
      "-DENABLE_GAMEPAD=OFF"
      "-DENABLE_WEB_RTC=OFF"
      "-DENABLE_NOTIFICATIONS=OFF"
      "-DENABLE_SPEECH_SYNTHESIS=OFF"
      "-DENABLE_WEBXR=OFF"
      "-DENABLE_TOUCH_EVENTS=OFF"
      "-DENABLE_GEOLOCATION=OFF"
      # "-DENABLE_FULLSCREEN_API=OFF"
      "-DENABLE_REMOTE_INSPECTOR=OFF"
      "-DENABLE_CONTENT_EXTENSIONS=OFF"
      # CONTEXT_MENUS must stay ON — MediaControlsHost.cpp has unguarded
      # return type mismatch when disabled.
      # "-DENABLE_CONTEXT_MENUS=OFF"
      "-DENABLE_DRAG_SUPPORT=OFF"
      "-DENABLE_MATHML=OFF"

      # UI/rendering features
      "-DENABLE_ASYNC_SCROLLING=OFF"
      "-DENABLE_SMOOTH_SCROLLING=OFF"
      "-DENABLE_AUTOCAPITALIZE=OFF"
      # "-DENABLE_VARIATION_FONTS=OFF"
      # "-DENABLE_DARK_MODE_CSS=OFF"
      "-DENABLE_CURSOR_VISIBILITY=OFF"
      "-DENABLE_MOUSE_CURSOR_SCALE=OFF"
      "-DENABLE_OFFSCREEN_CANVAS=OFF"
      "-DENABLE_OFFSCREEN_CANVAS_IN_WORKERS=OFF"
      "-DENABLE_MHTML=OFF"
      "-DENABLE_PDFJS=OFF"
      "-DENABLE_XSLT=OFF"

      # Build/test/tooling
      "-DENABLE_DOCUMENTATION=OFF"
      "-DENABLE_INTROSPECTION=OFF"
      "-DENABLE_WPE_QT_API=OFF"
      "-DENABLE_MINIBROWSER=OFF"
      "-DENABLE_API_TESTS=OFF"
      "-DENABLE_LAYOUT_TESTS=OFF"
      "-DENABLE_WEBDRIVER=OFF"
      "-DENABLE_JOURNALD_LOG=OFF"

      # USE_ flags
      "-DUSE_SYSPROF_CAPTURE=OFF"
      "-DUSE_AVIF=OFF"
      "-DUSE_JPEGXL=OFF"
      "-DUSE_LCMS=OFF"
      "-DUSE_WOFF2=OFF"
      "-DUSE_LIBHYPHEN=OFF"
      "-DUSE_ATK=OFF"
      # GBM/LIBDRM must stay ON — AcceleratedSurface.cpp and AcceleratedBackingStore.cpp
      # assume USE(GBM) and USE(LIBDRM) unconditionally. Only used at compile time;
      # engine.c forces SHM at runtime.
      # "-DUSE_GBM=OFF"
      "-DUSE_SKIA_OPENTYPE_SVG=OFF"

      "-DENABLE_BUBBLEWRAP_SANDBOX=OFF"
    ];

    enableParallelBuilding = true;

    meta = {
      description = "Axium Engine - WebKit WPE2 web engine";
      homepage = "https://wpewebkit.org/";
      license = pkgs.lib.licenses.lgpl21Plus;
      platforms = [ "x86_64-linux" ];
    };
  };

  shim = pkgs.stdenv.mkDerivation {
    pname = "axium-engine-shim";
    version = "0.1.0";

    src = ./.;

    nativeBuildInputs = [ pkgs.pkg-config ];

    buildInputs = [
      webkitEngine
      pkgs.glib
      pkgs.libsoup_3
      pkgs.libxkbcommon
      pkgs.sqlite
    ];

    buildPhase = ''
      cc -c engine.c -o engine.o \
        -I${pages}/include \
        $(pkg-config --cflags wpe-webkit-2.0 wpe-platform-2.0 glib-2.0 gobject-2.0 sqlite3)
      ar rcs libengine.a engine.o
    '';

    installPhase = ''
      mkdir -p $out/lib
      cp libengine.a $out/lib/
    '';

    meta = {
      description = "Axium Engine Shim - WPE2 platform implementation";
      platforms = [ "x86_64-linux" ];
    };
  };

  odinBindings = ./engine.odin;

in {
  webkit = webkitEngine;
  inherit shim odinBindings pages;
}
