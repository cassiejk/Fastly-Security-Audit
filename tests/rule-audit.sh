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
query=""
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
    --data-urlencode)
      case "$2" in
        q=*) query="${2#q=}" ;;
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

request_total() {
  local q="$1"
  case "$q" in
    *"ruleid:allow-rule tag:SQLI"*) printf '100' ;;
    *"ruleid:allow-rule tag:XSS"*) printf '0' ;;
    *"ruleid:allow-rule tag:CMDEXE"*) printf '3' ;;
    *"ruleid:allow-rule tag:TRAVERSAL"*) printf '1' ;;
    *"ruleid:allow-rule tag:SCANNER"*) printf '10' ;;
    *"ruleid:allow-rule tag:SUSPECTED-BAD-BOT"*) printf '20' ;;
    *"ruleid:allow-rule tag:DATACENTER"*) printf '50' ;;
    *"ruleid:allow-rule"*) printf '1000001' ;;
    *"ruleid:block-rule tag:"*) printf '0' ;;
    *"ruleid:block-rule"*) printf '0' ;;
    *) printf '0' ;;
  esac
}

case "$url" in
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    printf '200'
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"production","name":"Production"}]}' >"$outfile"
    printf '200'
    ;;
  */ngwaf/v1/workspaces/production/rules/allow-rule)
    jq -n '{
      id: "allow-rule",
      type: "request",
      enabled: true,
      description: "Allow static assets",
      scope: {applies_to: ["production"]},
      request_logging: "sampled",
      condition_operator: "all",
      group_operator: "all",
      conditions: [
        {field: "path", operator: "matches_regex", value: "^/assets/.*\\.(css|js|png)$"}
      ],
      actions: [
        {type: "allow"},
        {type: "add_signal", signal: "allowed.static"}
      ],
      created_at: "2000-01-01T00:00:00Z",
      updated_at: "2000-01-01T00:00:00Z"
    }' >"$outfile"
    printf '200'
    ;;
  */ngwaf/v1/workspaces/production/rules/block-rule)
    jq -n '{
      id: "block-rule",
      type: "request",
      enabled: true,
      description: "Block scanner traffic",
      scope: {applies_to: ["production"]},
      conditions: [
        {field: "signal", operator: "equals", value: "SCANNER"}
      ],
      actions: [{type: "block"}],
      created_at: "2026-09-01T00:00:00Z",
      updated_at: "2026-09-01T00:00:00Z"
    }' >"$outfile"
    printf '200'
    ;;
  */ngwaf/v1/workspaces/production/requests)
    if [[ "${NGWAF_TEST_RULE_AUDIT_MODE:-ok}" == "malformed-count" ]]; then
      printf '%s\n' '{"meta":{"total":1},"data":{"unexpected":true}}' >"$outfile"
    else
      total="$(request_total "$query")"
      jq -n --argjson total "$total" '{meta:{total:$total},data:[]}' >"$outfile"
    fi
    printf '200'
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
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0
export NGWAF_TEST_CURL_ARGS="$TEST_TMP/curl-args"
: >"$NGWAF_TEST_CURL_ARGS"

"$ROOT/fastly-audit" ngwaf help >"$TEST_TMP/help"
grep -F "rule-audit <workspace> <rule_id> [<rule_id> ...]" "$TEST_TMP/help" >/dev/null

output="$(
  "$ROOT/fastly-audit" ngwaf rule-audit \
    Production \
    allow-rule \
    block-rule \
    --days 7 \
    --json \
    2>"$TEST_TMP/stderr"
)"

jq -e '
  .command == "rule-audit"
  and .customer == "Test Customer"
  and .customer_id == "test-customer"
  and .workspace == "Production"
  and .workspace_id == "production"
  and .workspace_input == "Production"
  and .days == 7
  and .signals == ["SQLI","XSS","CMDEXE","TRAVERSAL","SCANNER","SUSPECTED-BAD-BOT","DATACENTER"]
  and .count_scope == "retained_searchable_request_records"
  and .window.type == "rolling"
  and .window.ingestion_buffer_seconds == 300
  and ((.window.until_epoch - .window.from_epoch) == (7 * 86400))
  and .summary.rules_audited == 2
  and .summary.rules_with_allow == 1
  and .summary.rules_with_signal_intersections == 1
  and .summary.rules_over_high_volume_threshold == 1
  and .provenance.request_search.aggregation == "response.meta.total"
  and .provenance.request_search.rows_requested_per_count == 1
  and .provenance.rule_configuration.identity_validation == "response id must match requested rule id"
' >/dev/null <<<"$output"

jq -e '
  any(.rules[];
    .rule_id == "allow-rule"
    and .description == "Allow static assets"
    and .enabled == true
    and .type == "request"
    and .action_types == ["allow", "add_signal"]
    and .configuration.request_logging == "sampled"
    and .configuration.condition_operator == "all"
    and .configuration.group_operator == "all"
    and .configuration.raw.id == "allow-rule"
    and .total_retained_matches == 1000001
    and .total_match_query == "ruleid:allow-rule"
    and any(.signal_intersections[];
      .signal == "SQLI"
      and .query == "ruleid:allow-rule tag:SQLI"
      and .count == 100
      and (.percent_of_rule_matches > 0.009 and .percent_of_rule_matches < 0.011)
    )
    and any(.signal_intersections[];
      .signal == "XSS"
      and .count == 0
      and .percent_of_rule_matches == 0
    )
    and any(.review_indicators[]; .indicator == "allow_action")
    and any(.review_indicators[]; .indicator == "add_signal_plus_allow")
    and any(.review_indicators[]; .indicator == "path_only_allow")
    and any(.review_indicators[]; .indicator == "static_extension_allow")
    and any(.review_indicators[]; .indicator == "regex_condition")
    and any(.review_indicators[]; .indicator == "stale_rule")
    and any(.review_indicators[]; .indicator == "high_match_volume")
    and any(.review_indicators[]; .indicator == "allow_signal_intersections")
  )
' >/dev/null <<<"$output"

jq -e '
  any(.rules[];
    .rule_id == "block-rule"
    and .action_types == ["block"]
    and .total_retained_matches == 0
    and any(.signal_intersections[];
      .signal == "SQLI"
      and .count == 0
      and .percent_of_rule_matches == null
    )
    and any(.review_indicators[]; .indicator == "block_action")
  )
' >/dev/null <<<"$output"

grep -F 'fastly-audit: customer scope: Test Customer (test-customer; source=environment)' "$TEST_TMP/stderr" >/dev/null
grep -F 'fastly-audit: workspace scope: Production (production; resolved_by=name)' "$TEST_TMP/stderr" >/dev/null
grep -F 'https://api.fastly.com/ngwaf/v1/workspaces/production/rules/allow-rule' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'https://api.fastly.com/ngwaf/v1/workspaces/production/requests' "$NGWAF_TEST_CURL_ARGS" >/dev/null
request_window_count="$(
  grep -E '^q=from:[0-9]+ until:[0-9]+' "$NGWAF_TEST_CURL_ARGS" |
    sed -E 's/^q=from:([0-9]+) until:([0-9]+).*/\1 \2/' |
    sort -u |
    wc -l |
    tr -d '[:space:]'
)"
[[ "$request_window_count" == "1" ]]
limit_count="$(grep -c '^limit=1$' "$NGWAF_TEST_CURL_ARGS")"
(( limit_count >= 16 ))

"$ROOT/ngwaf" rule-audit Production allow-rule \
  --days 7 \
  --signals SQLI,DATACENTER \
  >"$TEST_TMP/human" \
  2>"$TEST_TMP/human-err"
grep -F 'NGWAF rule audit' "$TEST_TMP/human" >/dev/null
grep -F 'Rule allow-rule' "$TEST_TMP/human" >/dev/null
grep -F 'Signal intersections' "$TEST_TMP/human" >/dev/null
grep -F 'Review indicators' "$TEST_TMP/human" >/dev/null
grep -F 'Counts represent retained searchable NGWAF records' "$TEST_TMP/human" >/dev/null

if "$ROOT/ngwaf" rule-audit Production allow-rule --days 8 >"$TEST_TMP/out" 2>"$TEST_TMP/days-err"; then
  printf 'rule-audit test: invalid days unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'request-search days must be between 1 and 7' "$TEST_TMP/days-err" >/dev/null

export NGWAF_TEST_RULE_AUDIT_MODE=malformed-count
if "$ROOT/ngwaf" rule-audit Production allow-rule --json >"$TEST_TMP/out" 2>"$TEST_TMP/malformed-err"; then
  printf 'rule-audit test: malformed request-search response unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'request search returned an unexpected response' "$TEST_TMP/malformed-err" >/dev/null

printf 'rule-audit: OK\n'
