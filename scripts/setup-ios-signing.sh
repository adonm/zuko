#!/bin/sh
# scripts/setup-ios-signing.sh
#
# One-time setup for the iOS signed-build / TestFlight pipeline. Generates the
# Apple signing material, walks you through the developer-portal dance, and
# pushes the seven secrets GitHub Actions needs straight into the repo via
# `gh` — no Mac required, no manual copy-paste into the secrets UI.
#
# Re-running is safe: existing artifacts in the workspace are reused, and the
# GH secrets are overwritten in place (the supported rotation flow). The
# signing artifacts (.key, .p12, .mobileprovision, .p8) live under
# $ZUKO_IOS_SIGNING_DIR (default ~/.config/zuko/ios-signing) so they survive
# a `git clean`; back them up to your password manager — the .key is the only
# way to renew the cert without redoing the portal dance.
#
# Prereqs:
#   - openssl on PATH (every Mac + most Linux distros)
#   - gh on PATH, authenticated (`gh auth login`)
#   - run from inside the zuko repo (gh auto-detects the repo via git remote)
#   - an Apple Developer Program membership + access to developer.apple.com
#     and appstoreconnect.apple.com
#
# Usage:
#   mise run setup-ios-signing
#   sh scripts/setup-ios-signing.sh
#
# After it finishes, run the release-flutter-ios workflow with lane=build to verify
# signing end-to-end (no TestFlight slot spent); then lane=beta for TestFlight.
# See docs/releasing.md.
set -eu

# ─── pre-flight ────────────────────────────────────────────────────────────
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing dep: $1 (install it, then re-run)" >&2
        exit 1
    }
}
need openssl
need gh
need base64

if [ ! -t 0 ]; then
    echo "this script is interactive — run it from a terminal, not piped." >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "gh is not authenticated. Run: gh auth login" >&2
    exit 1
fi
# gh auto-detects the repo via git remote; fail loudly here instead of pushing
# secrets to the wrong repo. Capture the repo name NOW — the script later
# `cd`s into a workspace outside the repo, after which `gh` can't auto-detect
# any more (so every later `gh` call passes `--repo "$REPO"` explicitly).
if ! REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"; then
    echo "gh couldn't identify the current repo." >&2
    echo "cd into the zuko checkout (or set GH_REPO) and re-run." >&2
    exit 1
fi

WORKDIR="${ZUKO_IOS_SIGNING_DIR:-$HOME/.config/zuko/ios-signing}"
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
cd "$WORKDIR"
umask 077  # everything written here is sensitive (.key, .p12, .p8)

echo "==> workspace: $WORKDIR"
echo "==> target repo: $REPO"
echo "    (workspace lives outside the repo so 'git clean' can't delete it;"
echo "     back it up to your password manager when done.)"
echo ""

# ─── 1. private key + CSR ──────────────────────────────────────────────────
if [ -f zuko.key ] && [ -f zuko.csr ]; then
    echo "==> reusing existing zuko.key + zuko.csr"
else
    echo "==> generating RSA private key + CSR for 'Apple Distribution: Zuko'"
    openssl req -newkey rsa:2048 -nodes \
        -keyout zuko.key -out zuko.csr \
        -subj "/CN=Zuko Distribution"
fi

# ─── 2. user uploads CSR to Apple, downloads .cer ──────────────────────────
if [ ! -f zuko.cer ]; then
    cat <<EOF

==> ACTION NEEDED (Apple Developer portal):

    1. open https://developer.apple.com/account/resources/certificates/add
    2. choose "Apple Distribution" (NOT the older "iOS Distribution")
    3. upload this CSR:  $WORKDIR/zuko.csr
    4. download the resulting .cer
    5. save it as:      $WORKDIR/zuko.cer

    Press ENTER when zuko.cer is in place.
EOF
    read -r _
fi
[ -f zuko.cer ] || { echo "zuko.cer still missing — aborting." >&2; exit 1; }

# ─── 3. combine key + cer into a password-protected .p12 ───────────────────
if [ -f zuko.p12 ] && [ -f p12-password ]; then
    echo "==> reusing existing zuko.p12 (and its password)"
else
    # Hex-only avoids any quoting/escaping pitfalls when GH Actions later
    # passes the password through to import-codesign-certs. 24 random bytes
    # = 192 bits, far beyond reach.
    P12_PASSWORD="$(openssl rand -hex 24)"
    printf '%s' "$P12_PASSWORD" > p12-password
    echo "==> building zuko.p12 (password-protected)"
    # openssl 3.x defaults to a newer PKCS12 format that some keychain
    # tooling rejects; `-legacy` writes the widely-compatible form. The
    # fallback covers openssl 1.x where `-legacy` is unknown.
    if ! openssl pkcs12 -export -legacy \
        -out zuko.p12 -inkey zuko.key -in zuko.cer \
        -passout pass:"$P12_PASSWORD" 2>/dev/null; then
        openssl pkcs12 -export \
            -out zuko.p12 -inkey zuko.key -in zuko.cer \
            -passout pass:"$P12_PASSWORD"
    fi
fi

# ─── 4. user creates App Store profile, downloads .mobileprovision ─────────
if [ ! -f Zuko_AppStore.mobileprovision ]; then
    cat <<EOF

==> ACTION NEEDED (Apple Developer portal):

    1. open https://developer.apple.com/account/resources/profiles/add
    2. under "iOS, tvOS, watchOS" choose "App Store Connect"
    3. App ID:      dev.adonm.zuko
    4. Certificate: the "Zuko Distribution" cert you just created
    5. generate, then download the profile
    6. save it as: $WORKDIR/Zuko_AppStore.mobileprovision

    Press ENTER when the profile is in place.
EOF
    read -r _
fi
[ -f Zuko_AppStore.mobileprovision ] || {
    echo "profile still missing — aborting." >&2
    exit 1
}

# ─── 5. Apple Team ID + App Store Connect API key ──────────────────────────
if [ -f team-id ]; then
    TEAM_ID="$(cat team-id)"
    echo "==> reusing team-id: $TEAM_ID"
else
    printf '\nApple Team ID (10 chars, find it at https://developer.apple.com/account/#/MembershipDetailsCard): '
    read -r TEAM_ID
    [ -n "$TEAM_ID" ] || { echo "empty Team ID — aborting." >&2; exit 1; }
    printf '%s' "$TEAM_ID" > team-id
fi

if [ -f asc-key-id ] && [ -f asc-issuer-id ]; then
    ASC_KEY_ID="$(cat asc-key-id)"
    ASC_ISSUER_ID="$(cat asc-issuer-id)"
    echo "==> reusing ASC key/issuer IDs"
else
    cat <<EOF

==> ACTION NEEDED (App Store Connect API key):

    1. open https://appstoreconnect.apple.com/access/integrations/api
    2. generate a key with "App Manager" (or "Admin") role
    3. note the Key ID and Issuer ID on that page
    4. download the .p8 (one-time download — keep it safe)
EOF
    printf 'Key ID: '
    read -r ASC_KEY_ID
    [ -n "$ASC_KEY_ID" ] || { echo "empty Key ID — aborting." >&2; exit 1; }
    printf 'Issuer ID (UUID): '
    read -r ASC_ISSUER_ID
    [ -n "$ASC_ISSUER_ID" ] || { echo "empty Issuer ID — aborting." >&2; exit 1; }
    printf '%s' "$ASC_KEY_ID" > asc-key-id
    printf '%s' "$ASC_ISSUER_ID" > asc-issuer-id
fi

# Locate the .p8 — check the workspace first, then the usual browser-download
# spots (`~/Downloads` is where every browser dumps it; matching by the ASC
# Key ID is most specific, falling back to any AuthKey_*.p8). Only prompt if
# none of those have it, so the common case is zero typing.
P8_PATH=""
for f in AuthKey_*.p8; do
    [ -f "$f" ] && P8_PATH="$f" && break
done
if [ -z "$P8_PATH" ]; then
    for candidate in \
        "$HOME/Downloads/AuthKey_${ASC_KEY_ID}.p8" \
        "$HOME/Downloads/AuthKey_*.p8" \
        "./AuthKey_${ASC_KEY_ID}.p8"; do
        # Glob needs to expand unquoted; one candidate per iteration.
        # shellcheck disable=SC2086
        for f in $candidate; do
            if [ -f "$f" ]; then
                P8_PATH="$f"
                break 2
            fi
        done
    done
fi
if [ -n "$P8_PATH" ]; then
    echo "==> found .p8 at: $P8_PATH"
else
    printf '\nCould not find the .p8 automatically. Drop it in ~/Downloads and re-run,\nor enter its path here:\n  '
    read -r P8_PATH
    # Expand a leading ~/ (POSIX: case, not the bash ${var/#..} extension).
    # The tilde in the strip pattern needs `\~` — unescaped, it expands to
    # $HOME inside the parameter expansion too, so the pattern stops matching.
    case "$P8_PATH" in
        \~/*) P8_PATH="$HOME/${P8_PATH#\~/}" ;;
        \~)   P8_PATH="$HOME" ;;
    esac
    [ -f "$P8_PATH" ] || { echo "$P8_PATH not found — aborting." >&2; exit 1; }
fi
# Normalise into the workspace so re-runs don't re-hunt for it.
if [ "$(dirname -- "$P8_PATH")" != "$WORKDIR" ]; then
    cp "$P8_PATH" "./AuthKey_${ASC_KEY_ID}.p8"
    P8_PATH="./AuthKey_${ASC_KEY_ID}.p8"
fi

# ─── 6. push the seven secrets to GitHub via `gh` ──────────────────────────
echo ""
echo "==> setting GitHub Actions secrets on $REPO..."
# `--repo "$REPO"` is explicit because we cd'd into $WORKDIR (outside the
# repo) — without it, `gh` would try git-based auto-detection from $WORKDIR
# and fail with "not a git repository".
# `base64 | tr -d '\n'` produces a single unbroken line, which is what the
# import-codesign-certs action expects (macOS `base64` wraps by default).
base64 < zuko.p12 | tr -d '\n' | gh secret set --repo "$REPO" BUILD_CERTIFICATE_BASE64
gh secret set --repo "$REPO" P12_PASSWORD < p12-password
base64 < Zuko_AppStore.mobileprovision | tr -d '\n' \
    | gh secret set --repo "$REPO" PROVISIONING_PROFILE_BASE64
gh secret set --repo "$REPO" TEAM_ID --body "$TEAM_ID"
gh secret set --repo "$REPO" ASC_KEY_ID --body "$ASC_KEY_ID"
gh secret set --repo "$REPO" ASC_ISSUER_ID --body "$ASC_ISSUER_ID"
# Read the .p8 raw — GitHub preserves the interior newlines altool needs.
gh secret set --repo "$REPO" ASC_KEY_CONTENT < "$P8_PATH"

# ─── 7. verify + summary ───────────────────────────────────────────────────
echo ""
echo "==> secrets currently set on $REPO:"
gh secret list --repo "$REPO"

cat <<EOF

==> done. all seven secrets are set on $REPO.

Artifacts in $WORKDIR  (KEEP SAFE — back them up to a password manager):
  zuko.key                          private key (needed to renew the cert)
  zuko.csr                          certificate signing request
  zuko.cer                          Apple Distribution cert
  zuko.p12 + p12-password           cert+key bundle + its password
  Zuko_AppStore.mobileprovision     the App Store profile
  team-id / asc-key-id / asc-issuer-id / AuthKey_*.p8   API auth material

Next: verify end-to-end WITHOUT spending a TestFlight slot —
  GitHub → Actions → release-flutter-ios → Run workflow → lane: build
Then push to TestFlight:
  same flow, lane: beta.

See docs/releasing.md for details.
EOF
