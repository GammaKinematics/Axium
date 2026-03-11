{ pkgs, hostPkgs ? pkgs, adblock-rust, engine, uassets, ublock, static ? false }:

let
  webkitEngine = engine.webkit;

  # For static builds, use cross pkgs' rustPlatform so cargoBuildHook
  # targets x86_64-unknown-linux-musl (matching the musl stdenv).
  rustPlatform = if static then pkgs.rustPlatform else hostPkgs.rustPlatform;

  lib = rustPlatform.buildRustPackage {
    pname = "axium-adblock";
    version = "0.1.0";

    src = adblock-rust;

    cargoLock = {
      lockFile = "${adblock-rust}/Cargo.lock";
    };

    nativeBuildInputs = [ hostPkgs.pkg-config ];

    buildInputs = [
      hostPkgs.glib
      hostPkgs.libsoup_3
    ];

    # Inject our FFI wrapper into adblock-rust's tree as a workspace member
    postUnpack = ''
      mkdir -p $sourceRoot/ffi/src
      cp ${./lib.rs} $sourceRoot/ffi/src/lib.rs
      cp ${./serialize.rs} $sourceRoot/ffi/src/main.rs

      cat > $sourceRoot/ffi/Cargo.toml << 'EOF'
      [package]
      name = "axium-adblock"
      version = "0.1.0"
      edition = "2021"

      [lib]
      crate-type = ["staticlib"]

      [[bin]]
      name = "adblock-serialize"
      path = "src/main.rs"

      [dependencies]
      adblock = { path = "..", features = ["resource-assembler"] }
      serde_json = "1"
      EOF
    '' + hostPkgs.lib.optionalString static ''
      # LTO build: Rust-internal LTO + abort on panic (no unwinding across FFI)
      cat >> $sourceRoot/ffi/Cargo.toml << 'EOF'

      [profile.release]
      lto = true
      codegen-units = 1
      panic = "abort"
      EOF
    '' + ''
      # Add ffi to existing workspace members
      sed -i 's/members = \[/members = ["ffi", /' $sourceRoot/Cargo.toml
    '';

    # Only build our FFI crate
    cargoBuildFlags = [ "-p" "axium-adblock" ];

    # Skip tests (adblock-rust tests require network)
    doCheck = false;

    meta = {
      description = "Axium Adblock - Rust FFI static library";
      license = hostPkgs.lib.licenses.mpl20;
      platforms = [ "x86_64-linux" ];
    };
  };

  # Static: compile adblock.c to .o (linked into binary, WebKit patched for direct init)
  # Dynamic: compile adblock.c to .so (WebKit loads via dlopen)
  ext = pkgs.stdenv.mkDerivation {
    pname = "axium-adblock-ext";
    version = "0.1.0";

    src = ./.;

    nativeBuildInputs = [ hostPkgs.pkg-config ];

    buildInputs = [
      webkitEngine
      pkgs.glib
      pkgs.libsoup_3
      pkgs.nghttp2
    ];

    buildPhase = if static then ''
      $CC -c -o adblock.o adblock.c \
        $(pkg-config --cflags wpe-web-process-extension-2.0 glib-2.0)
    '' else ''
      $CC -shared -fPIC -o libaxium-adblock-ext.so adblock.c \
        $(pkg-config --cflags --libs wpe-web-process-extension-2.0 glib-2.0) \
        -L${lib}/lib -laxium_adblock -lpthread -ldl
    '';

    installPhase = if static then ''
      mkdir -p $out/lib
      cp adblock.o $out/lib/
    '' else ''
      mkdir -p $out/lib
      cp libaxium-adblock-ext.so $out/lib/
    '';

    meta = {
      description = "Axium Adblock - compiled extension object";
      platforms = [ "x86_64-linux" ];
    };
  };

  resources = pkgs.stdenv.mkDerivation {
    pname = "axium-adblock-resources";
    version = "0.1.0";

    dontUnpack = true;

    installPhase = ''
      mkdir -p $out/share/adblock

      # Concatenate filter lists into a temp file for serialization
      cat \
        ${uassets}/filters/filters.txt \
        ${uassets}/filters/filters-2020.txt \
        ${uassets}/filters/filters-2021.txt \
        ${uassets}/filters/filters-2022.txt \
        ${uassets}/filters/filters-2023.txt \
        ${uassets}/filters/filters-2024.txt \
        ${uassets}/filters/filters-2025.txt \
        ${uassets}/filters/filters-2026.txt \
        ${uassets}/filters/filters-general.txt \
        ${uassets}/filters/privacy.txt \
        ${uassets}/filters/privacy-removeparam.txt \
        ${uassets}/filters/badware.txt \
        ${uassets}/filters/resource-abuse.txt \
        ${uassets}/filters/unbreak.txt \
        ${uassets}/filters/quick-fixes.txt \
        ${uassets}/filters/ubo-link-shorteners.txt \
        ${uassets}/filters/annoyances-cookies.txt \
        ${uassets}/thirdparties/easylist/easylist.txt \
        ${uassets}/thirdparties/easylist/easyprivacy.txt \
        ${uassets}/thirdparties/easylist/easylist-cookies.txt \
        ${uassets}/thirdparties/urlhaus-filter/urlhaus-filter-online.txt \
        > filters.txt

      # Peter Lowe's hosts list (needs a title header for the parser)
      echo '! Title: Peter Lowe hosts' >> filters.txt
      cat ${uassets}/thirdparties/pgl.yoyo.org/as/serverlist >> filters.txt

      # Pre-compile engine to .dat (only the .dat is installed)
      ${lib}/bin/adblock-serialize filters.txt $out/share/adblock/engine.dat

      # Redirect resources (from uBlock)
      cp -r ${ublock}/src/web_accessible_resources $out/share/adblock/resources
      cp ${ublock}/src/js/redirect-resources.js $out/share/adblock/redirect-resources.js

      # Scriptlets (old-format, from adblock-rust test fixtures)
      cp ${adblock-rust}/data/test/fake-uBO-files/scriptlets.js $out/share/adblock/scriptlets.js
    '';

    meta = {
      description = "Axium Adblock - filter lists and redirect resources";
      platforms = [ "x86_64-linux" ];
    };
  };

in {
  inherit lib ext resources;
  sources = [];

  linkFlags = if static then builtins.concatStringsSep " " [
    "${ext}/lib/adblock.o"
    "-L${lib}/lib"
    "-laxium_adblock"
  ] else "";

  buildInputs = [];
}
