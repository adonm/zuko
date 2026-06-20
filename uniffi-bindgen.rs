//! Thin wrapper that exposes `uniffi-bindgen` as a binary in this crate, so
//! `cargo run --bin uniffi-bindgen -- generate ...` works in dev and CI
//! without a separate `cargo install` step. Mirrors the iroh-ffi pattern.
fn main() {
    uniffi::uniffi_bindgen_main()
}
