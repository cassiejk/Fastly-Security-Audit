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
SHORT="$TEST_HOME/bin/fa"
INSTALL_ROOT="$TEST_DATA/fastly-audit"

[[ -L "$PRIMARY" ]]
[[ -L "$LEGACY" ]]
[[ -L "$UPDATER" ]]
[[ -L "$SHORT" ]]
[[ -x "$INSTALL_ROOT/fastly-audit" ]]
[[ -x "$INSTALL_ROOT/ngwaf" ]]
[[ -x "$INSTALL_ROOT/ngwaf-update" ]]

[[ "$(readlink "$PRIMARY")" == "$INSTALL_ROOT/fastly-audit" ]]
[[ "$(readlink "$LEGACY")" == "$INSTALL_ROOT/ngwaf" ]]
[[ "$(readlink "$UPDATER")" == "$INSTALL_ROOT/ngwaf-update" ]]
[[ "$(readlink "$SHORT")" == "$INSTALL_ROOT/fastly-audit" ]]

[[ "$("$PRIMARY" version)" == "fastly-audit 24.2.3" ]]
[[ "$("$LEGACY" version)" == "ngwaf 24.2.3" ]]
[[ "$("$SHORT" version)" == "fastly-audit 24.2.3" ]]
HOME="$TEST_HOME" \
XDG_DATA_HOME="$TEST_DATA" \
NGWAF_PROGRESS=never \
"$UPDATER" "$ROOT" >"$TEST_TMP/updater-self-output"
grep -F "Updater command:" "$TEST_TMP/updater-self-output" >/dev/null
grep -F "fa ngwaf workspace-services --service-id EXACT_CDN_SERVICE_ID --json" "$TEST_TMP/updater-self-output" >/dev/null

grep -F "Installed package:" "$TEST_TMP/updater-output" >/dev/null
grep -F "Primary command:" "$TEST_TMP/updater-output" >/dev/null
grep -F "Compatibility command:" "$TEST_TMP/updater-output" >/dev/null
grep -F "Updater command:" "$TEST_TMP/updater-output" >/dev/null
grep -F "Short command:" "$TEST_TMP/updater-output" >/dev/null
grep -F "PATH note: add $TEST_HOME/bin to PATH" "$TEST_TMP/updater-output" >/dev/null
grep -F "Required runtime: Bash 5.2 or newer via /usr/bin/env bash" "$TEST_TMP/updater-output" >/dev/null
grep -F "Next setup check:" "$TEST_TMP/updater-output" >/dev/null
grep -F "fa setup --customer-id CUSTOMER_ID" "$TEST_TMP/updater-output" >/dev/null
grep -F "fastly-audit 24.2.3" "$TEST_TMP/updater-output" >/dev/null
grep -F "ngwaf 24.2.3" "$TEST_TMP/updater-output" >/dev/null
grep -F 'ngwaf-update: installation succeeded' "$TEST_TMP/updater-output" >/dev/null
grep -F 'ngwaf-update: upgrade succeeded' "$TEST_TMP/updater-self-output" >/dev/null

# Every command name must refuse an unrelated file before touching the package.
printf 'previous install\n' >"$INSTALL_ROOT/ownership-marker"
for target in "$SHORT" "$PRIMARY" "$LEGACY" "$UPDATER"; do
  name="${target##*/}"
  mv "$target" "$TEST_TMP/our-$name"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$target"
  chmod +x "$target"
  if HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" "$ROOT/ngwaf-update" "$ROOT" >"$TEST_TMP/conflict-out" 2>"$TEST_TMP/conflict-err"; then
    printf 'updater: unrelated %s collision unexpectedly succeeded\n' "$name" >&2; exit 1
  fi
  grep -F "$target already exists and is not this installation" "$TEST_TMP/conflict-err" >/dev/null
  grep -F 'installation failed before changes were applied' "$TEST_TMP/conflict-err" >/dev/null
  [[ -f "$target" && ! -L "$target" && -f "$INSTALL_ROOT/ownership-marker" ]]
  mv "$TEST_TMP/our-$name" "$target"
done

# A late link failure must restore the old package and every old command link.
printf 'previous install\n' >"$INSTALL_ROOT/rollback-marker"
real_ln="$(command -v ln)"
mkdir -p "$TEST_TMP/fail-bin"
cat >"$TEST_TMP/fail-bin/ln" <<'FAKE_LN'
#!/usr/bin/env bash
if [[ "${*: -1}" == "$FAIL_SHORT_TARGET" ]]; then exit 91; fi
exec "$REAL_LN" "$@"
FAKE_LN
chmod +x "$TEST_TMP/fail-bin/ln"
if PATH="$TEST_TMP/fail-bin:$PATH" REAL_LN="$real_ln" FAIL_SHORT_TARGET="$SHORT" \
  HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  "$ROOT/ngwaf-update" "$ROOT" >"$TEST_TMP/rollback-out" 2>"$TEST_TMP/rollback-err"; then
  printf 'updater: injected link failure unexpectedly succeeded\n' >&2; exit 1
fi
grep -F 'previous installation restored' "$TEST_TMP/rollback-err" >/dev/null
[[ -f "$INSTALL_ROOT/rollback-marker" ]]
for command_path in "$PRIMARY" "$LEGACY" "$UPDATER" "$SHORT"; do [[ -L "$command_path" ]]; done
[[ "$("$SHORT" version)" == 'fastly-audit 24.2.3' ]]

# A terminated upgrade must return nonzero and restore the previous package.
cat >"$TEST_TMP/fail-bin/ln" <<'FAKE_SIGNAL_LN'
#!/usr/bin/env bash
if [[ "${*: -1}" == "$FAIL_SHORT_TARGET" ]]; then
  kill -TERM "$PPID"
  exit 143
fi
exec "$REAL_LN" "$@"
FAKE_SIGNAL_LN
chmod +x "$TEST_TMP/fail-bin/ln"
if PATH="$TEST_TMP/fail-bin:$PATH" REAL_LN="$real_ln" FAIL_SHORT_TARGET="$SHORT" \
  HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  "$ROOT/ngwaf-update" "$ROOT" >"$TEST_TMP/signal-out" 2>"$TEST_TMP/signal-err"; then
  printf 'updater: interrupted upgrade unexpectedly succeeded\n' >&2; exit 1
fi
grep -F 'previous installation restored' "$TEST_TMP/signal-err" >/dev/null
[[ -f "$INSTALL_ROOT/rollback-marker" ]]
for command_path in "$PRIMARY" "$LEGACY" "$UPDATER" "$SHORT"; do [[ -L "$command_path" ]]; done

printf 'updater: OK\n'
