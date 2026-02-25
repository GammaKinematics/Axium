{ pkgs, adblock-rust, engine }:

let
  webkitEngine = engine.webkit;
in
pkgs.rustPlatform.buildRustPackage {
  pname = "axium-adblock";
  version = "0.1.0";

  src = adblock-rust;

  cargoLock = {
    lockFile = "${adblock-rust}/Cargo.lock";
  };

  nativeBuildInputs = [ pkgs.pkg-config ];

  buildInputs = [
    webkitEngine
    pkgs.glib
    pkgs.libsoup_3
  ];

  # Inject our FFI wrapper into adblock-rust's tree as a workspace member
  postUnpack = ''
    mkdir -p $sourceRoot/ffi/src
    cp ${./lib.rs} $sourceRoot/ffi/src/lib.rs

    cat > $sourceRoot/ffi/Cargo.toml << 'EOF'
    [package]
    name = "axium-adblock"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    adblock = { path = ".." }
    serde_json = "1"
    EOF

    # Add ffi to existing workspace members
    sed -i 's/members = \[/members = ["ffi", /' $sourceRoot/Cargo.toml
  '';

  # Only build our FFI crate
  cargoBuildFlags = [ "-p" "axium-adblock" ];

  # Skip tests (adblock-rust tests require network)
  doCheck = false;

  # Build the web process extension after Rust install
  postInstall = ''
    cc -shared -fPIC -o $out/lib/libaxium_adblock_ext.so ${./adblock.c} \
      $(pkg-config --cflags wpe-web-process-extension-2.0) \
      $(pkg-config --libs glib-2.0) \
      -L$out/lib -laxium_adblock -Wl,-rpath,$out/lib
  '';

  meta = {
    description = "Axium Adblock - C FFI wrapper for adblock-rust";
    license = pkgs.lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
  };
}
