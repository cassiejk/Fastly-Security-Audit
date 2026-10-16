#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init

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
    --data-urlencode)
      printf '%s\n' "$2" >>"${NGWAF_TEST_CURL_LOG:-/dev/null}"
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
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"production","name":"Production"}]}' >"$outfile"
    ;;
  */ngwaf/v1/timeseries)
    if [[ "${NGWAF_TEST_METRICS_MODE:-valid}" == metrics ]]; then
      printf '%s\n' '{"data":[{"dimensions":{"workspace":"Production","time":"2026-09-01T00:00:00Z"},"values":[{"XSS":2,"SQLI":"1"}]}]}' >"$outfile"
    else
      cat "$NGWAF_TEST_FIXTURE_DIR/account-${NGWAF_TEST_METRICS_MODE:-valid}.json" >"$outfile"
    fi
    ;;
  */ngwaf/v1/workspaces/production/timeseries)
    if [[ "${NGWAF_TEST_METRICS_MODE:-complete}" == "bad-date" ]]; then
      printf '%s\n' '{"message":"start is required and must be a valid RFC3339 date"}' >"$outfile"
      printf '400'
      exit 0
    else
      cat "$NGWAF_TEST_FIXTURE_DIR/workspace-${NGWAF_TEST_METRICS_MODE:-valid}.json" >"$outfile"
    fi
    ;;
  *)
    printf '%s\n' '{"error":"unhandled fake endpoint"}' >"$outfile"
    printf '404'
    exit 0
    ;;
esac
printf '200'
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"

export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN="test-token"
export FASTLY_CUSTOMER_ID="test-customer"
export NGWAF_PROGRESS=never
export NGWAF_CURL_RETRIES=0
export NGWAF_TEST_CURL_LOG="$TEST_TMP/curl-query"
export NGWAF_TEST_FIXTURE_DIR="$ROOT/tests/fixtures/timeseries"

env -u FASTLY_API_TOKEN -u FASTLY_CUSTOMER_ID "$ROOT/fastly-audit" ngwaf timeseries --help >"$TEST_TMP/help" 2>"$TEST_TMP/help-err"
grep -F 'Usage:' "$TEST_TMP/help" >/dev/null
[[ ! -s "$TEST_TMP/help-err" && ! -e "$NGWAF_TEST_CURL_LOG" ]]
env -u FASTLY_API_TOKEN -u FASTLY_CUSTOMER_ID "$ROOT/fastly-audit" ngwaf timeseries -h >"$TEST_TMP/short-help" 2>"$TEST_TMP/short-help-err"
cmp "$TEST_TMP/help" "$TEST_TMP/short-help"
env -u FASTLY_API_TOKEN -u FASTLY_CUSTOMER_ID "$ROOT/fastly-audit" help ngwaf timeseries >"$TEST_TMP/route-help" 2>"$TEST_TMP/route-help-err"
cmp "$TEST_TMP/help" "$TEST_TMP/route-help"

assert_timeseries_invalid() {
  local expected="$1"
  shift
  rm -f "$NGWAF_TEST_CURL_LOG"
  if env -u FASTLY_API_TOKEN -u FASTLY_CUSTOMER_ID "$ROOT/fastly-audit" ngwaf timeseries "$@" >"$TEST_TMP/invalid-out" 2>"$TEST_TMP/invalid-err"; then
    printf 'metrics test: invalid timeseries arguments unexpectedly succeeded\n' >&2
    exit 1
  fi
  [[ ! -s "$TEST_TMP/invalid-out" && ! -e "$NGWAF_TEST_CURL_LOG" ]]
  grep -F "$expected" "$TEST_TMP/invalid-err" >/dev/null
  grep -F 'example:' "$TEST_TMP/invalid-err" >/dev/null
}
assert_timeseries_invalid 'missing required workspace'
assert_timeseries_invalid 'missing value for --start' Production --start
assert_timeseries_invalid 'missing required --start' Production --end 2026-09-08T00:00:00Z
assert_timeseries_invalid 'invalid --start: expected UTC RFC3339' Production --start 2026-99-01T00:00:00Z
assert_timeseries_invalid 'unexpected positional argument: 7' Production 7 7
assert_timeseries_invalid 'unknown option: --bogus' --bogus
assert_timeseries_invalid 'days cannot be combined' Production 7 --start 2026-09-01T00:00:00Z

overview="$($ROOT/ngwaf overview 1 --json 2>"$TEST_TMP/overview-err")" || {
  cat "$TEST_TMP/overview-err" >&2
  exit 1
}
jq -e '
  .customer == "Test Customer"
  and .window.type == "complete_utc_days"
  and .window.to_is_exclusive == true
  and .workspaces[0].requests_total == 100
  and .workspaces[0].requests_attack == 4
  and .workspaces[0].buckets[1].timestamp == "2026-09-02T00:00:00Z"
  and .workspaces[0].buckets[1].requests_total == 0
  and .provenance.data_class == "ngwaf_timeseries"
  and .provenance.missing_data_policy == "fail_closed"
' >/dev/null <<<"$overview"
grep -F 'customer scope: Test Customer (test-customer; source=environment)' "$TEST_TMP/overview-err" >/dev/null

: >"$NGWAF_TEST_CURL_LOG"
timeseries="$($ROOT/ngwaf timeseries Production 1 --json 2>"$TEST_TMP/timeseries-err")"
grep -E '^start=[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00Z$' "$NGWAF_TEST_CURL_LOG" >/dev/null
grep -E '^end=[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00Z$' "$NGWAF_TEST_CURL_LOG" >/dev/null
if grep -E '^(from|to)=' "$NGWAF_TEST_CURL_LOG" >/dev/null; then
  printf 'metrics test: obsolete date parameter sent\n' >&2
  exit 1
fi
jq -e '
  .workspace == "Production"
  and .workspace_id == "production"
  and .workspace_input == "Production"
  and .window.to_is_exclusive == true
  and .data[0].requests_attack == 4
  and .data[1].requests_total == 0
  and .data[1].timestamp == "2026-09-02T00:00:00Z"
  and .provenance.endpoint == "GET /ngwaf/v1/workspaces/{workspace_id}/timeseries"
' >/dev/null <<<"$timeseries"

: >"$NGWAF_TEST_CURL_LOG"
explicit="$($ROOT/fastly-audit ngwaf timeseries Production --start 2026-09-01T00:00:00Z --end 2026-09-08T00:00:00Z --json 2>"$TEST_TMP/explicit-err")"
grep -Fx 'start=2026-09-01T00:00:00Z' "$NGWAF_TEST_CURL_LOG" >/dev/null
grep -Fx 'end=2026-09-08T00:00:00Z' "$NGWAF_TEST_CURL_LOG" >/dev/null
jq -e '.days == null and .window.type == "explicit_utc_range" and .window.to_is_exclusive == null' >/dev/null <<<"$explicit"

export NGWAF_TEST_METRICS_MODE=bad-date
if "$ROOT/fastly-audit" ngwaf timeseries Production 7 --json >"$TEST_TMP/bad-date-out" 2>"$TEST_TMP/bad-date-err"; then
  printf 'metrics test: HTTP 400 unexpectedly succeeded\n' >&2
  exit 1
fi
[[ ! -s "$TEST_TMP/bad-date-out" ]]
grep -F 'timeseries date parameters were rejected' "$TEST_TMP/bad-date-err" >/dev/null
grep -F 'start is required and must be a valid RFC3339 date' "$TEST_TMP/bad-date-err" >/dev/null
export NGWAF_TEST_METRICS_MODE=metrics

metrics="$($ROOT/ngwaf metrics 'XSS,SQLI' 1 --json 2>"$TEST_TMP/metrics-err")"
jq -e '
  .requested_metrics == ["XSS", "SQLI"]
  and .data[0].XSS == 2
  and .data[0].SQLI == 1
  and .window.to_is_exclusive == true
  and .provenance.aggregation == "sum_of_daily_workspace_rows"
' >/dev/null <<<"$metrics"

export NGWAF_TEST_METRICS_MODE=missing
if $ROOT/ngwaf overview 1 --json >"$TEST_TMP/out" 2>"$TEST_TMP/missing-err"; then
  printf 'metrics test: missing requested metric unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'omitted or returned non-numeric requested metric(s): requests_attack' "$TEST_TMP/missing-err" >/dev/null
grep -F 'refusing to substitute zero' "$TEST_TMP/missing-err" >/dev/null

for mode in empty malformed null; do
  export NGWAF_TEST_METRICS_MODE="$mode"
  if "$ROOT/fastly-audit" ngwaf overview 1 --json >"$TEST_TMP/out" 2>"$TEST_TMP/account-$mode-err"; then
    printf 'metrics test: account %s response unexpectedly succeeded\n' "$mode" >&2
    exit 1
  fi
  [[ ! -s "$TEST_TMP/out" ]]
done
grep -F 'returned no timeseries rows' "$TEST_TMP/account-empty-err" >/dev/null
grep -F 'non-numeric requested metric(s): requests_total' "$TEST_TMP/account-malformed-err" >/dev/null
grep -F 'non-numeric requested metric(s): requests_attack' "$TEST_TMP/account-null-err" >/dev/null

for mode in empty missing malformed null; do
  export NGWAF_TEST_METRICS_MODE="$mode"
  if "$ROOT/fastly-audit" ngwaf timeseries Production 1 --json >"$TEST_TMP/out" 2>"$TEST_TMP/workspace-$mode-err"; then
    printf 'metrics test: workspace %s response unexpectedly succeeded\n' "$mode" >&2
    exit 1
  fi
  [[ ! -s "$TEST_TMP/out" ]]
done
grep -F 'returned no timeseries rows' "$TEST_TMP/workspace-empty-err" >/dev/null
grep -F 'non-numeric requested metric(s): requests_attack' "$TEST_TMP/workspace-missing-err" >/dev/null
grep -F 'non-numeric requested metric(s): requests_total' "$TEST_TMP/workspace-malformed-err" >/dev/null
grep -F 'non-numeric requested metric(s): requests_attack' "$TEST_TMP/workspace-null-err" >/dev/null

export NGWAF_TEST_METRICS_MODE=valid
NGWAF_DEBUG=1 "$ROOT/fastly-audit" ngwaf timeseries Production 1 --json >"$TEST_TMP/debug-out" 2>"$TEST_TMP/debug-err"
grep -F 'timeseries response shape:' "$TEST_TMP/debug-err" >/dev/null
grep -F '"row_count":2' "$TEST_TMP/debug-err" >/dev/null
grep -F 'scope and query values redacted' "$TEST_TMP/debug-err" >/dev/null
grep 'debug:' "$TEST_TMP/debug-err" >"$TEST_TMP/debug-lines"
if grep -E 'test-token|test-customer|/workspaces/production/timeseries|"requests_total":100' "$TEST_TMP/debug-lines" >/dev/null; then
  printf 'metrics test: sensitive debug detail leaked\n' >&2
  cat "$TEST_TMP/debug-lines" >&2
  exit 1
fi

printf 'metrics: OK\n'
