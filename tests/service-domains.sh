#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
fail() { printf '%s\n' "$1" >&2; exit 1; }
mkdir -p "$TEST_TMP/bin"
# The mock records only methods and URLs.
mock_curl() {
  local outfile='' url='' method=GET status=200
  while (( $# > 0 )); do
    case "$1" in
      -o) outfile="$2"; shift 2 ;;
      -X) method="$2"; shift 2 ;;
      http://*|https://*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  printf '%s %s\n' "$method" "$url" >>"$FASTLY_TEST_DOMAIN_CALLS"
  case "$url" in
    */customer/test-customer)
      printf '{"id":"test-customer","name":"Test Customer"}\n' >"$outfile" ;;
    */service)
      printf '%s\n' '[
        {"id":"s1","name":"staging-is","type":"vcl","customer_id":"test-customer","active_version":{"number":111}},
        {"id":"empty","name":"empty","type":"vcl","customer_id":"test-customer","active_version":1},
        {"id":"noversion","name":"noversion","type":"vcl","customer_id":"test-customer"},
        {"id":"compute","name":"compute","type":"wasm","customer_id":"test-customer","active_version":1},
        {"id":"other","name":"other","type":"vcl","customer_id":"another-customer","active_version":1}
      ]' >"$outfile" ;;
    */service/empty/version/1/domain) printf '[]\n' >"$outfile" ;;
    */service/s1/version/38/domain) printf '[{"name":"explicit.example"}]\n' >"$outfile" ;;
    */service/s1/version/111/domain)
      case "${FASTLY_TEST_DOMAIN_MODE:-ok}" in
        ok) printf '[{"name":"www.example","service_id":"s1","version":111},{"name":"api.example"}]\n' >"$outfile" ;;
        one) printf '[{"name":"one.example"}]\n' >"$outfile" ;;
        malformed) printf 'not-json\n' >"$outfile" ;;
        missing) printf '{}\n' >"$outfile" ;;
        null) printf 'null\n' >"$outfile" ;;
        badrow) printf '[{"name":null}]\n' >"$outfile" ;;
        mismatch) printf '[{"name":"wrong.example","service_id":"other"}]\n' >"$outfile" ;;
        timeout) return 28 ;;
        *) status="$FASTLY_TEST_DOMAIN_MODE"; printf '{}\n' >"$outfile" ;;
      esac ;;
    *) printf '{}\n' >"$outfile"; status=404 ;;
  esac
  printf '%s' "$status"
}
# Materialize the mock as a temporary executable.
{ printf '#!/usr/bin/env bash\nset -euo pipefail\n'; declare -f mock_curl; printf 'mock_curl "$@"\n'; } >"$TEST_TMP/bin/curl"
chmod +x "$TEST_TMP/bin/curl"
export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN=domain-token-secret
export FASTLY_CUSTOMER_ID=test-customer
export NGWAF_PROGRESS=never NGWAF_COLOR=never NGWAF_CURL_RETRIES=0
export FASTLY_TEST_DOMAIN_CALLS="$TEST_TMP/calls"
unset FASTLY_DSTOKEN FASTLY_VOUCH_COOKIE

"$ROOT/fastly-audit" service domains staging-is --json >"$TEST_TMP/named.json" 2>"$TEST_TMP/named.err"
jq -e '.command == "service domains" and .status == "COMPLETE" and .service_id == "s1" and .version == 111 and .version_source == "active" and .domain_count == 2 and .domains == [{name:"api.example"},{name:"www.example"}]' "$TEST_TMP/named.json" >/dev/null
rg -q '/service/s1/version/111/domain$' "$TEST_TMP/calls"
"$ROOT/fastly-audit" service domains s1 --version 38 --json >"$TEST_TMP/explicit.json" 2>"$TEST_TMP/explicit.err"
jq -e '.version == 38 and .version_source == "explicit" and .domains == [{name:"explicit.example"}]' "$TEST_TMP/explicit.json" >/dev/null
FASTLY_TEST_DOMAIN_MODE=one "$ROOT/fastly-audit" service domains s1 --json >"$TEST_TMP/one.json" 2>"$TEST_TMP/one.err"
jq -e '.domain_count == 1' "$TEST_TMP/one.json" >/dev/null
"$ROOT/fastly-audit" service domains empty --json >"$TEST_TMP/empty.json" 2>"$TEST_TMP/empty.err"
jq -e '.status == "COMPLETE" and .domains == [] and .domain_count == 0' "$TEST_TMP/empty.json" >/dev/null
"$ROOT/fastly-audit" service domains empty >"$TEST_TMP/empty-human" 2>"$TEST_TMP/empty-human.err"
rg -q 'NO CONFIGURED FASTLY DOMAINS OBSERVED' "$TEST_TMP/empty-human"

for mode in 401 403 404 503 malformed missing null badrow mismatch timeout; do
  if FASTLY_TEST_DOMAIN_MODE="$mode" "$ROOT/fastly-audit" service domains s1 --json >"$TEST_TMP/error-$mode.json" 2>"$TEST_TMP/error-$mode.err"; then fail 'failed inventory succeeded'; fi
  jq -e '.status == "UNKNOWN" and .domains == null and .domain_count == null and (.reason | length > 0)' "$TEST_TMP/error-$mode.json" >/dev/null
done
jq -e '.http_status == 403 and (.reason | contains("HTTP 403"))' "$TEST_TMP/error-403.json" >/dev/null
if FASTLY_TEST_DOMAIN_MODE=403 "$ROOT/fastly-audit" service domains s1 >"$TEST_TMP/failed-human" 2>"$TEST_TMP/failed-human.err"; then fail 'human failed inventory succeeded'; fi
rg -q 'HTTP 403' "$TEST_TMP/failed-human"
if rg -q 'Total configured domains: 0|NO CONFIGURED FASTLY DOMAINS OBSERVED' "$TEST_TMP/failed-human"; then fail 'failure appeared as empty'; fi
domain_calls_before="$(rg -c '/domain$' "$TEST_TMP/calls")"
if "$ROOT/fastly-audit" service domains noversion --json >"$TEST_TMP/no-version.json" 2>"$TEST_TMP/no-version.err"; then fail 'missing version succeeded'; fi
[[ "$(rg -c '/domain$' "$TEST_TMP/calls")" == "$domain_calls_before" ]] || fail 'missing version triggered domain API request'
jq -e '.version == null and .status == "UNKNOWN" and .domain_count == null and (.reason | contains("no active version"))' "$TEST_TMP/no-version.json" >/dev/null
"$ROOT/fastly-audit" service domains noversion --version 38 --json >"$TEST_TMP/override.json" 2>"$TEST_TMP/override.err" && fail 'unhandled version unexpectedly succeeded'
jq -e '.version == 38 and .http_status == 404' "$TEST_TMP/override.json" >/dev/null
for selector in nonexistent other compute; do
  if "$ROOT/fastly-audit" service domains "$selector" --json >"$TEST_TMP/reject-$selector.out" 2>"$TEST_TMP/reject-$selector.err"; then fail 'invalid/non-CDN service accepted'; fi
done
for version in 0 -1 abc '1/activate'; do
  if "$ROOT/fastly-audit" service domains s1 --version "$version" >"$TEST_TMP/bad-version.out" 2>"$TEST_TMP/bad-version.err"; then fail 'invalid version accepted'; fi
done
if rg -q 'domain-token-secret' "$TEST_TMP" --glob '*.json' --glob '*.err' --glob '*.out'; then fail 'token leaked'; fi
if rg -q '^(POST|PUT|PATCH|DELETE) |generated_vcl|/service/(compute|other)/version/' "$TEST_TMP/calls"; then fail 'unexpected API operation'; fi
printf 'service-domains: OK\n'
