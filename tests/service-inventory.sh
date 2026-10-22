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
if [[ -n "${FASTLY_TEST_SERVICE_INVENTORY_CURL_ARGS:-}" ]]; then
  printf '%s\n' "$@" >>"$FASTLY_TEST_SERVICE_INVENTORY_CURL_ARGS"
fi
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

status=200
mode="${FASTLY_TEST_SERVICE_INVENTORY_MODE:-ok}"
case "$url" in
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    ;;
  */service)
    case "$mode" in
      service-api-error)
        printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
        status=503
        ;;
      service-malformed)
        printf '%s\n' '{"services":[{"id":"service-1"}]}' >"$outfile"
        ;;
      *)
        printf '%s\n' '{
          "meta":{"total":4},
          "data":[
            {"id":"service-1","name":"www.example.com","customer_id":"test-customer","type":"vcl","active_version":7,"paused":false},
            {"id":"service-2","name":"api.example.com","customer_id":"test-customer","type":"wasm","active_version":{"number":3},"paused":false},
            {"id":"service-3","name":"new.example.com","customer_id":"test-customer","type":"vcl","environments":[{"name":"production","active_version":12}],"paused":true},
            {"id":"other-service","name":"other.example.com","customer_id":"other-customer","type":"vcl","active_version":1,"paused":false}
          ]
        }' >"$outfile"
        ;;
    esac
    ;;
  */events)
    printf '%s\n' '{"errors":[{"title":"Audit events should not be used for service inventory"}]}' >"$outfile"
    status=503
    ;;
  */service/*)
    printf '%s\n' '{"error":"per-service lookup should not be used"}' >"$outfile"
    status=599
    ;;
  */enabled-products/v1/bot_management/services)
    printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-3","other-service"]}' >"$outfile"
    ;;
  */enabled-products/v1/bot_management/services/service-3/configuration)
    printf '%s\n' '{"configuration":{"contentguard":"on"}}' >"$outfile"
    ;;
  */enabled-products/v1/ddos_protection/services)
    printf '%s\n' '{"customer":{"id":"test-customer"},"services":[]}' >"$outfile"
    ;;
  */enabled-products/v1/ngwaf/services)
    printf '%s\n' '{"customer":{"id":"test-customer"},"services":[]}' >"$outfile"
    ;;
  */enabled-products/v1/api_discovery/services)
    printf '%s\n' '{"customer":{"id":"test-customer"},"services":[]}' >"$outfile"
    ;;
  */enabled-products/v1/*/services)
    printf '%s\n' '{"customer":{"id":"test-customer"},"services":[]}' >"$outfile"
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":0},"data":[]}' >"$outfile"
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
export FASTLY_TEST_SERVICE_INVENTORY_CURL_ARGS="$TEST_TMP/curl-args"

: >"$FASTLY_TEST_SERVICE_INVENTORY_CURL_ARGS"
service_list="$("$ROOT/fastly-audit" service list --json 2>"$TEST_TMP/service-list-err")"
jq -e '
  .summary.total == 3
  and .summary.cdn == 2
  and .summary.compute == 1
  and .summary.paused == 1
  and .summary.discovery_method == "fastly-service-inventory"
  and .summary.source == "GET /service"
  and .summary.status == "COMPLETE"
  and .summary.evidence_type == "DIRECT"
  and .summary.completeness == "token-visible"
  and any(.services[]; .id == "service-1" and .platform == "CDN" and .active_version == 7)
  and any(.services[]; .id == "service-2" and .platform == "Compute" and .active_version == 3)
  and any(.services[]; .id == "service-3" and .platform == "CDN" and .active_version == 12 and .paused == true)
  and all(.services[]; .customer_id == "test-customer")
  and all(.services[]; .id != "other-service")
  and (.summary | has("activation_events_scanned") | not)
  and (.summary | has("activation_scan_truncated") | not)
' >/dev/null <<<"$service_list"
! grep -F '/events' "$FASTLY_TEST_SERVICE_INVENTORY_CURL_ARGS" >/dev/null
! grep -E '/service/service-[0-9]' "$FASTLY_TEST_SERVICE_INVENTORY_CURL_ARGS" >/dev/null

"$ROOT/fastly-audit" service list >"$TEST_TMP/service-list-human" 2>"$TEST_TMP/service-list-human-err"
grep -F 'Token-visible customer services: 3 total' "$TEST_TMP/service-list-human" >/dev/null
grep -F 'Service inventory source: GET /service' "$TEST_TMP/service-list-human" >/dev/null
grep -F 'Inventory completeness: token-visible' "$TEST_TMP/service-list-human" >/dev/null
! grep -F 'audit events' "$TEST_TMP/service-list-human" >/dev/null
! grep -F 'audit-observed' "$TEST_TMP/service-list-human" >/dev/null

: >"$FASTLY_TEST_SERVICE_INVENTORY_CURL_ARGS"
inventory="$("$ROOT/fastly-audit" service inventory --json 2>"$TEST_TMP/inventory-err")"
jq -e '
  .edge_services.total == 3
  and .edge_services.cdn == 2
  and .edge_services.compute == 1
  and .edge_services.discovery.discovery_method == "fastly-service-inventory"
  and .edge_services.discovery.source == "GET /service"
  and .edge_services.discovery.evidence_type == "DIRECT"
  and .edge_services.discovery.status == "COMPLETE"
  and .edge_services.discovery.completeness == "token-visible"
  and (.edge_services.discovery | has("activation_events_scanned") | not)
  and (.edge_services.discovery | has("activation_scan_truncated") | not)
  and ([.edge_services.services[].id] | sort) == ["service-1","service-2","service-3"]
  and any(.service_products.products[];
    .id == "bot_management"
    and .result.count == 1
    and .result.rejected_service_ids == ["other-service"]
    and any(.services[]; .id == "service-3")
    and all(.services[]; .id != "other-service")
  )
' >/dev/null <<<"$inventory"
! grep -F '/events' "$FASTLY_TEST_SERVICE_INVENTORY_CURL_ARGS" >/dev/null
! grep -E '/service/service-[0-9]' "$FASTLY_TEST_SERVICE_INVENTORY_CURL_ARGS" >/dev/null

products="$("$ROOT/fastly-audit" service products --json 2>"$TEST_TMP/products-err")"
jq -e '
  .services_scanned == 3
  and .service_discovery.discovery_method == "fastly-service-inventory"
  and .service_discovery.source == "GET /service"
  and any(.products[];
    .id == "bot_management"
    and .result.count == 1
    and .result.rejected_service_ids == ["other-service"]
    and any(.services[]; .id == "service-3")
  )
' >/dev/null <<<"$products"

for route in list products inventory; do
  NGWAF_PROGRESS=always "$ROOT/fastly-audit" service "$route" --json \
    >"$TEST_TMP/progress-json" 2>"$TEST_TMP/progress-err"
  jq -e 'type == "object"' "$TEST_TMP/progress-json" >/dev/null
  grep -F 'Starting ' "$TEST_TMP/progress-err" >/dev/null
  grep -F 'Services retrieved: 3' "$TEST_TMP/progress-err" >/dev/null
  grep -F 'Completed successfully' "$TEST_TMP/progress-err" >/dev/null
done
grep -F 'Product checks: 11/11' "$TEST_TMP/progress-err" >/dev/null
NGWAF_PROGRESS=always "$ROOT/fastly-audit" inventory --json \
  >"$TEST_TMP/progress-json" 2>"$TEST_TMP/progress-err"
jq -e '.edge_services.total == 3' "$TEST_TMP/progress-json" >/dev/null
grep -F 'Workspaces discovered: 0' "$TEST_TMP/progress-err" >/dev/null
NGWAF_PROGRESS=always "$ROOT/fastly-audit" service list --json 2>"$TEST_TMP/pipeline-err" |
  jq -e '.summary.total == 3' >/dev/null
grep -F 'Completed successfully' "$TEST_TMP/pipeline-err" >/dev/null

security="$("$ROOT/fastly-audit" security summary --json 2>"$TEST_TMP/security-err")"
jq -e --argjson inventory "$inventory" '
  .summary.token_visible_customer_services == $inventory.edge_services.total
  and .inventory_sections.service_inventory.count == $inventory.edge_services.total
  and .inventory_sections.service_inventory.source == $inventory.edge_services.discovery.result.source
' >/dev/null <<<"$security"

export FASTLY_TEST_SERVICE_INVENTORY_MODE=service-api-error
if NGWAF_PROGRESS=always "$ROOT/fastly-audit" service inventory --json >"$TEST_TMP/service-api-error-out" 2>"$TEST_TMP/service-api-error-err"; then
  printf 'service inventory test: service API error unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'Service inventory unavailable: GET /service returned HTTP 503' "$TEST_TMP/service-api-error-err" >/dev/null
grep -F 'Failed:' "$TEST_TMP/service-api-error-err" >/dev/null
if grep -F 'Completed successfully' "$TEST_TMP/service-api-error-err" >/dev/null; then
  printf 'service inventory test: progress reported success after HTTP failure\n' >&2; exit 1
fi

export FASTLY_TEST_SERVICE_INVENTORY_MODE=service-malformed
if "$ROOT/fastly-audit" service inventory --json >"$TEST_TMP/service-malformed-out" 2>"$TEST_TMP/service-malformed-err"; then
  printf 'service inventory test: malformed service API unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'Service inventory unavailable: GET /service returned invalid JSON shape' "$TEST_TMP/service-malformed-err" >/dev/null

printf 'service-inventory: OK\n'
