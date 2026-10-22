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
from=""
to=""
start=""
end=""
while (( $# > 0 )); do
  case "$1" in
    -o)
      outfile="$2"
      shift 2
      ;;
    --data-urlencode)
      printf '%s\n' "$2" >>"${NGWAF_TEST_CURL_LOG:-/dev/null}"
      case "$2" in
        from=*) from="${2#from=}" ;;
        to=*) to="${2#to=}" ;;
        start=*) start="${2#start=}" ;;
        end=*) end="${2#end=}" ;;
      esac
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
    if [[ -n "${NGWAF_TEST_INVENTORY_BODY:-}" ]]; then
      cat "$NGWAF_TEST_INVENTORY_BODY" >"$outfile"
    else
      printf '%s\n' '{"meta":{"total":2},"data":[{"id":"production","name":"Production"},{"id":"my-prd-api","name":"my-prd-api"}]}' >"$outfile"
    fi
    ;;
  */ngwaf/v1/timeseries)
    if [[ -n "${NGWAF_TEST_ACCOUNT_BODY:-}" ]]; then
      cat "$NGWAF_TEST_ACCOUNT_BODY" >"$outfile"
    elif [[ "${NGWAF_TEST_METRICS_MODE:-valid}" == metrics ]]; then
      printf '%s\n' '{"data":[{"dimensions":{"workspace":"Production","time":"2026-09-01T00:00:00Z"},"values":[{"XSS":2,"SQLI":"1"}]}]}' >"$outfile"
    else
      cat "$NGWAF_TEST_FIXTURE_DIR/account-${NGWAF_TEST_METRICS_MODE:-valid}.json" >"$outfile"
    fi
    if [[ -n "$from" && "${NGWAF_TEST_PRESERVE_TIMES:-0}" != 1 ]]; then
      next="$(jq -nr --arg from "$from" '$from | fromdateiso8601 | . + 86400 | todateiso8601')"
      jq --arg from "$from" --arg next "$next" --arg to "$to" '
        .data |= map(if .dimensions.time == "2026-09-01T00:00:00Z" then .dimensions.time = $from
                     elif .dimensions.time == "2026-09-02T00:00:00Z" then .dimensions.time = $next else . end)
        | if $to != "" and (.meta.total? != null) then
            .data |= map(select(.dimensions.time < $to)) | .meta.total = (.data | length)
          else . end
      ' "$outfile" >"$outfile.new"
      mv "$outfile.new" "$outfile"
    fi
    ;;
  */ngwaf/v1/reports/signals)
    if [[ -n "${NGWAF_TEST_REPORT_BODY:-}" ]]; then
      cat "$NGWAF_TEST_REPORT_BODY" >"$outfile"
    else
      cat "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$outfile"
    fi
    ;;
  */ngwaf/v1/workspaces/production/timeseries)
    if [[ "${NGWAF_TEST_METRICS_MODE:-complete}" == "bad-date" ]]; then
      printf '%s\n' '{"message":"start is required and must be a valid RFC3339 date"}' >"$outfile"
      printf '400'
      exit 0
    else
      cat "$NGWAF_TEST_FIXTURE_DIR/workspace-${NGWAF_TEST_METRICS_MODE:-valid}.json" >"$outfile"
      if [[ -n "$start" && "${NGWAF_TEST_PRESERVE_TIMES:-0}" != 1 ]]; then
        next="$(jq -nr --arg start "$start" '$start | fromdateiso8601 | . + 86400 | todateiso8601')"
        jq --arg start "$start" --arg next "$next" --arg end "$end" '
          .data |= map(if .timestamp == "2026-09-01T00:00:00Z" then .timestamp = $start
                       elif .timestamp == "2026-09-02T00:00:00Z" then .timestamp = $next else . end)
          | if $end != "" and (.meta.total? != null) then
              .data |= map(select(.timestamp < $end)) | .meta.total = (.data | length)
            else . end
        ' "$outfile" >"$outfile.new"
        mv "$outfile.new" "$outfile"
      fi
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

overview="$($ROOT/ngwaf overview 2 --json 2>"$TEST_TMP/overview-err")" || {
  cat "$TEST_TMP/overview-err" >&2
  exit 1
}
jq -e '
  .customer == "Test Customer"
  and .window.type == "complete_utc_days"
  and .window.to_is_exclusive == true
  and .workspaces[0].requests_total == 100
  and .workspaces[0].requests_attack == 4
  and .workspaces[0].buckets[1].timestamp > .workspaces[0].buckets[0].timestamp
  and .workspaces[0].buckets[1].requests_total == 0
  and .provenance.data_class == "ngwaf_timeseries"
  and .validation.requested_intervals == 2
  and .validation.completeness == "unknown"
  and .provenance.missing_data_policy == "report_unobserved_intervals_without_zero_substitution"
' >/dev/null <<<"$overview"
grep -F 'customer scope: Test Customer (test-customer; source=environment)' "$TEST_TMP/overview-err" >/dev/null

: >"$NGWAF_TEST_CURL_LOG"
timeseries="$($ROOT/ngwaf timeseries Production 2 --json 2>"$TEST_TMP/timeseries-err")"
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
  and .data[1].timestamp > .data[0].timestamp
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

export NGWAF_TEST_ACCOUNT_BODY="$TEST_TMP/account-body.json"
account_body() {
  jq -n --argjson values "$1" '{data:[{dimensions:{workspace:"my-prd-api",time:"2026-09-01T00:00:00Z"},values:$values}]}' >"$NGWAF_TEST_ACCOUNT_BODY"
}
assert_account_rejected() {
  local expected="$1"
  shift
  if "$ROOT/ngwaf" "$@" >"$TEST_TMP/rejected-out" 2>"$TEST_TMP/rejected-err"; then
    printf 'metrics test: invalid account values unexpectedly succeeded\n' >&2
    exit 1
  fi
  [[ ! -s "$TEST_TMP/rejected-out" ]]
  grep -F "$expected" "$TEST_TMP/rejected-err" >/dev/null
}

account_body '[{"XSS":2}]'
metrics="$($ROOT/ngwaf metrics XSS 1 --json 2>"$TEST_TMP/metrics-err")"
jq -e '.data[0].XSS == 2' >/dev/null <<<"$metrics"

account_body '[{"XSS":2,"SQLI":"1"}]'
metrics="$($ROOT/ngwaf metrics XSS,SQLI 1 --json 2>"$TEST_TMP/metrics-err")"
jq -e '.data[0].XSS == 2 and .data[0].SQLI == 1' >/dev/null <<<"$metrics"

account_body '[{"XSS":2},{"SQLI":"1"}]'
metrics="$($ROOT/ngwaf metrics XSS,SQLI 1 --json 2>"$TEST_TMP/metrics-err")"
jq -e '.data[0].XSS == 2 and .data[0].SQLI == 1' >/dev/null <<<"$metrics"

account_body '[{"requests_attack":6}]'
: >"$NGWAF_TEST_CURL_LOG"
profile="$($ROOT/ngwaf attack-profile 1 --json 2>"$TEST_TMP/profile-err")"
jq -e '.production_workspaces[0].requests_attack == 6 and
  ([.attack_signals[] | .requests] | sort) == [1,2,3,4,5] and
  all(.attack_signals[]; .status == "complete") and
  .provenance.signal_endpoint == "GET /ngwaf/v1/reports/signals"' >/dev/null <<<"$profile"
grep -Fx 'metrics=requests_attack' "$NGWAF_TEST_CURL_LOG" >/dev/null
if grep -F 'metrics=requests_attack,' "$NGWAF_TEST_CURL_LOG" >/dev/null; then
  printf 'metrics test: attack profile requested signal names as timeseries metrics\n' >&2
  exit 1
fi

export NGWAF_TEST_REPORT_BODY="$TEST_TMP/signals-report.json"
jq '(.data[] | select(.name == "XSS") | .top_workspaces) = []' \
  "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
profile="$($ROOT/ngwaf attack-profile 1 --json 2>"$TEST_TMP/profile-err")"
jq -e '(.attack_signals[] | select(.metric == "XSS") |
  .requests == null and .status == "selected_workspace_not_reported")' >/dev/null <<<"$profile"
"$ROOT/ngwaf" attack-profile 1 >"$TEST_TMP/profile-text" 2>"$TEST_TMP/profile-text-err"
grep -E 'Cross-Site Scripting[[:space:]]+XSS[[:space:]]+unavailable' "$TEST_TMP/profile-text" >/dev/null
jq 'del(.data[] | select(.name == "AWS-SSRF"))' \
  "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
profile="$($ROOT/ngwaf attack-profile 1 --json 2>"$TEST_TMP/profile-err")"
jq -e '(.attack_signals[] | select(.metric == "AWS-SSRF") |
  .requests == null and .status == "not_reported")' >/dev/null <<<"$profile"
jq '(.data[] | select(.name == "SQLI") | .top_workspaces[0].count) = 0' \
  "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
profile="$($ROOT/ngwaf attack-profile 1 --json 2>"$TEST_TMP/profile-err")"
jq -e '(.attack_signals[] | select(.metric == "SQLI") |
  .requests == 0 and .status == "complete")' >/dev/null <<<"$profile"
jq '(.data[] | select(.name == "SQLI") | .top_workspaces[0].id) = "other-customer"' \
  "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
profile="$($ROOT/ngwaf attack-profile 1 --json 2>"$TEST_TMP/profile-unmatched-err")"
jq -e '.production_workspaces[0].requests_attack == 6 and
  .signal_report_diagnostics == {unmatched_workspace_count:1,unmatched_workspace_ids:["other-customer"]} and
  (.attack_signals[] | select(.metric == "SQLI") |
    .requests == null and .status == "selected_workspace_not_reported")' >/dev/null <<<"$profile"
grep -F 'excluded 1 unmatched signals-report workspace ID(s)' "$TEST_TMP/profile-unmatched-err" >/dev/null
jq '(.data[] | select(.name == "SQLI") | .top_workspaces) +=
  [{id:"other-customer",name:"unrelated-prd",count:50}] |
  (.data[] | select(.name == "SQLI") | .count) = 51' \
  "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
profile="$($ROOT/ngwaf attack-profile 1 --json 2>"$TEST_TMP/profile-unmatched-err")"
jq -e '.signal_report_diagnostics.unmatched_workspace_count == 1 and
  .signal_report_diagnostics.unmatched_workspace_ids == ["other-customer"] and
  .production_workspaces[0].requests_attack == 6 and
  (.attack_signals[] | select(.metric == "SQLI") | .requests == 1 and .status == "complete")' >/dev/null <<<"$profile"
jq '(.data[] | select(.name == "SQLI") | .top_workspaces) +=
  [{id:"other-customer",name:"unrelated-prd",count:50},
   {id:"other-customer",name:"unrelated-prd",count:50}]' \
  "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
profile="$($ROOT/ngwaf attack-profile 1 --json 2>"$TEST_TMP/profile-unmatched-err")"
jq -e '.signal_report_diagnostics.unmatched_workspace_count == 1 and
  (.attack_signals[] | select(.metric == "SQLI") | .requests == 1 and .status == "complete")' >/dev/null <<<"$profile"
jq '(.data[] | select(.name == "SQLI") | .top_workspaces[0].name) = "renamed-other"' \
  "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
profile="$($ROOT/ngwaf attack-profile 1 --json 2>"$TEST_TMP/profile-unmatched-err")"
jq -e '.signal_report_diagnostics.unmatched_workspace_ids == ["my-prd-api"] and
  (.attack_signals[] | select(.metric == "SQLI") | .requests == null)' >/dev/null <<<"$profile"
jq '(.data[] | select(.name == "SQLI") | .top_workspaces) +=
  [{id:"my-prd-api",name:"my-prd-api",count:1}]' \
  "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
assert_account_rejected 'duplicate workspace in signals report' attack-profile 1 --json
jq '(.data[] | select(.name == "SQLI") | .count) = "unknown"' \
  "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
assert_account_rejected 'malformed signals report entry' attack-profile 1 --json
jq '(.data[] | select(.name == "SQLI") | .count) = 0' \
  "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
assert_account_rejected 'workspace counts exceed signal count' attack-profile 1 --json
jq '.data += [.data[0]]' "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
assert_account_rejected 'duplicate signal in signals report' attack-profile 1 --json
jq '.meta.total = 99' "$NGWAF_TEST_FIXTURE_DIR/signals-report.json" >"$NGWAF_TEST_REPORT_BODY"
assert_account_rejected 'meta.total differs from returned row count' attack-profile 1 --json
unset NGWAF_TEST_REPORT_BODY

export NGWAF_TEST_PRESERVE_TIMES=1
jq -n '{meta:{total:2},data:[
  {dimensions:{workspace:"my-prd-api",time:"2026-09-16T00:00:00Z"},values:[{requests_attack:6}]},
  {dimensions:{workspace:"my-prd-api",time:"2026-10-15T00:00:00Z"},values:[{requests_attack:1000}]}
]}' >"$NGWAF_TEST_ACCOUNT_BODY"
profile="$($ROOT/ngwaf attack-profile 2026-09-16 2026-10-15 --json 2>"$TEST_TMP/profile-err")"
jq -e '.production_workspaces[0].requests_attack == 6 and
  .validation.excluded_end_boundary_rows == 1 and
  .validation.observed_rows == 1' >/dev/null <<<"$profile"
jq '.data += [.data[0]] | .meta.total = 3' "$NGWAF_TEST_ACCOUNT_BODY" >"$TEST_TMP/profile-duplicate.json"
cp "$TEST_TMP/profile-duplicate.json" "$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'duplicate workspace/time interval' attack-profile 2026-09-16 2026-10-15 --json
unset NGWAF_TEST_PRESERVE_TIMES

account_body '[{"XSS":2}]'
assert_account_rejected 'non-numeric requested metric(s): SQLI' metrics XSS,SQLI 1 --json
account_body '[{"XSS":2},{"SQLI":null}]'
assert_account_rejected 'non-numeric requested metric(s): SQLI' metrics XSS,SQLI 1 --json
account_body '[{"XSS":2},{"SQLI":"many"}]'
assert_account_rejected 'non-numeric requested metric(s): SQLI' metrics XSS,SQLI 1 --json
account_body '[{"XSS":2},{"SQLI":1},{"SQLI":3}]'
assert_account_rejected 'duplicate metric key(s): SQLI' metrics XSS,SQLI 1 --json
account_body '[{"XSS":2},null,{"SQLI":1}]'
assert_account_rejected 'malformed timeseries rows or metric values' metrics XSS,SQLI 1 --json
account_body '[{"SQLI":1}]'
assert_account_rejected 'non-numeric requested metric(s): requests_attack' attack-profile 1 --json
unset NGWAF_TEST_ACCOUNT_BODY

export NGWAF_TEST_METRICS_MODE=valid
metrics="$($ROOT/ngwaf metrics requests_attack 1 --json 2>"$TEST_TMP/metrics-err")"
jq -e '.data[0].requests_attack == 4' >/dev/null <<<"$metrics"

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
grep -F '"row_count":1' "$TEST_TMP/debug-err" >/dev/null
grep -F 'scope and query values redacted' "$TEST_TMP/debug-err" >/dev/null
grep 'debug:' "$TEST_TMP/debug-err" >"$TEST_TMP/debug-lines"
if grep -E 'test-token|test-customer|/workspaces/production/timeseries|"requests_total":100' "$TEST_TMP/debug-lines" >/dev/null; then
  printf 'metrics test: sensitive debug detail leaked\n' >&2
  cat "$TEST_TMP/debug-lines" >&2
  exit 1
fi

# Synthetic 30-day histories exercise integrity independently of API access.
export NGWAF_TEST_ACCOUNT_BODY="$TEST_TMP/account-body.json"
export NGWAF_TEST_INVENTORY_BODY="$TEST_TMP/inventory.json"
export NGWAF_TEST_PRESERVE_TIMES=1
cat >"$NGWAF_TEST_INVENTORY_BODY" <<'JSON'
{"meta":{"total":3},"data":[{"id":"prod-a","name":"site-prd-a"},{"id":"prod-b","name":"site-prod-b"},{"id":"qa","name":"site-qa"}]}
JSON
window_to="$(date -u '+%Y-%m-%dT00:00:00Z')"
window_from="$(jq -nr --arg to "$window_to" '$to | fromdateiso8601 | . - 30 * 86400 | todateiso8601')"
jq -n --arg from "$window_from" '
  ($from | fromdateiso8601) as $start |
  [range(0;30) as $day | ["site-prd-a","site-prod-b","site-qa"][] as $name |
    {dimensions:{workspace:$name,time:($start + $day * 86400 | todateiso8601)},
     values:[{requests_attack:(if $day == 7 then 0 else 1 end)}]}] as $data |
  {meta:{total:($data | length)},data:$data}
' >"$NGWAF_TEST_ACCOUNT_BODY"
cp "$NGWAF_TEST_ACCOUNT_BODY" "$TEST_TMP/complete.json"
metrics="$($ROOT/ngwaf metrics requests_attack 30 --json 2>"$TEST_TMP/integrity-err")"
jq -e '
  .validation.requested_intervals == 30 and .validation.observed_rows == 90
  and ([.validation.workspace_intervals[].missing_intervals | length] | all(.[]; . == 0))
  and .data[0].workspace_id == "prod-a" and .data[0].requests_attack == 29
  and .data[1].workspace_id == "prod-b" and .data[2].workspace_id == "qa"
  and .validation.unobserved_workspaces == []
  and .validation.completeness == "unknown"
' >/dev/null <<<"$metrics"
explicit_metrics="$($ROOT/ngwaf metrics requests_attack --start "$window_from" --end "$window_to" --json 2>"$TEST_TMP/explicit-metrics-err")"
jq -e --arg from "$window_from" --arg to "$window_to" '
  .window.from == $from and .window.to == $to and .days == 30 and
  .data[0].requests_attack == 29
' >/dev/null <<<"$explicit_metrics"
assert_account_rejected 'must start and end at UTC midnight' metrics requests_attack --start "${window_from/T00:00:00Z/T01:00:00Z}" --end "$window_to" --json
assert_account_rejected 'required together without days' metrics requests_attack --start "$window_from" --json

# The first and last bucket starts in [from, to) are accepted. RFC3339
# representations of the same UTC midnight use the same interval key.
jq '.data = [.data[0]] | .meta.total = 1' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
metrics="$($ROOT/ngwaf metrics requests_attack --start "$window_from" --end "$window_to" --json 2>"$TEST_TMP/boundary-err")"
jq -e --arg from "$window_from" '.validation.observed_rows == 1 and
  (.validation.workspace_intervals[] | select(.workspace == "site-prd-a") | .missing_intervals | index($from) | not)' >/dev/null <<<"$metrics"
jq --arg from "$window_from" '
  .data = [.data[0]] | .meta.total = 1 |
  .data[0].dimensions.time = ($from | fromdateiso8601 | . + 3600 | todateiso8601 | sub("Z$"; "+01:00"))
' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
metrics="$($ROOT/ngwaf metrics requests_attack --start "$window_from" --end "$window_to" --json 2>"$TEST_TMP/boundary-err")"
jq -e --arg from "$window_from" '(.validation.workspace_intervals[] |
  select(.workspace == "site-prd-a") | .missing_intervals | index($from) | not)' >/dev/null <<<"$metrics"
jq --arg from "$window_from" '.data = [.data[0]] | .meta.total = 1 |
  .data[0].dimensions.time = ($from | sub("Z$"; ".000Z"))' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
metrics="$($ROOT/ngwaf metrics requests_attack --start "$window_from" --end "$window_to" --json 2>"$TEST_TMP/boundary-err")"
jq -e '.validation.observed_rows == 1' >/dev/null <<<"$metrics"

jq '.data = [.data[-3]] | .meta.total = 1' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
metrics="$($ROOT/ngwaf metrics requests_attack --start "$window_from" --end "$window_to" --json 2>"$TEST_TMP/boundary-err")"
last_bucket="$(jq -nr --arg to "$window_to" '$to | fromdateiso8601 | . - 86400 | todateiso8601')"
jq -e --arg last "$last_bucket" '(.validation.workspace_intervals[] |
  select(.workspace == "site-prd-a") | .missing_intervals | index($last) | not)' >/dev/null <<<"$metrics"

assert_interval_diagnostic() {
  local timestamp="$1"
  if "$ROOT/ngwaf" metrics requests_attack --start "$window_from" --end "$window_to" --json --diagnose-intervals >"$TEST_TMP/diagnostic-out" 2>"$TEST_TMP/diagnostic-err"; then
    printf 'metrics test: out-of-window interval unexpectedly succeeded\n' >&2
    exit 1
  fi
  [[ ! -s "$TEST_TMP/diagnostic-out" ]]
  grep -F 'timeseries interval outside requested window' "$TEST_TMP/diagnostic-err" >/dev/null
  grep -F "\"timestamp\":\"$timestamp\"" "$TEST_TMP/diagnostic-err" >/dev/null
  grep -F '"workspace":"site-prd-a"' "$TEST_TMP/diagnostic-err" >/dev/null
  grep -F "\"from\":\"$window_from\"" "$TEST_TMP/diagnostic-err" >/dev/null
  grep -F "\"to\":\"$window_to\"" "$TEST_TMP/diagnostic-err" >/dev/null
  grep -F 'interval diagnostic:' "$TEST_TMP/diagnostic-err" >"$TEST_TMP/diagnostic-lines"
  if grep -E 'test-token|"values"|"requests_attack"|test-customer' "$TEST_TMP/diagnostic-lines" >/dev/null; then
    printf 'metrics test: interval diagnostic leaked response or credential detail\n' >&2
    exit 1
  fi
}
jq --arg from "$window_from" '.data = [.data[0]] | .meta.total = 1 |
  .data[0].dimensions.time = ($from | fromdateiso8601 | . - 86400 | todateiso8601)' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
before_start="$(jq -r '.data[0].dimensions.time' "$NGWAF_TEST_ACCOUNT_BODY")"
assert_interval_diagnostic "$before_start"
jq --arg to "$window_to" '
  .data = [.data[0], .data[1], .data[2]] | .meta.total = 3 |
  .data[1].dimensions.time = $to | .data[1].values[0].requests_attack = 1000 |
  .data[2].dimensions.time = ($to | fromdateiso8601 | . + 3600 | todateiso8601 | sub("Z$"; "+01:00")) |
  .data[2].values[0].requests_attack = 1000
' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
metrics="$($ROOT/ngwaf metrics requests_attack --start "$window_from" --end "$window_to" --json 2>"$TEST_TMP/end-boundary-err")"
jq -e '.validation.requested_intervals == 30 and .validation.observed_rows == 1 and
  .validation.excluded_end_boundary_rows == 2 and .validation.meta_total_checked == true and
  .data == [{workspace:"site-prd-a",workspace_id:"prod-a",requests_attack:1}]' >/dev/null <<<"$metrics"
grep -F 'excluded 2 row(s) timestamped at the requested end boundary' "$TEST_TMP/end-boundary-err" >/dev/null
"$ROOT/ngwaf" metrics requests_attack --start "$window_from" --end "$window_to" >"$TEST_TMP/end-boundary-text" 2>"$TEST_TMP/end-boundary-text-err"
grep -F 'excluded 2 row(s) timestamped at the requested end boundary' "$TEST_TMP/end-boundary-text-err" >/dev/null
jq --arg to "$window_to" '.data = [.data[0]] | .meta.total = 2 |
  .data += [{dimensions:{workspace:"unknown-workspace",time:$to},values:[{requests_attack:1000}]}]' \
  "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'workspace name is absent from selected customer inventory' metrics requests_attack --start "$window_from" --end "$window_to" --json
jq --arg to "$window_to" '
  .data = [.data[0], .data[1], .data[2]] | .meta.total = 3 |
  .data[1].dimensions.time = $to | .data[1].values[0].requests_attack = 1000 |
  .data[2].dimensions.time = ($to | fromdateiso8601 | . + 3600 | todateiso8601 | sub("Z$"; "+01:00")) |
  .data[2].values[0].requests_attack = 1000
' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
jq '.data += [.data[1]] | .meta.total = (.data | length)' "$NGWAF_TEST_ACCOUNT_BODY" >"$TEST_TMP/end-duplicate.json"
cp "$TEST_TMP/end-duplicate.json" "$NGWAF_TEST_ACCOUNT_BODY"
metrics="$($ROOT/ngwaf metrics requests_attack --start "$window_from" --end "$window_to" --json 2>"$TEST_TMP/end-boundary-err")"
jq -e '.validation.excluded_end_boundary_rows == 3 and .data[0].requests_attack == 1' >/dev/null <<<"$metrics"
jq '.meta.total = 5' "$NGWAF_TEST_ACCOUNT_BODY" >"$TEST_TMP/end-meta-mismatch.json"
cp "$TEST_TMP/end-meta-mismatch.json" "$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'meta.total differs from returned row count' metrics requests_attack --start "$window_from" --end "$window_to" --json
jq --arg to "$window_to" '.data = [.data[0]] | .meta.total = 1 |
  .data[0].dimensions.time = ($to | fromdateiso8601 | . + 86400 | todateiso8601)' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
after_end="$(jq -r '.data[0].dimensions.time' "$NGWAF_TEST_ACCOUNT_BODY")"
assert_account_rejected 'timeseries interval outside requested window' metrics requests_attack --start "$window_from" --end "$window_to" --json
if grep -F "$after_end" "$TEST_TMP/rejected-err" >/dev/null; then
  printf 'metrics test: interval detail emitted without opt-in\n' >&2
  exit 1
fi
assert_interval_diagnostic "$after_end"

jq 'del(.data[0]) | .meta.total = (.data | length)' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
metrics="$($ROOT/ngwaf metrics requests_attack 30 --json 2>"$TEST_TMP/integrity-err")"
jq -e '.validation.observed_rows == 89 and
  (.validation.workspace_intervals[] | select(.workspace == "site-prd-a") | .missing_intervals | length) == 1 and
  (.data[] | select(.workspace == "site-prd-a") | .requests_attack) == 28' >/dev/null <<<"$metrics"

jq '.data |= map(select(.dimensions.workspace != "site-qa")) | .meta.total = (.data | length)' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
metrics="$($ROOT/ngwaf metrics requests_attack 30 --json 2>"$TEST_TMP/integrity-err")"
jq -e '.validation.unobserved_workspaces == [{workspace:"site-qa",workspace_id:"qa"}] and
  (.data | length) == 2' >/dev/null <<<"$metrics"

jq '.data += [.data[0]] | .meta.total = (.data | length)' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'duplicate workspace/time interval' metrics requests_attack 30 --json
jq '.data += [(.data[0] | .dimensions.time |= sub("Z$"; ".000Z"))] |
  .meta.total = (.data | length)' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'duplicate workspace/time interval' metrics requests_attack 30 --json
jq '.data += [(.data[0] | .values[0].requests_attack = 99)] | .meta.total = (.data | length)' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'duplicate workspace/time interval' metrics requests_attack 30 --json
jq '.data[0].dimensions.time = "not-a-date"' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'malformed or unaligned timeseries timestamp' metrics requests_attack 30 --json
jq '.data[0].dimensions.time |= sub("Z$"; ".001Z")' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'malformed or unaligned timeseries timestamp' metrics requests_attack 30 --json
jq '.data[0].dimensions.time = "2026-02-30T00:00:00Z"' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'malformed or unaligned timeseries timestamp' metrics requests_attack 30 --json
jq --arg to "$window_to" '.data[0].dimensions.time = ($to | fromdateiso8601 | . + 86400 | todateiso8601)' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'timeseries interval outside requested window' metrics requests_attack 30 --json
jq '.meta.total = 91' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'meta.total differs from returned row count' metrics requests_attack 30 --json
jq '.meta.next_cursor = "more"' "$TEST_TMP/complete.json" >"$NGWAF_TEST_ACCOUNT_BODY"
assert_account_rejected 'response indicates another page' metrics requests_attack 30 --json
cp "$TEST_TMP/complete.json" "$NGWAF_TEST_ACCOUNT_BODY"
jq '.data += [{id:"another",name:"site-prd-a"}] | .meta.total = (.data | length)' "$NGWAF_TEST_INVENTORY_BODY" >"$TEST_TMP/collision.json"
export NGWAF_TEST_INVENTORY_BODY="$TEST_TMP/collision.json"
assert_account_rejected 'workspace display-name collision' metrics requests_attack 30 --json

printf 'metrics: OK\n'
