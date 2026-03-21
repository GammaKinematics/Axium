{ pkgs, hostPkgs ? pkgs, webkit, pages,
  static ? false,
  gpu ? false,
  gstreamer ? null,  # gstreamer-full attrset { drv, linkFlags, wholeArchiveFlags, buildInputs }
}:

let
  # Static cross overlay already builds harfbuzz with ICU; dynamic nixpkgs doesn't.
  hb = if static then pkgs.harfbuzz else pkgs.harfbuzzFull;

  # Single source of truth: all WebKit dep link flags (-L/-l).
  # Used by cmake (bare -l extracted) and exported for the final binary.
  depFlags = [
    "-L${pkgs.glib.out}/lib -lglib-2.0 -lgobject-2.0 -lgio-2.0 -lgmodule-2.0"
    "-L${pkgs.libsoup_3}/lib -lsoup-3.0"
    "-L${hb}/lib -lharfbuzz -lharfbuzz-icu"
    "-L${pkgs.icu.out}/lib -licui18n -licuuc -licudata"
    "-L${pkgs.libxml2}/lib -lxml2"
    "-L${pkgs.sqlite.out}/lib -lsqlite3"
    "-L${pkgs.zlib}/lib -lz"
    "-L${pkgs.libpng}/lib -lpng16"
    "-L${pkgs.libjpeg}/lib -ljpeg"
    "-L${pkgs.libwebp}/lib -lwebp -lwebpdemux -lwebpmux -lsharpyuv"
    "-L${pkgs.freetype}/lib -lfreetype"
    "-L${pkgs.fontconfig.lib}/lib -lfontconfig"
    "-L${pkgs.expat}/lib -lexpat"
    "-L${pkgs.libepoxy}/lib -lepoxy"
    "-L${pkgs.libgcrypt}/lib -lgcrypt"
    "-L${pkgs.libgpg-error}/lib -lgpg-error"
    "-L${pkgs.libtasn1}/lib -ltasn1"
    "-L${pkgs.libxkbcommon}/lib -lxkbcommon"
    "-L${pkgs.libffi}/lib -lffi"
    "-L${pkgs.pcre2}/lib -lpcre2-8"
    "-L${pkgs.nghttp2.lib}/lib -lnghttp2"
    "-L${pkgs.libpsl}/lib -lpsl"
    "-L${pkgs.brotli.lib}/lib -lbrotlidec -lbrotlicommon"
    "-L${pkgs.bzip2}/lib -lbz2"
    "-L${pkgs.libidn2}/lib -lidn2"
    "-L${pkgs.libunistring}/lib -lunistring"
    "-L${pkgs.util-linuxMinimal}/lib -lmount -lblkid"
  ];

  # Strip -L paths to get bare -l flags for cmake (cmake finds paths via pkg-config).
  # Includes gstreamer codec transitive deps when static (cmake-built WebProcess/
  # NetworkProcess link gstreamer whole-archive and need these to resolve symbols).
  bareLFlags = builtins.concatStringsSep " " (
    builtins.filter (s: builtins.match "-L.*" s == null)
      (builtins.concatMap (s: pkgs.lib.splitString " " s)
        (depFlags ++ pkgs.lib.optionals (gstreamer != null)
          (pkgs.lib.splitString " " gstreamer.linkFlags)))
  );

  # WebKit uses stdenvNoLto when static — cmake handles LTO via -DLTO_MODE=thin
  webkitEngine = (if static then pkgs.stdenvNoLto else pkgs.stdenv).mkDerivation {
    pname = "axium-engine";
    version = "2.51.92";

    src = webkit;

    postPatch = ''
      # ── Extension system ──
      # Replace dlopen bundle loading with direct WebProcessExtensionManager call.
      # adblock.o is linked into the binary — symbol available at link time.
      substituteInPlace Source/WebKit/WebProcess/InjectedBundle/glib/InjectedBundleGlib.cpp \
        --replace-fail '#include "WKBundleInitialize.h"' '#include "WebProcessExtensionManager.h"' \
        --replace-fail \
          '    m_platformBundle = g_module_open(FileSystem::fileSystemRepresentation(m_path).data(), G_MODULE_BIND_LOCAL);
    if (!m_platformBundle) {
        g_warning("Error loading the injected bundle (%s): %s", m_path.utf8().data(), g_module_error());
        return false;
    }

    WKBundleInitializeFunctionPtr initializeFunction = 0;
    if (!g_module_symbol(m_platformBundle, "WKBundleInitialize", reinterpret_cast<void**>(&initializeFunction)) || !initializeFunction) {
        g_warning("Error loading WKBundleInitialize symbol from injected bundle.");
        return false;
    }

    initializeFunction(toAPI(this), toAPI(initializationUserData.get()));' \
          '    WebProcessExtensionManager::singleton().initialize(this, initializationUserData.get());'

      # Weak extern decl at file scope — provides default no-op when no extension is linked.
      # Keeps the WebKitWebProcessExtension object (needed for user message routing)
      # but skips directory scanning and g_module_open entirely.
      substituteInPlace Source/WebKit/WebProcess/InjectedBundle/API/glib/WebProcessExtensionManager.cpp \
        --replace-fail \
          'namespace WebKit {' \
          'extern "C" __attribute__((weak, visibility("default"))) void webkit_web_process_extension_initialize_with_user_data(
    WebKitWebProcessExtension*, GVariant*) {}

namespace WebKit {' \
        --replace-fail \
          '    if (webProcessExtensionsDirectory.isNull())
        return;

    Vector<String> modulePaths;
    scanModules(webProcessExtensionsDirectory, modulePaths);

    for (size_t i = 0; i < modulePaths.size(); ++i) {
        auto module = makeUnique<Module>(modulePaths[i]);
        if (!module->load())
            continue;
        if (initializeWebProcessExtension(module.get(), userData.get()))
            m_extensionModules.append(module.release());
    }' \
          '    webkit_web_process_extension_initialize_with_user_data(m_extension.get(), userData.get());'

      # ── Subprocess discovery ──
      # Single-binary architecture: WPEWebProcess/WPENetworkProcess are symlinks to axium.
      # WEBKIT_EXEC_PATH is behind DEVELOPER_MODE — enable unconditionally so release
      # builds check the env var and executable's parent dir before falling back to PKGLIBEXECDIR.
      substituteInPlace Source/WebKit/Shared/glib/ProcessExecutablePathGLib.cpp \
        --replace-fail '#if ENABLE(DEVELOPER_MODE)' '#if 1'

      # ── Preferences / env vars ──
      # Expose process/preference settings via AXIUM_DISABLE_* environment variables.
      substituteInPlace Source/WebKit/UIProcess/API/glib/WebKitWebContext.cpp \
        --replace-fail 'configuration->setUsesWebProcessCache(true);' \
          'configuration->setUsesWebProcessCache(!g_getenv("AXIUM_DISABLE_PROCESS_CACHE"));' \
        --replace-fail 'configuration->setProcessSwapsOnNavigation(true);' \
          'configuration->setProcessSwapsOnNavigation(!g_getenv("AXIUM_DISABLE_PSON"));'

      substituteInPlace Source/WebKit/UIProcess/wpe/WebPreferencesWPE.cpp \
        --replace-fail '#include "WebPreferences.h"' \
          '#include "WebPreferences.h"
#include <glib.h>' \
        --replace-fail 'setThreadedScrollingEnabled(true);' \
          'setThreadedScrollingEnabled(true);
    setLazyImageLoadingEnabled(!g_getenv("AXIUM_DISABLE_LAZY_IMAGES"));
    setLazyIframeLoadingEnabled(!g_getenv("AXIUM_DISABLE_LAZY_IFRAMES"));
    setSpeculationRulesPrefetchEnabled(!g_getenv("AXIUM_DISABLE_SPECULATIVE_PREFETCH"));'

    '' + pkgs.lib.optionalString (!gpu) ''
      # ── CPU-only rendering ──
      # Force NonCompositedFrameRenderer (Skia CPU raster).
      substituteInPlace Source/WebKit/UIProcess/wpe/WebPreferencesWPE.cpp \
        --replace-fail 'setAcceleratedCompositingEnabled(true)' 'setHardwareAccelerationEnabled(false); setAcceleratedCompositingEnabled(false)' \
        --replace-fail 'setForceCompositingMode(true)' 'setForceCompositingMode(false)'

      # Won't compile without libdrm.
      substituteInPlace Source/WebKit/UIProcess/wpe/AcceleratedBackingStore.cpp \
        --replace-fail 'if (wpe_buffer_dma_buf_get_format(dmaBuffer) == DRM_FORMAT_XRGB8888)' 'if (false)'

      # Requires USE(GBM).
      substituteInPlace Source/WebCore/platform/graphics/skia/SkiaPaintingEngine.cpp \
        --replace-fail 'if (!texture->memoryMappedGPUBuffer())' 'if (false)'

      # Skip fallback EGL display creation.
      substituteInPlace Source/WebKit/WebProcess/glib/WebProcessGLib.cpp \
        --replace-fail 'if (PlatformDisplay::sharedDisplayIfExists())' 'if (true)'

      # ── LTO GPU stripping ──
      # Compile-time constants that let LTO prove GPU code is unreachable and strip
      # ~400 files (Skia Ganesh, TextureMapper GL, GPU RenderTargets, EGL contexts).

      # Kills GPU ImageBuffer + SkiaPaintingEngine GPU paths.
      substituteInPlace Source/WebCore/platform/ProcessCapabilities.cpp \
        --replace-fail \
          'return s_canUseAcceleratedBuffers;' \
          'return false;'

      # Severs Skia Ganesh backend, SkiaGPUAtlas, GrDirectContext.
      substituteInPlace Source/WebCore/platform/graphics/skia/PlatformDisplaySkia.cpp \
        --replace-fail 'if (!s_skiaGLContext) {' 'if (false) {' \
        --replace-fail 'return s_skiaGLContext->skiaGLContext();' 'return nullptr;' \
        --replace-fail 'RELEASE_ASSERT(s_skiaGLContext);' '(void)0;' \
        --replace-fail 'return s_skiaGLContext->skiaGrContext();' 'return nullptr;'

      # Severs TextureMapper GL and BitmapTexturePool GPU paths.
      substituteInPlace Source/WebCore/platform/graphics/PlatformDisplay.cpp \
        --replace-fail 'if (!m_sharingGLContext)' 'if (false)' \
        --replace-fail 'return m_sharingGLContext.get();' 'return nullptr;'

      # Force SharedMemoryWithoutGL — kills GPU RenderTargets, skips GL context.
      substituteInPlace Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/AcceleratedSurface.cpp \
        --replace-fail \
          'if (renderingPurpose == RenderingPurpose::NonComposited && !useHardwareBuffersForFrameRendering) {' \
          'if (true) {'

    '' + pkgs.lib.optionalString static ''
      # ── Static build: cmake fixes ──
      # FindSoup3.cmake: pkg-config version detection fails in cross builds.
      substituteInPlace Source/cmake/FindSoup3.cmake \
        --replace-fail 'set(Soup3_VERSION ''${PC_Soup3_VERSION})' \
          'set(Soup3_VERSION ''${PC_Soup3_VERSION})
if (NOT Soup3_VERSION)
    set(Soup3_VERSION "3.6.5")
endif()'

      # GStreamerChecks.cmake: checks PC_GSTREAMER_FULL_FOUND (pkg-config) which fails
      # in cross builds. Patch to check the actual library variable instead.
      substituteInPlace Source/cmake/GStreamerChecks.cmake \
        --replace-fail 'NOT PC_GSTREAMER_FULL_FOUND' 'NOT GSTREAMER_FULL_LIBRARIES'

      # ── Static build: library types ──
      # Produce libWPEWebKit-2.0.a instead of .so (no cmake flag exists for this).
      substituteInPlace Source/cmake/WebKitCommon.cmake \
        --replace-fail 'set(WebKit_LIBRARY_TYPE SHARED)' 'set(WebKit_LIBRARY_TYPE STATIC)'

      # Internal frameworks (bmalloc, WTF, JSC, WebCore) are OBJECT type so they fold
      # into libWPEWebKit.so. With STATIC WebKit, OBJECT→exe propagation breaks.
      # Change to STATIC for proper .a linking into WPEWebProcess/WPENetworkProcess.
      substituteInPlace Source/cmake/OptionsWPE.cmake \
        --replace-fail 'set(bmalloc_LIBRARY_TYPE OBJECT)' 'set(bmalloc_LIBRARY_TYPE STATIC)' \
        --replace-fail 'set(WTF_LIBRARY_TYPE OBJECT)' 'set(WTF_LIBRARY_TYPE STATIC)' \
        --replace-fail 'set(JavaScriptCore_LIBRARY_TYPE OBJECT)' 'set(JavaScriptCore_LIBRARY_TYPE STATIC)' \
        --replace-fail 'set(WebCore_LIBRARY_TYPE OBJECT)' 'set(WebCore_LIBRARY_TYPE STATIC)'

      # ── Static build: linker config ──
      # Disable --gc-sections — conflicts with LTO bitcode from deps (glib).
      # LTO does its own dead code elimination, making --gc-sections redundant.
      substituteInPlace Source/cmake/OptionsCommon.cmake \
        --replace-fail 'if (LD_SUPPORTS_GC_SECTIONS)' 'if (FALSE) # Axium: LTO handles DCE'

      # Ensure cmake installs the static archive (LIBRARY only covers shared libs).
      substituteInPlace Source/WebKit/CMakeLists.txt \
        --replace-fail \
          'install(TARGETS WebKit WebProcess NetworkProcess' \
          'install(TARGETS WebKit WebProcess NetworkProcess
    ARCHIVE DESTINATION "''${LIB_INSTALL_DIR}"'

      # GStreamer --whole-archive — target-specific to avoid poisoning cmake try_compile.
      gst_whole="$(echo ${gstreamer.drv}/lib/libgst*.a) $(echo ${gstreamer.drv}/lib/gstreamer-1.0/lib*.a)"
      cat >> Source/WebKit/CMakeLists.txt << GSTEOF

# Axium: GStreamer --whole-archive — target-specific to avoid poisoning cmake try_compile.
# WebProcess/NetworkProcess use keyword signature (PRIVATE) per WebKitMacros.cmake.
foreach(axium_target WebProcess NetworkProcess)
  target_link_libraries(\''${axium_target} PRIVATE -Wl,--whole-archive $gst_whole -Wl,--no-whole-archive)
endforeach()
GSTEOF
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

    buildInputs = [ hb ] ++ (with pkgs; [
      glib
      libffi            # transitive dep of gobject (gclosure marshalling)
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
      libepoxy          # Skia cmake requires it; LTO strips unused GL symbols
      freetype
      fontconfig
      expat
    ]) ++ (if static then [ gstreamer.drv ] ++ gstreamer.buildInputs else with pkgs; [
      gst_all_1.gstreamer
      gst_all_1.gst-plugins-base
      gst_all_1.gst-plugins-good
      gst_all_1.gst-plugins-bad
    ]) ++ pkgs.lib.optionals gpu (with pkgs; [
      libdrm
      libgbm
      mesa
    ]);

    cmakeFlags = [
      "-DPORT=WPE"
      (if static then "-DCMAKE_BUILD_TYPE=MinSizeRel" else "-DCMAKE_BUILD_TYPE=Release")
      # Inline 128-bit atomics (cmpxchg16b) — avoids __atomic_*_16 libcalls
      # that require libatomic (not available in LLVM-only toolchain).
      "-DCMAKE_C_FLAGS=-mcx16"
      "-DCMAKE_CXX_FLAGS=-mcx16"

      # --- Platform ---
      "-DENABLE_WPE_PLATFORM=ON"
      "-DENABLE_WPE_PLATFORM_DRM=OFF"
      "-DENABLE_WPE_PLATFORM_HEADLESS=OFF"
      "-DENABLE_WPE_PLATFORM_WAYLAND=OFF"
      "-DENABLE_WPE_LEGACY_API=OFF"

      # --- Graphics / GPU ---
      "-DENABLE_GPU_PROCESS=OFF"
      "-DENABLE_WEBGL=OFF"
      "-DENABLE_OFFSCREEN_CANVAS=OFF"
      "-DENABLE_OFFSCREEN_CANVAS_IN_WORKERS=OFF"
      "-DUSE_GBM=${if gpu then "ON" else "OFF"}"
      "-DUSE_LIBDRM=${if gpu then "ON" else "OFF"}"
      "-DUSE_GSTREAMER_GL=${if gpu then "ON" else "OFF"}"

      # --- Media ---
      "-DENABLE_MEDIA_STREAM=OFF"
      "-DENABLE_MEDIA_RECORDER=OFF"
      "-DENABLE_ENCRYPTED_MEDIA=OFF"
      "-DENABLE_WEB_CODECS=OFF"
      "-DENABLE_WEB_AUDIO=OFF"

      # --- Web APIs ---
      "-DENABLE_GAMEPAD=OFF"
      "-DENABLE_WEB_RTC=OFF"
      "-DENABLE_NOTIFICATIONS=OFF"
      "-DENABLE_SPEECH_SYNTHESIS=OFF"
      "-DENABLE_WEBXR=OFF"
      "-DENABLE_TOUCH_EVENTS=OFF"
      "-DENABLE_GEOLOCATION=OFF"
      "-DENABLE_CONTENT_EXTENSIONS=OFF"
      "-DENABLE_MATHML=OFF"
      "-DENABLE_MHTML=OFF"
      "-DENABLE_PDFJS=OFF"
      "-DENABLE_XSLT=OFF"

      # --- JSC ---
      "-DENABLE_WEBASSEMBLY=OFF"
      "-DENABLE_FTL_JIT=OFF"
      "-DENABLE_SAMPLING_PROFILER=OFF"
      "-DENABLE_JAVASCRIPT_SHELL=OFF"

      # --- UI ---
      "-DENABLE_AUTOCAPITALIZE=OFF"
      "-DENABLE_MOUSE_CURSOR_SCALE=OFF"
      "-DENABLE_CSS_TAP_HIGHLIGHT_COLOR=OFF"

      # --- Security ---
      "-DENABLE_BUBBLEWRAP_SANDBOX=OFF"

      # --- Build / tooling ---
      "-DENABLE_REMOTE_INSPECTOR=OFF"
      "-DENABLE_DOCUMENTATION=OFF"
      "-DENABLE_INTROSPECTION=OFF"
      "-DENABLE_WPE_QT_API=OFF"
      "-DENABLE_MINIBROWSER=OFF"
      "-DENABLE_API_TESTS=OFF"
      "-DENABLE_LAYOUT_TESTS=OFF"
      "-DENABLE_WEBDRIVER=OFF"
      "-DENABLE_JOURNALD_LOG=OFF"
      "-DENABLE_PERIODIC_MEMORY_MONITOR=OFF"

      # --- USE_ flags ---
      "-DUSE_SYSPROF_CAPTURE=OFF"
      "-DUSE_AVIF=OFF"
      "-DUSE_JPEGXL=OFF"
      "-DUSE_LCMS=OFF"
      "-DUSE_WOFF2=OFF"
      "-DUSE_LIBHYPHEN=OFF"
      "-DUSE_ATK=OFF"
      "-DUSE_LIBBACKTRACE=OFF"
      "-DUSE_SKIA_OPENTYPE_SVG=OFF"

    ] ++ pkgs.lib.optionals static [
      # Thin LTO for WebKit only (too large for full LTO linking).
      # WebKit's cmake adds -flto=thin to C/CXX/linker flags and enables LLD.
      # Requires COMPILER_IS_CLANG (provided by pkgsLto's useLLVM = true).
      # Deps use full LTO via the crossOverlay — compatible with thin here.
      "-DLTO_MODE=thin"
      "-DUSE_THIN_ARCHIVES=OFF"
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

    # Static linking: cmake misses transitive deps — pass bare -l flags
    # derived from depFlags. cmakeFlagsArray preserves spaces.
    preConfigure = pkgs.lib.optionalString static ''
      cmakeFlagsArray+=("-DCMAKE_EXE_LINKER_FLAGS=${bareLFlags} -Wl,--allow-multiple-definition -Wl,--error-limit=0")
      cmakeFlagsArray+=("-DCMAKE_MODULE_LINKER_FLAGS=${bareLFlags} -Wl,--allow-multiple-definition -Wl,--error-limit=0")
      # GStreamer plugin .pc files are in lib/gstreamer-1.0/pkgconfig/, not lib/pkgconfig/
      export PKG_CONFIG_PATH="${gstreamer.drv}/lib/gstreamer-1.0/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    '';

    # Install all static libraries from the build dir.
    postInstall = pkgs.lib.optionalString static ''
      cp lib/*.a $out/lib/
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
      pkgs.nghttp2
    ] ++ pkgs.lib.optionals gpu [
      pkgs.libdrm
    ];

    buildPhase = ''
      $CC -c engine.c -o engine.o \
        -I${pages}/include \
        ${pkgs.lib.optionalString gpu "-DGPU"} \
        ${pkgs.lib.optionalString static "-DSTATIC"} \
        $(pkg-config --cflags wpe-webkit-2.0 wpe-platform-2.0 glib-2.0 gobject-2.0 sqlite3 \
          ${pkgs.lib.optionalString gpu "libdrm"})

    '' + ''
      $CXX -c subprocess.cpp -o subprocess.o \
        ${pkgs.lib.optionalString static "-DSTATIC"}
      $AR rcs libengine.a engine.o subprocess.o
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

  # Full link flags for the final binary (WebKit libs + all deps + gstreamer).
  linkFlags = builtins.concatStringsSep " " ([
    "-Wl,--whole-archive"
    "-L${webkitEngine}/lib"
    "-lWPEWebKit-2.0 -lWebCore -lJavaScriptCore -lPAL -lWTF -lbmalloc -lSkia -lxdgmime"
    "-Wl,--no-whole-archive"
  ] ++ depFlags
    ++ pkgs.lib.optionals (gstreamer != null) [
    gstreamer.wholeArchiveFlags
    gstreamer.linkFlags
  ]);

  # All pkgs needed by the final binary for nix dep tracking.
  buildInputs = with pkgs; [
    glib libsoup_3 icu libxml2 sqlite zlib libpng libjpeg
    libwebp freetype fontconfig expat libepoxy libgcrypt libgpg-error
    libtasn1 libxkbcommon libffi pcre2 nghttp2 libpsl brotli bzip2
    libidn2 libunistring util-linuxMinimal
  ] ++ [ hb ]
    ++ pkgs.lib.optionals gpu (with pkgs; [ libdrm libgbm mesa ])
    ++ pkgs.lib.optionals (gstreamer != null) gstreamer.buildInputs;
}
