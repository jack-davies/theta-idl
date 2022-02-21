# Overlay pinning the version of Rust nightly we use
{ naersk-flake }:
final:
current:
let
  rust-with-src = final.rust-nightly.rust.override {
    extensions = [ "rust-src" ];
  };
  rustPlatform = final.makeRustPlatform {
    cargo = final.rust-nightly.cargo;
    rustc = rust-with-src;
  };
  rust-tools = with rustPlatform.rust; [ rustc cargo ];

  frameworks = final.darwin.apple_sdk.frameworks;
  darwin = if final.stdenv.isDarwin then [ frameworks.Security ] else [];
in rec {
  rust-nightly = final.rustChannelOf {
    channel = "nightly";
    date = "2020-08-27";
    sha256 = "0d9bna9l8w7sps7hqjq35835p2pp73dvy3y367b0z3wg1ha7gvjj";
  };

  naersk = naersk-flake.lib.${final.system}.override {
    cargo = rust-nightly.rust;
    rustc = rust-nightly.rust;
  };

  # Tools for Rust development in Nix shells
  rust-dev-tools = rust-tools ++ darwin;
}
