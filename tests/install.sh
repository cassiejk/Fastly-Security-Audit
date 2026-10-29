#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init

DIST="$TEST_TMP/dist"
"$ROOT/scripts/package-release" --dist "$DIST" --tag v24.2 >/dev/null

mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
outfile=""
url=""

while (( $# > 0 )); do
  case "$1" in
    -o)
      outfile="$2"
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  */fastly-audit.tar.gz)
    cp "$FASTLY_AUDIT_TEST_DIST/fastly-audit.tar.gz" "$outfile"
    ;;
  */fastly-audit.tar.gz.sha256)
    cp "$FASTLY_AUDIT_TEST_DIST/fastly-audit.tar.gz.sha256" "$outfile"
    ;;
  *)
    printf 'fake curl: unexpected URL: %s\n' "$url" >&2
    exit 22
    ;;
esac
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"

TEST_HOME="$TEST_TMP/home"
TEST_DATA="$TEST_TMP/data"
mkdir -p "$TEST_HOME"

PATH="$TEST_TMP/bin:$PATH" \
HOME="$TEST_HOME" \
XDG_DATA_HOME="$TEST_DATA" \
FASTLY_AUDIT_TEST_DIST="$DIST" \
FASTLY_AUDIT_RELEASE_BASE_URL="https://example.invalid/releases/latest/download" \
NGWAF_PROGRESS=never \
"$ROOT/install.sh" --customer-id test-customer >"$TEST_TMP/install-output"

PRIMARY="$TEST_HOME/bin/fastly-audit"
LEGACY="$TEST_HOME/bin/ngwaf"
UPDATER="$TEST_HOME/bin/ngwaf-update"
SHORT="$TEST_HOME/bin/fa"
INSTALL_ROOT="$TEST_DATA/fastly-audit"

[[ -L "$PRIMARY" ]]
[[ -L "$LEGACY" ]]
[[ -L "$UPDATER" ]]
[[ -L "$SHORT" ]]
[[ -x "$INSTALL_ROOT/fastly-audit" ]]
[[ -x "$INSTALL_ROOT/ngwaf" ]]
[[ -x "$INSTALL_ROOT/ngwaf-update" ]]
[[ "$(readlink "$SHORT")" == "$INSTALL_ROOT/fastly-audit" ]]

[[ "$("$PRIMARY" version)" == "fastly-audit 24.2" ]]
[[ "$("$LEGACY" version)" == "ngwaf 24.2" ]]
[[ "$("$SHORT" version)" == "fastly-audit 24.2" ]]

grep -F 'Downloading fastly-audit.tar.gz' "$TEST_TMP/install-output" >/dev/null
grep -F 'fastly-audit.tar.gz: OK' "$TEST_TMP/install-output" >/dev/null
grep -F 'Primary command:' "$TEST_TMP/install-output" >/dev/null
grep -F 'Compatibility command:' "$TEST_TMP/install-output" >/dev/null
grep -F 'Updater command:' "$TEST_TMP/install-output" >/dev/null
grep -F 'Short command:' "$TEST_TMP/install-output" >/dev/null
grep -F 'Install complete.' "$TEST_TMP/install-output" >/dev/null
grep -F "For this terminal, run: export PATH=\"$TEST_HOME/bin:" "$TEST_TMP/install-output" >/dev/null
grep -F "Load FASTLY_API_TOKEN through your approved credential workflow, then run: $TEST_HOME/bin/fa setup --customer-id test-customer" "$TEST_TMP/install-output" >/dev/null

# Opt-in shell configuration is idempotent and leaves credentials untouched.
SHELL=/bin/zsh PATH="$TEST_TMP/bin:$PATH" HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
FASTLY_AUDIT_TEST_DIST="$DIST" FASTLY_AUDIT_RELEASE_BASE_URL="https://example.invalid/releases/latest/download" \
"$ROOT/install.sh" --configure-shell --skip-setup >"$TEST_TMP/configure-output"
# shellcheck disable=SC2016
grep -Fqx 'export PATH="$HOME/bin:$PATH"' "$TEST_HOME/.zprofile"
SHELL=/bin/zsh PATH="$TEST_TMP/bin:$PATH" HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
FASTLY_AUDIT_TEST_DIST="$DIST" FASTLY_AUDIT_RELEASE_BASE_URL="https://example.invalid/releases/latest/download" \
"$ROOT/install.sh" --configure-shell --skip-setup >"$TEST_TMP/configure-again-output"
# shellcheck disable=SC2016
[[ "$(grep -Fc 'export PATH="$HOME/bin:$PATH"' "$TEST_HOME/.zprofile")" == 1 ]]

# A damaged release checksum must stop before touching an installation.
mkdir -p "$TEST_TMP/bad-dist" "$TEST_TMP/bad-home"
cp "$DIST/fastly-audit.tar.gz" "$TEST_TMP/bad-dist/fastly-audit.tar.gz"
printf '%s\n' '0000000000000000000000000000000000000000000000000000000000000000  fastly-audit.tar.gz' >"$TEST_TMP/bad-dist/fastly-audit.tar.gz.sha256"
if PATH="$TEST_TMP/bin:$PATH" HOME="$TEST_TMP/bad-home" XDG_DATA_HOME="$TEST_TMP/bad-home/data" \
  FASTLY_AUDIT_TEST_DIST="$TEST_TMP/bad-dist" FASTLY_AUDIT_RELEASE_BASE_URL="https://example.invalid/releases/latest/download" \
  "$ROOT/install.sh" >"$TEST_TMP/bad-out" 2>"$TEST_TMP/bad-err"; then
  printf 'install: damaged checksum unexpectedly succeeded\n' >&2; exit 1
fi
[[ ! -e "$TEST_TMP/bad-home/bin/fa" && ! -e "$TEST_TMP/bad-home/data/fastly-audit" ]]

mkdir -p "$TEST_TMP/empty-path"
if PATH="$TEST_TMP/empty-path" "$BASH" "$ROOT/install.sh" --skip-setup >"$TEST_TMP/dependency-out" 2>"$TEST_TMP/dependency-err"; then
  printf 'install: missing curl unexpectedly succeeded\n' >&2; exit 1
fi
grep -F 'missing dependency: curl' "$TEST_TMP/dependency-err" >/dev/null

printf 'install: OK\n'
