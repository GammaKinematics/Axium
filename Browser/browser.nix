{ pkgs, hostPkgs ? pkgs, engine, pages, display-onix, generatedBindings
, lvgl, lvglBindings, themeOdin, fontSources, iconFont, edgeSources
, adblock, keepass, translate
, gstreamer ? null  # gstreamer-full for static build
, static_lto ? false
}:

let
  displaySources = display-onix.lib.sources { backend = "x11"; package = "axium"; };
  displayDeps = display-onix.lib.deps "x11" pkgs;
  displayLinkFlags = display-onix.lib.linkFlags "x11" pkgs;

  musl = pkgs.stdenv.cc.libc;
in
pkgs.stdenv.mkDerivation {
  pname = "axium-browser";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = with hostPkgs; [
    odin
    pkg-config
  ] ++ hostPkgs.lib.optionals static_lto (with hostPkgs; [
    llvmPackages.clang
    llvmPackages.lld
    llvmPackages_18.llvm   # llvm-as matching Odin's LLVM 18 IR
  ]);

  buildInputs = [
    engine.webkit
    engine.shim
    pages
    lvgl
    pkgs.glib
    pkgs.libsoup_3      # required by wpe-webkit-2.0.pc
    pkgs.libxkbcommon   # WPEKeymapXKB.h
    pkgs.sqlite          # history DB (linked via libengine.a)
  ] ++ displayDeps ++ lvgl.passthru.deps ++ keepass.buildInputs ++ translate.buildInputs
    ++ pkgs.lib.optionals static_lto [
      gstreamer pkgs.libogg pkgs.libvorbis pkgs.libopus pkgs.libvpx
      pkgs.libffi pkgs.pcre2 pkgs.nghttp2 pkgs.libpsl pkgs.brotli pkgs.bzip2
      pkgs.graphite2 pkgs.libidn2 pkgs.libunistring pkgs.util-linuxMinimal
      pkgs.libselinux pkgs.libsepol
      pkgs.libxcb-image pkgs.libxcb-render-util
      pkgs.libwebp
      pkgs.libseccomp     # bubblewrap sandbox seccomp filter
    ];

  buildPhase = ''
    # Copy Display-Onix backend source
    for f in ${builtins.concatStringsSep " " displaySources}; do
      cp "$f" ./
    done

    # Copy generated bindings
    cp ${generatedBindings} ./bindings.odin

    # Copy LVGL bindings, theme, font, and UI
    cp ${lvglBindings} ./lvgl.odin
    cp ${themeOdin} ./theme_gen.odin
    for f in ${builtins.concatStringsSep " " fontSources}; do
      cp "$f" ./
    done
    cp ${iconFont} ./icons.ttf
    for f in ${builtins.concatStringsSep " " edgeSources}; do
      cp "$f" ./
    done

    # Copy keepass sources
    for f in ${builtins.concatStringsSep " " keepass.sources}; do
      cp "$f" ./
    done

    # Copy adblock sources
    for f in ${builtins.concatStringsSep " " adblock.sources}; do
      cp "$f" ./
    done

    # Copy translate sources
    for f in ${builtins.concatStringsSep " " translate.sources}; do
      cp "$f" ./
    done

    # Copy engine Odin bindings
    cp ${engine.odinBindings} ./engine.odin

  '' + (if static_lto then ''
    # ═══ Static+LTO build ═══
    # Step 1: Odin emits LLVM IR
    odin build . -build-mode:llvm-ir -out:axium -o:speed

    # Step 2: Convert LLVM 18 IR text to bitcode (backward-compatible with newer LLVM)
    ${hostPkgs.llvmPackages_18.llvm}/bin/llvm-as axium.ll -o axium.bc

    # Step 3: Full LTO link — Odin bitcode + static WebKit + all deps.
    # All .a archives from pkgsLto contain LLVM bitcode (via -flto crossOverlay).
    # Deps use full LTO, WebKit uses thin LTO — both produce bitcode that
    # clang+LLD can optimize across at link time.
    clang -flto -Os --target=x86_64-unknown-linux-musl \
      -static -fuse-ld=lld \
      -fsanitize=cfi -fvisibility=hidden \
      --sysroot=${musl} --rtlib=compiler-rt --unwindlib=libunwind \
      -Wl,--strip-all -Wl,--icf=all -Wl,--gc-sections -Wl,--allow-multiple-definition -Wl,-z,noexecstack \
      -o axium axium.bc \
      ${engine.shim}/lib/libengine.a \
      -Wl,--whole-archive ${pages}/lib/libpages.a -Wl,--no-whole-archive \
      -Wl,--whole-archive \
      -L${engine.webkit}/lib \
      -lWPEWebKit-2.0 -lWebCore -lJavaScriptCore -lPAL -lWTF -lbmalloc -lSkia -lxdgmime \
      -Wl,--no-whole-archive \
      ${displayLinkFlags} \
      ${lvgl}/lib/liblvgl.a \
      ${lvgl.passthru.linkFlags} \
      ${keepass.linkFlags} \
      ${translate.linkFlags} \
      ${adblock.linkFlags} \
      -L${pkgs.glib.out}/lib -lglib-2.0 -lgobject-2.0 -lgio-2.0 -lgmodule-2.0 \
      -L${pkgs.libsoup_3}/lib -lsoup-3.0 \
      -L${pkgs.harfbuzzFull}/lib -lharfbuzz -lharfbuzz-icu \
      -L${pkgs.icu.out}/lib -licui18n -licuuc -licudata \
      -L${pkgs.libxml2}/lib -lxml2 \
      -L${pkgs.sqlite.out}/lib -lsqlite3 \
      -L${pkgs.zlib}/lib -lz \
      -L${pkgs.libpng}/lib -lpng16 \
      -L${pkgs.libjpeg}/lib -ljpeg \
      -L${pkgs.libwebp}/lib -lwebp -lwebpdemux -lwebpmux -lsharpyuv \
      -L${pkgs.freetype}/lib -lfreetype \
      -L${pkgs.fontconfig.lib}/lib -lfontconfig \
      -L${pkgs.expat}/lib -lexpat \
      -L${pkgs.libepoxy}/lib -lepoxy \
      -L${pkgs.libgcrypt}/lib -lgcrypt \
      -L${pkgs.libgpg-error}/lib -lgpg-error \
      -L${pkgs.libtasn1}/lib -ltasn1 \
      -L${pkgs.libxkbcommon}/lib -lxkbcommon \
      -Wl,--whole-archive $(echo ${gstreamer}/lib/libgst*.a) $(echo ${gstreamer}/lib/gstreamer-1.0/lib*.a) -Wl,--no-whole-archive \
      -L${pkgs.libogg}/lib -logg \
      -L${pkgs.libvorbis}/lib -lvorbis -lvorbisenc \
      -L${pkgs.libopus}/lib -lopus \
      -L${pkgs.libvpx}/lib -lvpx \
      -L${pkgs.libffi}/lib -lffi \
      -L${pkgs.pcre2}/lib -lpcre2-8 \
      -L${pkgs.nghttp2.lib}/lib -lnghttp2 \
      -L${pkgs.libpsl}/lib -lpsl \
      -L${pkgs.brotli.lib}/lib -lbrotlidec -lbrotlicommon \
      -L${pkgs.bzip2}/lib -lbz2 \
      -L${pkgs.graphite2}/lib -lgraphite2 \
      -L${pkgs.libidn2}/lib -lidn2 \
      -L${pkgs.libunistring}/lib -lunistring \
      -L${pkgs.util-linuxMinimal}/lib -lmount -lblkid \
      -L${pkgs.libselinux}/lib -lselinux \
      -L${pkgs.libsepol}/lib -lsepol \
      -L${pkgs.glib.out}/lib -lsysprof-capture-4 \
      -L${pkgs.libxcb-image}/lib -lxcb-image \
      -L${pkgs.libxcb-render-util}/lib -lxcb-render-util \
      -lxcb-render -lxcb-shm \
      -L${pkgs.libseccomp}/lib -lseccomp \
      -lm -lpthread -ldl -lc++ \
      -Wl,--whole-archive $(clang --target=x86_64-unknown-linux-musl --rtlib=compiler-rt --print-libgcc-file-name) -Wl,--no-whole-archive
  '' else ''
    # ═══ Dynamic build (unchanged) ═══
    odin build . -out:axium -debug \
      -extra-linker-flags:"-L${engine.shim}/lib -L${pages}/lib \
        ${displayLinkFlags} \
        ${lvgl}/lib/liblvgl.a \
        ${lvgl.passthru.linkFlags} \
        $(pkg-config --libs wpe-webkit-2.0 wpe-platform-2.0 glib-2.0 gobject-2.0) \
        ${keepass.linkFlags} \
        ${translate.linkFlags} \
        ${adblock.linkFlags} \
        -Wl,--whole-archive -lpages -Wl,--no-whole-archive \
        -lsqlite3 -lm -lstdc++"
  '');

  installPhase = if static_lto then ''
    mkdir -p $out/bin
    cp axium $out/bin/
    mv $out/bin/axium $out/bin/.axium-unwrapped
    ln -s .axium-unwrapped $out/bin/WPEWebProcess
    ln -s .axium-unwrapped $out/bin/WPENetworkProcess
  '' else ''
    mkdir -p $out/bin
    cp axium $out/bin/

    mv $out/bin/axium $out/bin/.axium-unwrapped
    ln -s .axium-unwrapped $out/bin/WPEWebProcess
    ln -s .axium-unwrapped $out/bin/WPENetworkProcess
    cat > $out/bin/axium << WRAPPER
    #!/bin/sh
    export WEBKIT_EXEC_PATH="\$(dirname "\$0")"
    export GIO_EXTRA_MODULES=${pkgs.glib-networking}/lib/gio/modules
    export GIO_USE_TLS=gnutls
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export GNUTLS_SYSTEM_TRUST_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export GST_PLUGIN_PATH=${pkgs.gst_all_1.gst-plugins-base}/lib/gstreamer-1.0:${pkgs.gst_all_1.gst-plugins-good}/lib/gstreamer-1.0
    export WEBKIT_SKIA_ENABLE_CPU_RENDERING=1
    export AXIUM_ADBLOCK_DIR="\''${AXIUM_ADBLOCK_DIR:-${adblock.resources}/share/adblock}"
    exec "\$(dirname "\$0")/.axium-unwrapped" "\$@"
    WRAPPER
    chmod +x $out/bin/axium
  '';

  # Static wrapper written in postFixup to avoid patchShebangs rewriting
  # #!/bin/sh to pkgsLto's musl+LTO bash (which crashes with Illegal instruction).
  postFixup = pkgs.lib.optionalString static_lto ''
    cat > $out/bin/axium << 'WRAPPER'
#!/bin/sh
export WEBKIT_EXEC_PATH="$(dirname "$0")"
export SSL_CERT_FILE=${hostPkgs.cacert}/etc/ssl/certs/ca-bundle.crt
export GNUTLS_SYSTEM_TRUST_FILE=${hostPkgs.cacert}/etc/ssl/certs/ca-bundle.crt
export WEBKIT_SKIA_ENABLE_CPU_RENDERING=1
export AXIUM_ADBLOCK_DIR="${adblock.resources}/share/adblock"
exec "$(dirname "$0")/.axium-unwrapped" "$@"
WRAPPER
    chmod +x $out/bin/axium
  '';

  meta = {
    description = "Axium Browser - engine rendering test";
    mainProgram = "axium";
    platforms = [ "x86_64-linux" ];
  };
}
