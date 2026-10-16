#!/usr/bin/env bash
# Globals and doubles are consumed by the dynamically sourced production code.
# shellcheck disable=SC2034,SC2329
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
# Exercise production command formatters/normalizers with synthetic collections.
# All HTTP is intercepted: even an unexpected request cannot reach the network.
for module in core services security bots rule_audit; do
  # shellcheck source=/dev/null
  source "$ROOT/lib/$module.sh"
done
PROGRAM_NAME=fastly-audit
NGWAF_COLOR=never
current_cid() { printf 'CustomerSynthetic\n'; }
API_BASE=https://api.fastly.com
FASTLY_API_TOKEN=offline-synthetic-token
CURL_CONNECT_TIMEOUT=1
CURL_MAX_TIME=1
CURL_RETRIES=0
CURL_RETRY_MAX_TIME=0
curl() {
  local url='' outfile=''
  while (( $# > 0 )); do
    case "$1" in
      -o) outfile="$2"; shift 2 ;;
      https://*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  [[ "$url" == https://api.fastly.com/customer/CustomerSynthetic ]] || {
    printf 'Unexpected HTTP request: %s\n' "$url" >&2; return 1;
  }
  printf '%s\n' '{"id":"CustomerSynthetic","name":"Synthetic customer"}' >"$outfile"
  printf '200'
}
get_customer_services() {
  printf '%s\n' '{"meta":{"result":{"status":"COMPLETE"},"status":"COMPLETE"},"data":[{"id":"ServiceSynthetic","name":"Synthetic CDN","customer_id":"CustomerSynthetic","type":"vcl","paused":false}]}'
}
get_all_pages() { printf '%s\n' '{"meta":{"pages_fetched":1,"total":0},"data":[]}'; }
fixture_products="$(jq -n '
  [{tag:"true",value:true},{tag:"false",value:false},{tag:"null",value:null},
   {tag:"missing"},{tag:"on",value:"on"},{tag:"off",value:"off"},{tag:"unknown",value:"unknown"}]
  | [{id:"bot_management",label:"Bot Management",category:"security",discovery_method:"offline",
      enabled_count:7,unknown_check_count:0,
      result:{status:"COMPLETE",count:7,services_checked:7,configuration:{status:"COMPLETE"}},
      services:map({id:.tag,name:("Case-"+.tag),customer_id:"CustomerSynthetic",type:"vcl",platform:"CDN",
        configuration:(if has("value") then {contentguard:.value} else {} end),
        configuration_requested:true,configuration_status:"RETRIEVED",configuration_http_status:200})}]')"
printf '%s\n' "$fixture_products" >"$TEST_TMP/products.json"
collect_products_json() { printf '%s\n' "$fixture_products"; }
collect_security_products_json() { printf '%s\n' "$fixture_products"; }
# Keep the actual security-summary collector: counts/statuses must not depend on
# whether the returned configuration value is true, false, null, or absent.
for command in cmd_products cmd_inventory cmd_security_summary; do
  extra=()
  [[ "$command" != cmd_security_summary ]] || extra=(--detailed)
  "$command" "${extra[@]}" --json >"$TEST_TMP/$command.json"
  "$command" "${extra[@]}" >"$TEST_TMP/$command.human"
  jq -e --slurpfile expected "$TEST_TMP/products.json" '
    (.products // .service_products.products)==$expected[0]
  ' "$TEST_TMP/$command.json" >/dev/null
  jq -e '
    (.products // .service_products.products)[0] as $p
    | $p.result.count==7 and $p.result.status=="COMPLETE"
      and all($p.services[]; .configuration_status=="RETRIEVED")
      and ($p.services | any(.id=="false" and .configuration.contentguard==false))
      and ($p.services | any(.id=="null" and .configuration.contentguard==null and (.configuration|has("contentguard"))))
      and ($p.services | any(.id=="missing" and (.configuration|has("contentguard")|not)))
  ' "$TEST_TMP/$command.json" >/dev/null
  for tag in true false null missing on off unknown; do
    expected="$tag"
    case "$tag" in null|missing) expected=unknown ;; esac
    # Match the complete cell, not a substring of the service name.
    awk -v name="Case-$tag" -v expected="contentguard=$expected" '
      $1==name {for(i=2;i<=NF;i++) if($i==expected) found=1} END {exit !found}
    ' "$TEST_TMP/$command.human"
  done
done
jq -e '.summary.configuration_summary.retrieved_count==7 and .summary.configuration_summary.unavailable_count==0
  and .summary.configuration_summary.not_requested_count==0' "$TEST_TMP/cmd_security_summary.json" >/dev/null

# Normalize actual rule-audit output and render both normalized and direct raw
# false input so the human fallback is tested independently of normalization.
get_workspace_rule_json() { printf '%s\n' "$source_rule"; }
rule_audit_count_query() { printf '0\n'; }
rule_audit_intersections_json() { printf '[]\n'; }
rule_audit_indicators_json() { printf '[]\n'; }
REQUEST_SEARCH_CUSTOMER_ID=CustomerSynthetic
REQUEST_SEARCH_WORKSPACE_ID=WorkspaceSynthetic
REQUEST_SEARCH_WORKSPACE=Synthetic
for tag in true false null missing; do
  source_rule="$(jq -n --arg tag "$tag" '{id:"RuleSynthetic",actions:[]} +
    (if $tag=="missing" then {} else {enabled:($tag|fromjson)} end)')"
  normalized="$(rule_audit_one_rule_json RuleSynthetic '[]')"
  jq -e --argjson raw "$source_rule" '
    .enabled==$raw.enabled and .configuration.enabled==$raw.enabled
    and .configuration.raw==$raw
  ' <<<"$normalized" >/dev/null
  expected="$tag"
  case "$tag" in null|missing) expected=unknown ;; esac
  report="$(jq -n --argjson rule "$normalized" '{signals:[],rules:[$rule]}')"
  rule_audit_render_human "$report" >"$TEST_TMP/rule-$tag.human"
  grep -F "Enabled: $expected ·" "$TEST_TMP/rule-$tag.human" >/dev/null
  if [[ "$tag" == false ]]; then
    jq -e '.enabled==false and .configuration.enabled==false and .configuration.raw.enabled==false' <<<"$normalized" >/dev/null
    rule_audit_render_human '{"signals":[],"rules":[{"rule_id":"DirectFalse","enabled":false,"action_types":[],"signal_intersections":[],"review_indicators":[],"total_retained_matches":0}]}' >"$TEST_TMP/direct-false"
    grep -F 'Enabled: false ·' "$TEST_TMP/direct-false" >/dev/null
  fi
done
resolve_workspace_json() { printf '%s\n' '{"id":"WorkspaceSynthetic","name":"Synthetic"}'; }
get_all_pages() {
  jq -n '{meta:{pages_fetched:1},data:[
    {id:"true",enabled:true},{id:"false",enabled:false},{id:"null",enabled:null},{id:"missing"}
  ] | map(.+{conditions:["SUSPECTED-BAD-BOT"]})}'
}
cmd_bot_rules WorkspaceSynthetic --json >"$TEST_TMP/bots.json"
cmd_bot_rules WorkspaceSynthetic >"$TEST_TMP/bots.human"
jq -e '.matched_rules==4 and .total_rules_scanned==4
  and any(.rules[]; .id=="true" and .enabled==true)
  and any(.rules[]; .id=="false" and .enabled==false)
  and all(.rules[] | select(.id=="null" or .id=="missing"); has("enabled") and .enabled==null)
  and all(.rules[]; .actions==[] and .bot_signals==["SUSPECTED-BAD-BOT"] and .match_basis==["bot-signal"])
' "$TEST_TMP/bots.json" >/dev/null
awk '$1=="true" {t++} $1=="false" {f++} $1=="unknown" {u++} END {exit !(t==1 && f==1 && u==2)}' "$TEST_TMP/bots.human"
printf 'boolean-evidence: OK (offline synthetic collections)\n'
