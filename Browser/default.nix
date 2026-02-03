{ pkgs, lvgl }:

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
    pkgs.glfw
    pkgs.libGL
    pkgs.glew
  ];

  buildPhase = ''
    # Copy LVGL bindings and library into build tree
    mkdir -p lvgl
    cp ${lvgl}/odin/lvgl.odin lvgl/
    cp ${lvgl}/lib/liblvgl.a lvgl/
    cp ${lvgl}/lib/liblvgl_thorvg.a lvgl/

    # Debug
    echo "=== Build directory ==="
    pwd
    ls -la
    ls -la lvgl/
    echo "=== lvgl.odin content (first 10 lines) ==="
    head -10 lvgl/lvgl.odin

    # Build with Odin - pass libraries directly (NixOS workaround)
    # Use absolute paths since clang runs from /build, not /build/Browser
    odin build . -out:axium -debug \
      -extra-linker-flags:"$(pwd)/lvgl/liblvgl.a $(pwd)/lvgl/liblvgl_thorvg.a -L${pkgs.glfw}/lib -lglfw -lGL -lGLEW -lm -lstdc++"
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp axium $out/bin/
  '';

  meta = {
    description = "Axium Browser - minimal privacy-focused browser";
    mainProgram = "axium";
    platforms = [ "x86_64-linux" ];
  };
}
