#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zuko-installer-test.XXXXXX")
cleanup() {
    rm -rf "$WORK"
}
trap cleanup 0 HUP INT TERM

MOCK_BIN="$WORK/bin"
FIXTURES="$WORK/fixtures"
HOME_DIR="$WORK/home"
mkdir -p "$MOCK_BIN" "$FIXTURES" "$HOME_DIR"

cat > "$FIXTURES/mise" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "${MISE_TEST_LOG:?}"
case "${1:-}" in
    where) [ -f "${MISE_TEST_INSTALLED:?}" ] ;;
    use) touch "${MISE_TEST_INSTALLED:?}" ;;
    upgrade) exit 0 ;;
    trust) exit 0 ;;
    bootstrap)
        config_dir=
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -C ]; then
                config_dir=$2
                break
            fi
            shift
        done
        [ -n "$config_dir" ]
        if grep -Fq 'bashrc = "activate"' "$config_dir/mise.toml"; then
            rc_file="$HOME/.bashrc"
            if ! grep -Fq '# >>> mise:activate >>>' "$rc_file" 2>/dev/null; then
                printf '%s\n' \
                    '# >>> mise:activate >>> managed by mise - do not edit between markers' \
                    'eval "$(mise activate bash)"' \
                    '# <<< mise:activate <<<' >> "$rc_file"
            fi
        fi
        ;;
    exec)
        [ "${2:-}" = -- ]
        [ "${3:-}" = zuko ]
        [ "${4:-}" = --version ]
        printf 'zuko 1.2.3\n'
        ;;
    *) exit 0 ;;
esac
EOF
chmod 0755 "$FIXTURES/mise"

cat > "$MOCK_BIN/uname" <<'EOF'
#!/bin/sh
case "$1" in
    -s) printf 'Linux\n' ;;
    -m) printf 'x86_64\n' ;;
    *) exit 2 ;;
esac
EOF

cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/sh
set -eu
for arg in "$@"; do
    case "$arg" in
        https://mise.run)
            cat <<'INSTALL'
mkdir -p "$HOME/.local/bin"
cp "$MISE_FIXTURE" "$HOME/.local/bin/mise"
chmod 0755 "$HOME/.local/bin/mise"
INSTALL
            exit 0
            ;;
    esac
done
exit 2
EOF
chmod 0755 "$MOCK_BIN/uname" "$MOCK_BIN/curl"

MISE_TEST_LOG="$WORK/mise.log" \
MISE_TEST_INSTALLED="$WORK/zuko-installed" \
MISE_FIXTURE="$FIXTURES/mise" \
MISE_SHELL= \
HOME="$HOME_DIR" \
SHELL=/bin/bash \
PATH="$MOCK_BIN:/usr/bin:/bin" \
ZUKO_VERSION=1.2.3 \
    sh "$ROOT/docs/install.sh" > "$WORK/output"

[ -x "$HOME_DIR/.local/bin/mise" ]
grep -Fq 'use --global github:adonm/zuko[minimum_release_age=0s]@1.2.3' "$WORK/mise.log"
if grep -Fq 'upgrade github:adonm/zuko' "$WORK/mise.log"; then
    echo "fresh install unexpectedly ran mise upgrade" >&2
    exit 1
fi
grep -Fq 'exec -- zuko --version' "$WORK/mise.log"
grep -Fq 'bootstrap --yes --only mise-shell-activate -C' "$WORK/mise.log"
grep -Fq '# >>> mise:activate >>>' "$HOME_DIR/.bashrc"
grep -Fq 'activate bash' "$HOME_DIR/.bashrc"
bash -n "$HOME_DIR/.bashrc"
grep -Fq 'Exit and relaunch your shell' "$WORK/output"

before=$(grep -Fc 'activate bash' "$HOME_DIR/.bashrc")
: > "$WORK/mise.log"
MISE_TEST_LOG="$WORK/mise.log" \
MISE_TEST_INSTALLED="$WORK/zuko-installed" \
MISE_SHELL= \
HOME="$HOME_DIR" \
SHELL=/bin/bash \
PATH="$MOCK_BIN:$HOME_DIR/.local/bin:/usr/bin:/bin" \
    sh "$ROOT/docs/install.sh" > "$WORK/second-output"
after=$(grep -Fc 'activate bash' "$HOME_DIR/.bashrc")
[ "$before" -eq "$after" ]
grep -Fq 'use --global github:adonm/zuko[minimum_release_age=0s]' "$WORK/mise.log"
grep -Fq 'upgrade github:adonm/zuko' "$WORK/mise.log"
grep -Fq 'Upgrading github:adonm/zuko[minimum_release_age=0s]' "$WORK/second-output"

MISE_TEST_LOG="$WORK/mise.log" \
MISE_TEST_INSTALLED="$WORK/zuko-installed" \
MISE_SHELL=bash \
HOME="$HOME_DIR" \
SHELL=/bin/bash \
PATH="$MOCK_BIN:$HOME_DIR/.local/bin:/usr/bin:/bin" \
    sh "$ROOT/docs/install.sh" > "$WORK/active-output"
grep -Fq 'Next:' "$WORK/active-output"

echo "test-installer: ok"
