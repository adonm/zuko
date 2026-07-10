#!/usr/bin/env python3
"""Patch a UniFFI 0.31 Kotlin error-field collision deterministically.

UniFFI emits both a constructor property named `message` and Throwable.message
when a Rust error field is also named `message`. Kotlin 2.2 rejects that source.
The serialized ABI is unchanged; only the generated Kotlin property is renamed.
Fail closed when the expected generator output changes.
"""

from pathlib import Path


path = Path("android/app/src/main/kotlin/dev/adonm/zuko/ffi/zuko.kt")
source = path.read_text()
replacements = {
    "val `message`: kotlin.String": "val `detail`: kotlin.String",
    'get() = "message=${ `message` }"': 'get() = "detail=${ `detail` }"',
    "value.`message`": "value.`detail`",
}

for old, new in replacements.items():
    count = source.count(old)
    expected = 2 if old == "value.`message`" else 1
    if count == expected:
        source = source.replace(old, new)
    elif count == 0 and source.count(new) == expected:
        # Permit re-running against an already patched generated file.
        continue
    else:
        raise SystemExit(
            f"patch-android-uniffi: expected {expected} occurrence(s) of {old!r}, found {count}"
        )

# UniFFI 0.31 also emits trailing spaces. Normalize them so the committed
# binding is reproducible and passes `git diff --check` after regeneration.
source = "\n".join(line.rstrip() for line in source.splitlines()).rstrip() + "\n"
path.write_text(source)
