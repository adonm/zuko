#!/usr/bin/env python3
"""Finalize and validate the generated Flutter web client."""

from __future__ import annotations

import hashlib
import json
import pathlib
import shutil
import sys
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "target/book/web"
CACHE = ROOT / "target/web-assets"
GHOSTTY_WASM_NAME = "libghostty-wasm32-freestanding.wasm"
GHOSTTY_WASM_URL = (
    "https://github.com/elias8/libghostty/releases/download/"
    f"libghostty-v0.0.11/{GHOSTTY_WASM_NAME}"
)
GHOSTTY_WASM_SHA256 = (
    "b0f39cfe981af36745c6b9c6919e9ac9cdf20aa507764e78bfb7a63ddc945c5b"
)
GHOSTTY_WASM_OUTPUT = (
    OUTPUT / "assets/packages/libghostty/assets" / GHOSTTY_WASM_NAME
)
LOADER_DEBUG = 'console.debug("Injecting <script> tag. Using callback.")'
FLUTTER_SOURCE_MAP = "//# sourceMappingURL=flutter.js.map"
DEPRECATED_WEBGL_EXTENSION = "WEBGL_debug_renderer_info"
GECKO_WASM_OPT_IN = "gecko: true"
SKWASM_RENDERER = "renderer: 'skwasm'"
FLUTTER_LOADER_CALL = "_flutter.loader.load({"
EXPERIMENTAL_WIMP = "enableWimp"
TERMINAL_FONT_FAMILY = "JetBrains Mono"
TERMINAL_FONTS = {
    "JetBrainsMono-Regular.ttf": (
        "a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f"
    ),
    "JetBrainsMono-Bold.ttf": (
        "5590990c82e097397517f275f430af4546e1c45cff408bde4255dad142479dcb"
    ),
    "NotoSansMono.ttf": (
        "3c874b97ce11dc54de004c81df02c8f0974033ed1b113377130cbdd71d478f11"
    ),
    "NotoEmoji-Regular.ttf": (
        "4ac5d75ee7270e8dd76de58758bf0aae36fc56f1db3a1d41a41cd64b79265efa"
    ),
    "NotoSansSymbols2-Regular.ttf": (
        "c4a0a80f0041ce4be81e2478faad22776d23edb98ae3f0d19bd37044820ecf9d"
    ),
}
TERMINAL_FONT_FAMILIES = {
    TERMINAL_FONT_FAMILY,
    "Noto Sans Mono",
    "Noto Emoji",
    "Noto Sans Symbols 2",
}
DIAGNOSTIC_SOURCE_MAPS = ("main.dart.js.map", "main.dart.wasm.map")
DIAGNOSTIC_WASM_SYMBOLS = (b"ClientStateStore._load", b"transport_web.dart")


def fail(message: str) -> None:
    print(f"web build finalization: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cache_ghostty_wasm() -> pathlib.Path:
    cached = CACHE / GHOSTTY_WASM_NAME
    if cached.is_file() and sha256(cached) == GHOSTTY_WASM_SHA256:
        return cached

    CACHE.mkdir(parents=True, exist_ok=True)
    temporary = cached.with_suffix(".wasm.tmp")
    request = urllib.request.Request(GHOSTTY_WASM_URL, headers={"User-Agent": "zuko-build"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            temporary.write_bytes(response.read())
    except Exception as error:
        temporary.unlink(missing_ok=True)
        fail(f"failed to download {GHOSTTY_WASM_URL}: {error}")

    actual = sha256(temporary)
    if actual != GHOSTTY_WASM_SHA256:
        temporary.unlink(missing_ok=True)
        fail(f"Ghostty WASM SHA-256 is {actual}, expected {GHOSTTY_WASM_SHA256}")
    temporary.replace(cached)
    return cached


def quiet_flutter_loader() -> None:
    for name in ("flutter.js", "flutter_bootstrap.js"):
        path = OUTPUT / name
        text = path.read_text()
        text = text.replace(LOADER_DEBUG, "void 0")
        text = text.replace(FLUTTER_SOURCE_MAP, "")
        path.write_text(text)


def avoid_deprecated_webgl_extension() -> None:
    for path in (OUTPUT / "canvaskit").rglob("*.js"):
        text = path.read_text()
        if DEPRECATED_WEBGL_EXTENSION not in text:
            continue
        text = text.replace(
            f'.getExtension("{DEPRECATED_WEBGL_EXTENSION}");',
            ";",
        )
        text = text.replace(f" {DEPRECATED_WEBGL_EXTENSION}", "")
        path.write_text(text)


def validate_source_map(path: pathlib.Path) -> None:
    try:
        source_map = json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid diagnostic source map {path}: {error}")
    sources = source_map.get("sources")
    if source_map.get("version") != 3 or not isinstance(sources, list):
        fail(f"invalid diagnostic source map structure: {path}")
    if not any(
        isinstance(source, str) and source.endswith("lib/src/transport_web.dart")
        for source in sources
    ):
        fail(f"diagnostic source map does not contain Zuko sources: {path}")


def validate() -> None:
    if GHOSTTY_WASM_OUTPUT.read_bytes()[:4] != b"\0asm":
        fail(f"{GHOSTTY_WASM_OUTPUT} is not a WebAssembly module")
    if sha256(GHOSTTY_WASM_OUTPUT) != GHOSTTY_WASM_SHA256:
        fail(f"{GHOSTTY_WASM_OUTPUT} has an unexpected SHA-256")

    dart_wasm = OUTPUT / "main.dart.wasm"
    dart_wasm_bytes = dart_wasm.read_bytes()
    if dart_wasm_bytes[:4] != b"\0asm":
        fail(f"{dart_wasm} is not a WebAssembly module")
    for symbol in DIAGNOSTIC_WASM_SYMBOLS:
        if symbol not in dart_wasm_bytes:
            fail(f"{dart_wasm} does not retain diagnostic symbol {symbol!r}")
    for name in DIAGNOSTIC_SOURCE_MAPS:
        validate_source_map(OUTPUT / name)
    bootstrap = (OUTPUT / "flutter_bootstrap.js").read_text()
    if FLUTTER_LOADER_CALL not in bootstrap:
        fail("Flutter bootstrap does not contain a loader call")
    loader_config = bootstrap.rsplit(FLUTTER_LOADER_CALL, 1)[1]
    if GECKO_WASM_OPT_IN not in loader_config:
        fail("Flutter bootstrap does not opt supported Firefox into SkWasm")
    if SKWASM_RENDERER not in loader_config:
        fail("Flutter bootstrap does not select SkWasm")
    if EXPERIMENTAL_WIMP in loader_config:
        fail("Flutter bootstrap enables experimental Web Impeller")

    for name, expected in TERMINAL_FONTS.items():
        font = OUTPUT / "assets/assets/fonts" / name
        if not font.is_file():
            fail(f"terminal font is missing: {font}")
        if sha256(font) != expected:
            fail(f"{font} has an unexpected SHA-256")

    manifest_path = OUTPUT / "assets/FontManifest.json"
    manifest = json.loads(manifest_path.read_text())
    families = {entry.get("family") for entry in manifest}
    missing_families = TERMINAL_FONT_FAMILIES - families
    if missing_families:
        fail(f"{manifest_path} does not register {sorted(missing_families)}")

    generated_javascript = list(OUTPUT.rglob("*.js"))
    for path in generated_javascript:
        text = path.read_text()
        for unwanted in (LOADER_DEBUG, FLUTTER_SOURCE_MAP, DEPRECATED_WEBGL_EXTENSION):
            if unwanted in text:
                fail(f"{path} still contains {unwanted!r}")


def main() -> None:
    if not OUTPUT.is_dir():
        fail("run `flutter build web` first")

    ghostty_wasm = cache_ghostty_wasm()
    GHOSTTY_WASM_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ghostty_wasm, GHOSTTY_WASM_OUTPUT)
    quiet_flutter_loader()
    avoid_deprecated_webgl_extension()
    validate()
    print(f"web build finalization: validated {OUTPUT}")


if __name__ == "__main__":
    main()
