#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/config"

cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
outfile='' url='' page=1
printf 'CALL\n' >>"$CUSTOMER_SECURITY_CURL_LOG"
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    --data-urlencode)
      printf '%s\n' "$2" >>"$CUSTOMER_SECURITY_CURL_LOG"
      [[ "$2" != page=* ]] || page="${2#page=}"
      shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$CUSTOMER_SECURITY_CURL_LOG"
mode="${CUSTOMER_SECURITY_TEST_MODE:-ok}"
status=200
case "$url" in
  */customer/test-customer)
    if [[ "$mode" == customer-mismatch ]]; then
      printf '%s\n' '{"id":"other-customer","name":"Other Customer"}' >"$outfile"
    else
      printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    fi ;;
  */search/services)
    if [[ "$mode" == service-failure ]]; then
      status=503
      printf '%s\n' '{"error":"unavailable"}' >"$outfile"
    else
      printf '%s\n' '{"meta":{"total":2},"data":[{"id":"cdn","name":"CDN Service","type":"vcl","state":"active","production_version_number":7},{"id":"compute","name":"Compute Service","type":"wasm","state":"inactive","production_version_number":3}]}' >"$outfile"
    fi ;;
  */service)
    if [[ "$mode" == service-failure ]]; then
      status=503
      printf '%s\n' '{"error":"unavailable"}' >"$outfile"
    else
      printf '%s\n' '[{"id":"cdn","name":"CDN Service","type":"vcl","customer_id":"test-customer","paused":false},{"id":"compute","name":"Compute Service","type":"wasm","customer_id":"test-customer"},{"id":"foreign","name":"Other Customer Service","type":"vcl","customer_id":"other-customer"}]' >"$outfile"
    fi ;;
  */enabled-products/v1/*/services)
    product="${url#*/enabled-products/v1/}"; product="${product%/services}"
    if [[ "$mode" == zero || ( "$mode" == edge-zero && "$product" == ngwaf ) ]]; then
      printf '%s\n' '{"customer":{"id":"test-customer"},"services":[]}' >"$outfile"
    elif [[ "$mode" == unknown || "$mode" == partial || ( "$mode" == edge-unknown && "$product" == ngwaf ) ]]; then
      status=503
      printf '%s\n' '{"error":"unavailable"}' >"$outfile"
    else
      printf '%s\n' '{"customer":{"id":"test-customer"},"services":["cdn","compute","foreign"]}' >"$outfile"
    fi ;;
  */enabled-products/v1/*/configuration)
    case "$url" in
      */ngwaf/*)
        if [[ "$mode" == edge-config-unavailable ]]; then
          status=503
          printf '%s\n' '{"error":"unavailable"}' >"$outfile"
        elif [[ "$url" == */cdn/configuration ]]; then
          printf '%s\n' '{"configuration":{"workspace_id":"production","traffic_ramp":100}}' >"$outfile"
        else
          printf '%s\n' '{"configuration":{"workspace_id":"production","traffic_ramp":0}}' >"$outfile"
        fi ;;
      */ddos_protection/*)
        if [[ "$mode" == ddos-config-unavailable ]]; then
          status=503
          printf '%s\n' '{"error":"unavailable"}' >"$outfile"
        else
          printf '%s\n' '{"configuration":{"mode":"log"}}' >"$outfile"
        fi ;;
      */bot_management/*)
        printf '%s\n' '{"configuration":{"contentguard":false}}' >"$outfile" ;;
      *) status=599; printf '%s\n' '{}' >"$outfile" ;;
    esac ;;
  */enabled-products/v1/*/services/*)
    if [[ "$mode" == partial && "$url" == */cdn ]]; then
      printf '%s\n' '{}' >"$outfile"
    else
      status=503
      printf '%s\n' '{"error":"unavailable"}' >"$outfile"
    fi ;;
  */ngwaf/v1/workspaces)
    case "$mode" in
      workspace-failure) status=503; printf '%s\n' '{"error":"unavailable"}' >"$outfile" ;;
      workspace-incomplete) printf '%s\n' '{"meta":{"total":5},"data":[{"id":"production","name":"Production"}]}' >"$outfile" ;;
      workspace-mismatch) printf '%s\n' '{"meta":{"total":1},"data":[{"id":"production","name":"Production","customer_id":"other-customer"}]}' >"$outfile" ;;
      workspace-duplicate) printf '%s\n' '{"meta":{"total":2},"data":[{"id":"production"},{"id":"production"}]}' >"$outfile" ;;
      workspace-empty) printf '%s\n' '{"meta":{"total":0},"data":[]}' >"$outfile" ;;
      workspace-pagination)
        if [[ "$page" == 1 ]]; then
          jq -n '{meta:{total:101},data:[range(1;101) | {id:("workspace-" + tostring),name:("Workspace " + tostring),customer_id:"test-customer"}]}' >"$outfile"
        else
          printf '%s\n' '{"meta":{"total":101},"data":[{"id":"workspace-101","name":"Workspace 101","customer_id":"test-customer"}]}' >"$outfile"
        fi ;;
      *) printf '%s\n' '{"meta":{"total":2},"data":[{"id":"production","name":"Production","customer_id":"test-customer","mode":"block","default_blocking_response_code":406},{"id":"unattached","name":"Unattached Workspace","customer_id":"test-customer","mode":"log","default_blocking_response_code":403}]}' >"$outfile" ;;
    esac ;;
  *) status=599; printf '%s\n' '{"error":"unexpected endpoint"}' >"$outfile" ;;
esac
printf '%s' "$status"
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"
export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN=test-token FASTLY_CUSTOMER_ID=test-customer
export NGWAF_COLOR=never NGWAF_PROGRESS=never NGWAF_CURL_RETRIES=0
export XDG_CONFIG_HOME="$TEST_TMP/config"
export CUSTOMER_SECURITY_CURL_LOG="$TEST_TMP/curl-log"

# All help forms and invalid argument errors are offline, through both launchers.
for launcher in fastly-audit ngwaf; do
  for flag in help -h --help; do
    rm -f "$CUSTOMER_SECURITY_CURL_LOG"
    env -u FASTLY_API_TOKEN -u FASTLY_CUSTOMER_ID "$ROOT/$launcher" customer security "$flag" >"$TEST_TMP/help" 2>"$TEST_TMP/err"
    grep -F "$launcher customer security [--json]" "$TEST_TMP/help" >/dev/null
    grep -F 'configuration overview' "$TEST_TMP/help" >/dev/null
    [[ ! -s "$TEST_TMP/err" && ! -e "$CUSTOMER_SECURITY_CURL_LOG" ]]
  done
  for args in '--detailed' '--bogus' 'help --json' '--json --json'; do
    read -r -a invalid_args <<<"$args"
    if env -u FASTLY_API_TOKEN -u FASTLY_CUSTOMER_ID "$ROOT/$launcher" customer security "${invalid_args[@]}" >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
      printf 'customer-security: invalid arguments succeeded: %s\n' "$args" >&2; exit 1
    fi
    grep -F "usage: $launcher customer security" "$TEST_TMP/err" >/dev/null
    [[ ! -s "$TEST_TMP/out" && ! -e "$CUSTOMER_SECURITY_CURL_LOG" ]]
  done
done
"$ROOT/fastly-audit" help | grep -F 'fastly-audit customer security [--json]' >/dev/null
"$ROOT/fastly-audit" customer help | grep -F 'security [--json]' >/dev/null
"$ROOT/ngwaf" help | grep -F 'ngwaf customer security [--json]' >/dev/null

run_json() {
  "$ROOT/fastly-audit" customer security --json >"$TEST_TMP/json" 2>"$TEST_TMP/err"
  # Slurp also proves exactly one JSON value on stdout.
  jq -e -s 'length == 1 and .[0].schema_version == 1' "$TEST_TMP/json" >/dev/null
}
run_human() {
  "$ROOT/fastly-audit" customer security >"$TEST_TMP/human" 2>"$TEST_TMP/err"
}

run_json
cp "$TEST_TMP/json" "$TEST_TMP/complete-json"
jq -e '
  .command == "customer security" and .customer.id == "test-customer"
  and .summary.token_visible_customer_services == 2
  and .summary.service_inventory_status == "COMPLETE"
  and .provenance.service_discovery.source == "GET /search/services"
  and .inventory_sections.service_inventory.pagination.type == "cursor"
  and all(.products[].services[]; .paused == null and .active_version == null)
  and .summary.token_visibility_complete_for_customer == null
  and all(.products[]; .result.count == 2 and .result.status == "COMPLETE"
    and all(.services[]; .customer_id == "test-customer" and .id != "foreign"))
  and (.products[] | select(.id == "api_discovery") | [.services[].platform] | sort) == ["CDN","Compute"]
  and (.products[] | select(.id == "bot_management") | all(.services[]; .configuration.contentguard == false))
  and (.products[] | select(.id == "ddos_protection") | all(.services[]; .configuration.mode == "log" and .configuration_status == "RETRIEVED"))
  and (.ngwaf.attachments | length) == 2
  and .ngwaf.attachments[1].traffic_ramp_raw == 0
  and (.ngwaf.workspaces[] | select(.id == "production") | .attachment_count) == 2
  and (.ngwaf.workspaces[] | select(.id == "unattached") | .attachment_count) == 0
  and .ngwaf.attachment_mapping_result.status == "COMPLETE"
  and .inventory_sections.ngwaf_workspaces.evidence_type == "DIRECT"
  and (has("reconciliation") | not) and (.ngwaf | has("anomalies") | not)
' "$TEST_TMP/json" >/dev/null
grep -F 'customer scope: Test Customer (test-customer; source=environment)' "$TEST_TMP/err" >/dev/null
grep -Fx 'customer_id=test-customer' "$CUSTOMER_SECURITY_CURL_LOG" >/dev/null
if grep -Fx 'https://api.fastly.com/service' "$CUSTOMER_SECURITY_CURL_LOG" >/dev/null; then
  printf 'customer-security: successful search retrieved global service inventory\n' >&2; exit 1
fi
if grep -E '/events|/domains|/backends|/timeseries|/rules|/requests' "$CUSTOMER_SECURITY_CURL_LOG" >/dev/null; then
  printf 'customer-security: out-of-scope retrieval\n' >&2; exit 1
fi
run_human
grep -F 'Customer security configuration' "$TEST_TMP/human" >/dev/null
grep -F 'NGWAF workspaces inventoried: 2 (COMPLETE).' "$TEST_TMP/human" >/dev/null
grep -F 'they do not count NGWAF workspaces or every NGWAF deployment method.' "$TEST_TMP/human" >/dev/null
if grep -F 'Zero Edge WAF service attachments does not mean NGWAF is undeployed.' "$TEST_TMP/human" >/dev/null; then
  printf 'customer-security: zero-attachment note appeared for nonzero attachments\n' >&2; exit 1
fi
for heading in 'API DISCOVERY' 'BOT MANAGEMENT' 'DDOS PROTECTION' 'EDGE WAF SERVICE ATTACHMENTS' 'NGWAF WORKSPACES'; do
  grep -F "$heading" "$TEST_TMP/human" >/dev/null
done
grep -E 'CDN Service.*CDN.*log.*RETRIEVED' "$TEST_TMP/human" >/dev/null
grep -E 'Compute Service.*Compute.*Production.*0.*block.*406' "$TEST_TMP/human" >/dev/null
grep -E 'CDN Service.*CDN.*false.*RETRIEVED' "$TEST_TMP/human" >/dev/null
grep -E 'Unattached Workspace.*unattached.*log.*403.*0' "$TEST_TMP/human" >/dev/null
"$ROOT/ngwaf" customer security --json >"$TEST_TMP/legacy-json" 2>"$TEST_TMP/err"
diff -u <(jq 'del(.generated_at) | walk(if type == "object" then del(.retrieved_at) else . end)' "$TEST_TMP/complete-json") \
  <(jq 'del(.generated_at) | walk(if type == "object" then del(.retrieved_at) else . end)' "$TEST_TMP/legacy-json")

# The projection retains existing product/provenance data, and security summary
# still exposes its original v1 command, modes, reconciliation and renderer.
"$ROOT/fastly-audit" security summary --detailed --json >"$TEST_TMP/summary" 2>"$TEST_TMP/err"
diff -u <(jq '.products | walk(if type == "object" then del(.retrieved_at) else . end)' "$TEST_TMP/complete-json") \
  <(jq '.products | walk(if type == "object" then del(.retrieved_at) else . end)' "$TEST_TMP/summary")
jq -e '.command == "security summary" and .detailed == true and has("reconciliation") and (.ngwaf | has("anomalies"))' "$TEST_TMP/summary" >/dev/null
: >"$CUSTOMER_SECURITY_CURL_LOG"
"$ROOT/fastly-audit" security summary --json >"$TEST_TMP/summary" 2>"$TEST_TMP/err"
jq -e '.mode == "summary" and .detailed == false and (.products[] | select(.id == "ddos_protection") | all(.services[]; .configuration_status == "NOT_REQUESTED"))' "$TEST_TMP/summary" >/dev/null
if grep -E '/(bot_management|ddos_protection)/services/[^/]+/configuration' "$CUSTOMER_SECURITY_CURL_LOG" >/dev/null; then
  printf 'customer-security: default security summary fetched detailed configuration\n' >&2; exit 1
fi
"$ROOT/fastly-audit" security summary >"$TEST_TMP/summary-human" 2>"$TEST_TMP/err"
grep -F 'Security product summary' "$TEST_TMP/summary-human" >/dev/null

for mode in zero unknown partial edge-zero edge-unknown edge-config-unavailable ddos-config-unavailable workspace-pagination workspace-empty; do
  export CUSTOMER_SECURITY_TEST_MODE="$mode"
  run_json
  run_human
  case "$mode" in
    zero)
      jq -e 'all(.products[]; .result.status == "COMPLETE" and .result.count == 0) and all(.ngwaf.workspaces[]; .attachment_count == 0)' "$TEST_TMP/json" >/dev/null
      [[ "$(grep -Fc 'No configured service mappings found.' "$TEST_TMP/human")" == 4 ]] ;;
    unknown)
      jq -e 'all(.products[]; .result.status == "UNKNOWN" and .result.count == null and .result.count_lower_bound == null)' "$TEST_TMP/json" >/dev/null
      [[ "$(grep -Fc 'Retrieval was inconclusive (UNKNOWN)' "$TEST_TMP/human")" == 4 ]]
      if grep -F 'No configured service mappings found.' "$TEST_TMP/human" >/dev/null; then
        printf 'customer-security: unknown retrieval rendered as zero\n' >&2; exit 1
      fi ;;
    partial)
      jq -e 'all(.products[]; .result.status == "PARTIAL" and .result.count == null and .result.count_lower_bound == 1)' "$TEST_TMP/json" >/dev/null
      grep -F 'Retrieval was inconclusive (PARTIAL)' "$TEST_TMP/human" >/dev/null ;;
    edge-zero)
      jq -e '.ngwaf.workspace_count == 2 and all(.ngwaf.workspaces[]; .attachment_count == 0)
        and any(.limitations[]; contains("zero attachments does not mean NGWAF is undeployed"))' "$TEST_TMP/json" >/dev/null
      grep -F 'NGWAF workspaces inventoried: 2 (COMPLETE).' "$TEST_TMP/human" >/dev/null
      grep -F 'Zero Edge WAF service attachments does not mean NGWAF is undeployed.' "$TEST_TMP/human" >/dev/null ;;
    edge-unknown|edge-config-unavailable)
      jq -e 'all(.ngwaf.workspaces[]; .attachment_count == null and .attachment_count_lower_bound == 0)' "$TEST_TMP/json" >/dev/null
      grep -E 'Unattached Workspace.*UNKNOWN' "$TEST_TMP/human" >/dev/null
      if [[ "$mode" == edge-config-unavailable ]]; then
        jq -e '(.products[] | select(.id == "ngwaf") | .result.count == 2 and all(.services[]; .configuration_status == "UNAVAILABLE"))' "$TEST_TMP/json" >/dev/null
      fi ;;
    ddos-config-unavailable)
      jq -e '(.products[] | select(.id == "ddos_protection") | .result.count == 2 and all(.services[]; .configuration == null and .configuration_status == "UNAVAILABLE"))' "$TEST_TMP/json" >/dev/null
      grep -E 'CDN Service.*not reported.*UNAVAILABLE' "$TEST_TMP/human" >/dev/null ;;
    workspace-pagination)
      jq -e '.ngwaf.workspace_count == 101 and .ngwaf.pages_fetched == 2 and (.ngwaf.workspaces | length) == 101' "$TEST_TMP/json" >/dev/null ;;
    workspace-empty) grep -F 'No NGWAF workspaces found in the complete inventory.' "$TEST_TMP/human" >/dev/null ;;
  esac
done

for mode in customer-mismatch service-failure workspace-failure workspace-incomplete workspace-mismatch workspace-duplicate; do
  export CUSTOMER_SECURITY_TEST_MODE="$mode"
  if "$ROOT/fastly-audit" customer security --json >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'customer-security: unsafe %s response succeeded\n' "$mode" >&2; exit 1
  fi
  [[ ! -s "$TEST_TMP/out" ]]
done
printf 'customer-security: OK\n'
