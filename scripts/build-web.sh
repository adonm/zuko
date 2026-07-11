#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLIENT="$ROOT/flutter"
WASM="$CLIENT/rust/web_transport"
OUT="$CLIENT/web/wasm"
WASM_BINDGEN_VERSION="0.2.122"

cd "$ROOT"
if command -v rustup >/dev/null 2>&1; then
  rustup target add wasm32-unknown-unknown >/dev/null
fi

if ! command -v wasm-bindgen >/dev/null 2>&1 || ! wasm-bindgen --version 2>/dev/null | grep -q "${WASM_BINDGEN_VERSION}"; then
  cargo install wasm-bindgen-cli --version "$WASM_BINDGEN_VERSION" --locked
fi

CARGO_TARGET_DIR="$ROOT/target/web-wasm" \
  cargo build --manifest-path "$WASM/Cargo.toml" --target wasm32-unknown-unknown --release

rm -rf "$OUT"
mkdir -p "$OUT"
wasm-bindgen \
  "$ROOT/target/web-wasm/wasm32-unknown-unknown/release/zuko_web.wasm" \
  --out-dir "$OUT" \
  --target web \
  --weak-refs

cd "$CLIENT"
rm -rf "$ROOT/target/book/web"
mise exec -- flutter build web \
  --release \
  --wasm \
  --no-web-resources-cdn \
  --base-href /web/ \
  --output "$ROOT/target/book/web"

python3 "$ROOT/scripts/finalize-web-build.py"
