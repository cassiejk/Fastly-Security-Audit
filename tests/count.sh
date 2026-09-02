#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_TMP="$(mktemp -d)"
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$TEST_TMP/bin"

cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

outfile=""
args_file="${NGWAF_TEST_CURL_ARGS:?}"
printf '%s\n' "$@" >"$args_file"

while (( $# > 0 )); do
  case "$1" in
    -o)
      outfile="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "${NGWAF_TEST_CURL_MODE:-success}" in
  success)
    printf '%s\n' '{"meta":{"limit":1,"total":42},"data":[]}' >"$outfile"
    printf '200'
    ;;
  malformed)
    printf '%s\n' 'not-json' >"$outfile"
    printf '200'
    ;;
  timeout)
    printf '%s\n' 'curl: (28) Operation timed out' >&2
    exit 28
    ;;
  http_error)
    printf '%s\n' '{"error":"upstream unavailable"}' >"$outfile"
    printf '503'
    ;;
  slow)
    sleep 2
    printf '%s\n' '{"meta":{"limit":1,"total":7},"data":[]}' >"$outfile"
    printf '200'
    ;;
  *)
    exit 99
    ;;
esac
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"

export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN="test-token"
export FASTLY_CUSTOMER_ID="test-customer"
export NGWAF_PROGRESS=never
export NGWAF_CURL_RETRIES=0
export NGWAF_TEST_CURL_ARGS="$TEST_TMP/curl-args"

if ! output="$($ROOT/ngwaf count production 'rule:abc123' 7 2>"$TEST_TMP/stderr")"; then
  printf 'count test: initial mocked request failed\n' >&2
  cat "$TEST_TMP/stderr" >&2
  exit 1
fi
jq -e '
  .workspace == "production"
  and .query == "ruleid:abc123"
  and .requested_query == "rule:abc123"
  and .query_normalized == true
  and .count == 42
' >/dev/null <<<"$output"
grep -E '^q=from:[0-9]+ until:[0-9]+ ruleid:abc123$' "$TEST_TMP/curl-args" >/dev/null
! grep -E '^q=.* rule:abc123$' "$TEST_TMP/curl-args" >/dev/null
grep -F 'normalized search key rule: to ruleid:' "$TEST_TMP/stderr" >/dev/null

export NGWAF_TEST_CURL_MODE=malformed
if $ROOT/ngwaf count production 'tag:XSS' 1 >"$TEST_TMP/out" 2>"$TEST_TMP/malformed-err"; then
  printf 'count test: malformed JSON unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'returned invalid JSON' "$TEST_TMP/malformed-err" >/dev/null

export NGWAF_TEST_CURL_MODE=timeout
if $ROOT/ngwaf count production 'tag:XSS' 1 >"$TEST_TMP/out" 2>"$TEST_TMP/timeout-err"; then
  printf 'count test: timeout unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'Fastly API request timed out' "$TEST_TMP/timeout-err" >/dev/null
grep -F 'connect=5s, transfer=60s, retry-window=90s' "$TEST_TMP/timeout-err" >/dev/null
grep -F 'curl: (28) Operation timed out' "$TEST_TMP/timeout-err" >/dev/null

export NGWAF_TEST_CURL_MODE=http_error
if $ROOT/ngwaf count production 'tag:XSS' 1 >"$TEST_TMP/out" 2>"$TEST_TMP/http-err"; then
  printf 'count test: HTTP 503 unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'Fastly API returned HTTP 503' "$TEST_TMP/http-err" >/dev/null
grep -F 'upstream unavailable' "$TEST_TMP/http-err" >/dev/null

export NGWAF_TEST_CURL_MODE=success
export NGWAF_DEBUG=1
$ROOT/ngwaf count production 'ruleid:abc123' 1 >"$TEST_TMP/out" 2>"$TEST_TMP/debug-err"
grep -F 'GET https://api.fastly.com/ngwaf/v1/workspaces/production/requests' "$TEST_TMP/debug-err" >/dev/null
grep -E 'query parameter: q=from:[0-9]+ until:[0-9]+ ruleid:abc123' "$TEST_TMP/debug-err" >/dev/null
! grep -F 'test-token' "$TEST_TMP/debug-err" >/dev/null
unset NGWAF_DEBUG

export NGWAF_TEST_CURL_MODE=slow
export NGWAF_PROGRESS=always
$ROOT/ngwaf count production 'tag:XSS' 1 >"$TEST_TMP/out" 2>"$TEST_TMP/progress-err"
grep -F 'counting matching requests in production' "$TEST_TMP/progress-err" >/dev/null
grep -F 'completed counting matching requests in production' "$TEST_TMP/progress-err" >/dev/null

printf 'count: OK\n'
