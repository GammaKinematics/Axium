{ pkgs, engine, display-onix, generatedBindings
, lvgl, lvglBindings, themeOdin, fontOdin, font-onix, generatedUI
}:

let
  displaySources = display-onix.lib.sources { backend = "x11"; package = "display"; };
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
    engine
    lvgl
    pkgs.glib
    pkgs.libsoup_3      # required by wpe-webkit-2.0.pc
    pkgs.libxkbcommon   # WPEKeymapXKB.h
    pkgs.libglvnd       # EGL headers + libs
  ] ++ displayDeps ++ lvgl.passthru.deps ++ (font-onix.lib.deps pkgs);

  buildPhase = ''
    # Copy Display-Onix backend source
    mkdir -p display
    for f in ${builtins.concatStringsSep " " displaySources}; do
      cp "$f" display/
    done

    # Copy generated bindings
    cp ${generatedBindings} ./bindings.odin

    # Copy LVGL bindings, theme, font, and UI
    cp ${lvglBindings} ./lvgl.odin
    cp ${themeOdin} ./theme_gen.odin
    cp ${fontOdin} ./font_gen.odin
    cp ${generatedUI} ./ui.odin

    # Compile WPE2 C shim
    cc -c wpe_shim.c -o wpe_shim.o \
      $(pkg-config --cflags wpe-webkit-2.0 wpe-platform-2.0 glib-2.0 gobject-2.0) \
      -I${pkgs.libglvnd.dev}/include
    ar rcs libwpe_shim.a wpe_shim.o

    # Build with Odin
    odin build . -out:axium -debug \
      -extra-linker-flags:"-L$(pwd) \
        ${displayLinkFlags} \
        -L${pkgs.libglvnd}/lib -lEGL \
        ${lvgl}/lib/liblvgl.a \
        ${lvgl.passthru.linkFlags} \
        $(pkg-config --libs wpe-webkit-2.0 wpe-platform-2.0 glib-2.0 gobject-2.0) \
        ${font-onix.lib.linkFlags pkgs} \
        -lm -lstdc++"
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp axium $out/bin/

    mv $out/bin/axium $out/bin/.axium-unwrapped
    cat > $out/bin/axium << WRAPPER
    #!/bin/sh
    export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
    export GIO_EXTRA_MODULES=${pkgs.glib-networking}/lib/gio/modules
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export GNUTLS_SYSTEM_TRUST_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
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
