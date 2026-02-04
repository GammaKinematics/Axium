{ pkgs, lvgl }:

let
  # Generate UI code at Nix evaluation time
  uiConfig = import ./UI/default.nix;
  generatedUI = import ./UI/ui.nix { ui = uiConfig; };
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
    pkgs.glfw
    pkgs.libGL
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

    # Build with Odin - pass libraries directly (NixOS workaround)
    # Use absolute paths since clang runs from /build, not /build/Browser
    odin build . -out:axium -debug \
      -extra-linker-flags:"$(pwd)/lvgl/liblvgl.a $(pwd)/lvgl/liblvgl_thorvg.a -L${pkgs.glfw}/lib -lglfw -L${pkgs.libGL}/lib -lGL -lm -lstdc++"
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
