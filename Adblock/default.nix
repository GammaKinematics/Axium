{ pkgs, adblock-rust }:

pkgs.rustPlatform.buildRustPackage {
  pname = "axium-adblock";
  version = "0.1.0";

  src = adblock-rust;

  cargoLock = {
    lockFile = "${adblock-rust}/Cargo.lock";
  };

  # Inject our FFI wrapper into adblock-rust's tree as a workspace member
  postUnpack = ''
    mkdir -p $sourceRoot/ffi/src
    cp ${./src/lib.rs} $sourceRoot/ffi/src/lib.rs

    cat > $sourceRoot/ffi/Cargo.toml << 'EOF'
    [package]
    name = "axium-adblock"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    adblock = { path = ".." }
    EOF

    # Add ffi to existing workspace members
    sed -i 's/members = \[/members = ["ffi", /' $sourceRoot/Cargo.toml
  '';

  # Only build our FFI crate
  cargoBuildFlags = [ "-p" "axium-adblock" ];

  # Skip tests (adblock-rust tests require network)
  doCheck = false;

  meta = {
    description = "Axium Adblock - C FFI wrapper for adblock-rust";
    license = pkgs.lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
  };
}
