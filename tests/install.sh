#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init

DIST="$TEST_TMP/dist"
"$ROOT/scripts/package-release" --dist "$DIST" --tag v24.1 >/dev/null

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
INSTALL_ROOT="$TEST_DATA/fastly-audit"

[[ -L "$PRIMARY" ]]
[[ -L "$LEGACY" ]]
[[ -L "$UPDATER" ]]
[[ -x "$INSTALL_ROOT/fastly-audit" ]]
[[ -x "$INSTALL_ROOT/ngwaf" ]]
[[ -x "$INSTALL_ROOT/ngwaf-update" ]]

[[ "$("$PRIMARY" version)" == "fastly-audit 24.1" ]]
[[ "$("$LEGACY" version)" == "ngwaf 24.1" ]]

grep -F 'Downloading https://example.invalid/releases/latest/download/fastly-audit.tar.gz' "$TEST_TMP/install-output" >/dev/null
grep -F 'fastly-audit.tar.gz: OK' "$TEST_TMP/install-output" >/dev/null
grep -F 'Primary command:' "$TEST_TMP/install-output" >/dev/null
grep -F 'Compatibility command:' "$TEST_TMP/install-output" >/dev/null
grep -F 'Updater command:' "$TEST_TMP/install-output" >/dev/null
grep -F 'Install complete.' "$TEST_TMP/install-output" >/dev/null
grep -F "For this terminal, run: export PATH=\"$TEST_HOME/bin:" "$TEST_TMP/install-output" >/dev/null
grep -F "Set FASTLY_API_TOKEN, then run: $TEST_HOME/bin/fastly-audit setup --customer-id test-customer" "$TEST_TMP/install-output" >/dev/null

printf 'install: OK\n'
