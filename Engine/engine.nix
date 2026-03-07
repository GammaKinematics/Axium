{ pkgs, hostPkgs ? pkgs, webkit, pages,
  static_lto ? false,
  gstreamer ? null,  # gstreamer-full static library (required when static_lto)
}:

let
  # WebKit uses stdenvNoLto when static — cmake handles LTO via -DLTO_MODE=thin
  webkitEngine = (if static_lto then pkgs.stdenvNoLto else pkgs.stdenv).mkDerivation {
    pname = "axium-engine";
    version = "2.51.92";

    src = webkit;

    postPatch = ''
      # Axium: disable compositing — force NonCompositedFrameRenderer (Skia CPU).
      # DrawingAreaCoordinatedGraphicsGLib.cpp:enterAcceleratedCompositingModeIfNeeded()
      # checks settings().acceleratedCompositingEnabled() to choose LayerTreeHost vs
      # NonCompositedFrameRenderer. Setting these to false ensures the non-GL path.
      substituteInPlace Source/WebKit/UIProcess/wpe/WebPreferencesWPE.cpp \
        --replace-warn 'setAcceleratedCompositingEnabled(true)' 'setHardwareAccelerationEnabled(false); setAcceleratedCompositingEnabled(false)' \
        --replace-warn 'setForceCompositingMode(true)' 'setForceCompositingMode(false)'

      # Axium: skip ALL EGL/PlatformDisplay init — we run CPU-only.
      # Without this, PlatformDisplaySurfaceless::create() loads Mesa (~75 MB per process).
      # We return immediately so no EGL display is ever created.
      substituteInPlace Source/WebKit/WebProcess/glib/WebProcessGLib.cpp \
        --replace-warn 'if (PlatformDisplay::sharedDisplayIfExists())' 'if (true) // Axium: skip EGL init entirely'

      # Axium: neutralize unguarded DRM_FORMAT_XRGB8888 in AcceleratedBackingStore.cpp.
      # This DMA-BUF branch is dead code for us (we use SHM), but won't compile without libdrm.
      substituteInPlace Source/WebKit/UIProcess/wpe/AcceleratedBackingStore.cpp \
        --replace-warn 'if (wpe_buffer_dma_buf_get_format(dmaBuffer) == DRM_FORMAT_XRGB8888)' 'if (false) // Axium: no LIBDRM, DMA-BUF path unused'

      # Axium: neutralize unguarded memoryMappedGPUBuffer() call — only exists with USE(GBM).
      # isDMABufBackedTexture is already false without GBM, so this is a no-op anyway.
      substituteInPlace Source/WebCore/platform/graphics/skia/SkiaPaintingEngine.cpp \
        --replace-warn 'if (!texture->memoryMappedGPUBuffer())' 'if (false) // Axium: memoryMappedGPUBuffer requires USE(GBM)'
    '' + pkgs.lib.optionalString static_lto ''
      # FindSoup3.cmake: pkg-config version detection fails in cross builds.
      substituteInPlace Source/cmake/FindSoup3.cmake \
        --replace-warn 'set(Soup3_VERSION ''${PC_Soup3_VERSION})' \
          'set(Soup3_VERSION ''${PC_Soup3_VERSION})
if (NOT Soup3_VERSION)
    set(Soup3_VERSION "3.6.5")
endif()'

      # GStreamerChecks.cmake: checks PC_GSTREAMER_FULL_FOUND (pkg-config) which fails
      # in cross builds. Patch to check the actual library variable instead.
      substituteInPlace Source/cmake/GStreamerChecks.cmake \
        --replace-warn 'NOT PC_GSTREAMER_FULL_FOUND' 'NOT GSTREAMER_FULL_LIBRARIES'

      # Axium: static build — produce libWPEWebKit-2.0.a instead of .so.
      # No cmake flag exists for this — WebKit_LIBRARY_TYPE is hardcoded.
      substituteInPlace Source/cmake/WebKitCommon.cmake \
        --replace-warn 'set(WebKit_LIBRARY_TYPE SHARED)' 'set(WebKit_LIBRARY_TYPE STATIC)'

      # Axium: WPE sets internal frameworks (bmalloc, WTF, JSC, WebCore) to OBJECT type
      # so they get folded into libWPEWebKit.so. With STATIC WebKit, the OBJECT→exe
      # propagation through cmake aliases breaks. Change to STATIC so they produce
      # separate .a files that link properly into WPEWebProcess/WPENetworkProcess.
      substituteInPlace Source/cmake/OptionsWPE.cmake \
        --replace-warn 'set(bmalloc_LIBRARY_TYPE OBJECT)' 'set(bmalloc_LIBRARY_TYPE STATIC)' \
        --replace-warn 'set(WTF_LIBRARY_TYPE OBJECT)' 'set(WTF_LIBRARY_TYPE STATIC)' \
        --replace-warn 'set(JavaScriptCore_LIBRARY_TYPE OBJECT)' 'set(JavaScriptCore_LIBRARY_TYPE STATIC)' \
        --replace-warn 'set(WebCore_LIBRARY_TYPE OBJECT)' 'set(WebCore_LIBRARY_TYPE STATIC)'

      # Axium: disable --gc-sections — conflicts with LTO bitcode from deps (glib).
      # LTO does its own dead code elimination, making --gc-sections redundant.
      # Can't use -DLD_SUPPORTS_GC_SECTIONS=OFF — cmake set() shadows cache vars.
      substituteInPlace Source/cmake/OptionsCommon.cmake \
        --replace-warn 'if (LD_SUPPORTS_GC_SECTIONS)' 'if (FALSE) # Axium: LTO handles DCE'

      # Ensure cmake installs the static archive (LIBRARY only covers shared libs).
      substituteInPlace Source/WebKit/CMakeLists.txt \
        --replace-warn \
          'install(TARGETS WebKit WebProcess NetworkProcess' \
          'install(TARGETS WebKit WebProcess NetworkProcess
    ARCHIVE DESTINATION "''${LIB_INSTALL_DIR}"'
    '';

    nativeBuildInputs = with hostPkgs; [
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
      libffi            # transitive dep of gobject (gclosure marshalling)
      harfbuzzFull
      icu
      libjpeg
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

      libepoxy

    ] ++ (if static_lto then [ gstreamer ] else with pkgs; [
      # GStreamer (video/audio playback) — nixpkgs packages for dynamic build
      gst_all_1.gstreamer
      gst_all_1.gst-plugins-base
      gst_all_1.gst-plugins-good
    ]) ++ (with pkgs; [
      # Graphics — Mesa, GBM, DRM removed: compositing disabled, no EGL init at runtime.
      freetype
      fontconfig
      expat
    ]);

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
      "-DENABLE_WEB_AUDIO=OFF"
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
      # ASYNC_SCROLLING must stay ON — ScrollingStateScrollingNodeCoordinated.cpp
      # requires it when USE(COORDINATED_GRAPHICS) is enabled. Dead code at runtime
      # with NonCompositedFrameRenderer.
      # "-DENABLE_ASYNC_SCROLLING=OFF"
      "-DENABLE_AUTOCAPITALIZE=OFF"
      # "-DENABLE_VARIATION_FONTS=OFF"
      # "-DENABLE_DARK_MODE_CSS=OFF"
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
      "-DUSE_GBM=OFF"              # No GBM — compositing disabled, AcceleratedSurface GL path dead
      "-DUSE_LIBDRM=OFF"           # No DRM — only needed with GBM
      "-DUSE_GSTREAMER_GL=OFF"     # No GL in GStreamer video pipeline
      "-DUSE_LIBBACKTRACE=OFF"     # Debug-only backtraces
      "-DUSE_SKIA_OPENTYPE_SVG=OFF"

      "-DENABLE_BUBBLEWRAP_SANDBOX=OFF"
    ] ++ pkgs.lib.optionals static_lto [
      # Thin LTO for WebKit only (too large for full LTO linking).
      # WebKit's cmake adds -flto=thin to C/CXX/linker flags and enables LLD.
      # Requires COMPILER_IS_CLANG (provided by pkgsLto's useLLVM = true).
      # Deps use full LTO via the crossOverlay — compatible with thin here.
      "-DLTO_MODE=thin"
      # CMAKE_EXE_LINKER_FLAGS set via preConfigure (contains spaces)
      # Use monolithic gstreamer-full-1.0 instead of individual gstreamer libs.
      # WebKit cmake has first-class support: links only gstreamer-full-1.0
      # and skips all per-library pkg-config lookups.
      "-DUSE_GSTREAMER_FULL=ON"
      # musl has pthreads in libc — cmake's FindThreads test programs fail
      # due to LTO bitcode, so tell it directly.
      "-DCMAKE_HAVE_LIBC_PTHREAD=ON"
      "-DCMAKE_USE_PTHREADS_INIT=1"
      "-DTHREADS_PREFER_PTHREAD_FLAG=ON"
      # cmake feature-detection (try_compile/check_include_file/check_symbol_exists)
      # fails in cross/LTO builds — test binaries are LLVM bitcode and can't link.
      # WebKit's WEBKIT_CHECK_HAVE_* macros store results in ${VAR}_value cache
      # variables, then SET_AND_EXPOSE_TO_BUILD overwrites any -DVAR=ON we pass.
      # So we must set the _value suffixed variables to skip the checks entirely.
      #
      # Headers present on musl:
      "-DHAVE_FEATURES_H_value=1"       # minimal features.h (no __GLIBC__)
      "-DHAVE_ERRNO_H_value=1"
      "-DHAVE_LANGINFO_H_value=1"
      "-DHAVE_MMAP_value=1"             # sys/mman.h
      "-DHAVE_SYS_PARAM_H_value=1"
      "-DHAVE_SYS_TIME_H_value=1"
      "-DHAVE_LINUX_MEMFD_H_value=1"    # kernel headers
      # Functions present on musl:
      "-DHAVE_LOCALTIME_R_value=1"
      "-DHAVE_STATX_value=1"            # musl 1.2.5+
      "-DHAVE_TIMEGM_value=1"
      "-DHAVE_TIMERFD_value=1"
      "-DHAVE_VASPRINTF_value=1"
      # Symbols present on musl:
      "-DHAVE_REGEX_H_value=1"          # regexec in regex.h
      "-DHAVE_SIGNAL_H_value=1"         # SIGTRAP in signal.h
      # Struct members present on musl:
      "-DHAVE_TM_GMTOFF_value=1"
      "-DHAVE_TM_ZONE_value=1"
      # Not on musl (cmake fail = correct): HAVE_SYS_TIMEB_H, HAVE_PTHREAD_NP_H,
      # HAVE_ALIGNED_MALLOC, HAVE_MALLOC_TRIM, HAVE_PTHREAD_MAIN_NP,
      # HAVE_MAP_ALIGNED, HAVE_SHM_ANON, HAVE_TIMINGSAFE_BCMP, HAVE_STAT_BIRTHTIME
    ];

    # Static linking: cmake misses transitive deps of glib/gio.
    # gobject→libffi, gio→gmodule/libmount/libblkid/libselinux/sysprof, glib→pcre2.
    # cmakeFlagsArray preserves spaces (cmakeFlags word-splits).
    preConfigure = pkgs.lib.optionalString static_lto ''
      cmakeFlagsArray+=("-DCMAKE_EXE_LINKER_FLAGS=-lffi -lgmodule-2.0 -lmount -lblkid -lselinux -lsysprof-capture-4 -lpcre2-8 -Wl,--allow-multiple-definition")
      cmakeFlagsArray+=("-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--allow-multiple-definition")
      # GStreamer plugin .pc files are in lib/gstreamer-1.0/pkgconfig/, not lib/pkgconfig/
      export PKG_CONFIG_PATH="${gstreamer}/lib/gstreamer-1.0/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    '';

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

    nativeBuildInputs = [ hostPkgs.pkg-config ];

    buildInputs = [
      webkitEngine
      pkgs.glib
      pkgs.libsoup_3
      pkgs.libxkbcommon
      pkgs.sqlite
    ];

    buildPhase = ''
      $CC -c engine.c -o engine.o \
        -I${pages}/include \
        $(pkg-config --cflags wpe-webkit-2.0 wpe-platform-2.0 glib-2.0 gobject-2.0 sqlite3)
      $AR rcs libengine.a engine.o
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
