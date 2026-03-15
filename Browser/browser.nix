{ pkgs, hostPkgs ? pkgs, engine, pages, display, generatedBindings
, lvgl, lvglBindings, themeOdin, fontSources, iconFont, edgeSources
, adblock
, static ? false, detour ? null, gpu ? false
}:

let
  configFlagsStr = builtins.concatStringsSep " " (display.configFlags
    ++ pkgs.lib.optionals static [ "-define:STATIC=true" ]);

  musl = pkgs.stdenv.cc.libc;
in
pkgs.stdenv.mkDerivation {
  pname = "axium-browser";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = with hostPkgs; [
    odin
    pkg-config
  ] ++ hostPkgs.lib.optionals static (with hostPkgs; [
    llvmPackages.clang
    llvmPackages.lld
    llvmPackages_18.llvm   # llvm-as matching Odin's LLVM 18 IR
  ]);

  buildInputs = [
    engine.webkit
    engine.shim
    pages
    lvgl.drv
    # shim deps below
    pkgs.glib
    pkgs.libsoup_3
    pkgs.libxkbcommon
    pkgs.sqlite
  ] ++ display.buildInputs ++ lvgl.buildInputs
    ++ pkgs.lib.optionals gpu [ pkgs.libdrm ]
    ++ pkgs.lib.optionals (detour != null) [ detour ]
    ++ pkgs.lib.optionals static (engine.buildInputs ++ [
      pkgs.libseccomp
      pkgs.glib-networking pkgs.gnutls pkgs.nettle pkgs.gmp
    ]);

  buildPhase = ''
    # Copy Display-Onix backend source
    for f in ${builtins.concatStringsSep " " display.sources}; do
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

    # Copy adblock sources
    for f in ${builtins.concatStringsSep " " adblock.sources}; do
      cp "$f" ./
    done

    # Copy engine Odin bindings
    cp ${engine.odinBindings} ./engine.odin

  '' + (if static then ''
    # ═══ Static+LTO build ═══
    # Step 1: Odin emits LLVM IR
    odin build . -build-mode:llvm-ir -out:axium -o:speed \
      ${configFlagsStr}

    # Step 2: Convert LLVM 18 IR text to bitcode (backward-compatible with newer LLVM)
    ${hostPkgs.llvmPackages_18.llvm}/bin/llvm-as axium.ll -o axium.bc

    # Step 3: Full LTO link — Odin bitcode + static WebKit + all deps.
    clang -flto -Os --target=x86_64-unknown-linux-musl \
      -static -fuse-ld=lld \
      \
      --sysroot=${musl} --rtlib=compiler-rt --unwindlib=libunwind \
      -Wl,--strip-all -Wl,--gc-sections -Wl,--allow-multiple-definition -Wl,-z,noexecstack \
      -Wl,--export-dynamic-symbol-list=export_syms.ld \
      -o axium axium.bc \
      ${engine.shim}/lib/libengine.a \
      -Wl,--whole-archive ${pages}/lib/libpages.a -Wl,--no-whole-archive \
      ${engine.linkFlags} \
      ${display.linkFlags} \
      ${if detour != null then detour.linkFlags else ""} \
      ${lvgl.drv}/lib/liblvgl.a \
      ${lvgl.linkFlags} \
      ${adblock.linkFlags} \
      -L${pkgs.libseccomp}/lib -lseccomp \
      -L${pkgs.glib-networking}/lib/gio/modules -lgiognutls \
      -L${pkgs.gnutls}/lib -lgnutls \
      -L${pkgs.nettle}/lib -lhogweed -lnettle \
      -L${pkgs.gmp}/lib -lgmp \
      -lm -lpthread -ldl -lc++ \
      -Wl,--whole-archive $(clang --target=x86_64-unknown-linux-musl --rtlib=compiler-rt --print-libgcc-file-name) -Wl,--no-whole-archive
  '' else ''
    # ═══ Dynamic build ═══
    odin build . -out:axium -debug \
      ${configFlagsStr} \
      -extra-linker-flags:"-L${engine.shim}/lib -L${pages}/lib \
        ${display.linkFlags} \
        -L${lvgl.drv}/lib -llvgl \
        ${lvgl.linkFlags} \
        $(pkg-config --libs wpe-webkit-2.0 wpe-platform-2.0 glib-2.0 gobject-2.0) \
        ${adblock.linkFlags} \
        -Wl,--whole-archive -lpages -Wl,--no-whole-archive \
        -Wl,--export-dynamic-symbol-list=export_syms.ld \
        -lsqlite3 -lm -lstdc++ ${pkgs.lib.optionalString gpu "-ldrm"}"
  '');

  installPhase = ''
    mkdir -p $out/bin
    cp axium $out/bin/.axium-unwrapped
  '';

  # Wrapper written in postFixup to avoid patchShebangs rewriting #!/bin/sh
  # to pkgsLto's musl+LTO bash (which crashes with Illegal instruction).
  postFixup = ''
    cat > $out/bin/axium << 'WRAPPER'
#!/bin/sh
${if static then ''
export WEBKIT_EXEC_PATH="$(dirname "$0")"
'' else ''
export GIO_EXTRA_MODULES=${pkgs.glib-networking}/lib/gio/modules
export GIO_USE_TLS=gnutls
export GST_PLUGIN_PATH=${pkgs.gst_all_1.gst-plugins-base}/lib/gstreamer-1.0:${pkgs.gst_all_1.gst-plugins-good}/lib/gstreamer-1.0:${pkgs.gst_all_1.gst-plugins-bad}/lib/gstreamer-1.0
export AXIUM_EXT_DIR=${adblock.ext}/lib
''}
export SSL_CERT_FILE=${hostPkgs.cacert}/etc/ssl/certs/ca-bundle.crt
export GNUTLS_SYSTEM_TRUST_FILE=${hostPkgs.cacert}/etc/ssl/certs/ca-bundle.crt
export WEBKIT_SKIA_ENABLE_CPU_RENDERING=1
export AXIUM_ADBLOCK_DIR="''${AXIUM_ADBLOCK_DIR:-${adblock.resources}/share/adblock}"
exec "$(dirname "$0")/.axium-unwrapped" "$@"
WRAPPER
    chmod +x $out/bin/axium
${pkgs.lib.optionalString static ''
    ln -sf .axium-unwrapped $out/bin/WPEWebProcess
    ln -sf .axium-unwrapped $out/bin/WPENetworkProcess
''}
  '';

  meta = {
    description = "Axium Browser";
    mainProgram = "axium";
    platforms = [ "x86_64-linux" ];
  };
}
