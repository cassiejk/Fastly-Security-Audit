#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init

# shellcheck source=../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../lib/template_audit.sh
source "$ROOT/lib/template_audit.sh"

resolver_candidates='[
  {
    "rule_id": "rule-registration",
    "enabled": true,
    "type": "templated_signal",
    "name": "REGATTEMPT",
    "template_id": "tmpl-registration",
    "template_name": null,
    "signal_id": null,
    "signal_name": "REGATTEMPT",
    "correlation_key": "template_id:tmpl-registration",
    "selectors": ["rule-registration", "tmpl-registration", "REGATTEMPT"]
  }
]'

assert_template_resolves() {
  local selector="$1"
  local expected_strategy="$2"
  local result

  result="$(template_audit_select_template_json "$resolver_candidates" "$selector")"
  jq -e \
    --arg selector "$selector" \
    --arg expected_strategy "$expected_strategy" '
      .status == "selected"
      and .requested_template == $selector
      and .template.canonical_signal == "REGATTEMPT"
      and .template.signal_name == "REGATTEMPT"
      and .template.match_strategy == $expected_strategy
    ' >/dev/null <<<"$result"
}

assert_template_not_found() {
  local selector="$1"
  local result

  result="$(template_audit_select_template_json "$resolver_candidates" "$selector")"
  jq -e \
    --arg selector "$selector" '
      .status == "not_found"
      and .requested_template == $selector
    ' >/dev/null <<<"$result"
}

assert_template_resolves REGATTEMPT canonical_exact
assert_template_resolves regattempt canonical_exact_case_insensitive
assert_template_resolves "Registration Attempt" friendly_name_alias
assert_template_resolves "Registration Attempts" friendly_name_alias
assert_template_not_found "Password Reset"
assert_template_not_found Registration

alias_result="$(template_audit_select_template_json "$resolver_candidates" "Registration Attempt")"
jq -e '
  .template.alias == "Registration Attempt"
  and .template.alias_canonical == "REGATTEMPT"
  and .template.resolver.input == "Registration Attempt"
  and .template.resolver.canonical_signal == "REGATTEMPT"
' >/dev/null <<<"$alias_result"

ambiguous_candidates='[
  {
    "rule_id": "rule-a",
    "enabled": true,
    "type": "templated_signal",
    "name": "Shared Friendly",
    "template_id": "tmpl-one",
    "template_name": "Shared Friendly",
    "signal_id": "SIG_A",
    "signal_name": "SIG_A",
    "correlation_key": "signal_id:SIG_A",
    "selectors": ["rule-a", "tmpl-one", "SIG_A", "Shared Friendly"]
  },
  {
    "rule_id": "rule-b",
    "enabled": true,
    "type": "templated_signal",
    "name": "Shared Friendly",
    "template_id": "tmpl-two",
    "template_name": "Shared Friendly",
    "signal_id": "SIG_B",
    "signal_name": "SIG_B",
    "correlation_key": "signal_id:SIG_B",
    "selectors": ["rule-b", "tmpl-two", "SIG_B", "Shared Friendly"]
  }
]'
ambiguous_result="$(template_audit_select_template_json "$ambiguous_candidates" "Shared Friendly")"
jq -e '
  .status == "ambiguous"
  and .match_strategy == "display_name_exact"
  and (.matches | length) == 2
' >/dev/null <<<"$ambiguous_result"

mkdir -p "$TEST_TMP/bin"

cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
outfile=""
url=""

if [[ -n "${NGWAF_TEST_CURL_ARGS:-}" ]]; then
  printf '%s\n' "$@" >>"$NGWAF_TEST_CURL_ARGS"
fi

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

write_rules() {
  case "${NGWAF_TEST_TEMPLATE_AUDIT_MODE:-ok}" in
    ambiguous)
      cat >"$outfile" <<'JSON'
{"meta":{"total":2},"data":[
  {"id":"rule-a","type":"templated_signal","enabled":true,"template":{"id":"tmpl-one","name":"Shared Friendly"},"signal":{"id":"SIG_A","name":"SIG_A"},"conditions":[{"field":"method","operator":"equals","value":"POST"},{"field":"path","operator":"equals","value":"/register"}],"actions":[{"type":"add_signal","signal":{"id":"SIG_A","name":"SIG_A"}}]},
  {"id":"rule-b","type":"templated_signal","enabled":true,"template":{"id":"tmpl-two","name":"Shared Friendly"},"signal":{"id":"SIG_B","name":"SIG_B"},"conditions":[{"field":"method","operator":"equals","value":"POST"},{"field":"path","operator":"equals","value":"/signup"}],"actions":[{"type":"add_signal","signal":{"id":"SIG_B","name":"SIG_B"}}]}
]}
JSON
      ;;
    *)
      cat >"$outfile" <<'JSON'
{"meta":{"total":4},"data":[
  {"id":"rule-enabled","type":"templated_signal","enabled":true,"description":"Registration Attempt submit route","template":{"id":"tmpl-registration"},"signal":{"name":"REGATTEMPT"},"conditions":[{"field":"method","operator":"equals","value":"POST"},{"field":"path","operator":"equals","value":"/register/submit"}],"actions":[{"type":"add_signal","signal":"REGATTEMPT"}],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z"},
  {"id":"rule-disabled","type":"templated_signal","enabled":false,"description":"Registration Attempt legacy route","template":{"id":"tmpl-registration"},"signal":{"name":"REGATTEMPT"},"conditions":[{"field":"method","operator":"equals","value":"POST"},{"field":"path","operator":"equals","value":"/api/register"}],"actions":[{"type":"add_signal","signal":"REGATTEMPT"}],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-08-01T00:00:00Z"},
  {"id":"rule-duplicate","type":"templated_signal","enabled":true,"description":"Registration Attempt duplicate route","template":{"id":"tmpl-registration"},"signal":{"name":"REGATTEMPT"},"conditions":[{"field":"method","operator":"equals","value":"POST"},{"field":"path","operator":"equals","value":"/register/submit"}],"actions":[{"type":"add_signal","signal":"REGATTEMPT"}]},
  {"id":"rule-other","type":"templated_signal","enabled":true,"description":"Login Attempt route","template":{"id":"tmpl-login"},"signal":{"name":"LOGINATTEMPT"},"conditions":[{"field":"method","operator":"equals","value":"POST"},{"field":"path","operator":"equals","value":"/login"}],"actions":[{"type":"add_signal","signal":"LOGINATTEMPT"}]}
]}
JSON
      ;;
  esac
}

write_thresholds() {
  case "${NGWAF_TEST_TEMPLATE_AUDIT_MODE:-ok}" in
    malformed-thresholds)
      printf '%s\n' '{"unexpected":[]}' >"$outfile"
      ;;
    no-thresholds)
      printf '%s\n' '{"data":[]}' >"$outfile"
      ;;
    *)
      cat >"$outfile" <<'JSON'
{"data":[
  {"id":"threshold-1","enabled":true,"signal":{"name":"REGATTEMPT"},"count":3,"window_seconds":60,"action":"block","key":"IP","duration_seconds":86400},
  {"id":"threshold-2","enabled":true,"signal":{"name":"REGATTEMPT"},"count":7,"window_seconds":600,"action":"block","key":"IP","duration_seconds":86400},
  {"id":"threshold-disabled","enabled":false,"signal":{"name":"REGATTEMPT"},"count":10,"window_seconds":3600,"action":"block","key":"IP","duration_seconds":86400},
  {"id":"threshold-duplicate","enabled":true,"signal":{"name":"REGATTEMPT"},"count":3,"window_seconds":60,"action":"block","key":"IP","duration_seconds":86400},
  {"id":"threshold-other","enabled":true,"signal":{"name":"LOGINATTEMPT"},"count":5,"window_seconds":60,"action":"block","key":"IP","duration_seconds":3600}
]}
JSON
      ;;
  esac
}

case "$url" in
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"production","name":"Production"}]}' >"$outfile"
    ;;
  */ngwaf/v1/workspaces/production/rules)
    write_rules
    ;;
  */ngwaf/v1/workspaces/production/thresholds)
    write_thresholds
    ;;
  */ngwaf/v1/workspaces/production/requests)
    if [[ "${NGWAF_TEST_TEMPLATE_AUDIT_MODE:-ok}" == "zero-traffic" ]]; then
      printf '%s\n' '{"meta":{"total":0},"data":[]}' >"$outfile"
    else
      printf '%s\n' '{"meta":{"total":123456},"data":[]}' >"$outfile"
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
export XDG_CONFIG_HOME="$TEST_TMP/config"
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0
export NGWAF_TEST_CURL_ARGS="$TEST_TMP/curl-args"

"$ROOT/fastly-audit" ngwaf template-audit --help >"$TEST_TMP/help"
grep -F "template-audit <workspace> <template>" "$TEST_TMP/help" >/dev/null

output="$("$ROOT/fastly-audit" ngwaf template-audit Production "Registration Attempt" --json 2>"$TEST_TMP/name.err")"
jq -e '
  .command == "template-audit"
  and .customer == "Test Customer"
  and .customer_id == "test-customer"
  and .workspace == "Production"
  and .workspace_id == "production"
  and .template.name == "REGATTEMPT"
  and .template.template_id == "tmpl-registration"
  and .template.signal_id == null
  and .template.signal_name == "REGATTEMPT"
  and .template.canonical_signal == "REGATTEMPT"
  and .template.input == "Registration Attempt"
  and .template.alias == "Registration Attempt"
  and .template.alias_canonical == "REGATTEMPT"
  and .template.match_strategy == "friendly_name_alias"
  and .summary.tagging_rules == 3
  and .summary.enabled_tagging_rules == 2
  and .summary.disabled_tagging_rules == 1
  and .summary.thresholds == 4
  and .summary.active_thresholds == 3
  and .summary.disabled_thresholds == 1
  and .traffic.retained_matches == 123456
  and .traffic.query == "tag:REGATTEMPT"
  and .traffic.count_scope == "retained_searchable_request_records"
  and (.traffic.sampling_caveat | contains("not raw traffic"))
  and (.drill_down.command | contains("fastly-audit ngwaf requests"))
  and any(.tagging_rules[]; .rule_id == "rule-enabled" and .enabled == true and .method == "POST" and .path == "/register/submit")
  and any(.tagging_rules[]; .rule_id == "rule-disabled" and .enabled == false and .path == "/api/register")
  and any(.thresholds[]; .threshold_id == "threshold-1" and .count == 3 and .window_label == "1 minute" and .duration_label == "1 day" and .action == "block" and .key == "IP")
  and any(.thresholds[]; .threshold_id == "threshold-disabled" and .enabled == false)
  and any(.review_indicators[]; .indicator == "disabled_tagging_rules")
  and any(.review_indicators[]; .indicator == "disabled_thresholds")
  and any(.review_indicators[]; .indicator == "duplicate_tagging_conditions")
  and any(.review_indicators[]; .indicator == "identical_thresholds")
  and any(.review_indicators[]; .indicator == "duplicate_threshold_window_action")
  and any(.review_indicators[]; .indicator == "possible_overlap")
  and .provenance.API_access == "read_only_GET_requests"
' >/dev/null <<<"$output"
grep -F 'tag:REGATTEMPT' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'https://api.fastly.com/ngwaf/v1/workspaces/production/rules' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'https://api.fastly.com/ngwaf/v1/workspaces/production/thresholds' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'https://api.fastly.com/ngwaf/v1/workspaces/production/requests' "$NGWAF_TEST_CURL_ARGS" >/dev/null

id_output="$("$ROOT/fastly-audit" ngwaf template-audit production REGATTEMPT --json 2>"$TEST_TMP/id.err")"
jq -e '
  .template.match_strategy == "canonical_exact"
  and .template.canonical_signal == "REGATTEMPT"
  and .template.alias == null
  and .template.template_id == "tmpl-registration"
  and .summary.tagging_rules == 3
' >/dev/null <<<"$id_output"

"$ROOT/ngwaf" template-audit Production "Registration Attempt" 7 >"$TEST_TMP/human" 2>"$TEST_TMP/human.err"
grep -F 'Template Audit: REGATTEMPT' "$TEST_TMP/human" >/dev/null
grep -F 'Input: Registration Attempt' "$TEST_TMP/human" >/dev/null
grep -F 'Signal: REGATTEMPT' "$TEST_TMP/human" >/dev/null
grep -F 'Matched by: friendly_name_alias' "$TEST_TMP/human" >/dev/null
grep -F 'Signal tagging rules' "$TEST_TMP/human" >/dev/null
grep -F 'DISABLED' "$TEST_TMP/human" >/dev/null
grep -F 'Thresholds' "$TEST_TMP/human" >/dev/null
grep -F 'Signal matches: 123456' "$TEST_TMP/human" >/dev/null
grep -F 'ngwaf requests' "$TEST_TMP/human" >/dev/null
grep -F 'Review indicators' "$TEST_TMP/human" >/dev/null

NGWAF_TEST_TEMPLATE_AUDIT_MODE=no-thresholds \
  "$ROOT/fastly-audit" ngwaf template-audit Production "Registration Attempt" --json >"$TEST_TMP/no-thresholds.json" 2>"$TEST_TMP/no-thresholds.err"
jq -e '
  .summary.thresholds == 0
  and any(.review_indicators[]; .indicator == "no_associated_thresholds")
  and any(.review_indicators[]; .indicator == "enabled_tagging_rules_without_active_thresholds")
' >/dev/null "$TEST_TMP/no-thresholds.json"

NGWAF_TEST_TEMPLATE_AUDIT_MODE=zero-traffic \
  "$ROOT/fastly-audit" ngwaf template-audit Production "Registration Attempt" --json >"$TEST_TMP/zero.json" 2>"$TEST_TMP/zero.err"
jq -e '
  .traffic.retained_matches == 0
  and any(.review_indicators[]; .indicator == "zero_retained_matches")
' >/dev/null "$TEST_TMP/zero.json"

if "$ROOT/fastly-audit" ngwaf template-audit Production "Password Reset" --json >"$TEST_TMP/missing.out" 2>"$TEST_TMP/missing.err"; then
  printf 'template-audit test: missing template unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'templated signal not found: Password Reset' "$TEST_TMP/missing.err" >/dev/null

if NGWAF_TEST_TEMPLATE_AUDIT_MODE=ambiguous \
  "$ROOT/fastly-audit" ngwaf template-audit Production "Shared Friendly" --json >"$TEST_TMP/ambiguous.out" 2>"$TEST_TMP/ambiguous.err"; then
  printf 'template-audit test: ambiguous template unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'templated signal is ambiguous: Shared Friendly' "$TEST_TMP/ambiguous.err" >/dev/null

if NGWAF_TEST_TEMPLATE_AUDIT_MODE=malformed-thresholds \
  "$ROOT/fastly-audit" ngwaf template-audit Production "Registration Attempt" --json >"$TEST_TMP/malformed.out" 2>"$TEST_TMP/malformed.err"; then
  printf 'template-audit test: malformed thresholds unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'thresholds returned an unexpected response' "$TEST_TMP/malformed.err" >/dev/null

count_output="$("$ROOT/ngwaf" count Production 'tag:SQLI' 7 2>"$TEST_TMP/count.err")"
jq -e '.count == 123456 and .query == "tag:SQLI"' >/dev/null <<<"$count_output"

printf 'template-audit: OK\n'
