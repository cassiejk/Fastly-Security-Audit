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
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"production","name":"Production"}]}' >"$outfile"
    ;;
  */ngwaf/v1/timeseries|*/ngwaf/v1/workspaces/production/timeseries)
    if [[ "${NGWAF_TEST_METRICS_MODE:-complete}" == "missing" ]]; then
      printf '%s\n' '{"data":[{"dimensions":{"workspace":"Production","time":"2026-09-01T00:00:00Z"},"values":[{"requests_total":100,"requests_total_blocked":3}]}]}' >"$outfile"
    else
      printf '%s\n' '{"data":[{"dimensions":{"workspace":"Production","time":"2026-09-01T00:00:00Z"},"values":[{"requests_total":100,"requests_attack":4,"requests_total_blocked":3,"XSS":2,"SQLI":"1"}]}]}' >"$outfile"
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

overview="$($ROOT/ngwaf overview 1 --json 2>"$TEST_TMP/overview-err")"
jq -e '
  .customer == "Test Customer"
  and .window.type == "complete_utc_days"
  and .window.to_is_exclusive == true
  and .workspaces[0].requests_total == 100
  and .provenance.data_class == "ngwaf_timeseries"
  and .provenance.missing_data_policy == "fail_closed"
' >/dev/null <<<"$overview"
grep -F 'customer scope: Test Customer (test-customer; source=environment)' "$TEST_TMP/overview-err" >/dev/null

timeseries="$($ROOT/ngwaf timeseries Production 1 --json 2>"$TEST_TMP/timeseries-err")"
jq -e '
  .workspace == "Production"
  and .workspace_id == "production"
  and .workspace_input == "Production"
  and .window.to_is_exclusive == true
  and .data[0].values[0].requests_attack == 4
  and .provenance.endpoint == "GET /ngwaf/v1/workspaces/{workspace_id}/timeseries"
' >/dev/null <<<"$timeseries"

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

printf 'metrics: OK\n'
