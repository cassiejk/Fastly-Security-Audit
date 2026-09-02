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
url=""
args_file="${NGWAF_TEST_CURL_ARGS:?}"
{
  printf '%s\n' '--- request ---'
  printf '%s\n' "$@"
} >>"$args_file"

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
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    printf '200'
    ;;
  */ngwaf/v1/workspaces)
    if [[ "${NGWAF_TEST_WORKSPACES:-normal}" == "ambiguous" ]]; then
      printf '%s\n' '{"meta":{"total":2},"data":[{"id":"prod-a","name":"Production"},{"id":"prod-b","name":"production"}]}' >"$outfile"
    else
      printf '%s\n' '{"meta":{"total":2},"data":[{"id":"production","name":"Production"},{"id":"staging","name":"Staging"}]}' >"$outfile"
    fi
    printf '200'
    ;;
  */ngwaf/v1/workspaces/production/requests)
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
    ;;
  *)
    printf '%s\n' '{"error":"unhandled fake endpoint"}' >"$outfile"
    printf '404'
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
: >"$NGWAF_TEST_CURL_ARGS"

if ! output="$($ROOT/ngwaf count Production 'rule:abc123' 7 2>"$TEST_TMP/stderr")"; then
  printf 'count test: initial mocked request failed\n' >&2
  cat "$TEST_TMP/stderr" >&2
  exit 1
fi
jq -e '
  .workspace == "Production"
  and .workspace_id == "production"
  and .workspace_input == "Production"
  and .query == "ruleid:abc123"
  and .requested_query == "rule:abc123"
  and .query_normalized == true
  and .count == 42
  and .count_scope == "retained_searchable_request_records"
  and .window.type == "rolling"
  and .window.boundary_semantics == "from/until passed verbatim to request search; endpoint-defined"
  and .window.ingestion_buffer_seconds == 300
  and ((.window.until_epoch - .window.from_epoch) == (7 * 86400))
  and .provenance.endpoint == "GET /ngwaf/v1/workspaces/{workspace_id}/requests"
  and .provenance.data_class == "retained_request_search"
  and .provenance.aggregation == "response.meta.total"
  and .provenance.missing_data_policy == "fail_closed"
  and .sampling_caveat == "This count may reflect sampled or mixed-storage request data. It is not raw traffic or a scaled estimate."
' >/dev/null <<<"$output"
grep -F 'https://api.fastly.com/customer/test-customer' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'https://api.fastly.com/ngwaf/v1/workspaces/production/requests' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -E '^q=from:[0-9]+ until:[0-9]+ ruleid:abc123$' "$NGWAF_TEST_CURL_ARGS" >/dev/null
! grep -E '^q=.* rule:abc123$' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'customer scope: Test Customer (test-customer; source=environment)' "$TEST_TMP/stderr" >/dev/null
grep -F 'workspace scope: Production (production; resolved_by=name)' "$TEST_TMP/stderr" >/dev/null
grep -F 'normalized search key rule: to ruleid:' "$TEST_TMP/stderr" >/dev/null

export NGWAF_TEST_WORKSPACES=ambiguous
if $ROOT/ngwaf count Production 'tag:XSS' 1 >"$TEST_TMP/out" 2>"$TEST_TMP/ambiguous-err"; then
  printf 'count test: ambiguous workspace unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'workspace name is ambiguous' "$TEST_TMP/ambiguous-err" >/dev/null
unset NGWAF_TEST_WORKSPACES

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
grep -F 'counting matching requests in Production' "$TEST_TMP/progress-err" >/dev/null
grep -F 'completed counting matching requests in Production' "$TEST_TMP/progress-err" >/dev/null

printf 'count: OK\n'
