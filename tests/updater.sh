#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init

TEST_HOME="$TEST_TMP/home"
TEST_DATA="$TEST_TMP/data"
mkdir -p "$TEST_HOME"

HOME="$TEST_HOME" \
XDG_DATA_HOME="$TEST_DATA" \
NGWAF_PROGRESS=never \
"$ROOT/ngwaf-update" "$ROOT" >"$TEST_TMP/updater-output"

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

[[ "$(readlink "$PRIMARY")" == "$INSTALL_ROOT/fastly-audit" ]]
[[ "$(readlink "$LEGACY")" == "$INSTALL_ROOT/ngwaf" ]]
[[ "$(readlink "$UPDATER")" == "$INSTALL_ROOT/ngwaf-update" ]]

[[ "$("$PRIMARY" version)" == "fastly-audit 24.1" ]]
[[ "$("$LEGACY" version)" == "ngwaf 24.1" ]]
HOME="$TEST_HOME" \
XDG_DATA_HOME="$TEST_DATA" \
NGWAF_PROGRESS=never \
"$UPDATER" "$ROOT" >"$TEST_TMP/updater-self-output"
grep -F "Updater command:" "$TEST_TMP/updater-self-output" >/dev/null
grep -F "fastly-audit doctor --verbose" "$TEST_TMP/updater-self-output" >/dev/null

grep -F "Installed package:" "$TEST_TMP/updater-output" >/dev/null
grep -F "Primary command:" "$TEST_TMP/updater-output" >/dev/null
grep -F "Compatibility command:" "$TEST_TMP/updater-output" >/dev/null
grep -F "Updater command:" "$TEST_TMP/updater-output" >/dev/null
grep -F "PATH note: add $TEST_HOME/bin to PATH" "$TEST_TMP/updater-output" >/dev/null
grep -F "Required runtime: Bash 5.2 or newer via /usr/bin/env bash" "$TEST_TMP/updater-output" >/dev/null
grep -F "Next setup check:" "$TEST_TMP/updater-output" >/dev/null
grep -F "fastly-audit setup --customer-id CUSTOMER_ID" "$TEST_TMP/updater-output" >/dev/null
grep -F "fastly-audit 24.1" "$TEST_TMP/updater-output" >/dev/null
grep -F "ngwaf 24.1" "$TEST_TMP/updater-output" >/dev/null

printf 'updater: OK\n'
