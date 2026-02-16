{ pkgs, lvgl, engine, theme }:

let
  # Generate UI code at Nix evaluation time
  uiConfig = import ./UI/default.nix;
  generatedUI = import ./UI/ui.nix { ui = uiConfig; inherit theme; };
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
    lvgl
    engine
    pkgs.glfw
    pkgs.libGL
    pkgs.glib
    pkgs.libxkbcommon
    pkgs.libsoup_3
    pkgs.mesa  # EGL
    pkgs.libdrm  # drm_fourcc.h for DMA-BUF format constants
  ];

  buildPhase = ''
    # Copy LVGL bindings and library into build tree
    mkdir -p lvgl
    cp ${lvgl}/odin/lvgl.odin lvgl/
    cp ${lvgl}/lib/liblvgl.a lvgl/
    cp ${lvgl}/lib/liblvgl_thorvg.a lvgl/

    # Write generated UI code
    mkdir -p UI
    echo ${pkgs.lib.escapeShellArg generatedUI} > UI/ui.odin

    # Compile WPE2 C shim (use pkg-config for all transitive deps)
    cc -c wpe_shim.c -o wpe_shim.o \
      $(pkg-config --cflags wpe-webkit-2.0 wpe-platform-2.0 glib-2.0 gobject-2.0 libdrm)
    ar rcs libwpe_shim.a wpe_shim.o

    # Build with Odin - link everything together
    odin build . -out:axium -debug \
      -extra-linker-flags:"$(pwd)/lvgl/liblvgl.a $(pwd)/lvgl/liblvgl_thorvg.a \
        -L$(pwd) \
        -L${pkgs.glfw}/lib -lglfw \
        -L${pkgs.libGL}/lib -lGL \
        -L${pkgs.mesa}/lib -lEGL \
        $(pkg-config --libs wpe-webkit-2.0 wpe-platform-2.0 glib-2.0 gobject-2.0) \
        -lm -lstdc++"
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp axium $out/bin/

    # Wrapper script to set runtime environment
    mv $out/bin/axium $out/bin/.axium-unwrapped
    cat > $out/bin/axium << 'WRAPPER'
    #!/bin/sh
    # Disable sandbox for now (xdg-dbus-proxy path issues in Nix)
    export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
    exec "$(dirname "$0")/.axium-unwrapped" "$@"
    WRAPPER
    chmod +x $out/bin/axium
  '';

  meta = {
    description = "Axium Browser - minimal privacy-focused browser";
    mainProgram = "axium";
    platforms = [ "x86_64-linux" ];
  };
}
