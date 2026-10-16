#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
fail() { printf 'workspace-services service-id: %s\n' "$1" >&2; exit 1; }
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/config"

cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
outfile='' url=''
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$SERVICE_SCOPED_CURL_LOG"
mode="${SERVICE_SCOPED_MODE:-legacy}"
status=200
case "$url" in
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile" ;;
  */service/cdn-target)
    if [[ "$mode" == foreign ]]; then
      printf '%s\n' '{"id":"cdn-target","name":"Target CDN","type":"vcl","customer_id":"other-customer","active_version":7}' >"$outfile"
    elif [[ "$mode" == no-version ]]; then
      printf '%s\n' '{"id":"cdn-target","name":"Target CDN","type":"vcl","customer_id":"test-customer"}' >"$outfile"
    else
      printf '%s\n' '{"id":"cdn-target","name":"Target CDN","type":"vcl","customer_id":"test-customer","active_version":7}' >"$outfile"
    fi ;;
  */service/cdn-target/version/7/generated_vcl)
    case "$mode" in
      enabled|no-map) printf '%s\n' '{"content":"sub vcl_recv { return(pass); }"}' >"$outfile" ;;
      vcl-unavailable) status=503; printf '%s\n' '{"error":"unavailable"}' >"$outfile" ;;
      *) printf '%s\n' '{"content":"set req.http.X-Inspection = \"se--costco--prod.edgecompute.app\";"}' >"$outfile" ;;
    esac ;;
  */v0/corps/costco/sites)
    if [[ "$mode" == sites-unavailable ]]; then
      status=503; printf '%s\n' '{"error":"unavailable"}' >"$outfile"
    elif [[ "$mode" == sites-foreign ]]; then
      printf '%s\n' '{"data":[{"id":"internal-site","name":"Production Workspace","customer_id":"other-customer","serviceID":"inspection-target"}]}' >"$outfile"
    elif [[ "$mode" == sites-missing-customer ]]; then
      printf '%s\n' '{"data":[{"id":"internal-site","name":"Production Workspace","customer_id":"test-customer","serviceID":"inspection-target"},{"id":"unverified-site","name":"Unverified Workspace","serviceID":"other-inspection"}]}' >"$outfile"
    else
      printf '%s\n' '{"data":[{"id":"internal-site","name":"Production Workspace","customer_id":"test-customer","serviceID":"inspection-target"}]}' >"$outfile"
    fi ;;
  */service/inspection-target)
    if [[ "$mode" == inspection-foreign ]]; then
      printf '%s\n' '{"id":"inspection-target","name":"se--costco--prod","type":"wasm","customer_id":"other-customer"}' >"$outfile"
    else
      printf '%s\n' '{"id":"inspection-target","name":"se--costco--prod","type":"wasm","customer_id":"test-customer"}' >"$outfile"
    fi ;;
  */enabled-products/v1/ngwaf/services/cdn-target/configuration)
    if [[ "$mode" == conflict ]]; then
      printf '%s\n' '{"configuration":{"workspace_id":"workspace-other"}}' >"$outfile"
    else
      printf '%s\n' '{"configuration":{"workspace_id":"workspace-main"}}' >"$outfile"
    fi ;;
  */enabled-products/v1/ngwaf/services/cdn-target)
    case "$mode" in
      enabled|both|conflict) printf '%s\n' '{}' >"$outfile" ;;
      product-unavailable) status=503; printf '%s\n' '{"error":"unavailable"}' >"$outfile" ;;
      *) status=404; printf '%s\n' '{"error":"not found"}' >"$outfile" ;;
    esac ;;
  */ngwaf/v1/workspaces)
    if [[ "$mode" == workspaces-unavailable ]]; then
      status=503; printf '%s\n' '{"error":"unavailable"}' >"$outfile"
    elif [[ "$mode" == ambiguous ]]; then
      printf '%s\n' '{"meta":{"total":2},"data":[{"id":"workspace-main","name":"Production Workspace","customer_id":"test-customer"},{"id":"workspace-other","name":"Production Workspace","customer_id":"test-customer"}]}' >"$outfile"
    else
      printf '%s\n' '{"meta":{"total":2},"data":[{"id":"workspace-main","name":"Production Workspace","customer_id":"test-customer"},{"id":"workspace-other","name":"Other Workspace","customer_id":"test-customer"}]}' >"$outfile"
    fi ;;
  *) status=599; printf '%s\n' '{"error":"unexpected endpoint"}' >"$outfile" ;;
esac
printf '%s' "$status"
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"
export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN=test-fastly-secret FASTLY_CUSTOMER_ID=test-customer
export FASTLY_DSTOKEN=test-dstoken-secret FASTLY_VOUCH_COOKIE=test-vouch-secret
export SERVICE_SCOPED_CURL_LOG="$TEST_TMP/calls"
export XDG_CONFIG_HOME="$TEST_TMP/config" NGWAF_COLOR=never NGWAF_PROGRESS=never NGWAF_CURL_RETRIES=0

assert_scoped_requests() {
  if rg -q '/search/services|/service$|/enabled-products/v1/ngwaf/services$' "$SERVICE_SCOPED_CURL_LOG"; then
    fail 'customer-wide service or product inventory request was made'
  fi
  if rg '/generated_vcl$' "$SERVICE_SCOPED_CURL_LOG" | rg -qv '/service/cdn-target/version/7/generated_vcl$'; then
    fail 'unrelated service generated VCL was requested'
  fi
  [[ "$(rg -c '/service/cdn-target$' "$SERVICE_SCOPED_CURL_LOG")" == 1 ]] || fail 'selected service metadata was fetched more than once'
  if rg -q '/version/[0-9]+/domain$|/agents$|/cloud_waf/' "$SERVICE_SCOPED_CURL_LOG"; then
    fail 'unrequested domains, agents, or Cloud WAF were fetched'
  fi
}

run_case() {
  export SERVICE_SCOPED_MODE="$1"
  : >"$SERVICE_SCOPED_CURL_LOG"
  if "$ROOT/fastly-audit" ngwaf workspace-services --service-id cdn-target --json --sigsci-corp costco >"$TEST_TMP/result.json" 2>"$TEST_TMP/err"; then
    [[ "$2" == success ]] || fail "$1 unexpectedly succeeded"
  else
    [[ "$2" == failure ]] || { cat "$TEST_TMP/err" >&2; fail "$1 unexpectedly failed"; }
  fi
  assert_scoped_requests
  jq -e '.scope == "service_id" and .customer_id == "test-customer" and .customer == "Test Customer" and .selected_service.id == "cdn-target" and .selected_service.name == "Target CDN" and .summary.scanned_cdn_services == 1' "$TEST_TMP/result.json" >/dev/null
}

run_case legacy success
jq -e '.status == "COMPLETE" and .relationship_status == "MAPPED" and .selected_service.active_version == 7 and .workspaces[0].workspace_id == "workspace-main" and .workspaces[0].services[0].mapping_sources == ["in_band_vcl_evidence"] and .workspaces[0].services[0].mapping_evidence[0].evidence.internal_site_id == "internal-site" and .workspaces[0].services[0].mapping_evidence[0].evidence.workspace_resolution == "unique_exact_workspace_name"' "$TEST_TMP/result.json" >/dev/null
[[ "$(rg -c '/generated_vcl$' "$SERVICE_SCOPED_CURL_LOG")" == 1 ]] || fail 'generated VCL fetched more than once'
[[ "$(rg -c '/service/inspection-target$' "$SERVICE_SCOPED_CURL_LOG")" == 1 ]] || fail 'Inspection Service fetched more than once'
[[ "$(wc -l <"$SERVICE_SCOPED_CURL_LOG" | tr -d ' ')" == 7 ]] || fail 'legacy mapping made an unexpected number of API requests'
run_case enabled success
jq -e '.status == "COMPLETE" and .relationship_status == "MAPPED" and .workspaces[0].services[0].mapping_sources == ["enabled_product_api"] and .legacy_service_evidence[0].status == "NOT_FOUND"' "$TEST_TMP/result.json" >/dev/null
! rg -q '/v0/corps/|/service/inspection-target$' "$SERVICE_SCOPED_CURL_LOG" || fail 'site inventory fetched without an in-band hostname'
[[ "$(wc -l <"$SERVICE_SCOPED_CURL_LOG" | tr -d ' ')" == 6 ]] || fail 'product-only mapping made an unexpected number of API requests'
run_case both success
jq -e '.workspaces[0].services[0].mapping_sources == ["enabled_product_api","in_band_vcl_evidence"]' "$TEST_TMP/result.json" >/dev/null
run_case conflict failure
jq -e '.status == "PARTIAL" and .relationship_status == "CONFLICTING" and .mapping_conflicts[0].type == "source_workspace_disagreement" and (.workspaces | length) == 2' "$TEST_TMP/result.json" >/dev/null
run_case no-map success
jq -e '.status == "COMPLETE" and .relationship_status == "NO_OBSERVED_MAPPING" and (.workspaces | length) == 0 and .provenance.workspace_inventory.requested == false and (.limitations[0] | contains("does not prove"))' "$TEST_TMP/result.json" >/dev/null
! rg -q '/ngwaf/v1/workspaces$|/v0/corps/' "$SERVICE_SCOPED_CURL_LOG" || fail 'unneeded shared inventory fetched for no mapping'
[[ "$(wc -l <"$SERVICE_SCOPED_CURL_LOG" | tr -d ' ')" == 4 ]] || fail 'no-mapping case made an unexpected number of API requests'
run_case ambiguous failure
jq -e '.status == "PARTIAL" and .relationship_status == "UNRESOLVED" and (.unmatched_workspace_relationships | length) == 1 and (.workspaces | length) == 0' "$TEST_TMP/result.json" >/dev/null
run_case no-version failure
jq -e '.selected_service.active_version == null and .legacy_service_evidence[0].status == "UNKNOWN" and .relationship_status == "UNRESOLVED"' "$TEST_TMP/result.json" >/dev/null
! rg -q '/generated_vcl$' "$SERVICE_SCOPED_CURL_LOG" || fail 'generated VCL requested without active version'
run_case sites-unavailable failure
jq -e '.status == "UNKNOWN" and .relationship_status == "UNRESOLVED" and .provenance.in_band_vcl_evidence.internal_ngwaf_sites.status == "UNKNOWN"' "$TEST_TMP/result.json" >/dev/null
run_case vcl-unavailable failure
jq -e '.status == "PARTIAL" and .legacy_service_evidence[0].status == "UNKNOWN" and .relationship_status == "UNRESOLVED"' "$TEST_TMP/result.json" >/dev/null
run_case product-unavailable failure
jq -e '.status == "UNKNOWN" and .provenance.enabled_product_api.http_status == "503"' "$TEST_TMP/result.json" >/dev/null
run_case inspection-foreign failure
jq -e '.status == "PARTIAL" and .relationship_status == "UNRESOLVED" and .unresolved_services[0].lookup_failures[0].reason == "Inspection Service customer ownership could not be verified" and (.workspaces | length) == 0' "$TEST_TMP/result.json" >/dev/null
: >"$SERVICE_SCOPED_CURL_LOG"
SERVICE_SCOPED_MODE=workspaces-unavailable
if "$ROOT/fastly-audit" ngwaf workspace-services --service-id cdn-target --json --sigsci-corp costco >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then fail 'unavailable workspace inventory accepted'; fi
[[ ! -s "$TEST_TMP/out" ]] || fail 'unverified workspace inventory emitted a mapping'
rg -q 'workspace inventory unavailable; cannot verify the selected service mapping' "$TEST_TMP/err" || fail 'workspace failure lacked diagnostic'

: >"$SERVICE_SCOPED_CURL_LOG"
if "$ROOT/fastly-audit" ngwaf workspace-services --service-id 'cdn*' --json --sigsci-corp costco >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then fail 'invalid ID accepted'; fi
! rg -q '/service/|/generated_vcl|/v0/corps/' "$SERVICE_SCOPED_CURL_LOG" || fail 'invalid ID reached service configuration'
for args in '--all --service-id cdn-target' 'workspace-main --service-id cdn-target' '--service-id cdn-target --service-id cdn-target'; do
  read -r -a fields <<<"$args"
  if "$ROOT/fastly-audit" ngwaf workspace-services "${fields[@]}" --json --sigsci-corp costco >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then fail 'incompatible selectors accepted'; fi
done
: >"$SERVICE_SCOPED_CURL_LOG"
SERVICE_SCOPED_MODE=foreign
if "$ROOT/fastly-audit" ngwaf workspace-services --service-id cdn-target --json --sigsci-corp costco >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then fail 'foreign service accepted'; fi
[[ ! -s "$TEST_TMP/out" ]] || fail 'foreign service emitted a mapping'
! rg -q '/generated_vcl|/v0/corps/|/enabled-products/' "$SERVICE_SCOPED_CURL_LOG" || fail 'foreign service configuration was retrieved'
: >"$SERVICE_SCOPED_CURL_LOG"
if (unset FASTLY_DSTOKEN; "$ROOT/fastly-audit" ngwaf workspace-services --service-id cdn-target --json --sigsci-corp costco) >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then fail 'missing legacy credentials accepted'; fi
[[ ! -s "$TEST_TMP/out" ]] || fail 'missing credentials emitted mapping'
! rg -q '/service/|/generated_vcl|/v0/corps/' "$SERVICE_SCOPED_CURL_LOG" || fail 'missing credentials reached collection'
: >"$SERVICE_SCOPED_CURL_LOG"
SERVICE_SCOPED_MODE=sites-foreign
if "$ROOT/fastly-audit" ngwaf workspace-services --service-id cdn-target --json --sigsci-corp costco >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then fail 'foreign internal sites accepted'; fi
[[ ! -s "$TEST_TMP/out" ]] || fail 'foreign internal sites emitted mapping'
! rg -q '/service/inspection-target$|/ngwaf/v1/workspaces$' "$SERVICE_SCOPED_CURL_LOG" || fail 'foreign internal sites were reconciled'
: >"$SERVICE_SCOPED_CURL_LOG"
SERVICE_SCOPED_MODE=sites-missing-customer
if "$ROOT/fastly-audit" ngwaf workspace-services --service-id cdn-target --json --sigsci-corp costco >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then fail 'site without customer ID accepted'; fi
[[ ! -s "$TEST_TMP/out" ]] || fail 'unverified internal sites emitted mapping'
! rg -q '/service/inspection-target$|/service/other-inspection$|/ngwaf/v1/workspaces$' "$SERVICE_SCOPED_CURL_LOG" || fail 'unverified internal sites were reconciled'
if rg -q 'test-fastly-secret|test-dstoken-secret|test-vouch-secret' "$TEST_TMP" --glob '*.json' --glob '*.err' --glob '*.out'; then fail 'credential value leaked'; fi
printf 'workspace-services service-id: OK\n'
