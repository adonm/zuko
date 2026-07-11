#!/bin/sh
set -eu

VERSION="${ZUKO_VERSION:-latest}"
# Override mise's default 24-hour release delay for Zuko only. Keep this as a
# tool option so the installer does not weaken the user's policy for other tools.
MISE_TOOL="github:adonm/zuko[minimum_release_age=0s]"
MISE_TOOL_ID="github:adonm/zuko"
MISE_INSTALLED=0
ZUKO_INSTALLED=0
NEEDS_RELAUNCH=0
BOOTSTRAP_DIR=
: "${HOME:?HOME is not set}"

cleanup() {
    if [ -n "$BOOTSTRAP_DIR" ]; then
        rm -rf "$BOOTSTRAP_DIR"
    fi
}
trap cleanup 0 HUP INT TERM

say() {
    printf '%s\n' "$*"
}

fail() {
    printf 'zuko installer: %s\n' "$*" >&2
    exit 1
}

find_mise() {
    if command -v mise >/dev/null 2>&1; then
        command -v mise
    elif [ -x "$HOME/.local/bin/mise" ]; then
        printf '%s\n' "$HOME/.local/bin/mise"
    elif [ -x "$HOME/.local/share/mise/bin/mise" ]; then
        printf '%s\n' "$HOME/.local/share/mise/bin/mise"
    else
        return 1
    fi
}

bootstrap_activation() {
    shell_path=${SHELL:-}
    shell_name=${shell_path##*/}
    case "$shell_name" in
        bash)
            target=bashrc
            ;;
        zsh)
            target=zshrc
            ;;
        fish)
            target=fish
            ;;
        *)
            say "Could not configure mise activation for ${shell_name:-unknown shell}."
            say "See https://mise.jdx.dev/installing-mise.html#shells"
            return
            ;;
    esac

    BOOTSTRAP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zuko-mise-bootstrap.XXXXXX")
    printf '%s\n' \
        '[settings]' \
        'experimental = true' \
        '' \
        '[bootstrap.mise_shell_activate]' \
        "$target = \"activate\"" > "$BOOTSTRAP_DIR/mise.toml"
    "$MISE_BIN" trust --yes "$BOOTSTRAP_DIR/mise.toml"
    "$MISE_BIN" bootstrap --yes --only mise-shell-activate -C "$BOOTSTRAP_DIR"
    rm -rf "$BOOTSTRAP_DIR"
    BOOTSTRAP_DIR=
    say "Configured mise activation for $shell_name via mise bootstrap"
}

case "$(uname -s)" in
    Linux)
        case "$(uname -m)" in
            x86_64 | amd64 | aarch64 | arm64) ;;
            *) fail "unsupported Linux architecture: $(uname -m)" ;;
        esac
        if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
            fail "Zuko host releases require glibc; musl is not currently supported"
        fi
        ;;
    Darwin)
        case "$(uname -m)" in
            x86_64 | amd64 | aarch64 | arm64) ;;
            *) fail "unsupported macOS architecture: $(uname -m)" ;;
        esac
        ;;
    *) fail "Zuko host releases support Linux and macOS" ;;
esac

case "$VERSION" in
    latest) tool=$MISE_TOOL ;;
    v?*) tool="$MISE_TOOL@${VERSION#v}" ;;
    v) fail "invalid ZUKO_VERSION: $VERSION" ;;
    *) tool="$MISE_TOOL@$VERSION" ;;
esac
case "$VERSION" in
    '' | *[!0-9A-Za-z.-]*) fail "invalid ZUKO_VERSION: $VERSION" ;;
esac

if MISE_BIN=$(find_mise); then
    say "Using mise at $MISE_BIN"
else
    command -v curl >/dev/null 2>&1 || fail "curl is required to install mise"
    say "Installing mise..."
    curl --proto '=https' --tlsv1.2 -fsSL https://mise.run | sh
    MISE_BIN=$(find_mise) || fail "mise installed but its binary could not be found"
    MISE_INSTALLED=1
fi

if [ -z "${MISE_SHELL:-}" ]; then
    NEEDS_RELAUNCH=1
    bootstrap_activation
fi

if "$MISE_BIN" where "$MISE_TOOL_ID" >/dev/null 2>&1; then
    ZUKO_INSTALLED=1
fi

if [ "$ZUKO_INSTALLED" -eq 1 ]; then
    say "Upgrading $tool..."
else
    say "Installing $tool..."
fi
"$MISE_BIN" use --global "$tool"
if [ "$ZUKO_INSTALLED" -eq 1 ]; then
    "$MISE_BIN" upgrade "$MISE_TOOL_ID"
fi
"$MISE_BIN" exec -- zuko --version

say ""
say "Zuko is installed and managed by mise."
if [ "$MISE_INSTALLED" -eq 1 ] || [ "$NEEDS_RELAUNCH" -eq 1 ]; then
    say "Exit and relaunch your shell to activate mise, then run:"
else
    say "Next:"
fi
say "  zuko install"
