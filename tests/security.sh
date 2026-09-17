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
event_type_activate=false
if [[ -n "${FASTLY_TEST_SECURITY_CURL_ARGS:-}" ]]; then
  printf '%s\n' "$@" >>"$FASTLY_TEST_SECURITY_CURL_ARGS"
fi
for arg in "$@"; do
  [[ "$arg" == "filter[event_type]=version.activate" ]] && event_type_activate=true
done
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

status=200
case "$url" in
  */customer/test-customer)
    if [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'customer-mismatch' ]]; then
      printf '%s\n' '{"id":"wrong-customer","name":"Wrong Customer"}' >"$outfile"
    else
      printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    fi
    ;;
  */service)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      empty-service-inventory)
        printf '%s\n' '[]' >"$outfile"
        ;;
      service-api-error)
        printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
        status=503
        ;;
      service-invalid-json)
        printf '%s\n' '{"services":[{"id":"service-1"}]}' >"$outfile"
        ;;
      service-truncated)
        printf '%s\n' '{
          "meta":{"total":5},
          "data":[
            {"id":"service-1","name":"www.example.com","customer_id":"test-customer","type":"vcl","active_version":7,"paused":false},
            {"id":"service-2","name":"api.example.com","customer_id":"test-customer","type":"wasm","active_version":{"number":3},"paused":false},
            {"id":"other-service","name":"other.example.com","customer_id":"other-customer","type":"vcl","active_version":1,"paused":false}
          ]
        }' >"$outfile"
        ;;
      active-version-matrix)
        printf '%s\n' '[
          {"id":"service-env-absent","name":"env-absent.example.com","customer_id":"test-customer","type":"vcl","version":11,"paused":false},
          {"id":"service-env-null","name":"env-null.example.com","customer_id":"test-customer","type":"vcl","version":12,"environments":null,"paused":false},
          {"id":"service-env-empty","name":"env-empty.example.com","customer_id":"test-customer","type":"vcl","version":13,"environments":[],"paused":false},
          {"id":"service-env-production","name":"env-production.example.com","customer_id":"test-customer","type":"vcl","version":14,"environments":[{"name":"staging","active_version":140},{"name":"production","active_version":141}],"paused":false},
          {"id":"service-active-object","name":"active-object.example.com","customer_id":"test-customer","type":"vcl","active_version":{"number":15},"version":150,"environments":[{"name":"production","active_version":151}],"paused":false},
          {"id":"service-active-scalar","name":"active-scalar.example.com","customer_id":"test-customer","type":"vcl","active_version":16,"version":160,"environments":[{"name":"production","active_version":161}],"paused":false},
          {"id":"service-version-only","name":"version-only.example.com","customer_id":"test-customer","type":"vcl","version":17,"paused":false}
        ]' >"$outfile"
        ;;
      *)
        printf '%s\n' '[
          {"id":"service-1","name":"www.example.com","customer_id":"test-customer","type":"vcl","active_version":7,"paused":false},
          {"id":"service-2","name":"api.example.com","customer_id":"test-customer","type":"wasm","active_version":{"number":3},"paused":false},
          {"id":"service-1","name":"www.example.com duplicate","customer_id":"test-customer","type":"vcl","active_version":7,"paused":false},
          {"id":"other-service","name":"other.example.com","customer_id":"other-customer","type":"vcl","active_version":1,"paused":false}
        ]' >"$outfile"
        ;;
    esac
    ;;
  */events)
    if [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'observed-products' ]]; then
      if $event_type_activate; then
        printf '%s\n' '{"data":[{"attributes":{"customer_id":"test-customer","service_id":"service-1"}},{"attributes":{"customer_id":"test-customer","service_id":"service-2"}}]}' >"$outfile"
      else
        printf '%s\n' '{"data":[]}' >"$outfile"
      fi
    else
      printf '%s\n' '{"errors":[{"title":"Audit events should not be used by security summary"}]}' >"$outfile"
      status=503
    fi
    ;;
  */service/service-1)
    printf '%s\n' '{"id":"service-1","name":"www.example.com","customer_id":"test-customer","type":"vcl","active_version":7,"paused":false}' >"$outfile"
    ;;
  */service/service-2)
    printf '%s\n' '{"id":"service-2","name":"api.example.com","customer_id":"test-customer","type":"wasm","active_version":{"number":3},"paused":false}' >"$outfile"
    ;;
  */enabled-products/v1/api_discovery/services)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      all-products-503) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      product-null-services) printf '%s\n' '{"customer":{"id":"test-customer"},"services":null}' >"$outfile" ;;
      product-missing-collection) printf '%s\n' '{"customer":{"id":"test-customer"},"enabled":true}' >"$outfile" ;;
      product-401) printf '%s\n' '{"error":"unauthorized"}' >"$outfile"; status=401 ;;
      product-403) printf '%s\n' '{"error":"forbidden"}' >"$outfile"; status=403 ;;
      product-list-404) printf '%s\n' '{"error":"not found"}' >"$outfile"; status=404 ;;
      product-429) printf '%s\n' '{"error":"rate limited"}' >"$outfile"; status=429 ;;
      product-500) printf '%s\n' '{"error":"server error"}' >"$outfile"; status=500 ;;
      product-503|product-partial-fallback) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      product-timeout) printf 'timeout\n' >&2; exit 28 ;;
      product-malformed-json) printf '%s\n' '{"services":[' >"$outfile" ;;
      product-invalid-json) printf '%s\n' '{"services":"oops"}' >"$outfile" ;;
      *) printf '%s\n' '{"customer":{"id":"test-customer"},"services":[]}' >"$outfile" ;;
    esac
    ;;
  */enabled-products/v1/api_discovery/services/service-1)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      all-products-503) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      product-partial-fallback) printf '%s\n' '{}' >"$outfile" ;;
      product-list-404) printf '%s\n' '{"error":"not found"}' >"$outfile"; status=404 ;;
      product-401) printf '%s\n' '{"error":"unauthorized"}' >"$outfile"; status=401 ;;
      product-403) printf '%s\n' '{"error":"forbidden"}' >"$outfile"; status=403 ;;
      product-429) printf '%s\n' '{"error":"rate limited"}' >"$outfile"; status=429 ;;
      product-500) printf '%s\n' '{"error":"server error"}' >"$outfile"; status=500 ;;
      product-503|product-invalid-json) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      product-timeout) printf 'timeout\n' >&2; exit 28 ;;
      *) printf '%s\n' '{"error":"not found"}' >"$outfile"; status=404 ;;
    esac
    ;;
  */enabled-products/v1/api_discovery/services/service-2)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      all-products-503) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      product-list-404) printf '%s\n' '{"error":"not found"}' >"$outfile"; status=404 ;;
      product-401) printf '%s\n' '{"error":"unauthorized"}' >"$outfile"; status=401 ;;
      product-403) printf '%s\n' '{"error":"forbidden"}' >"$outfile"; status=403 ;;
      product-429) printf '%s\n' '{"error":"rate limited"}' >"$outfile"; status=429 ;;
      product-500) printf '%s\n' '{"error":"server error"}' >"$outfile"; status=500 ;;
      product-503|product-invalid-json|product-partial-fallback) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      product-timeout) printf 'timeout\n' >&2; exit 28 ;;
      *) printf '%s\n' '{"error":"not found"}' >"$outfile"; status=404 ;;
    esac
    ;;
  */enabled-products/v1/bot_management/services)
    if [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'all-products-503' ]]; then
      printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
      status=503
    elif [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'reconciliation-clean' || "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'ngwaf-zero-edge-waf-64-workspaces' ]]; then
      printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-1","service-2"]}' >"$outfile"
    elif [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'active-version-matrix' ]]; then
      printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-env-absent","service-env-null","service-env-empty","service-env-production","service-active-object","service-active-scalar","service-version-only"]}' >"$outfile"
    elif [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'product-data-object-shape' ]]; then
      printf '%s\n' '{"customer":{"id":"test-customer"},"data":[{"id":"service-1"},{"service_id":"service-2"},{"id":"other-service"}]}' >"$outfile"
    else
      printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-1","service-2","service-2","other-service"]}' >"$outfile"
    fi
    ;;
  */enabled-products/v1/ddos_protection/services)
    if [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'unknown-ddos' || "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'all-products-503' ]]; then
      printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
      status=503
    elif [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'reconciliation-clean' || "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'ngwaf-zero-edge-waf-64-workspaces' ]]; then
      printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-1","service-2"]}' >"$outfile"
    elif [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'product-services-object-shape' ]]; then
      printf '%s\n' '{"customer":{"id":"test-customer"},"services":[{"id":"service-1"},{"service_id":"service-2"},{"id":"other-service"}]}' >"$outfile"
    else
      printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-1","service-2","service-2","other-service"]}' >"$outfile"
    fi
    ;;
  */enabled-products/v1/ngwaf/services)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      ngwaf-product-503|all-products-503)
        printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
        status=503
        ;;
      ngwaf-zero-edge-waf-64-workspaces)
        printf '%s\n' '{"customer":{"id":"test-customer"},"services":[]}' >"$outfile"
        ;;
      reconciliation-clean)
        printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-1","service-2"]}' >"$outfile"
        ;;
      *)
        printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-1","service-2","service-2","other-service"]}' >"$outfile"
        ;;
    esac
    ;;
  */enabled-products/v1/ddos_protection/services/service-1)
    if [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'unknown-ddos' || "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'all-products-503' ]]; then
      printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
      status=503
    else
      printf '%s\n' '{}' >"$outfile"
    fi
    ;;
  */enabled-products/v1/ddos_protection/services/service-2)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      all-products-503) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      *) printf '%s\n' '{"error":"not found"}' >"$outfile"; status=404 ;;
    esac
    ;;
  */enabled-products/v1/bot_management/services/service-1)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      all-products-503) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      *) printf '%s\n' '{"error":"not found"}' >"$outfile"; status=404 ;;
    esac
    ;;
  */enabled-products/v1/bot_management/services/service-2)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      all-products-503) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      *) printf '%s\n' '{"error":"not found"}' >"$outfile"; status=404 ;;
    esac
    ;;
  */enabled-products/v1/ngwaf/services/service-1)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      ngwaf-product-503|all-products-503) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      *) printf '%s\n' '{}' >"$outfile" ;;
    esac
    ;;
  */enabled-products/v1/ngwaf/services/service-2)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      ngwaf-product-503|all-products-503) printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"; status=503 ;;
      *) printf '%s\n' '{}' >"$outfile" ;;
    esac
    ;;
  */enabled-products/v1/bot_management/services/service-1/configuration)
    printf '%s\n' '{"configuration":{"contentguard":"off"}}' >"$outfile"
    ;;
  */enabled-products/v1/bot_management/services/service-2/configuration)
    printf '%s\n' '{"configuration":{"contentguard":"on"}}' >"$outfile"
    ;;
  */enabled-products/v1/ddos_protection/services/service-1/configuration)
    printf '%s\n' '{"configuration":{"mode":"block"}}' >"$outfile"
    ;;
  */enabled-products/v1/ddos_protection/services/service-2/configuration)
    if [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'detailed-ddos-config-503' ]]; then
      printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
      status=503
    else
      printf '%s\n' '{"configuration":{"mode":"log"}}' >"$outfile"
    fi
    ;;
  */enabled-products/v1/ngwaf/services/service-1/configuration)
    printf '%s\n' '{"configuration":{"workspace_id":"production","traffic_ramp":100}}' >"$outfile"
    ;;
  */enabled-products/v1/ngwaf/services/service-2/configuration)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      ngwaf-same-workspace)
        printf '%s\n' '{"configuration":{"workspace_id":"production","traffic_ramp":100}}' >"$outfile"
        ;;
      ngwaf-missing-workspace-id)
        printf '%s\n' '{"configuration":{"traffic_ramp":100}}' >"$outfile"
        ;;
      ngwaf-missing-ramp)
        printf '%s\n' '{"configuration":{"workspace_id":"production-compute"}}' >"$outfile"
        ;;
      ngwaf-invalid-ramp)
        printf '%s\n' '{"configuration":{"workspace_id":"production-compute","traffic_ramp":"fast"}}' >"$outfile"
        ;;
      ngwaf-ramp-below-100)
        printf '%s\n' '{"configuration":{"workspace_id":"production-compute","traffic_ramp":50}}' >"$outfile"
        ;;
      *)
        printf '%s\n' '{"configuration":{"workspace_id":"production-compute","traffic_ramp":100}}' >"$outfile"
        ;;
    esac
    ;;
  */ngwaf/v1/workspaces)
    case "${FASTLY_TEST_SECURITY_MODE:-ok}" in
      ngwaf-missing-workspace)
        printf '%s\n' '{"meta":{"total":1},"data":[{"id":"production","name":"Production","mode":"block","default_blocking_response_code":406}]}' >"$outfile"
        ;;
      ngwaf-workspace-without-attachment)
        printf '%s\n' '{"meta":{"total":3},"data":[{"id":"production","name":"Production","mode":"block","default_blocking_response_code":406},{"id":"production-compute","name":"Production Compute","mode":"block","default_blocking_response_code":403},{"id":"unused","name":"Unused Workspace","mode":"log","default_blocking_response_code":406}]}' >"$outfile"
        ;;
      ngwaf-zero-edge-waf-64-workspaces)
        {
          printf '{"meta":{"total":64},"data":['
          for i in $(seq 1 64); do
            [[ "$i" -eq 1 ]] || printf ','
            printf '{"id":"workspace-%02d","name":"Workspace %02d","mode":"block","default_blocking_response_code":406}' "$i" "$i"
          done
          printf ']}'
        } >"$outfile"
        ;;
      ngwaf-workspace-api-error)
        printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
        status=503
        ;;
      *)
        printf '%s\n' '{"meta":{"total":2},"data":[{"id":"production","name":"Production","mode":"block","default_blocking_response_code":406},{"id":"production-compute","name":"Production Compute","mode":"block","default_blocking_response_code":403}]}' >"$outfile"
        ;;
    esac
    ;;
  *)
    printf '%s\n' '{"error":"unhandled fake endpoint"}' >"$outfile"
    status=404
    ;;
esac
printf '%s' "$status"
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"

export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN="test-token"
export FASTLY_CUSTOMER_ID="test-customer"
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0
export NGWAF_SERVICE_AUDIT_PAGE_SIZE=100
export FASTLY_TEST_SECURITY_CURL_ARGS="$TEST_TMP/curl-args"

# Directly exercise the product collector boundary where selected-service
# inventory is handed to discover_product_json().
PROGRAM_NAME="fastly-audit"
API_BASE="https://api.fastly.com"
CONFIG_DIR="$TEST_TMP/config"
CID_FILE="$CONFIG_DIR/customer_id"
CURL_CONNECT_TIMEOUT="${NGWAF_CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${NGWAF_CURL_MAX_TIME:-60}"
CURL_RETRIES="${NGWAF_CURL_RETRIES:-0}"
CURL_RETRY_MAX_TIME="${NGWAF_CURL_RETRY_MAX_TIME:-90}"
SERVICE_AUDIT_DAYS="${NGWAF_SERVICE_AUDIT_DAYS:-365}"
SERVICE_AUDIT_MAX_PAGES="${NGWAF_SERVICE_AUDIT_MAX_PAGES:-25}"
SERVICE_AUDIT_PAGE_SIZE="${NGWAF_SERVICE_AUDIT_PAGE_SIZE:-100}"
NGWAF_CUSTOMER_CONTEXT_JSON=""
# shellcheck source=../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../lib/services.sh
source "$ROOT/lib/services.sh"
# shellcheck source=../lib/security.sh
source "$ROOT/lib/security.sh"

malformed_selected_products="$(collect_security_products_json '{"meta":{},"services":[]}' 2>"$TEST_TMP/malformed-selected-products-err")"
jq -e '
  length == 4
  and all(.[];
    .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.count == null
    and .result.count_lower_bound == null
    and (.result.reason | contains("selected service inventory could not be normalized"))
    and .result.http_statuses == []
    and .result.services_checked == 0
    and (.services | length) == 0
  )
' >/dev/null <<<"$malformed_selected_products"

zero_selected_products="$(collect_security_products_json '{"meta":{},"data":[]}' 2>"$TEST_TMP/zero-selected-products-err")"
jq -e '
  length == 4
  and all(.[];
    .result.status == "COMPLETE"
    and .result.evidence_type == "DIRECT"
    and .result.count == 0
    and .result.count_lower_bound == null
    and .result.services_checked == 0
    and (.services | length) == 0
  )
' >/dev/null <<<"$zero_selected_products"

$ROOT/fastly-audit security help >"$TEST_TMP/help"
grep -F 'summary [--json] [--detailed]' "$TEST_TMP/help" >/dev/null

: >"$FASTLY_TEST_SECURITY_CURL_ARGS"
output="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/stderr")"
jq -e '
  .schema_version == 1
  and .command == "security summary"
  and .mode == "summary"
  and .detailed == false
  and .customer.id == "test-customer"
  and .summary.token_visible_customer_services == 2
  and .summary.evidence_type == "DERIVED"
  and (.summary.derived_from | index("products") != null)
  and (.summary | has("observed_services") | not)
  and .summary.security_products_scanned == 4
  and .summary.enabled_product_types == 3
  and .summary.product_inventory_status == "COMPLETE"
  and .summary.service_product_mappings == 6
  and .summary.service_product_mappings == ([.products[].result.count] | add)
  and .summary.cdn_mappings == 3
  and .summary.compute_mappings == 3
  and .summary.unknown_enablement_checks == 0
  and .summary.configuration_summary.evidence_type == "DERIVED"
  and .summary.configuration_summary.status == "PARTIAL"
  and .summary.configuration_summary.mapping_count == 6
  and .summary.configuration_summary.requested_count == 2
  and .summary.configuration_summary.retrieved_count == 2
  and .summary.configuration_summary.unavailable_count == 0
  and .summary.configuration_summary.known_unavailable_count == 0
  and .summary.configuration_summary.not_requested_count == 4
  and .summary.configuration_summary.not_applicable_count == 0
  and (.summary.configuration_summary.legacy_unavailable_configurations_semantics | contains("NOT_REQUESTED"))
  and .summary.known_unavailable_configurations == 0
  and .summary.unavailable_configurations == 0
  and .summary.ngwaf_workspaces == 2
  and .summary.edge_waf_service_attachments == 2
  and .summary.edge_waf_service_attachment_status == "COMPLETE"
  and .summary.ngwaf_service_attachments == 2
  and .summary.ngwaf_service_attachment_status == "COMPLETE"
  and .summary.completeness == "token-visible"
  and (.products | length) == 4
  and (.provenance.service_discovery.source == "GET /service")
  and (.provenance.service_discovery.evidence_type == "DIRECT")
  and (.provenance.service_discovery.result.evidence_type == "DIRECT")
  and (.provenance.service_discovery.result.customer_scope.customer_id == "test-customer")
  and all(.products[];
    ((.result.status == "UNKNOWN" and .result.evidence_type == "UNKNOWN")
     or (.result.status != "UNKNOWN" and .result.evidence_type == "DIRECT"))
  )
  and any(.products[];
    .id == "api_discovery"
    and .result.status == "COMPLETE"
    and .result.evidence_type == "DIRECT"
    and .result.count == 0
    and .count == 0
    and .result.configuration.evidence_type == "INFORMATIONAL"
  )
  and all(.products[] | select(.id == "bot_management" or .id == "ddos_protection") | .services[]?;
    .configuration_status == "NOT_REQUESTED"
    and .configuration_evidence_type == "UNKNOWN"
    and .configuration_source == null
    and .configuration_requested == false
    and .configuration == null
  )
  and all(.products[] | select(.id == "bot_management" or .id == "ddos_protection");
    .result.configuration.status == "NOT_REQUESTED"
    and .result.configuration.evidence_type == "UNKNOWN"
    and .result.configuration.requested == false
  )
  and (.products[] | select(.id == "ngwaf") | .services | length) == 2
  and any(.products[];
    .id == "ngwaf"
    and .result.status == "COMPLETE"
    and .result.count == 2
    and .result.services_checked == 2
    and .result.disabled_count == 0
    and .result.rejected_count == 1
    and .result.rejected_service_ids == ["other-service"]
    and .result.duplicate_returned_count == 1
    and .result.duplicate_returned_service_ids == ["service-2"]
  )
  and any(.products[]; .id == "ngwaf" and any(.services[]; .id == "service-1" and .configuration.workspace_id == "production"))
  and .ngwaf.service_attachment_count == 2
  and .ngwaf.workspace_count == 2
  and (.ngwaf.attachments | length) == 2
  and any(.ngwaf.attachments[];
    .service_id == "service-1"
    and .workspace_id == "production"
    and .traffic_ramp == 100
    and .workspace.name == "Production"
    and .workspace.mode == "block"
    and (.anomalies | length) == 0
  )
  and any(.ngwaf.attachments[];
    .service_id == "service-2"
    and .workspace_id == "production-compute"
    and .traffic_ramp == 100
    and .workspace.name == "Production Compute"
    and .workspace.default_blocking_response_code == 403
    and (.anomalies | length) == 0
  )
  and any(.ngwaf.workspaces[]; .id == "production" and .attachment_count == 1)
  and any(.ngwaf.workspaces[]; .id == "production-compute" and .attachment_count == 1)
  and (.ngwaf.anomalies.multiple_attachments_per_service | length) == 1
  and .ngwaf.anomalies.multiple_attachments_per_service[0].service_id == "service-2"
  and .ngwaf.anomaly_count == 1
  and .inventory_sections.service_inventory.status == "COMPLETE"
  and .inventory_sections.service_inventory.evidence_type == "DIRECT"
  and .inventory_sections.service_inventory.count == 2
  and .inventory_sections.service_inventory.source == "GET /service"
  and (.inventory_sections.service_inventory.retrieved_at | test("^20[0-9]{2}-[0-9]{2}-[0-9]{2}T"))
  and .inventory_sections.service_inventory.pagination.truncated == false
  and .inventory_sections.service_inventory.fallback_used == false
  and .inventory_sections.product_attachments.status == "COMPLETE"
  and .inventory_sections.product_attachments.evidence_type == "DERIVED"
  and (.inventory_sections.product_attachments.derived_from | index("products[].result") != null)
  and .inventory_sections.product_attachments.count == 6
  and .inventory_sections.product_attachments.source == "GET /enabled-products/v1/{product_id}/services"
  and (.inventory_sections.product_attachments.products | length) == 4
  and all(.inventory_sections.product_attachments.products[]; (.retrieved_at | test("^20[0-9]{2}-[0-9]{2}-[0-9]{2}T")))
  and all(.inventory_sections.product_attachments.products[]; .evidence_type == "DIRECT")
  and .inventory_sections.edge_waf_service_attachments.status == "COMPLETE"
  and .inventory_sections.edge_waf_service_attachments.evidence_type == "DIRECT"
  and .inventory_sections.edge_waf_service_attachments.count == 2
  and .inventory_sections.edge_waf_service_attachments.source == "GET /enabled-products/v1/ngwaf/services"
  and .inventory_sections.ngwaf_service_attachments.status == "COMPLETE"
  and .inventory_sections.ngwaf_service_attachments.evidence_type == "DIRECT"
  and .inventory_sections.ngwaf_service_attachments.count == 2
  and .inventory_sections.ngwaf_service_attachments.source == "GET /enabled-products/v1/ngwaf/services"
  and .inventory_sections.ngwaf_workspaces.status == "COMPLETE"
  and .inventory_sections.ngwaf_workspaces.evidence_type == "DIRECT"
  and .inventory_sections.ngwaf_workspaces.count == 2
  and .inventory_sections.ngwaf_workspaces.source == "GET /ngwaf/v1/workspaces"
  and .inventory_sections.ngwaf_workspaces.pagination.pages_fetched == 1
  and all(.products[].services[]?; .customer_id == "test-customer")
  and all(.products[].services[]?; .id != "other-service")
  and .provenance.product_enablement.missing_data_policy == "unknown_not_disabled"
  and (.limitations | length) == 7
  and .reconciliation.status == "WARN"
  and .reconciliation.evidence_type == "DERIVED"
  and (.reconciliation.derived_from | index("inventory_sections.product_attachments") != null)
  and .reconciliation.finding_count > 0
  and any(.reconciliation.findings[];
    .type == "rejected_service_id"
    and .product_id == "bot_management"
    and .service_id == "other-service"
  )
  and any(.reconciliation.findings[];
    .type == "duplicate_service_mapping"
    and .product_id == "ddos_protection"
    and .service_id == "service-2"
  )
' >/dev/null <<<"$output"
grep -F 'fastly-audit: customer scope:' "$TEST_TMP/stderr" >/dev/null
! grep -F '/events' "$FASTLY_TEST_SECURITY_CURL_ARGS" >/dev/null
! grep -E '/enabled-products/v1/bot_management/services/[^[:space:]]+/configuration' "$FASTLY_TEST_SECURITY_CURL_ARGS" >/dev/null
! grep -E '/enabled-products/v1/ddos_protection/services/[^[:space:]]+/configuration' "$FASTLY_TEST_SECURITY_CURL_ARGS" >/dev/null
grep -E '/enabled-products/v1/ngwaf/services/[^[:space:]]+/configuration' "$FASTLY_TEST_SECURITY_CURL_ARGS" >/dev/null
scope_count="$(grep -c '^customer_id=test-customer$' "$FASTLY_TEST_SECURITY_CURL_ARGS")"
(( scope_count >= 5 )) || {
  printf 'security test: expected customer_id on all four product lists and the workspace list; found %s\n' "$scope_count" >&2
  exit 1
}

$ROOT/fastly-audit security summary >"$TEST_TMP/human" 2>"$TEST_TMP/human-err"
grep -F 'Security product summary' "$TEST_TMP/human" >/dev/null
grep -F 'Token-visible customer services: 2' "$TEST_TMP/human" >/dev/null
grep -F 'Configuration detail: 2 retrieved, 0 unavailable, 4 not requested' "$TEST_TMP/human" >/dev/null
grep -F 'Service inventory source: GET /service' "$TEST_TMP/human" >/dev/null
grep -F 'Inventory provenance' "$TEST_TMP/human" >/dev/null
grep -F 'EVIDENCE' "$TEST_TMP/human" >/dev/null
grep -F 'Service inventory' "$TEST_TMP/human" | grep -F 'DIRECT' >/dev/null
grep -F 'Product attachments' "$TEST_TMP/human" | grep -F 'DERIVED' >/dev/null
grep -F 'Service inventory' "$TEST_TMP/human" | grep -F '2' | grep -F 'COMPLETE' | grep -F 'GET /service' >/dev/null
grep -F 'Product attachments' "$TEST_TMP/human" | grep -F '6' | grep -F 'COMPLETE' | grep -F 'GET /enabled-products/v1/{product_id}/services' >/dev/null
grep -F 'Edge WAF service attachments: 2' "$TEST_TMP/human" >/dev/null
grep -F 'Reconciliation: WARN' "$TEST_TMP/human" >/dev/null
grep -F 'Reconciliation findings' "$TEST_TMP/human" >/dev/null
grep -F 'DDoS Protection' "$TEST_TMP/human" >/dev/null
grep -F 'Edge WAF service attachments' "$TEST_TMP/human" | grep -F '2/2' | grep -F 'COMPLETE' >/dev/null
grep -F 'www.example.com' "$TEST_TMP/human" | grep -F 'Production' | grep -F '100%' | grep -F 'block' >/dev/null
grep -F 'DEFAULT BLOCK RESPONSE' "$TEST_TMP/human" >/dev/null
grep -F 'configuration not requested' "$TEST_TMP/human" >/dev/null
! grep -F 'contentguard=on' "$TEST_TMP/human" >/dev/null
! grep -F 'mode=block' "$TEST_TMP/human" >/dev/null
grep -F 'Enabled means the product is attached' "$TEST_TMP/human" >/dev/null

: >"$FASTLY_TEST_SECURITY_CURL_ARGS"
detailed="$($ROOT/fastly-audit security summary --detailed --json 2>"$TEST_TMP/detailed-err")"
jq -e '
  .mode == "detailed"
  and .detailed == true
  and .summary.configuration_summary.status == "COMPLETE"
  and .summary.configuration_summary.mapping_count == 6
  and .summary.configuration_summary.requested_count == 6
  and .summary.configuration_summary.retrieved_count == 6
  and .summary.configuration_summary.unavailable_count == 0
  and .summary.configuration_summary.not_requested_count == 0
  and any(.products[];
    .id == "bot_management"
    and .result.count == 2
    and .result.configuration.status == "COMPLETE"
    and .result.configuration.evidence_type == "DIRECT"
    and (.result.configuration.source | contains("/configuration"))
    and .result.configuration.requested == true
    and any(.services[];
      .configuration.contentguard == "on"
      and .configuration_status == "RETRIEVED"
      and .configuration_evidence_type == "DIRECT"
      and (.configuration_source | contains("/configuration"))
    )
  )
  and any(.products[];
    .id == "ddos_protection"
    and .result.count == 2
    and .result.configuration.status == "COMPLETE"
    and .result.configuration.evidence_type == "DIRECT"
    and (.result.configuration.source | contains("/configuration"))
    and .result.configuration.requested == true
    and any(.services[];
      .configuration.mode == "block"
      and .configuration_status == "RETRIEVED"
      and .configuration_evidence_type == "DIRECT"
      and (.configuration_source | contains("/configuration"))
    )
  )
  and .summary.edge_waf_service_attachments == 2
  and .summary.ngwaf_workspaces == 2
  and .reconciliation.status == "WARN"
  and ([.reconciliation.findings[] | select(.type == "rejected_service_id" or .type == "duplicate_service_mapping")] | length) > 0
' >/dev/null <<<"$detailed"
grep -E '/enabled-products/v1/bot_management/services/[^[:space:]]+/configuration' "$FASTLY_TEST_SECURITY_CURL_ARGS" >/dev/null
grep -E '/enabled-products/v1/ddos_protection/services/[^[:space:]]+/configuration' "$FASTLY_TEST_SECURITY_CURL_ARGS" >/dev/null
$ROOT/fastly-audit security summary --detailed >"$TEST_TMP/detailed-human" 2>"$TEST_TMP/detailed-human-err"
grep -F 'contentguard=on' "$TEST_TMP/detailed-human" >/dev/null
grep -F 'mode=block' "$TEST_TMP/detailed-human" >/dev/null

export FASTLY_TEST_SECURITY_MODE=detailed-ddos-config-503
detailed_config_fail="$($ROOT/fastly-audit security summary --detailed --json 2>"$TEST_TMP/detailed-config-fail-err")"
jq -e '
  any(.products[];
    .id == "ddos_protection"
    and .result.status == "COMPLETE"
    and .result.count == 2
    and .enabled_count == 2
    and .result.configuration.status == "PARTIAL"
    and .result.configuration.evidence_type == "UNKNOWN"
    and .result.configuration.unavailable_count == 1
    and .result.configuration.retrieved_count == 1
    and any(.services[];
      .id == "service-2"
      and .configuration_status == "UNAVAILABLE"
      and .configuration_evidence_type == "UNKNOWN"
      and .configuration_http_status == "503"
    )
  )
  and .summary.configuration_summary.status == "PARTIAL"
  and .summary.configuration_summary.requested_count == 6
  and .summary.configuration_summary.retrieved_count == 5
  and .summary.configuration_summary.unavailable_count == 1
  and .summary.known_unavailable_configurations == 1
  and .summary.unavailable_configurations == 1
' >/dev/null <<<"$detailed_config_fail"
export FASTLY_TEST_SECURITY_MODE=ok

export FASTLY_TEST_SECURITY_MODE=reconciliation-clean
clean_reconciliation="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/reconciliation-clean-err")"
jq -e '
  .reconciliation.status == "PASS"
  and .reconciliation.evidence_type == "DERIVED"
  and .reconciliation.finding_count == 0
  and (.reconciliation.findings | length) == 0
  and any(.products[]; .id == "api_discovery" and .result.status == "COMPLETE" and .result.count == 0)
  and .summary.service_product_mappings == ([.products[] | (.services | length)] | add)
' >/dev/null <<<"$clean_reconciliation"
$ROOT/fastly-audit security summary >"$TEST_TMP/reconciliation-clean-human" 2>"$TEST_TMP/reconciliation-clean-human-err"
grep -F 'Reconciliation: PASS (0 finding(s))' "$TEST_TMP/reconciliation-clean-human" >/dev/null
! grep -F 'Reconciliation findings' "$TEST_TMP/reconciliation-clean-human" >/dev/null
export FASTLY_TEST_SECURITY_MODE=ok

missing_expected_product="$(
  (
    service_product_specs() {
      cat <<'EOF'
api_discovery	API Discovery	none	security
bot_management	Bot Management	bot_management	security
ddos_protection	DDoS Protection	ddos_protection	security
EOF
    }
    cmd_security_summary --json
  ) 2>"$TEST_TMP/missing-product-err"
)"
jq -e '
  .reconciliation.status == "UNKNOWN"
  and .reconciliation.evidence_type == "DERIVED"
  and any(.reconciliation.findings[];
    .type == "missing_product_result"
    and .product_id == "ngwaf"
  )
' >/dev/null <<<"$missing_expected_product"

count_mismatch="$(
  (
    collect_security_products_json() {
      local services_body="$1" config_mode="${2:-summary}"
      local tmp request_config
      tmp="$(mktemp)"
      request_config=true
      [[ "$config_mode" != "detailed" ]] && request_config=false
      discover_product_json api_discovery "API Discovery" none security "$services_body" true >>"$tmp"
      discover_product_json bot_management "Bot Management" bot_management security "$services_body" "$request_config" >>"$tmp"
      discover_product_json ddos_protection "DDoS Protection" ddos_protection security "$services_body" "$request_config" >>"$tmp"
      discover_product_json ngwaf "Edge WAF service attachments" ngwaf security "$services_body" true >>"$tmp"
      jq -s '
        map(
          if .id == "bot_management" then
            .count = 99
            | .enabled_count = 99
            | .result.count = 99
            | .result.enabled_count = 99
          else .
          end
        )
      ' "$tmp"
      rm -f "$tmp"
    }
    cmd_security_summary --json
  ) 2>"$TEST_TMP/count-mismatch-err"
)"
jq -e '
  .reconciliation.status == "FAIL"
  and any(.reconciliation.findings[];
    .type == "product_count_mismatch"
    and .product_id == "bot_management"
  )
  and any(.reconciliation.findings[];
    .type == "aggregate_mapping_count_mismatch"
  )
' >/dev/null <<<"$count_mismatch"

export FASTLY_TEST_SECURITY_MODE=observed-products
: >"$FASTLY_TEST_SECURITY_CURL_ARGS"
observed_products="$($ROOT/fastly-audit products --json 2>"$TEST_TMP/observed-products-err")"
jq -e '
  .services_scanned == 2
  and .service_discovery.discovery_method == "fastly-service-inventory"
  and .service_discovery.source == "GET /service"
  and .service_discovery.status == "COMPLETE"
  and .service_discovery.evidence_type == "DIRECT"
  and any(.products[];
    .id == "bot_management"
    and .result.status == "COMPLETE"
    and .result.count == 2
    and (.services | length) == 2
  )
  and any(.products[];
    .id == "ddos_protection"
    and .result.status == "COMPLETE"
    and .result.count == 2
    and (.services | length) == 2
  )
' >/dev/null <<<"$observed_products"
! grep -F '/events' "$FASTLY_TEST_SECURITY_CURL_ARGS" >/dev/null

export FASTLY_TEST_SECURITY_MODE=product-data-object-shape
data_shape="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-data-object-shape-err")"
jq -e '
  any(.products[];
    .id == "bot_management"
    and .result.status == "COMPLETE"
    and .result.count == 2
    and (.services | length) == 2
  )
' >/dev/null <<<"$data_shape"

export FASTLY_TEST_SECURITY_MODE=product-services-object-shape
services_object_shape="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-services-object-shape-err")"
jq -e '
  any(.products[];
    .id == "ddos_protection"
    and .result.status == "COMPLETE"
    and .result.count == 2
    and (.services | length) == 2
  )
' >/dev/null <<<"$services_object_shape"

export FASTLY_TEST_SECURITY_MODE=active-version-matrix
active_version_matrix="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/active-version-matrix-err")"
jq -e '
  (.products[] | select(.id == "bot_management") | .result.status) == "COMPLETE"
  and (.products[] | select(.id == "bot_management") | .result.count) == 7
  and any(.products[] | select(.id == "bot_management") | .services[];
    .id == "service-env-absent" and .active_version == 11
  )
  and any(.products[] | select(.id == "bot_management") | .services[];
    .id == "service-env-null" and .active_version == 12
  )
  and any(.products[] | select(.id == "bot_management") | .services[];
    .id == "service-env-empty" and .active_version == 13
  )
  and any(.products[] | select(.id == "bot_management") | .services[];
    .id == "service-env-production" and .active_version == 141
  )
  and any(.products[] | select(.id == "bot_management") | .services[];
    .id == "service-active-object" and .active_version == 15
  )
  and any(.products[] | select(.id == "bot_management") | .services[];
    .id == "service-active-scalar" and .active_version == 16
  )
  and any(.products[] | select(.id == "bot_management") | .services[];
    .id == "service-version-only" and .active_version == 17
  )
' >/dev/null <<<"$active_version_matrix"
! grep -F 'Cannot iterate over null' "$TEST_TMP/active-version-matrix-err" >/dev/null

export FASTLY_TEST_SECURITY_MODE=product-null-services
null_services="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-null-services-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.count == null
    and .result.count_lower_bound == null
    and (.result.reason | contains("services field is present but is not an array"))
    and (.services | length) == 0
  )
' >/dev/null <<<"$null_services"

export FASTLY_TEST_SECURITY_MODE=product-missing-collection
missing_collection="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-missing-collection-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.count == null
    and (.result.reason | contains("missing services or data collection"))
  )
' >/dev/null <<<"$missing_collection"

export FASTLY_TEST_SECURITY_MODE=product-malformed-json
malformed_product_json="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-malformed-json-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.count == null
    and (.result.reason | contains("not valid JSON"))
  )
' >/dev/null <<<"$malformed_product_json"

export FASTLY_TEST_SECURITY_MODE=ok

export FASTLY_TEST_SECURITY_MODE=ngwaf-same-workspace
same_workspace="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/ngwaf-same-workspace-err")"
jq -e '
  .ngwaf.service_attachment_count == 2
  and (.ngwaf.anomalies.multiple_services_per_workspace | length) == 1
  and .ngwaf.anomalies.multiple_services_per_workspace[0].workspace_id == "production"
  and ((.ngwaf.anomalies.workspace_without_attachment // []) | length) == 0
  and .ngwaf.informational.evidence_type == "INFORMATIONAL"
  and (.ngwaf.informational.derived_from | index("ngwaf.workspaces") != null)
  and (.ngwaf.informational.workspace_without_edge_waf_attachment | length) == 1
  and .ngwaf.informational.workspace_without_edge_waf_attachment[0].workspace_id == "production-compute"
' >/dev/null <<<"$same_workspace"

export FASTLY_TEST_SECURITY_MODE=ngwaf-workspace-without-attachment
unused_workspace="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/ngwaf-unused-workspace-err")"
jq -e '
  .ngwaf.workspace_count == 3
  and ((.ngwaf.anomalies.workspace_without_attachment // []) | length) == 0
  and .ngwaf.informational.evidence_type == "INFORMATIONAL"
  and (.ngwaf.informational.workspace_without_edge_waf_attachment | length) == 1
  and .ngwaf.informational.workspace_without_edge_waf_attachment[0].workspace_id == "unused"
' >/dev/null <<<"$unused_workspace"

export FASTLY_TEST_SECURITY_MODE=ngwaf-missing-workspace
missing_workspace="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/ngwaf-missing-workspace-err")"
jq -e '
  any(.ngwaf.attachments[];
    .service_id == "service-2"
    and .workspace_id == "production-compute"
    and (.anomalies | index("workspace_not_found") != null)
  )
  and (.ngwaf.anomalies.workspace_not_found | length) == 1
  and .ngwaf.anomalies.workspace_not_found[0].service_id == "service-2"
  and .reconciliation.status == "FAIL"
  and any(.reconciliation.findings[];
    .type == "workspace_not_found"
    and .product_id == "ngwaf"
    and .service_id == "service-2"
    and .workspace_id == "production-compute"
  )
' >/dev/null <<<"$missing_workspace"

export FASTLY_TEST_SECURITY_MODE=ngwaf-ramp-below-100
low_ramp="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/ngwaf-low-ramp-err")"
jq -e '
  any(.ngwaf.attachments[];
    .service_id == "service-2"
    and .traffic_ramp == 50
    and (.anomalies | index("traffic_ramp_below_100") != null)
  )
  and (.ngwaf.anomalies.traffic_ramp_below_100 | length) == 1
' >/dev/null <<<"$low_ramp"

export FASTLY_TEST_SECURITY_MODE=ngwaf-missing-ramp
missing_ramp="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/ngwaf-missing-ramp-err")"
jq -e '
  any(.ngwaf.attachments[];
    .service_id == "service-2"
    and .traffic_ramp == null
    and (.anomalies | index("missing_or_invalid_traffic_ramp") != null)
  )
  and (.ngwaf.anomalies.missing_or_invalid_traffic_ramp | length) == 1
' >/dev/null <<<"$missing_ramp"

export FASTLY_TEST_SECURITY_MODE=ngwaf-invalid-ramp
invalid_ramp="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/ngwaf-invalid-ramp-err")"
jq -e '
  any(.ngwaf.attachments[];
    .service_id == "service-2"
    and .traffic_ramp == null
    and .traffic_ramp_raw == "fast"
    and (.anomalies | index("missing_or_invalid_traffic_ramp") != null)
  )
' >/dev/null <<<"$invalid_ramp"

export FASTLY_TEST_SECURITY_MODE=ngwaf-missing-workspace-id
missing_workspace_id="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/ngwaf-missing-workspace-id-err")"
jq -e '
  any(.ngwaf.attachments[];
    .service_id == "service-2"
    and .workspace_id == null
    and (.anomalies | index("missing_workspace_id") != null)
  )
  and (.ngwaf.anomalies.missing_workspace_id | length) == 1
' >/dev/null <<<"$missing_workspace_id"

export FASTLY_TEST_SECURITY_MODE=ngwaf-product-503
ngwaf_product_fail="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/ngwaf-product-503-err")"
jq -e '
  .summary.ngwaf_service_attachment_status == "UNKNOWN"
  and .summary.ngwaf_service_attachments == null
  and .summary.edge_waf_service_attachment_status == "UNKNOWN"
  and .summary.edge_waf_service_attachments == null
  and .summary.ngwaf_workspaces == 2
  and .ngwaf.service_attachment_result.status == "UNKNOWN"
  and .ngwaf.service_attachment_result.evidence_type == "UNKNOWN"
  and .ngwaf.edge_waf_service_attachment_result.status == "UNKNOWN"
  and .ngwaf.edge_waf_service_attachment_result.evidence_type == "UNKNOWN"
  and .inventory_sections.edge_waf_service_attachments.status == "UNKNOWN"
  and .inventory_sections.edge_waf_service_attachments.evidence_type == "UNKNOWN"
  and .inventory_sections.edge_waf_service_attachments.count == null
  and .ngwaf.reconciliation_status == "UNAVAILABLE"
  and .ngwaf.service_attachment_count == null
  and (.ngwaf.attachments | length) == 0
  and ((.ngwaf.anomalies.workspace_without_attachment // []) | length) == 0
  and .ngwaf.informational.evidence_type == "INFORMATIONAL"
  and (.ngwaf.informational.workspace_without_edge_waf_attachment | length) == 0
  and .ngwaf.anomaly_count == 0
' >/dev/null <<<"$ngwaf_product_fail"

export FASTLY_TEST_SECURITY_MODE=ngwaf-zero-edge-waf-64-workspaces
: >"$FASTLY_TEST_SECURITY_CURL_ARGS"
zero_edge_waf="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/ngwaf-zero-edge-waf-64-workspaces-err")"
jq -e '
  .summary.edge_waf_service_attachment_status == "COMPLETE"
  and .summary.edge_waf_service_attachments == 0
  and .summary.ngwaf_service_attachments == 0
  and .summary.ngwaf_workspaces == 64
  and .inventory_sections.edge_waf_service_attachments.status == "COMPLETE"
  and .inventory_sections.edge_waf_service_attachments.evidence_type == "DIRECT"
  and .inventory_sections.edge_waf_service_attachments.count == 0
  and (.products[] | select(.id == "ngwaf") | .result.configuration.status) == "NOT_APPLICABLE"
  and (.products[] | select(.id == "ngwaf") | .result.configuration.requested) == false
  and (.products[] | select(.id == "ngwaf") | .result.configuration.source) == null
  and (.products[] | select(.id == "ngwaf") | .result.configuration.evidence_type) == "INFORMATIONAL"
  and .inventory_sections.ngwaf_workspaces.status == "COMPLETE"
  and .inventory_sections.ngwaf_workspaces.evidence_type == "DIRECT"
  and .inventory_sections.ngwaf_workspaces.count == 64
  and .ngwaf.edge_waf_service_attachment_count == 0
  and .ngwaf.workspace_count == 64
  and (.ngwaf.attachments | length) == 0
  and ((.ngwaf.anomalies.workspace_without_attachment // []) | length) == 0
  and .ngwaf.informational.evidence_type == "INFORMATIONAL"
  and (.ngwaf.informational.workspace_without_edge_waf_attachment | length) == 64
  and .ngwaf.anomaly_count == 0
  and .reconciliation.status == "PASS"
  and .reconciliation.finding_count == 0
' >/dev/null <<<"$zero_edge_waf"
! grep -E '/enabled-products/v1/ngwaf/services/[^[:space:]]+/configuration' "$FASTLY_TEST_SECURITY_CURL_ARGS" >/dev/null
$ROOT/fastly-audit security summary >"$TEST_TMP/ngwaf-zero-edge-waf-human" 2>"$TEST_TMP/ngwaf-zero-edge-waf-human-err"
grep -F 'Edge WAF service attachments: 0' "$TEST_TMP/ngwaf-zero-edge-waf-human" >/dev/null
grep -F 'NGWAF workspaces: 64' "$TEST_TMP/ngwaf-zero-edge-waf-human" >/dev/null
! grep -F 'workspace_without_attachment' "$TEST_TMP/ngwaf-zero-edge-waf-human" >/dev/null

export FASTLY_TEST_SECURITY_MODE=ngwaf-workspace-api-error
if $ROOT/fastly-audit security summary --json >"$TEST_TMP/ngwaf-workspace-api-error-out" 2>"$TEST_TMP/ngwaf-workspace-api-error-err"; then
  printf 'security test: NGWAF workspace API error unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'GET /ngwaf/v1/workspaces' "$TEST_TMP/ngwaf-workspace-api-error-err" >/dev/null

export FASTLY_TEST_SECURITY_MODE=ok

export FASTLY_TEST_SECURITY_MODE=unknown-ddos
unknown="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/unknown-err")"
jq -e '
  .summary.unknown_enablement_checks == 1
  and .summary.product_inventory_status == "PARTIAL"
  and .summary.service_product_mappings == null
  and .summary.service_product_mappings_lower_bound == 4
  and any(.products[];
    .id == "ddos_protection"
    and .result.status == "PARTIAL"
    and .result.evidence_type == "DIRECT"
    and .enabled_count == 0
    and .unknown_check_count == 1
    and .unknown_checks[0].http_status == "503"
  )
' >/dev/null <<<"$unknown"

export FASTLY_TEST_SECURITY_MODE=empty-service-inventory
empty="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/empty-err")"
jq -e '
  .summary.token_visible_customer_services == 0
  and .summary.service_product_mappings == 0
  and .summary.configuration_summary.status == "NOT_APPLICABLE"
  and .summary.configuration_summary.mapping_count == 0
  and .summary.configuration_summary.requested_count == 0
  and .summary.configuration_summary.not_requested_count == 0
  and all(.products[] | select(.id == "bot_management" or .id == "ddos_protection" or .id == "ngwaf");
    .result.configuration.status == "NOT_APPLICABLE"
    and .result.configuration.requested == false
    and .result.configuration.source == null
    and .result.configuration.evidence_type == "INFORMATIONAL"
  )
  and .inventory_sections.service_inventory.evidence_type == "DIRECT"
  and .inventory_sections.service_inventory.count == 0
  and all(.products[]; .enabled_count == 0)
' >/dev/null <<<"$empty"

export FASTLY_TEST_SECURITY_MODE=product-401
product_401="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-401-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.count == null
    and .result.http_statuses == ["401"]
  )
' >/dev/null <<<"$product_401"

export FASTLY_TEST_SECURITY_MODE=product-403
product_403="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-403-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.count == null
    and .result.http_statuses == ["403"]
  )
' >/dev/null <<<"$product_403"

export FASTLY_TEST_SECURITY_MODE=product-list-404
product_404="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-404-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "COMPLETE"
    and .result.evidence_type == "DIRECT"
    and .result.source == "per-service-probe"
    and .result.fallback_used == true
    and .result.count == 0
    and (.result.reason | contains("HTTP 404"))
  )
  and .inventory_sections.product_attachments.status == "COMPLETE"
  and .inventory_sections.product_attachments.fallback_used == true
' >/dev/null <<<"$product_404"
$ROOT/fastly-audit security summary >"$TEST_TMP/product-404-human" 2>"$TEST_TMP/product-404-human-err"
grep -F 'Product attachments' "$TEST_TMP/product-404-human" | grep -F 'fallback used' >/dev/null

export FASTLY_TEST_SECURITY_MODE=product-429
product_429="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-429-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.http_statuses == ["429"]
  )
' >/dev/null <<<"$product_429"

export FASTLY_TEST_SECURITY_MODE=product-500
product_500="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-500-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.http_statuses == ["500"]
  )
' >/dev/null <<<"$product_500"

export FASTLY_TEST_SECURITY_MODE=product-503
product_503="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-503-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.http_statuses == ["503"]
  )
' >/dev/null <<<"$product_503"
$ROOT/fastly-audit security summary >"$TEST_TMP/product-503-human" 2>"$TEST_TMP/product-503-human-err"
grep -F 'API Discovery' "$TEST_TMP/product-503-human" | grep -F 'UNKNOWN' | grep -F 'HTTP 503' >/dev/null

export FASTLY_TEST_SECURITY_MODE=product-timeout
product_timeout="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-timeout-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.http_statuses == ["000"]
  )
' >/dev/null <<<"$product_timeout"

export FASTLY_TEST_SECURITY_MODE=product-invalid-json
product_invalid="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-invalid-err")"
jq -e '
  any(.products[];
    .id == "api_discovery"
    and .result.status == "UNKNOWN"
    and .result.evidence_type == "UNKNOWN"
    and .result.count == null
    and .result.count_lower_bound == null
    and (.result.reason | contains("services field is present but is not an array"))
    and .result.http_statuses == ["parse_error"]
  )
' >/dev/null <<<"$product_invalid"

export FASTLY_TEST_SECURITY_MODE=product-partial-fallback
product_partial="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/product-partial-err")"
jq -e '
  .summary.product_inventory_status == "PARTIAL"
  and .summary.service_product_mappings == null
  and .inventory_sections.product_attachments.status == "PARTIAL"
  and .inventory_sections.product_attachments.evidence_type == "DERIVED"
  and .inventory_sections.product_attachments.count == null
  and .inventory_sections.product_attachments.count_lower_bound == 7
  and any(.products[];
    .id == "api_discovery"
    and .result.status == "PARTIAL"
    and .result.evidence_type == "DIRECT"
    and .result.count == null
    and .result.count_lower_bound == 1
    and .enabled_count == 1
    and .result.http_statuses == ["503"]
    and (.result.reason | contains("fallback reason: customer-list returned HTTP 503"))
  )
' >/dev/null <<<"$product_partial"
$ROOT/fastly-audit security summary >"$TEST_TMP/product-partial-human" 2>"$TEST_TMP/product-partial-human-err"
grep -F 'API Discovery' "$TEST_TMP/product-partial-human" | grep -F '>=1' | grep -F 'PARTIAL' >/dev/null
grep -F 'Product attachments' "$TEST_TMP/product-partial-human" | grep -F '>=7' | grep -F 'PARTIAL' >/dev/null

export FASTLY_TEST_SECURITY_MODE=all-products-503
all_products_unknown="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/all-products-503-err")"
jq -e '
  .summary.product_inventory_status == "UNKNOWN"
  and .summary.service_product_mappings == null
  and .summary.service_product_mappings_lower_bound == null
  and .inventory_sections.product_attachments.status == "UNKNOWN"
  and .inventory_sections.product_attachments.evidence_type == "DERIVED"
  and .inventory_sections.product_attachments.count == null
  and .inventory_sections.product_attachments.count_lower_bound == null
  and all(.products[]; .result.status == "UNKNOWN" and .result.evidence_type == "UNKNOWN" and .result.count == null)
' >/dev/null <<<"$all_products_unknown"
$ROOT/fastly-audit security summary >"$TEST_TMP/all-products-503-human" 2>"$TEST_TMP/all-products-503-human-err"
grep -F 'Product attachments' "$TEST_TMP/all-products-503-human" | grep -F 'UNKNOWN' | grep -F 'all product attachment inventories unknown' >/dev/null

export FASTLY_TEST_SECURITY_MODE=service-truncated
service_truncated="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/service-truncated-err")"
jq -e '
  .summary.service_inventory_status == "PARTIAL"
  and .summary.token_visible_customer_services == null
  and .summary.token_visible_customer_services_lower_bound == 2
  and .summary.product_inventory_status == "PARTIAL"
  and .inventory_sections.service_inventory.status == "PARTIAL"
  and .inventory_sections.service_inventory.evidence_type == "DIRECT"
  and .inventory_sections.service_inventory.count == null
  and .inventory_sections.service_inventory.count_lower_bound == 2
  and .inventory_sections.service_inventory.pagination.truncated == true
  and .provenance.service_discovery.result.status == "PARTIAL"
  and .provenance.service_discovery.result.evidence_type == "DIRECT"
  and (.provenance.service_discovery.result.reason | contains("PARTIAL"))
' >/dev/null <<<"$service_truncated"
$ROOT/fastly-audit security summary >"$TEST_TMP/service-truncated-human" 2>"$TEST_TMP/service-truncated-human-err"
grep -F 'Service inventory' "$TEST_TMP/service-truncated-human" | grep -F '>=2' | grep -F 'PARTIAL' >/dev/null

export FASTLY_TEST_SECURITY_MODE=service-api-error
if $ROOT/fastly-audit security summary --json >"$TEST_TMP/service-api-error-out" 2>"$TEST_TMP/service-api-error-err"; then
  printf 'security test: service inventory API error unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'Service inventory unavailable: GET /service returned HTTP 503; not falling back to audit-event inventory.' "$TEST_TMP/service-api-error-err" >/dev/null
grep -F 'service inventory unavailable; security summary cannot safely use audit-event-derived service counts as a substitute' "$TEST_TMP/service-api-error-err" >/dev/null

export FASTLY_TEST_SECURITY_MODE=service-invalid-json
if $ROOT/fastly-audit security summary --json >"$TEST_TMP/service-invalid-json-out" 2>"$TEST_TMP/service-invalid-json-err"; then
  printf 'security test: invalid service inventory JSON unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'Service inventory unavailable: GET /service returned invalid JSON shape' "$TEST_TMP/service-invalid-json-err" >/dev/null

export FASTLY_TEST_SECURITY_MODE=audit-events-fail
: >"$FASTLY_TEST_SECURITY_CURL_ARGS"
audit_fail="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/audit-events-fail-err")"
jq -e '.summary.token_visible_customer_services == 2' >/dev/null <<<"$audit_fail"
! grep -F '/events' "$FASTLY_TEST_SECURITY_CURL_ARGS" >/dev/null

export FASTLY_TEST_SECURITY_MODE=audit-page-cap
: >"$FASTLY_TEST_SECURITY_CURL_ARGS"
audit_page_cap="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/audit-page-cap-err")"
jq -e '.summary.token_visible_customer_services == 2' >/dev/null <<<"$audit_page_cap"
! grep -F 'activation_scan_truncated' <<<"$audit_page_cap" >/dev/null
! grep -F '/events' "$FASTLY_TEST_SECURITY_CURL_ARGS" >/dev/null

export FASTLY_TEST_SECURITY_MODE=customer-mismatch
if $ROOT/fastly-audit security summary --json >"$TEST_TMP/customer-mismatch-out" 2>"$TEST_TMP/customer-mismatch-err"; then
  printf 'security test: customer mismatch unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'customer-scope validation mismatch' "$TEST_TMP/customer-mismatch-err" >/dev/null

if $ROOT/fastly-audit security nope >"$TEST_TMP/out" 2>"$TEST_TMP/error"; then
  printf 'security test: unknown command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'unknown security command: nope' "$TEST_TMP/error" >/dev/null

printf 'security: OK\n'
