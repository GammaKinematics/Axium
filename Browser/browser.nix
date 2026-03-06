{ pkgs, engine, pages, display-onix, generatedBindings
, lvgl, lvglBindings, themeOdin, fontSources, iconFont, edgeSources
, adblock, keepass, translate
}:

let
  displaySources = display-onix.lib.sources { backend = "x11"; package = "axium"; };
  displayDeps = display-onix.lib.deps "x11" pkgs;
  displayLinkFlags = display-onix.lib.linkFlags "x11" pkgs;
in
pkgs.stdenv.mkDerivation {
  pname = "axium-browser";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = with pkgs; [
    odin
    pkg-config
  ];

  buildInputs = [
    engine.webkit
    engine.shim
    pages
    lvgl
    pkgs.glib
    pkgs.libsoup_3      # required by wpe-webkit-2.0.pc
    pkgs.libxkbcommon   # WPEKeymapXKB.h
    pkgs.sqlite          # history DB (linked via libengine.a)
  ] ++ displayDeps ++ lvgl.passthru.deps ++ keepass.buildInputs ++ translate.buildInputs;

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

    # Build with Odin
    odin build . -out:axium -debug \
      -extra-linker-flags:"-L${engine.shim}/lib -L${pages}/lib \
        ${displayLinkFlags} \
        ${lvgl}/lib/liblvgl.a \
        ${lvgl.passthru.linkFlags} \
        $(pkg-config --libs wpe-webkit-2.0 wpe-platform-2.0 glib-2.0 gobject-2.0) \
        ${keepass.linkFlags} \
        ${translate.linkFlags} \
        -Wl,--whole-archive -lpages -Wl,--no-whole-archive \
        -lsqlite3 -lm -lstdc++"
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp axium $out/bin/

    mkdir -p $out/lib/axium/extensions
    cp ${adblock.ext}/lib/libaxium_adblock_ext.so $out/lib/axium/extensions/

    mv $out/bin/axium $out/bin/.axium-unwrapped
    cat > $out/bin/axium << WRAPPER
    #!/bin/sh
    export GIO_EXTRA_MODULES=${pkgs.glib-networking}/lib/gio/modules
    export GIO_USE_TLS=gnutls
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export GNUTLS_SYSTEM_TRUST_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export GST_PLUGIN_PATH=${pkgs.gst_all_1.gst-plugins-base}/lib/gstreamer-1.0:${pkgs.gst_all_1.gst-plugins-good}/lib/gstreamer-1.0
    export WEBKIT_SKIA_ENABLE_CPU_RENDERING=1
    export AXIUM_EXT_DIR="\$(dirname "\$0")/../lib/axium/extensions"
    export AXIUM_ADBLOCK_DIR="\''${AXIUM_ADBLOCK_DIR:-${adblock.resources}/share/adblock}"
    exec "\$(dirname "\$0")/.axium-unwrapped" "\$@"
    WRAPPER
    chmod +x $out/bin/axium
  '';

  meta = {
    description = "Axium Browser - engine rendering test";
    mainProgram = "axium";
    platforms = [ "x86_64-linux" ];
  };
}
