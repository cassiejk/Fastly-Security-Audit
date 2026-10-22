#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/state"
assert_absent() {
  if grep -F "$1" "$2" >/dev/null; then
    printf 'progress: unexpected text: %s\n' "$1" >&2
    exit 1
  fi
}

cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
outfile=''
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    *) shift ;;
  esac
done
sleep "${PROGRESS_MOCK_SLEEP:-0}"
if [[ "${PROGRESS_MOCK_HTTP:-200}" == 200 ]]; then
  printf '%s\n' '{"ok":true}' >"$outfile"
else
  printf '%s\n' '{"error":"mock failure"}' >"$outfile"
fi
printf '%s' "${PROGRESS_MOCK_HTTP:-200}"
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"

cat >"$TEST_TMP/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../lib/core.sh
source "$PROGRESS_TEST_ROOT/lib/core.sh"
API_BASE=https://api.fastly.com
FASTLY_API_TOKEN=mock-token
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=60
CURL_RETRIES=0
CURL_RETRY_MAX_TIME=90
count_fixture() {
  progress_job_phase '[1/1] Checking workspaces'
  sleep 2
  progress_job_milestone 'Workspace checks' 1 2
  progress_job_milestone 'Workspace checks' 2 2
  printf '%s\n' '{"ok":true}'
}
pipe_failure_fixture() { false | true; }
case "$1" in
  fast) progress_run 'mock audit' printf '%s\n' '{"ok":true}' ;;
  quiet-phase) progress_run 'mock audit' ui_phase 1 2 'Checking workspaces' ;;
  slow) progress_run 'mock audit' bash -c 'sleep 3; printf "%s\\n" "{\"ok\":true}"' ;;
  count) progress_run 'mock audit' count_fixture ;;
  failed) progress_run 'mock audit' bash -c 'exit 7' ;;
  pipe-failed) progress_run 'mock audit' pipe_failure_fixture ;;
  api) progress_run 'mock audit' get '/test?secret=private-value' ;;
  signal) progress_run 'mock audit' sleep 4 ;;
  signal-int) progress_job_begin 'mock audit'; progress_job_signal INT ;;
esac
PROBE
chmod +x "$TEST_TMP/probe.sh"

export PATH="$TEST_TMP/bin:$PATH" PROGRESS_TEST_ROOT="$ROOT"
export NGWAF_PROGRESS=always NGWAF_PROGRESS_HEARTBEAT_SECONDS=1
export NGWAF_PROGRESS_MILESTONE_SECONDS=1 NGWAF_PROGRESS_SLOW_SECONDS=1
export TMPDIR="$TEST_TMP/state"

"$TEST_TMP/probe.sh" fast >"$TEST_TMP/json" 2>"$TEST_TMP/err"
jq -e '.ok == true' "$TEST_TMP/json" >/dev/null
grep -F 'Starting mock audit' "$TEST_TMP/err" >/dev/null
grep -F 'Completed successfully' "$TEST_TMP/err" >/dev/null
assert_absent 'Still working' "$TEST_TMP/err"

"$TEST_TMP/probe.sh" slow >"$TEST_TMP/json" 2>"$TEST_TMP/err"
jq -e '.ok == true' "$TEST_TMP/json" >/dev/null
grep -F 'Still working: mock audit' "$TEST_TMP/err" >/dev/null

"$TEST_TMP/probe.sh" count >"$TEST_TMP/json" 2>"$TEST_TMP/err"
jq -e '.ok == true' "$TEST_TMP/json" >/dev/null
grep -F 'Workspace checks: 1/2' "$TEST_TMP/err" >/dev/null
grep -F 'Workspace checks: 2/2' "$TEST_TMP/err" >/dev/null
assert_absent 'Workspace checks: 3/2' "$TEST_TMP/err"

if "$TEST_TMP/probe.sh" failed >"$TEST_TMP/json" 2>"$TEST_TMP/err"; then
  printf 'progress: failed operation succeeded\n' >&2; exit 1
else
  [[ "$?" == 7 ]]
fi
grep -F 'Failed: mock audit (exit=7)' "$TEST_TMP/err" >/dev/null
assert_absent 'Completed successfully' "$TEST_TMP/err"

if "$TEST_TMP/probe.sh" pipe-failed >"$TEST_TMP/json" 2>"$TEST_TMP/err"; then
  printf 'progress: failed pipeline succeeded\n' >&2; exit 1
fi
grep -F 'Failed: mock audit (exit=1)' "$TEST_TMP/err" >/dev/null
assert_absent 'Completed successfully' "$TEST_TMP/err"

PROGRESS_MOCK_SLEEP=3 "$TEST_TMP/probe.sh" api >"$TEST_TMP/json" 2>"$TEST_TMP/err"
jq -e '.ok == true' "$TEST_TMP/json" >/dev/null
grep -F 'Still working: mock audit; GET /test' "$TEST_TMP/err" >/dev/null
grep -F 'Slow API request: GET /test' "$TEST_TMP/err" >/dev/null
grep -F 'HTTP 200' "$TEST_TMP/err" >/dev/null
assert_absent 'private-value' "$TEST_TMP/err"

if PROGRESS_MOCK_HTTP=503 "$TEST_TMP/probe.sh" api >"$TEST_TMP/json" 2>"$TEST_TMP/err"; then
  printf 'progress: HTTP failure succeeded\n' >&2; exit 1
fi
grep -F 'Fastly API returned HTTP 503' "$TEST_TMP/err" >/dev/null
grep -F 'Failed: mock audit (exit=1)' "$TEST_TMP/err" >/dev/null

NGWAF_PROGRESS=never "$TEST_TMP/probe.sh" fast >"$TEST_TMP/json" 2>"$TEST_TMP/err"
[[ ! -s "$TEST_TMP/err" ]]
NGWAF_PROGRESS=never "$TEST_TMP/probe.sh" quiet-phase >"$TEST_TMP/json" 2>"$TEST_TMP/err"
[[ ! -s "$TEST_TMP/err" ]]
NGWAF_PROGRESS=auto "$TEST_TMP/probe.sh" fast >"$TEST_TMP/json" 2>"$TEST_TMP/err"
[[ ! -s "$TEST_TMP/err" ]]

"$TEST_TMP/probe.sh" signal >"$TEST_TMP/json" 2>"$TEST_TMP/err" &
probe_pid=$!
sleep 1
kill -TERM "$probe_pid"
if wait "$probe_pid"; then
  printf 'progress: TERM operation succeeded\n' >&2; exit 1
else
  [[ "$?" == 143 ]]
fi
grep -F 'Interrupted by user (SIGTERM)' "$TEST_TMP/err" >/dev/null
[[ -z "$(find "$TEST_TMP/state" -type f -print -quit)" ]]

if "$TEST_TMP/probe.sh" signal-int >"$TEST_TMP/json" 2>"$TEST_TMP/err"; then
  printf 'progress: INT handler succeeded\n' >&2; exit 1
else
  [[ "$?" == 130 ]]
fi
grep -F 'Interrupted by user (SIGINT)' "$TEST_TMP/err" >/dev/null
[[ -z "$(find "$TEST_TMP/state" -type f -print -quit)" ]]

printf 'progress: OK\n'
