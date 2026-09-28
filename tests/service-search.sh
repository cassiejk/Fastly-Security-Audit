#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/config"

cat >"$TEST_TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url='' outfile='' cursor=''
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    --data-urlencode)
      printf '%s\n' "$2" >>"$SEARCH_TEST_LOG"
      [[ "$2" != cursor=* ]] || cursor="${2#cursor=}"
      shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$SEARCH_TEST_LOG"
mode="${SEARCH_TEST_MODE:-single}"
status=200
case "$url" in
  */customer/*)
    printf '%s\n' '{"id":"CaseSensitiveCID","name":"Search Test Customer"}' >"$outfile" ;;
  */search/services)
    case "$mode" in
      multi)
        if [[ -z "$cursor" ]]; then
          jq -n '{data:[range(1;101) | {id:("S"+tostring),name:("Service "+tostring),type:(if . % 2 == 0 then "wasm" else "vcl" end),state:"active"}],meta:{total:190,limit:100,sort:"name",next_cursor:"PrivateCursor-CaseSensitive"}}' >"$outfile"
        else
          [[ "$cursor" == PrivateCursor-CaseSensitive ]]
          jq -n '{data:[range(101;191) | {id:("S"+tostring),name:("Service "+tostring),type:"vcl",state:"inactive"}],meta:{total:190,limit:100,sort:"name",previous_cursor:"PrivateCursor-Previous"}}' >"$outfile"
        fi ;;
      zero) printf '%s\n' '{"data":[],"meta":{"total":0}}' >"$outfile" ;;
      repeated)
        printf '%s\n' '{"data":[{"id":"R1"},{"id":"R2"}],"meta":{"total":5,"next_cursor":"PrivateCursor-CaseSensitive"}}' >"$outfile" ;;
      duplicate)
        if [[ -z "$cursor" ]]; then
          printf '%s\n' '{"data":[{"id":"S1"},{"id":"S2"}],"meta":{"total":3,"next_cursor":"PrivateCursor-CaseSensitive"}}' >"$outfile"
        else
          printf '%s\n' '{"data":[{"id":"S1"}],"meta":{"total":3}}' >"$outfile"
        fi ;;
      changed-total|second-auth|missing-second-total)
        if [[ -z "$cursor" ]]; then
          printf '%s\n' '{"data":[{"id":"S1"}],"meta":{"total":2,"next_cursor":"PrivateCursor-CaseSensitive"}}' >"$outfile"
        elif [[ "$mode" == second-auth ]]; then
          status=403; printf '%s\n' '{"error":"forbidden"}' >"$outfile"
        elif [[ "$mode" == missing-second-total ]]; then
          printf '%s\n' '{"data":[{"id":"S2"}],"meta":{}}' >"$outfile"
        else
          printf '%s\n' '{"data":[{"id":"S2"}],"meta":{"total":3}}' >"$outfile"
        fi ;;
      mismatch) printf '%s\n' '{"data":[{"id":"S1"}],"meta":{"total":2}}' >"$outfile" ;;
      malformed|both-fail) printf '%s\n' '{"data":[' >"$outfile" ;;
      bad-schema) printf '%s\n' '{"data":{},"meta":{"total":0}}' >"$outfile" ;;
      missing-meta) printf '%s\n' '{"data":[]}' >"$outfile" ;;
      missing-total) printf '%s\n' '{"data":[],"meta":{}}' >"$outfile" ;;
      string-total) printf '%s\n' '{"data":[],"meta":{"total":"0"}}' >"$outfile" ;;
      negative-total) printf '%s\n' '{"data":[],"meta":{"total":-1}}' >"$outfile" ;;
      fractional-total) printf '%s\n' '{"data":[],"meta":{"total":0.5}}' >"$outfile" ;;
      huge-total) printf '%s\n' '{"data":[],"meta":{"total":1e30}}' >"$outfile" ;;
      bad-id) printf '%s\n' '{"data":[{"id":false}],"meta":{"total":1}}' >"$outfile" ;;
      bad-cursor) printf '%s\n' '{"data":[],"meta":{"total":0,"next_cursor":false}}' >"$outfile" ;;
      empty-with-cursor) printf '%s\n' '{"data":[],"meta":{"total":2,"next_cursor":"PrivateCursor-CaseSensitive"}}' >"$outfile" ;;
      cursor-after-total) printf '%s\n' '{"data":[{"id":"S1"}],"meta":{"total":1,"next_cursor":"PrivateCursor-CaseSensitive"}}' >"$outfile" ;;
      ownership) printf '%s\n' '{"data":[{"id":"S1","customer_id":"OtherCID"}],"meta":{"total":1}}' >"$outfile" ;;
      meta-ownership) printf '%s\n' '{"data":[],"meta":{"total":0,"customer_id":"OtherCID"}}' >"$outfile" ;;
      http-*) status="${mode#http-}"; printf '%s\n' '{"error":"unavailable"}' >"$outfile" ;;
      fallback-partial) status=404; printf '%s\n' '{}' >"$outfile" ;;
      transport) printf 'mock timeout\n' >&2; exit 28 ;;
      *) printf '%s\n' '{"data":[{"id":"S1","name":"CDN Service","type":"vcl","state":"inactive","production_version_number":13,"staging_version_number":0},{"id":"S2","name":"Compute Service","type":"wasm","state":"active","production_version_number":0}],"meta":{"total":2,"limit":100,"sort":"name"}}' >"$outfile" ;;
    esac ;;
  */service)
    if [[ "$mode" == both-fail ]]; then
      status=503; printf '%s\n' '{"error":"unavailable"}' >"$outfile"
    elif [[ "$mode" == fallback-partial ]]; then
      printf '%s\n' '{"data":[{"id":"Legacy","customer_id":"CaseSensitiveCID","type":"vcl"}],"meta":{"total":5}}' >"$outfile"
    else
      printf '%s\n' '[{"id":"Legacy","name":"Legacy Service","customer_id":"CaseSensitiveCID","type":"vcl","paused":false,"active_version":7},{"id":"Foreign","customer_id":"OtherCID"}]' >"$outfile"
    fi ;;
  */service/S1|*/service/S2)
    sid="${url##*/}"
    if [[ "$mode" == detail-auth ]]; then
      status=403; printf '%s\n' '{}' >"$outfile"
    elif [[ "$mode" == detail-ownership ]]; then
      jq -n --arg sid "$sid" '{id:$sid,customer_id:"OtherCID"}' >"$outfile"
    elif [[ "$mode" == detail-unknown ]]; then
      jq -n --arg sid "$sid" '{id:$sid,customer_id:"CaseSensitiveCID"}' >"$outfile"
    else
      jq -n --arg sid "$sid" '{id:$sid,name:(if $sid == "S1" then "CDN Service" else "Compute Service" end),customer_id:"CaseSensitiveCID",type:(if $sid == "S1" then "vcl" else "wasm" end),paused:false,active_version:{number:7}}' >"$outfile"
    fi ;;
  */service/S1/version/7/domain) printf '%s\n' '[{"name":"example.test"}]' >"$outfile" ;;
  *) status=404; printf '%s\n' '{"error":"unhandled mock endpoint"}' >"$outfile" ;;
esac
printf '%s' "$status"
CURL
chmod +x "$TEST_TMP/bin/curl"

cat >"$TEST_TMP/driver" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
PROGRAM_NAME=fastly-audit
API_BASE=https://api.fastly.com
CONFIG_DIR="$XDG_CONFIG_HOME/fastly-ngwaf"
CID_FILE="$CONFIG_DIR/customer_id"
CURL_CONNECT_TIMEOUT=5 CURL_MAX_TIME=60 CURL_RETRIES=0 CURL_RETRY_MAX_TIME=90
NGWAF_CUSTOMER_CONTEXT_JSON=''
source "$ROOT/lib/core.sh"
source "$ROOT/lib/services.sh"
if [[ "${1:-}" == legacy ]]; then
  get_token_visible_customer_services
else
  get_customer_services "$@"
fi
DRIVER
chmod +x "$TEST_TMP/driver"
export ROOT PATH="$TEST_TMP/bin:$PATH" XDG_CONFIG_HOME="$TEST_TMP/config"
export FASTLY_API_TOKEN=mock-token FASTLY_CUSTOMER_ID=CaseSensitiveCID
export NGWAF_COLOR=never NGWAF_PROGRESS=never NGWAF_CURL_RETRIES=0
export SEARCH_TEST_LOG="$TEST_TMP/calls"
run_inventory() {
  : >"$SEARCH_TEST_LOG"
  "$BASH" "$TEST_TMP/driver" "$@" >"$TEST_TMP/json" 2>"$TEST_TMP/err"
  jq -e -s 'length == 1 and (.[0].data | type == "array")' "$TEST_TMP/json" >/dev/null
  if grep -E 'PrivateCursor|mock-token' "$TEST_TMP/json" "$TEST_TMP/err" >/dev/null; then
    printf 'service-search: sensitive data leaked\n' >&2; exit 1
  fi
}
assert_no_global() {
  if grep -Fx 'https://api.fastly.com/service' "$SEARCH_TEST_LOG" >/dev/null; then
    printf 'service-search: unexpected global inventory request\n' >&2; exit 1
  fi
}
run_inventory
jq -e '.meta.status == "COMPLETE" and .meta.count == 2 and .meta.source == "GET /search/services"
  and .meta.scope == "customer" and .meta.result.pagination.type == "cursor"
  and .meta.result.pagination.pages_fetched == 1 and .meta.fallback_used == false
  and .meta.selected_customer_id == "CaseSensitiveCID" and .data[0].state == "inactive"
  and .data[0].production_version_number == 13 and .data[0].staging_version_number == 0
  and .data[1].production_version_number == 0
  and all(.data[]; .paused == null and .active_version == null and .customer_id == "CaseSensitiveCID")
  and [.data[].type] == ["vcl","wasm"]' "$TEST_TMP/json" >/dev/null
assert_no_global
grep -Fx 'customer_id=CaseSensitiveCID' "$SEARCH_TEST_LOG" >/dev/null
grep -F 'Listing customer-scoped services' "$TEST_TMP/err" >/dev/null

export SEARCH_TEST_MODE=multi
run_inventory
jq -e '.meta.count == 190 and .meta.status == "COMPLETE" and .meta.result.pagination.pages_fetched == 2
  and (.data | length) == 190 and ([.data[].id] | unique | length) == 190
  and any(.data[]; .type == "vcl") and any(.data[]; .type == "wasm") and any(.data[]; .state == "inactive")' "$TEST_TMP/json" >/dev/null
[[ "$(grep -Fxc 'customer_id=CaseSensitiveCID' "$SEARCH_TEST_LOG")" == 2 ]]
[[ "$(grep -Fxc 'limit=100' "$SEARCH_TEST_LOG")" == 2 ]]
[[ "$(grep -Fxc 'sort=name' "$SEARCH_TEST_LOG")" == 2 ]]
grep -Fx 'cursor=PrivateCursor-CaseSensitive' "$SEARCH_TEST_LOG" >/dev/null
if grep -E '^page=' "$SEARCH_TEST_LOG" >/dev/null; then printf 'service-search: page-number request\n' >&2; exit 1; fi
assert_no_global
NGWAF_DEBUG=1 run_inventory
# Debug output also redacts cursor values.
grep -F 'cursor=<redacted>' "$TEST_TMP/err" >/dev/null

export SEARCH_TEST_MODE=zero
run_inventory
jq -e '.meta.status == "COMPLETE" and .meta.count == 0 and .data == []' "$TEST_TMP/json" >/dev/null
assert_no_global

for mode in repeated duplicate changed-total missing-second-total mismatch malformed bad-schema missing-meta missing-total string-total negative-total fractional-total huge-total bad-id bad-cursor empty-with-cursor cursor-after-total http-404 http-405 http-429 http-500 http-503 transport; do
  export SEARCH_TEST_MODE="$mode"
  run_inventory
  jq -e '.meta.source == "GET /service" and .meta.status == "COMPLETE" and .meta.count == 1
    and .meta.scope == "token-visible" and .meta.filtered_locally_by_customer_id == true
    and .meta.result.fallback_used == true and .meta.result.fallback_from == "GET /search/services"
    and .data[0].id == "Legacy"' "$TEST_TMP/json" >/dev/null
  grep -F 'using legacy token-visible service discovery' "$TEST_TMP/err" >/dev/null
  if [[ "$mode" == repeated ]]; then
    [[ "$(grep -Fxc 'https://api.fastly.com/search/services' "$SEARCH_TEST_LOG")" == 2 ]]
  fi
done

for mode in http-401 http-403 second-auth ownership meta-ownership both-fail; do
  export SEARCH_TEST_MODE="$mode"
  : >"$SEARCH_TEST_LOG"
  if "$BASH" "$TEST_TMP/driver" >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'service-search: unsafe %s response succeeded\n' "$mode" >&2; exit 1
  fi
  [[ ! -s "$TEST_TMP/out" ]]
  [[ "$mode" == both-fail ]] || assert_no_global
done
: >"$SEARCH_TEST_LOG"
if FASTLY_CUSTOMER_ID=casesensitivecid "$BASH" "$TEST_TMP/driver" >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
  printf 'service-search: unvalidated customer case accepted\n' >&2; exit 1
fi
[[ ! -s "$TEST_TMP/out" ]]
if grep -F '/search/services' "$SEARCH_TEST_LOG" >/dev/null; then printf 'service-search: search ran before scope validation\n' >&2; exit 1; fi

export SEARCH_TEST_MODE=fallback-partial
run_inventory
jq -e '.meta.status == "PARTIAL" and .meta.count == null and .meta.count_lower_bound == 1 and .meta.result.fallback_used == true' "$TEST_TMP/json" >/dev/null

export SEARCH_TEST_MODE=single
run_inventory --details
jq -e '.meta.enrichment.services_queried == 2 and all(.data[]; .paused == false and .active_version.number == 7)
  and .data[0].production_version_number == 13' "$TEST_TMP/json" >/dev/null
assert_no_global
for mode in detail-auth detail-ownership; do
  export SEARCH_TEST_MODE="$mode"
  : >"$SEARCH_TEST_LOG"
  if "$BASH" "$TEST_TMP/driver" --details >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'service-search: unverified enrichment succeeded\n' >&2; exit 1
  fi
  [[ ! -s "$TEST_TMP/out" ]]
  assert_no_global
done
export SEARCH_TEST_MODE=detail-unknown
run_inventory --details
jq -e 'all(.data[]; .paused == null and .active_version == null)' "$TEST_TMP/json" >/dev/null

: >"$SEARCH_TEST_LOG"
"$ROOT/fastly-audit" service list --json >"$TEST_TMP/services" 2>"$TEST_TMP/err"
jq -e '.service_discovery.source == "GET /search/services" and .service_discovery.scope == "customer"
  and .service_discovery.result.pagination.type == "cursor" and .summary.paused == null
  and all(.services[]; .paused == null and .active_version == null)' "$TEST_TMP/services" >/dev/null

# A selected-service command enriches only the selected service. An explicit
# version requires no legacy-version enrichment at all.
export SEARCH_TEST_MODE=single
: >"$SEARCH_TEST_LOG"
"$ROOT/fastly-audit" service domains S1 --json >"$TEST_TMP/domains" 2>"$TEST_TMP/err"
jq -e '.version == "7" or .version == 7' "$TEST_TMP/domains" >/dev/null
if grep -Fx 'https://api.fastly.com/service/S2' "$SEARCH_TEST_LOG" >/dev/null; then printf 'service-search: unrelated service enriched\n' >&2; exit 1; fi
: >"$SEARCH_TEST_LOG"
"$ROOT/fastly-audit" service domains S1 --version 7 --json >"$TEST_TMP/domains" 2>"$TEST_TMP/err"
if grep -E 'https://api.fastly.com/service/S[12]$' "$SEARCH_TEST_LOG" >/dev/null; then printf 'service-search: explicit version unnecessarily enriched\n' >&2; exit 1; fi

# The raw token-visible primitive remains unchanged and never invokes search.
run_inventory legacy
jq -e '.meta.source == "GET /service" and .meta.result.fallback_used == false and .data[0].id == "Legacy"' "$TEST_TMP/json" >/dev/null
if grep -F '/search/services' "$SEARCH_TEST_LOG" >/dev/null; then printf 'service-search: legacy primitive invoked search\n' >&2; exit 1; fi
printf 'service-search: OK\n'
