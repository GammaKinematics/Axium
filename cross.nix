# Static+LTO cross-compilation package set (musl + clang + full LTO).
# Follows the Fex pattern: useLLVM gives clang + compiler-rt + lld,
# crossOverlay injects -flto so all compiled code is LLVM bitcode.
# WebKit itself uses -DLTO_MODE=thin (too large for full LTO linking).
{ nixpkgs, system }:

import nixpkgs {
  localSystem = system;
  crossSystem = {
    config = "x86_64-unknown-linux-musl";
    isStatic = true;
    useLLVM = true;
  };
  crossOverlays = [
    (final: prev: {
      # Plain stdenv without -flto for builds that handle LTO themselves
      # (WebKit cmake uses -DLTO_MODE=thin).
      stdenvNoLto = prev.stdenv;
      # -flto so all .a files contain LLVM bitcode for the final LTO link.
      # Deps use default -O2 from cmake/autoconf — LTO handles cross-module optimization.
      stdenv = prev.stdenvAdapters.withCFlags [
        "-flto"
      ] prev.stdenv;
    })
    # Second overlay: globally disable checks + targeted fixes.
    # Test binaries segfault linking bitcode .o without -flto — tests are
    # useless in this env.
    (final: prev: {
      stdenv = prev.stdenv // {
        mkDerivation = args:
          let
            inject = a: a // { doCheck = false; doInstallCheck = false; };
          in prev.stdenv.mkDerivation (
            if builtins.isFunction args then (finalAttrs: inject (args finalAttrs))
            else inject args
          );
      };
      # Bash 5.3 typedef bool conflicts with clang 21 C23 default.
      # All three bash variants are independent callPackage invocations.
      bashNonInteractive = prev.bashNonInteractive.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace bashansi.h \
            --replace-fail 'typedef unsigned char bool;' \
              '#if __STDC_VERSION__ >= 202311L
#include <stdbool.h>
#else
typedef unsigned char bool;
#endif'
        '';
      });
      bash = prev.bash.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace bashansi.h \
            --replace-fail 'typedef unsigned char bool;' \
              '#if __STDC_VERSION__ >= 202311L
#include <stdbool.h>
#else
typedef unsigned char bool;
#endif'
        '';
      });
      bashInteractive = prev.bashInteractive.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace bashansi.h \
            --replace-fail 'typedef unsigned char bool;' \
              '#if __STDC_VERSION__ >= 202311L
#include <stdbool.h>
#else
typedef unsigned char bool;
#endif'
        '';
      });
      # glib: trim bloat deps + fix cross LTO issues.
      # - gettext (42.8 MB) — libintl redundant on musl (built-in stub)
      # - elfutils — debug/ELF inspection, not needed
      # - libsysprof-capture — profiling, not needed
      # - bash/gnum4 — only for glib-gettextize dev tool, kills bash-interactive→readline→ncurses
      # - libselinux — SELinux file labeling, not needed
      glib = (prev.glib.override {
        gettext = null;
        elfutils = null;
        libsysprof-capture = null;
        bash = null;
        gnum4 = null;
        libselinux = null;
      }).overrideAttrs (old: {
        buildInputs = builtins.filter (x: x != null) (old.buildInputs or []);
        propagatedBuildInputs = builtins.filter (x: x != null) (old.propagatedBuildInputs or []);
        mesonFlags = (old.mesonFlags or []) ++ [ "-Dselinux=disabled" "-Dsysprof=disabled" "-Dlibelf=disabled" "-Dnls=disabled" ];
        # meson runs cc.run() checks during configure (frexpl, printf).
        # With -flto, some test binaries crash (bitcode issues). Tell meson
        # it can't run host binaries — the gnulib fallback correctly assumes
        # frexpl/printf work on linux.
        preConfigure = (old.preConfigure or "") + ''
          cat > no-exe-wrapper.txt <<'EOF'
[properties]
needs_exe_wrapper = true
EOF
          mesonFlagsArray+=(--cross-file="$PWD/no-exe-wrapper.txt")
        '';
      });
      # Go segfaults during bootstrap in cross/LTO env — skip it, we don't need captree
      libcap = prev.libcap.override { withGo = false; };
      # wayland tools not needed, pulls unnecessary deps.
      # wayland tools not needed. Locale root: dummy path — compose sequences
      # irrelevant for a browser, avoids building libx11 just for data files.
      libxkbcommon = (prev.libxkbcommon.override { withWaylandTools = false; doxygen = null; xvfb = null; }).overrideAttrs (old: {
        nativeBuildInputs = builtins.filter (x: x != null) (old.nativeBuildInputs or []);
        outputs = builtins.filter (o: o != "doc") old.outputs;
        mesonFlags = builtins.map (f:
          if builtins.match ".*x-locale-root.*" f != null
          then "-Dx-locale-root=/dev/null"
          else f
        ) old.mesonFlags ++ [ "-Denable-docs=false" ];
      });
      # blis uses a custom (non-autotools) configure:
      # - no --build/--host (not autotools)
      # - x86_64 must be the LAST arg (positional confname) — nix's auto-appended
      #   --enable-static --disable-shared go after it and break parsing
      blis = prev.blis.overrideAttrs {
        configurePlatforms = [];
        dontAddStaticConfigureFlags = true;
        configureFlags = [
          "--enable-cblas" "--blas-int-size=32" "--enable-threading=pthreads"
          "--enable-static" "--disable-shared"
          "x86_64"
        ];
        postInstall = ""; # nixpkgs creates .so symlinks — no .so in static build
        # clang 21 dropped -mavx512pf/-mavx512er (Knights Landing / Xeon Phi — dead hardware)
        postPatch = ''
          patchShebangs configure build/flatten-headers.py
          substituteInPlace config_registry \
            --replace-warn 'skx knl haswell' 'skx haswell'
        '';
      };
      # llvm-strip can't handle LLVM bitcode .o — libvpx Makefile runs $(STRIP) itself
      libvpx = prev.libvpx.overrideAttrs { env.STRIP = "true"; };
      # libpsl: remove cross-compiled libxslt (only needed for doc tooling, not runtime)
      # and disable man page generation
      libpsl = (prev.libpsl.override { libxslt = null; }).overrideAttrs (old: {
        buildInputs = builtins.filter (x: x != null) (old.buildInputs or []);
        nativeBuildInputs = builtins.filter (x: x != null) (old.nativeBuildInputs or []);
        configureFlags = builtins.filter (f:
          !(builtins.match ".*enable-man.*" f != null)
        ) (old.configureFlags or []) ++ [ "--disable-man" ];
      });
      # openh264: gtest is only for tests, which are disabled in cross env
      openh264 = (prev.openh264.override { gtest = null; }).overrideAttrs (old: {
        buildInputs = builtins.filter (x: x != null) (old.buildInputs or []);
        mesonFlags = (old.mesonFlags or []) ++ [ "-Dtests=disabled" ];
      });
      # libwebp: only need the decoder library, not image conversion tools.
      # Kills libtiff (~52 MB), giflib, and avoids unnecessary png/jpeg build deps.
      libwebp = prev.libwebp.override {
        tiffSupport = false;
        gifSupport = false;
        pngSupport = false;
        jpegSupport = false;
      };
      # libepoxy: WebKit unconditionally requires it, but GL is never used at runtime.
      # Disable x11Support to drop libglvnd (can't build statically), libGL, libX11.
      # But WPEPlatform unconditionally needs epoxy/egl.h — re-enable EGL via a
      # stub that provides headers + pkg-config without the real libglvnd.
      eglStub = let
        glvndHeaders = (prev.buildPackages.libglvnd.override {
          libx11 = null; libxext = null; xorgproto = null;
        }).overrideAttrs (old: {
          buildInputs = builtins.filter (x: x != null) (old.buildInputs or []);
          configureFlags = (old.configureFlags or []) ++ [ "--disable-x11" "--disable-glx" ];
        });
      in prev.stdenv.mkDerivation {
        name = "egl-stub";
        dontUnpack = true;
        buildPhase = ''
          mkdir -p $out/include/EGL $out/include/KHR $out/lib/pkgconfig
          cp ${glvndHeaders.dev}/include/EGL/*.h $out/include/EGL/
          cp ${glvndHeaders.dev}/include/KHR/*.h $out/include/KHR/
          $AR rcs $out/lib/libEGL.a
          cat > $out/lib/pkgconfig/egl.pc << EOF
prefix=$out
includedir=$out/include
libdir=$out/lib
Name: egl
Description: EGL headers stub for static build
Version: 1.5
Cflags: -I$out/include
Libs: -L$out/lib
EOF
        '';
        installPhase = "true";
      };
      libepoxy = (prev.libepoxy.override { x11Support = false; }).overrideAttrs (old: {
        buildInputs = (old.buildInputs or []) ++ [ final.eglStub ];
        propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ [ final.eglStub ];
        mesonFlags = builtins.map (f:
          if f == "-Degl=no" then "-Degl=yes" else f
        ) old.mesonFlags;
        postPatch = (old.postPatch or "") + ''
          # Axium: static musl has no dlopen/dlsym. Patch epoxy so
          # unresolved GL/EGL functions return a stub (returns 0)
          # instead of aborting.

          # dispatch_common.c: neuter abort() in dlopen failure path
          substituteInPlace src/dispatch_common.c \
            --replace-fail 'abort();' '(void)0;'

          # dispatch_common.h: static stub that all resolvers can return
          substituteInPlace src/dispatch_common.h \
            --replace-fail \
              'extern epoxy_resolver_failure_handler_t epoxy_resolver_failure_handler;' \
              'extern epoxy_resolver_failure_handler_t epoxy_resolver_failure_handler;
static inline long epoxy_static_stub_(void) { return 0; }'

          # gen_dispatch.py: wrap provider condition in braces
          substituteInPlace src/gen_dispatch.py \
            --replace-fail \
              "self.outln('            if ({0})'.format(self.provider_condition[human_name]))" \
              "self.outln('            if ({0}) {{'.format(self.provider_condition[human_name]))"

          # gen_dispatch.py: NULL-check loader return, add closing brace
          substituteInPlace src/gen_dispatch.py \
            --replace-fail \
              "self.outln('                return {0};'.format(self.provider_loader[human_name]).format(\"entrypoint_strings + entrypoints[i]\"))
            self.outln('            break;')" \
              "self.outln('                void *_r = (void *){0};'.format(self.provider_loader[human_name]).format(\"entrypoint_strings + entrypoints[i]\"))
            self.outln('                if (_r) return _r;')
            self.outln('            }')
            self.outln('            break;')"

          # gen_dispatch.py: terminator abort -> break
          substituteInPlace src/gen_dispatch.py \
            --replace-fail \
              "self.outln('            abort(); /* Not reached */')" \
              "self.outln('            break;')"

          # gen_dispatch.py: remove handler check (LTO splits the global)
          substituteInPlace src/gen_dispatch.py \
            --replace-fail \
              "        self.outln('    if (epoxy_resolver_failure_handler)')
        self.outln('        return epoxy_resolver_failure_handler(name);')" \
              ""

          # gen_dispatch.py: final abort -> return stub
          substituteInPlace src/gen_dispatch.py \
            --replace-fail \
              "self.outln('    abort();')" \
              "self.outln('    return (void *)epoxy_static_stub_;')"

          echo "=== gen_dispatch.py patched resolver (lines 710-755) ==="
          sed -n '710,755p' src/gen_dispatch.py
        '';
      });
      # libsoup: disable sysprof profiling — not needed
      libsoup_3 = (prev.libsoup_3.override { libsysprof-capture = null; }).overrideAttrs (old: {
        mesonFlags = (old.mesonFlags or []) ++ [ "-Dsysprof=disabled" "-Dtests=false" ];
      });
      # Axium: glib-networking static TLS backend.
      # GIO loads TLS backends (gnutls) via dlopen of .so modules.
      # On static musl, dlopen is stubbed → no TLS backend registers →
      # g_tls_backend_get_default() returns GDummyTlsBackend → HTTPS dead.
      # Fix: build as static lib, link into binary, register directly.
      glib-networking = (prev.glib-networking.override {
        libproxy = null;
        bash = null;
        gsettings-desktop-schemas = null;
      }).overrideAttrs (old: {
        buildInputs = builtins.filter (x: x != null) (old.buildInputs or []);
        # All 3 upstream patches are for gnome-proxy or tests — both disabled.
        # hardcode-gsettings.patch pulls gsettings-desktop-schemas just for path subst.
        patches = [];
        mesonFlags = builtins.filter (f:
          !(builtins.match ".*installed_test_prefix.*" f != null)
        ) (old.mesonFlags or []) ++ [
          "-Ddefault_library=static"
          "-Dinstalled_tests=false"
          "-Dlibproxy=disabled"
          "-Dgnome_proxy=disabled"
          "-Dopenssl=disabled"
        ];
        # G_DEFINE_DYNAMIC_TYPE needs a GTypeModule — NULL won't work.
        # Switch to static type registration so get_type() works without a module.
        postPatch = (old.postPatch or "") + ''
          substituteInPlace tls/gnutls/gtlsbackend-gnutls.c \
            --replace-fail 'G_DEFINE_DYNAMIC_TYPE_EXTENDED' 'G_DEFINE_FINAL_TYPE_WITH_CODE' \
            --replace-fail 'G_TYPE_OBJECT, G_TYPE_FLAG_FINAL,' 'G_TYPE_OBJECT,' \
            --replace-fail 'G_IMPLEMENT_INTERFACE_DYNAMIC' 'G_IMPLEMENT_INTERFACE' \
            --replace-fail 'g_tls_backend_gnutls_register_type (G_TYPE_MODULE (module))' 'g_tls_backend_gnutls_get_type ()'
        '';
        preFixup = (old.preFixup or "") + ''
          mkdir -p $out/libexec $installedTests/libexec
        '';
        meta = old.meta // { badPlatforms = []; };
      });
      # ICU: trim locale data to English only (~28 MB savings).
      # Full ICU code is kept — only locale data tables are stripped.
      # Non-English Intl.* JS APIs fall back to English formatting.
      # Data is baked during the native buildRootOnly step, so the filter
      # must be applied there — the cross build just reuses that data.
      icu = let
        filterFile = builtins.toFile "icu-filter.json" (builtins.toJSON {
          localeFilter = { filterType = "language"; includelist = [ "en" ]; };
        });
        filteredBuildRoot = prev.buildPackages.icu.buildRootOnly.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ prev.buildPackages.python3 ];
          postPatch = (old.postPatch or "") + ''
            rm -f data/in/*.dat
          '';
          preConfigure = (old.preConfigure or "") + ''
            export ICU_DATA_FILTER_FILE=${filterFile}
          '';
        });
      in prev.icu.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ prev.buildPackages.python3 ];
        postPatch = (old.postPatch or "") + ''
          rm -f data/in/*.dat
        '';
        preConfigure = (old.preConfigure or "") + ''
          export ICU_DATA_FILTER_FILE=${filterFile}
        '';
        configureFlags = builtins.map (f:
          if builtins.match ".*--with-cross-build=.*" f != null
          then "--with-cross-build=${filteredBuildRoot}"
          else f
        ) (old.configureFlags or []);
      });
      # PulseAudio: client library only for GStreamer pulsesink.
      # libpulse talks to PipeWire/PulseAudio over a unix socket — no dlopen.
      # Disable X11, D-Bus, systemd (server discovery features we don't need).
      # Patch out sndfile-util.c (never called by client API, kills libsndfile dep).
      pulseaudio = (prev.pulseaudio.override {
        libOnly = true;
        x11Support = false;
        bluetoothSupport = false;
        remoteControlSupport = false;
        zeroconfSupport = false;
        alsaSupport = false;
        udevSupport = false;
        useSystemd = false;
        jackaudioSupport = false;
        ossWrapper = false;
        airtunesSupport = false;
      }).overrideAttrs (old: {
        # Client-only: just glib for GLib main loop. Everything else is server-side.
        buildInputs = [ prev.glib ];
        propagatedBuildInputs = [];
        postPatch = (old.postPatch or "") + ''
          substituteInPlace meson.build \
            --replace-fail "sndfile_dep = dependency('sndfile', version : '>= 1.0.20')" \
              "sndfile_dep = dependency('sndfile-removed', required : false)"
          substituteInPlace src/meson.build \
            --replace-fail "'pulsecore/sndfile-util.c'," "" \
            --replace-fail "'pulsecore/sndfile-util.h'," "" \
            --replace-fail "shared_library('pulsecommon-'" \
              "static_library('pulsecommon-'" \
            --replace-fail "subdir('utils')" "# subdir('utils')"
          substituteInPlace src/pulse/meson.build \
            --replace-fail "shared_library(" "static_library(" \
            --replace-fail "  version : libpulse_version," "" \
            --replace-fail "  version : libpulse_simple_version," "" \
            --replace-fail "  version : libpulse_mainloop_glib_version," "" \
            --replace-fail "  vs_module_defs : 'libpulse.def'," "" \
            --replace-fail "  install_rpath : privlibdir," ""
        '';
        mesonFlags = (old.mesonFlags or []) ++ [
          "-Ddatabase=simple"
          "-Dtests=false"
          "-Ddaemon=false"
          # Disable all auto-detected features except glib
          "-Dalsa=disabled"
          "-Dasyncns=disabled"
          "-Davahi=disabled"
          "-Dbluez5=disabled"
          "-Dbluez5-gstreamer=disabled"
          "-Dconsolekit=disabled"
          "-Ddbus=disabled"
          "-Delogind=disabled"
          "-Dfftw=disabled"
          "-Dglib=enabled"
          "-Dgsettings=disabled"
          "-Dgstreamer=disabled"
          "-Dgtk=disabled"
          "-Djack=disabled"
          "-Dlirc=disabled"
          "-Dopenssl=disabled"
          "-Dorc=disabled"
          "-Doss-output=disabled"
          "-Dsoxr=disabled"
          "-Dspeex=disabled"
          "-Dsystemd=disabled"
          "-Dtcpwrap=disabled"
          "-Dudev=disabled"
          "-Dvalgrind=disabled"
          "-Dwebrtc-aec=disabled"
          "-Dx11=disabled"
          "-Ddoxygen=false"
        ];
        postInstall = ''
          find $out/share -maxdepth 1 -mindepth 1 ! -name "vala" -prune -exec rm -r {} \; || true
          find $out/share/vala -maxdepth 1 -mindepth 1 ! -name "vapi" -prune -exec rm -r {} \; || true
          rm -rf $out/{.bin-unwrapped,etc,lib/pulse-*}
          moveToOutput lib/cmake "$dev"
          cp config.h $dev/include/pulse
        '';
        meta = old.meta // { badPlatforms = []; };
      });
      # harfbuzz: always enable ICU so there's one build instead of two
      # (nixpkgs harfbuzz-icu builds harfbuzz twice). Nuke postFixup which
      # deletes libharfbuzz and symlinks to a separate non-ICU derivation.
      harfbuzz = (prev.harfbuzz.override { withIcu = true; harfbuzz = prev.harfbuzz; withIntrospection = false; withGraphite2 = false; }).overrideAttrs (old: {
        outputs = builtins.filter (o: o != "devdoc") old.outputs;
        nativeBuildInputs = builtins.filter (x: x != null) (old.nativeBuildInputs or []);
        propagatedBuildInputs = builtins.filter (x: (x.pname or "") != "harfbuzz") (old.propagatedBuildInputs or []);
        mesonFlags = old.mesonFlags ++ [ "-Ddocs=disabled" "-Dtests=disabled" ];
        postFixup = "";
      });
      # flac: doxygen+graphviz are doc tools that drag in pango→cairo→libx11
      flac = prev.flac.override { doxygen = null; graphviz = null; };
      # mpg123: only need decoder lib, not audio output backends
      mpg123 = prev.mpg123.override { withPulse = false; withJack = false; withAlsa = false; withConplay = false; libOnly = true; };
      # gnutls: trim bloat deps.
      # - unbound (33 MB) pulls openssl (15.5 MB) + libevent (3 MB) — DANE/DNSSEC, not needed
      # - dns-root-data — only used with unbound
      # - gettext (42.8 MB) — only needed for i18n of CLI tools we don't ship
      # - doc/errcodes segfaults under LTO (bitcode can't run natively)
      gnutls = (prev.gnutls.override {
        unbound = null;
        gettext = null;
      }).overrideAttrs (old: {
        configureFlags = builtins.filter (f:
          !(builtins.match ".*unbound-root-key.*" f != null)
        ) (old.configureFlags or []) ++ [
          "--disable-doc"
          "--without-unbound-root-key-file"
          "--with-default-trust-store-file=/etc/ssl/certs/ca-certificates.crt"
        ];
        buildInputs = builtins.filter (x: x != null) (old.buildInputs or []);
        postInstall = (old.postInstall or "") + ''
          mkdir -p $devdoc $man
        '';
      });
      # gen-lock-obj.sh fails with LTO: clang -flto produces LLVM bitcode objects,
      # objdump can't read .bss section to determine pthread_mutex_t size, producing
      # a broken lock-obj header. Use the correct pre-generated file for musl.
      libgpg-error = prev.libgpg-error.overrideAttrs (old: {
        postConfigure = (old.postConfigure or "") + ''
          cp src/syscfg/lock-obj-pub.x86_64-unknown-linux-musl.h src/lock-obj-pub.native.h
        '';
      });
      # jitterentropy requires -O0 but our LTO flags in NIX_CFLAGS_COMPILE override it.
      # Jitter RNG is supplementary — /dev/urandom is the primary entropy source.
      libgcrypt = prev.libgcrypt.overrideAttrs (old: {
        configureFlags = (old.configureFlags or []) ++ [ "--disable-jent-support" ];
      });
      # freetype: LLVM cross toolchain exposes windres, which configure detects
      # and then tries to compile ftver.rc (Windows resource) — fails on Linux.
      # Setting RC="" before configure prevents detection. depsBuildBuild provides
      # a native CC that configure needs for build-time tools in cross mode.
      freetype = prev.freetype.overrideAttrs (old: {
        depsBuildBuild = (old.depsBuildBuild or []) ++ [ prev.buildPackages.stdenv.cc ];
        preConfigure = (old.preConfigure or "") + ''
          export RC=""
        '';
      });
    })
  ];
}
