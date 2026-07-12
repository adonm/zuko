#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: build-flatpak-repository.sh <bundle.flatpak> <output-repo>" >&2
  exit 2
fi
: "${FLATPAK_GPG_PRIVATE_KEY_BASE64:?FLATPAK_GPG_PRIVATE_KEY_BASE64 is required}"

readonly ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly PUBLIC_KEY="$ROOT/flatpak/zuko-flatpak-repo.gpg"
readonly BUNDLE=$(realpath "$1")
readonly REPO=$(realpath -m "$2")
readonly TEMP_ROOT=${RUNNER_TEMP:-$ROOT/.tmp}
readonly GPG_HOME="$TEMP_ROOT/zuko-flatpak-repo-gnupg"
readonly PRIVATE_KEY="$TEMP_ROOT/zuko-flatpak-repo-private.asc"

for command in base64 flatpak gpg ostree realpath; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Flatpak repository: required command not found: $command" >&2
    exit 1
  }
done
[[ -f "$BUNDLE" && "$BUNDLE" == *.flatpak ]] || {
  echo "Flatpak repository: expected a .flatpak bundle" >&2
  exit 1
}
[[ -s "$PUBLIC_KEY" ]] || {
  echo "Flatpak repository: missing public signing key" >&2
  exit 1
}
encoded_public_key=$(base64 --wrap=0 "$PUBLIC_KEY")
for descriptor in "$ROOT/flatpak/zuko.flatpakrepo" "$ROOT/flatpak/zuko.flatpakref"; do
  [[ $(sed -n 's/^GPGKey=//p' "$descriptor") == "$encoded_public_key" ]] || {
    echo "Flatpak repository: signing key does not match $descriptor" >&2
    exit 1
  }
done

cleanup() {
  rm -rf "$GPG_HOME" "$PRIVATE_KEY"
}
trap cleanup EXIT
cleanup
mkdir -m 700 -p "$GPG_HOME"
umask 077
printf '%s' "$FLATPAK_GPG_PRIVATE_KEY_BASE64" | base64 --decode > "$PRIVATE_KEY"
gpg --homedir "$GPG_HOME" --batch --import "$PRIVATE_KEY" >/dev/null 2>&1

mapfile -t secret_fingerprints < <(
  gpg --homedir "$GPG_HOME" --batch --with-colons --list-secret-keys |
    awk -F: '$1 == "sec" { primary = 1; next } primary && $1 == "fpr" { print $10; primary = 0 }'
)
mapfile -t public_fingerprints < <(
  gpg --batch --with-colons --show-keys "$PUBLIC_KEY" |
    awk -F: '$1 == "pub" { primary = 1; next } primary && $1 == "fpr" { print $10; primary = 0 }'
)
if [[ ${#secret_fingerprints[@]} -ne 1 || ${#public_fingerprints[@]} -ne 1 ||
      ${secret_fingerprints[0]} != "${public_fingerprints[0]}" ]]; then
  echo "Flatpak repository: private and public signing identities do not match" >&2
  exit 1
fi
fingerprint=${secret_fingerprints[0]}

rm -rf "$REPO"
mkdir -p "$REPO"
ostree init --repo="$REPO" --mode=archive-z2
flatpak build-import-bundle \
  --gpg-sign="$fingerprint" \
  --gpg-homedir="$GPG_HOME" \
  --update-appstream \
  "$REPO" "$BUNDLE"
flatpak build-update-repo \
  --title=Zuko \
  --comment='Signed Zuko testing builds' \
  --description='Checksummed release builds for testing the Zuko Flutter client.' \
  --homepage=https://zuko.adonm.dev/ \
  --icon=https://zuko.adonm.dev/zuko-logo.png \
  --default-branch=stable \
  --gpg-import="$PUBLIC_KEY" \
  --gpg-sign="$fingerprint" \
  --gpg-homedir="$GPG_HOME" \
  --generate-static-deltas \
  "$REPO"

test -s "$REPO/summary"
test -s "$REPO/summary.sig"
test -d "$REPO/objects"
echo "Flatpak repository: signed by $fingerprint"
echo "Flatpak repository: $REPO"
