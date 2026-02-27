{ pkgs, adblock-rust, engine, uassets, ublock }:

let
  webkitEngine = engine.webkit;

  lib = pkgs.rustPlatform.buildRustPackage {
    pname = "axium-adblock";
    version = "0.1.0";

    src = adblock-rust;

    cargoLock = {
      lockFile = "${adblock-rust}/Cargo.lock";
    };

    nativeBuildInputs = [ pkgs.pkg-config ];

    buildInputs = [
      pkgs.glib
      pkgs.libsoup_3
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
      crate-type = ["cdylib"]

      [[bin]]
      name = "adblock-serialize"
      path = "src/main.rs"

      [dependencies]
      adblock = { path = "..", features = ["resource-assembler"] }
      serde_json = "1"
      EOF

      # Add ffi to existing workspace members
      sed -i 's/members = \[/members = ["ffi", /' $sourceRoot/Cargo.toml
    '';

    # Only build our FFI crate
    cargoBuildFlags = [ "-p" "axium-adblock" ];

    # Skip tests (adblock-rust tests require network)
    doCheck = false;

    meta = {
      description = "Axium Adblock - Rust FFI library";
      license = pkgs.lib.licenses.mpl20;
      platforms = [ "x86_64-linux" ];
    };
  };

  ext = pkgs.stdenv.mkDerivation {
    pname = "axium-adblock-ext";
    version = "0.1.0";

    src = ./.;

    nativeBuildInputs = [ pkgs.pkg-config ];

    buildInputs = [
      webkitEngine
      pkgs.glib
      pkgs.libsoup_3
    ];

    buildPhase = ''
      cc -shared -fPIC -o libaxium_adblock_ext.so adblock.c \
        $(pkg-config --cflags wpe-web-process-extension-2.0) \
        $(pkg-config --libs glib-2.0) \
        -L${lib}/lib -laxium_adblock -Wl,-rpath,${lib}/lib
    '';

    installPhase = ''
      mkdir -p $out/lib
      cp libaxium_adblock_ext.so $out/lib/
    '';

    meta = {
      description = "Axium Adblock - WebKit web process extension";
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
}
