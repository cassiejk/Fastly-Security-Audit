#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init

# Installer coverage is local-only; never inherit a developer's credentials,
# customer selection, release overrides, or interactive Bash startup hooks.
unset FASTLY_API_TOKEN FASTLY_CUSTOMER_ID BASH_ENV ENV CDPATH
unset FASTLY_AUDIT_ARCHIVE_URL FASTLY_AUDIT_CHECKSUM_URL FASTLY_AUDIT_INSTALL_ROOT
unset FASTLY_AUDIT_BIN_DIR FASTLY_AUDIT_VERSION FASTLY_AUDIT_REPO
export XDG_CONFIG_HOME="$TEST_TMP/config"

DIST="$TEST_TMP/dist"
"$ROOT/scripts/package-release" --dist "$DIST" --tag v24.2.3 >/dev/null

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
ln -s "$BASH" "$TEST_TMP/bin/bash"
ln -s "$(command -v jq)" "$TEST_TMP/bin/jq"
TEST_PATH="$TEST_TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"

TEST_HOME="$TEST_TMP/home"
TEST_DATA="$TEST_TMP/data"
mkdir -p "$TEST_HOME"

PATH="$TEST_PATH" \
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
INSTALLED_FA="$(cd "$TEST_HOME/bin" && pwd -P)/fa"
INSTALLED_BIN_DIR="${INSTALLED_FA%/fa}"

[[ -L "$PRIMARY" ]]
[[ -L "$LEGACY" ]]
[[ -L "$UPDATER" ]]
[[ -L "$SHORT" ]]
[[ -x "$INSTALL_ROOT/fastly-audit" ]]
[[ -x "$INSTALL_ROOT/ngwaf" ]]
[[ -x "$INSTALL_ROOT/ngwaf-update" ]]
[[ "$(readlink "$SHORT")" == "$INSTALL_ROOT/fastly-audit" ]]

[[ "$("$PRIMARY" version)" == "fastly-audit 24.2.3" ]]
[[ "$("$LEGACY" version)" == "ngwaf 24.2.3" ]]
[[ "$("$SHORT" version)" == "fastly-audit 24.2.3" ]]

grep -F 'Downloading fastly-audit.tar.gz' "$TEST_TMP/install-output" >/dev/null
grep -F 'fastly-audit.tar.gz: OK' "$TEST_TMP/install-output" >/dev/null
grep -F 'Fastly-Audit installed successfully!' "$TEST_TMP/install-output" >/dev/null
grep -F 'Local verification: PASS (Fastly API access unverified)' "$TEST_TMP/install-output" >/dev/null
grep -F 'Version: fastly-audit 24.2.3' "$TEST_TMP/install-output" >/dev/null
grep -F "Installed command: $INSTALLED_FA" "$TEST_TMP/install-output" >/dev/null
grep -F 'Shell command: fa is not on PATH in this terminal.' "$TEST_TMP/install-output" >/dev/null
grep -F "For this terminal, run: export PATH=$INSTALLED_BIN_DIR:\"\$PATH\"" "$TEST_TMP/install-output" >/dev/null
grep -F 'Customer setup: incomplete.' "$TEST_TMP/install-output" >/dev/null
grep -F "Run: $INSTALLED_FA setup --customer-id test-customer" "$TEST_TMP/install-output" >/dev/null
grep -F "Need help? Run: $INSTALLED_FA setup --help" "$TEST_TMP/install-output" >/dev/null

# Opt-in shell configuration is idempotent and leaves credentials untouched.
SHELL=/bin/zsh PATH="$TEST_PATH" HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
FASTLY_AUDIT_TEST_DIST="$DIST" FASTLY_AUDIT_RELEASE_BASE_URL="https://example.invalid/releases/latest/download" \
"$ROOT/install.sh" --configure-shell --skip-setup >"$TEST_TMP/configure-output"
# shellcheck disable=SC2016
grep -Fqx 'export PATH="$HOME/bin:$PATH"' "$TEST_HOME/.zprofile"
grep -F 'PATH change takes effect in new terminals only' "$TEST_TMP/configure-output" >/dev/null
SHELL=/bin/zsh PATH="$TEST_PATH" HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
FASTLY_AUDIT_TEST_DIST="$DIST" FASTLY_AUDIT_RELEASE_BASE_URL="https://example.invalid/releases/latest/download" \
"$ROOT/install.sh" --configure-shell --skip-setup >"$TEST_TMP/configure-again-output"
# shellcheck disable=SC2016
[[ "$(grep -Fc 'export PATH="$HOME/bin:$PATH"' "$TEST_HOME/.zprofile")" == 1 ]]

# A damaged release checksum must stop before touching an installation.
mkdir -p "$TEST_TMP/bad-dist" "$TEST_TMP/bad-home"
cp "$DIST/fastly-audit.tar.gz" "$TEST_TMP/bad-dist/fastly-audit.tar.gz"
printf '%s\n' '0000000000000000000000000000000000000000000000000000000000000000  fastly-audit.tar.gz' >"$TEST_TMP/bad-dist/fastly-audit.tar.gz.sha256"
if PATH="$TEST_PATH" HOME="$TEST_TMP/bad-home" XDG_DATA_HOME="$TEST_TMP/bad-home/data" \
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
