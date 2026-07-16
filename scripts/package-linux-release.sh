#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: package-linux-release.sh <vX.Y.Z> <git-sha>" >&2
  exit 2
fi

readonly ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TAG=$1
readonly SHA=$2
readonly VERSION=$($ROOT/scripts/version.sh)
readonly BUNDLE=$ROOT/flutter/build/linux-gtk4/x64/release/bundle
readonly WORK=$ROOT/build/linux-release
readonly OUTPUT_DIR=$ROOT/dist/linux
readonly OUTPUT=$OUTPUT_DIR/zuko-linux-$TAG-x86_64.tar.gz

for command in find git gzip ldd readelf sha256sum strip tar; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Linux package: required command not found: $command" >&2
    exit 1
  }
done

if [[ ! $TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ $TAG != "v$VERSION" ]]; then
  echo "Linux package: tag must be v$VERSION, got $TAG" >&2
  exit 1
fi
commit=$(git -C "$ROOT" rev-parse "$SHA^{commit}")
if [[ $commit != "$(git -C "$ROOT" rev-parse HEAD)" ]]; then
  echo "Linux package: $SHA does not resolve to HEAD" >&2
  exit 1
fi
if [[ $(uname -m) != x86_64 ]]; then
  echo "Linux package: only x86_64 builds are supported" >&2
  exit 1
fi
for required in "$BUNDLE/zuko" "$BUNDLE/data" "$BUNDLE/lib"; do
  [[ -e $required ]] || {
    echo "Linux package: missing Flutter release output: $required" >&2
    exit 1
  }
done
if find "$BUNDLE" -type l -print -quit | grep -q .; then
  echo "Linux package: symbolic links are not allowed in the release bundle" >&2
  exit 1
fi
if find "$BUNDLE" -type f -perm /6000 -print -quit | grep -q .; then
  echo "Linux package: setuid or setgid files are not allowed" >&2
  exit 1
fi

check_linkage() {
  local root=$1 binary dynamic linkage runtime_path path paths saw_gtk4=false
  while IFS= read -r -d '' binary; do
    dynamic=$(readelf -d "$binary" 2>/dev/null || true)
    while IFS= read -r runtime_path; do
      runtime_path=${runtime_path#*[}
      runtime_path=${runtime_path%]*}
      IFS=: read -r -a paths <<<"$runtime_path"
      for path in "${paths[@]}"; do
        [[ $path == '$ORIGIN' || $path == '$ORIGIN/'* ]] || {
          echo "Linux package: non-relocatable runtime path in $binary: $path" >&2
          exit 1
        }
      done
    done < <(grep -E '\((RPATH|RUNPATH)\)' <<<"$dynamic" || true)
    linkage=$(ldd "$binary")
    printf '%s\n' "$linkage"
    if [[ $linkage == *"not found"* ]]; then
      echo "Linux package: unresolved dependency in $binary" >&2
      exit 1
    fi
    if [[ $linkage == *"libgtk-3.so.0"* ]]; then
      echo "Linux package: GTK4 bundle loads GTK3 through $binary" >&2
      exit 1
    fi
    if [[ $linkage == *"libgtk-4.so.1"* ]]; then
      saw_gtk4=true
    fi
  done < <(find "$root" -type f \( -name zuko -o -name '*.so' -o -name '*.so.*' \) -print0)
  if [[ $saw_gtk4 != true ]]; then
    echo "Linux package: bundle does not load GTK4" >&2
    exit 1
  fi
}
check_linkage "$BUNDLE"

validate_release_payload() {
  local root=$1 binary sections
  if find "$root" -type f \( \
    -name kernel_blob.bin -o \
    -name vm_snapshot_data -o \
    -name isolate_snapshot_data -o \
    -name '*.dill' \
  \) -print -quit | grep -q .; then
    echo "Linux package: release bundle contains a JIT artifact" >&2
    exit 1
  fi
  while IFS= read -r -d '' binary; do
    sections=$(readelf --sections --wide "$binary" 2>/dev/null || true)
    if grep -Eq '\.debug_(info|line)\b' <<<"$sections"; then
      echo "Linux package: debug sections remain in $binary" >&2
      exit 1
    fi
  done < <(find "$root" -type f \( -name zuko -o -name '*.so' -o -name '*.so.*' \) -print0)
}

if [[ -z ${SOURCE_DATE_EPOCH:-} ]]; then
  SOURCE_DATE_EPOCH=$(git -C "$ROOT" show -s --format=%ct "$commit")
fi
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]+$ ]] || {
  echo "Linux package: SOURCE_DATE_EPOCH must be an integer" >&2
  exit 1
}
export SOURCE_DATE_EPOCH TZ=UTC LC_ALL=C.UTF-8

rm -rf "$WORK" "$OUTPUT_DIR"
mkdir -p "$WORK/staging/bundle" "$WORK/extracted" "$OUTPUT_DIR"
cp -a "$BUNDLE/." "$WORK/staging/bundle/"
while IFS= read -r -d '' binary; do
  strip --strip-unneeded "$binary"
done < <(find "$WORK/staging/bundle" -type f \( \
  -name zuko -o -name '*.so' -o -name '*.so.*' \
\) -print0)
validate_release_payload "$WORK/staging/bundle"
find "$WORK/staging" -exec touch --no-dereference --date="@$SOURCE_DATE_EPOCH" {} +

(
  cd "$WORK/staging"
  tar \
    --sort=name \
    --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --mode='u+rwX,go+rX,go-w' \
    --pax-option=delete=atime,delete=ctime \
    -cf - bundle | gzip -n > "$OUTPUT"
)

# Verify that the published bytes preserve the complete Flutter layout and can
# be unpacked by FlatPark without privilege or network access.
tar --no-same-owner -xzf "$OUTPUT" -C "$WORK/extracted"
for required in \
  "$WORK/extracted/bundle/zuko" \
  "$WORK/extracted/bundle/data" \
  "$WORK/extracted/bundle/lib"; do
  [[ -e $required ]] || {
    echo "Linux package: archive is missing $required" >&2
    exit 1
  }
done
[[ -x $WORK/extracted/bundle/zuko ]] || {
  echo "Linux package: archived Zuko executable is not executable" >&2
  exit 1
}
check_linkage "$WORK/extracted/bundle"
validate_release_payload "$WORK/extracted/bundle"

(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256"
  sha256sum --check "$(basename "$OUTPUT").sha256"
)

echo "Linux package: $OUTPUT"
echo "Linux package: $OUTPUT.sha256"
