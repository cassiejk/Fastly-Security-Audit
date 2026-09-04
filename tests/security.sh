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
if [[ -n "${FASTLY_TEST_SECURITY_CURL_ARGS:-}" ]]; then
  printf '%s\n' "$@" >>"$FASTLY_TEST_SECURITY_CURL_ARGS"
fi
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
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    ;;
  */events)
    printf '%s\n' '{"data":[{"attributes":{"customer_id":"test-customer","service_id":"service-1"}}]}' >"$outfile"
    ;;
  */service/service-1)
    printf '%s\n' '{"id":"service-1","name":"www.example.com","customer_id":"test-customer","type":"vcl","active_version":7,"paused":false}' >"$outfile"
    ;;
  */enabled-products/v1/api_discovery/services)
    printf '%s\n' '{"customer":{"id":"test-customer"},"services":[]}' >"$outfile"
    ;;
  */enabled-products/v1/bot_management/services)
    printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-1"]}' >"$outfile"
    ;;
  */enabled-products/v1/ddos_protection/services)
    if [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'unknown-ddos' ]]; then
      printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
      status=503
    else
      printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-1"]}' >"$outfile"
    fi
    ;;
  */enabled-products/v1/ngwaf/services)
    printf '%s\n' '{"customer":{"id":"test-customer"},"services":["service-1"]}' >"$outfile"
    ;;
  */enabled-products/v1/ddos_protection/services/service-1)
    if [[ "${FASTLY_TEST_SECURITY_MODE:-ok}" == 'unknown-ddos' ]]; then
      printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
      status=503
    else
      printf '%s\n' '{}' >"$outfile"
    fi
    ;;
  */enabled-products/v1/bot_management/services/service-1/configuration)
    printf '%s\n' '{"configuration":{"contentguard":"off"}}' >"$outfile"
    ;;
  */enabled-products/v1/ddos_protection/services/service-1/configuration)
    printf '%s\n' '{"configuration":{"mode":"block"}}' >"$outfile"
    ;;
  */enabled-products/v1/ngwaf/services/service-1/configuration)
    printf '%s\n' '{"configuration":{"workspace_id":"production","traffic_ramp":100}}' >"$outfile"
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"production","name":"Production","mode":"block","default_blocking_response_code":406}]}' >"$outfile"
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

$ROOT/fastly-audit security help >"$TEST_TMP/help"
grep -F 'summary [--json]' "$TEST_TMP/help" >/dev/null

output="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/stderr")"
jq -e '
  .schema_version == 1
  and .command == "security summary"
  and .customer.id == "test-customer"
  and .summary.observed_services == 1
  and .summary.security_products_scanned == 4
  and .summary.enabled_product_types == 3
  and .summary.service_product_mappings == 3
  and .summary.cdn_mappings == 3
  and .summary.compute_mappings == 0
  and .summary.unknown_enablement_checks == 0
  and .summary.ngwaf_workspaces == 1
  and (.products | length) == 4
  and any(.products[]; .id == "ddos_protection" and .services[0].configuration.mode == "block")
  and any(.products[]; .id == "ngwaf" and .services[0].configuration.workspace_id == "production")
  and .provenance.product_enablement.missing_data_policy == "unknown_not_disabled"
  and (.limitations | length) == 5
' >/dev/null <<<"$output"
grep -F 'fastly-audit: customer scope:' "$TEST_TMP/stderr" >/dev/null
scope_count="$(grep -c '^customer_id=test-customer$' "$FASTLY_TEST_SECURITY_CURL_ARGS")"
(( scope_count >= 5 )) || {
  printf 'security test: expected customer_id on all four product lists and the workspace list; found %s\n' "$scope_count" >&2
  exit 1
}

$ROOT/fastly-audit security summary >"$TEST_TMP/human" 2>"$TEST_TMP/human-err"
grep -F 'Security product summary' "$TEST_TMP/human" >/dev/null
grep -F 'DDoS Protection' "$TEST_TMP/human" >/dev/null
grep -F 'mode=block' "$TEST_TMP/human" >/dev/null
grep -F 'Enabled means the product is attached' "$TEST_TMP/human" >/dev/null

export FASTLY_TEST_SECURITY_MODE=unknown-ddos
unknown="$($ROOT/fastly-audit security summary --json 2>"$TEST_TMP/unknown-err")"
jq -e '
  .summary.unknown_enablement_checks == 1
  and any(.products[];
    .id == "ddos_protection"
    and .enabled_count == 0
    and .unknown_check_count == 1
    and .unknown_checks[0].http_status == "503"
  )
' >/dev/null <<<"$unknown"

if $ROOT/fastly-audit security nope >"$TEST_TMP/out" 2>"$TEST_TMP/error"; then
  printf 'security test: unknown command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'unknown security command: nope' "$TEST_TMP/error" >/dev/null

printf 'security: OK\n'
