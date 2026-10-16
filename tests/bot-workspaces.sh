#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/config"
cat >"$TEST_TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url='' outfile='' cid='' sid='' cursor='' limit=''
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    --data-urlencode)
      case "$2" in
        customer_id=*) cid="${2#*=}" ;;
        service_id=*) sid="${2#*=}" ;;
        cursor=*) cursor="${2#*=}" ;;
        limit=*) limit="${2#*=}" ;;
        *) exit 91 ;;
      esac; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
jq -nc --arg url "$url" --arg cid "$cid" --arg sid "$sid" --arg cursor "$cursor" --arg limit "$limit" \
  '{url:$url,customer_id:$cid,service_id:$sid,cursor:$cursor,limit:$limit}' >>"$BOT_TEST_LOG"
mode="${BOT_TEST_MODE:-one}"
status=200
case "$url" in
  */customer/*)
    jq -n --arg id "${FASTLY_CUSTOMER_ID:-$BOT_TEST_CUSTOMER}" '{id:$id,name:"Synthetic customer"}' >"$outfile" ;;
  */service/ServiceAlpha)
    jq -n --arg cid "${FASTLY_CUSTOMER_ID:-$BOT_TEST_CUSTOMER}" '{id:"ServiceAlpha",name:"Synthetic CDN",customer_id:$cid,type:"vcl"}' >"$outfile"
    case "$mode" in
      cross-customer) jq '.customer_id="OtherCustomer"' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
      service-id) jq '.id="OtherService"' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
      service-type) jq '.type="wasm"' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
      service-owner-missing) jq 'del(.customer_id)' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
    esac ;;
  */bot-management/v1/workspaces)
    # Regression fixture: a service-only query succeeds but returns no match.
    if [[ -z "$cid" ]]; then
      printf '%s\n' '{"data":[],"meta":{"total":0,"next_cursor":null}}' >"$outfile"
    else
      [[ "$cid" == "${FASTLY_CUSTOMER_ID:-$BOT_TEST_CUSTOMER}" && "$limit" == 100 ]] || exit 92
      jq -n --arg cid "$cid" '{customer_id:$cid,data:[{id:"WorkspaceAlpha",name:"Default workspace",protection_mode:"log",services:["ServiceAlpha"]}],meta:{total:1,next_cursor:null}}' >"$outfile"
      case "$mode" in
        multi|repeat|duplicate|changed-total|partial|second-auth)
          if [[ -z "$cursor" ]]; then
            jq '.meta={total:2,next_cursor:"Opaque+Cursor/Case="}' "$outfile" >"$outfile.new"
          else
            [[ "$cursor" == 'Opaque+Cursor/Case=' ]] || exit 93
            jq '.data[0].id="WorkspaceBeta"' "$outfile" >"$outfile.new"
            case "$mode" in
              repeat) jq '.meta={total:3,next_cursor:"Opaque+Cursor/Case="}' "$outfile.new" >"$outfile.x"; mv "$outfile.x" "$outfile.new" ;;
              duplicate) jq '.data[0].id="WorkspaceAlpha" | .meta.total=2' "$outfile.new" >"$outfile.x"; mv "$outfile.x" "$outfile.new" ;;
              changed-total) jq '.meta.total=3' "$outfile.new" >"$outfile.x"; mv "$outfile.x" "$outfile.new" ;;
              partial) jq '.data=[] | .meta.total=2' "$outfile.new" >"$outfile.x"; mv "$outfile.x" "$outfile.new" ;;
              second-auth) status=403 ;;
              *) jq '.meta.total=2' "$outfile.new" >"$outfile.x"; mv "$outfile.x" "$outfile.new" ;;
            esac
          fi
          # Repeated-cursor fixture keeps totals stable across pages.
          if [[ "$mode" == repeat && -z "$cursor" ]]; then
            jq '.meta.total=3' "$outfile.new" >"$outfile.x"; mv "$outfile.x" "$outfile.new"
          fi
          mv "$outfile.new" "$outfile" ;;
        multiple) jq '.data += [(.data[0] | .id="WorkspaceBeta")] | .meta.total=2' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        zero) printf '%s\n' '{"data":[],"meta":{"total":0,"next_cursor":null}}' >"$outfile" ;;
        auth) status=401 ;;
        forbidden) status=403 ;;
        server) status=500 ;;
        transport) exit 7 ;;
        malformed) printf '{' >"$outfile" ;;
        wrong-service) jq '.data[0].services=["OtherService"]' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        missing-services) jq 'del(.data[0].services)' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        matching-owner) jq --arg cid "$cid" '.data[0].customer={id:$cid} | .meta.customer_id=$cid' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        missing-name) jq 'del(.data[0].name)' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        bad-services) jq '.data[0].services=[false]' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        duplicate-services) jq '.data[0].services += .data[0].services' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        bad-mode) jq '.data[0].protection_mode=false' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        missing-id) jq 'del(.data[0].id)' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        bad-data) jq '.data={}' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        owner-conflict) jq --arg cid "$cid" '.data[0] += {customer_id:$cid,customer:{id:"OtherCustomer"}}' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        meta-owner) jq '.meta.customer_id="OtherCustomer"' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        root-owner) jq '.customer={id:"OtherCustomer"}' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        null-owner) jq '.data[0].customer_id=null' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        bad-total) jq '.meta.total="1"' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        missing-cursor) jq 'del(.meta.next_cursor)' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        bad-cursor) jq '.meta.next_cursor="bad\n"' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        count-mismatch) jq '.meta.total=2' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
        empty-next) jq '.data=[] | .meta={total:2,next_cursor:"next"}' "$outfile" >"$outfile.new"; mv "$outfile.new" "$outfile" ;;
      esac
    fi ;;
  *) printf 'Unexpected request: %s\n' "$url" >&2; exit 94 ;;
esac
printf '%s' "$status"
CURL
chmod +x "$TEST_TMP/bin/curl"
export PATH="$TEST_TMP/bin:$PATH" FASTLY_API_TOKEN='offline-test-token'
export XDG_CONFIG_HOME="$TEST_TMP/config" FASTLY_CUSTOMER_ID='CustomerAlpha'
export BOT_TEST_LOG="$TEST_TMP/requests" BOT_TEST_MODE=one
export NGWAF_PROGRESS=0 NGWAF_CURL_RETRIES=0
run() {
  : >"$BOT_TEST_LOG"
  "$ROOT/fastly-audit" bot workspaces "$@" >"$TEST_TMP/out" 2>"$TEST_TMP/err"
}
fail() {
  if run "$@"; then printf 'Expected failure: %s\n' "$BOT_TEST_MODE" >&2; exit 1; fi
  [[ ! -s "$TEST_TMP/out" ]]
}
# Every failure here must remain entirely offline, including help and parsing.
for launcher in fastly-audit ngwaf; do
  env -u FASTLY_API_TOKEN -u FASTLY_CUSTOMER_ID "$ROOT/$launcher" bot workspaces --help >"$TEST_TMP/help"
  grep -F 'workspaces [--service-id <SID>] [--json]' "$TEST_TMP/help" >/dev/null
done
for args in '--wat' '--service-id' '--json --json' '--service-id ServiceAlpha --service-id ServiceAlpha' '--json --help'; do
  read -r -a parsed <<<"$args"
  fail "${parsed[@]}"
  [[ ! -s "$BOT_TEST_LOG" ]]
done
if env -u FASTLY_CUSTOMER_ID "$ROOT/fastly-audit" bot workspaces --json >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then exit 1; fi
[[ ! -s "$TEST_TMP/out" && ! -s "$BOT_TEST_LOG" ]]

# Directly demonstrate the service-only side of the regression fixture.
curl -o "$TEST_TMP/service-only" --data-urlencode service_id=ServiceAlpha https://api.fastly.com/bot-management/v1/workspaces >/dev/null
jq -e '.meta.total == 0 and .data == []' "$TEST_TMP/service-only" >/dev/null
for customer in CustomerAlpha CustomerBeta; do
  export FASTLY_CUSTOMER_ID="$customer"
  run --service-id ServiceAlpha --json
  jq -e --arg cid "$customer" '.customer.id==$cid and .result.status=="COMPLETE" and .result.count==1
    and .workspaces[0].workspace_id=="WorkspaceAlpha" and .workspaces[0].protection_mode=="log"
    and .workspaces[0].services==["ServiceAlpha"]' "$TEST_TMP/out" >/dev/null
  jq -se --arg cid "$customer" 'length==3 and .[0].url==("https://api.fastly.com/customer/"+$cid)
    and .[1].url=="https://api.fastly.com/service/ServiceAlpha"
    and .[2].url=="https://api.fastly.com/bot-management/v1/workspaces"
    and .[2].customer_id==$cid and .[2].service_id=="ServiceAlpha" and .[2].limit=="100"' "$BOT_TEST_LOG" >/dev/null
  export BOT_TEST_MODE=multi
  run --service-id ServiceAlpha --json
  jq -e '.result.count==2 and .pagination.pages_fetched==2' "$TEST_TMP/out" >/dev/null
  jq -se --arg cid "$customer" '[.[] | select(.url|endswith("/workspaces"))] |
    length==2 and all(.[]; .customer_id==$cid and .service_id=="ServiceAlpha" and .limit=="100")
    and .[1].cursor=="Opaque+Cursor/Case="' "$BOT_TEST_LOG" >/dev/null
  export BOT_TEST_MODE=one
  run --json
  jq -se --arg cid "$customer" 'length==2 and .[1].customer_id==$cid and .[1].service_id==""' "$BOT_TEST_LOG" >/dev/null
done
for mode in cross-customer service-id service-type service-owner-missing; do
  export BOT_TEST_MODE="$mode"
  fail --service-id ServiceAlpha --json
  [[ "$(wc -l <"$BOT_TEST_LOG" | tr -d ' ')" == 2 ]]
done
for mode in auth forbidden server transport malformed wrong-service missing-services missing-name bad-services duplicate-services bad-mode missing-id bad-data owner-conflict meta-owner root-owner null-owner bad-total missing-cursor bad-cursor count-mismatch empty-next repeat duplicate changed-total partial second-auth; do
  export BOT_TEST_MODE="$mode"
  fail --service-id ServiceAlpha --json
done
# Saved selection works without an environment override and remains unchanged.
export BOT_TEST_CUSTOMER=CustomerSaved BOT_TEST_MODE=matching-owner
mkdir -p "$XDG_CONFIG_HOME/fastly-ngwaf"
printf '%s\n' "$BOT_TEST_CUSTOMER" >"$XDG_CONFIG_HOME/fastly-ngwaf/customer_id"
env -u FASTLY_CUSTOMER_ID "$ROOT/fastly-audit" bot workspaces --service-id ServiceAlpha --json >"$TEST_TMP/saved" 2>"$TEST_TMP/err"
jq -e '.customer.id=="CustomerSaved" and .result.count==1' "$TEST_TMP/saved" >/dev/null
[[ "$(cat "$XDG_CONFIG_HOME/fastly-ngwaf/customer_id")" == CustomerSaved ]]
# Environment selection wins over the saved ID, including customer-wide pages.
export BOT_TEST_MODE=multi
run --json
jq -se 'length==3 and all(.[1:][]; .customer_id=="CustomerBeta" and .service_id=="")' "$BOT_TEST_LOG" >/dev/null
[[ "$(cat "$XDG_CONFIG_HOME/fastly-ngwaf/customer_id")" == CustomerSaved ]]
export BOT_TEST_MODE=multiple
run --service-id ServiceAlpha --json
jq -e '.result.count==2' "$TEST_TMP/out" >/dev/null
export BOT_TEST_MODE=zero
run --json
jq -e '.result.count==0 and .pagination.complete and .workspaces==[]' "$TEST_TMP/out" >/dev/null
run
grep -F 'No matching Bot Management workspaces' "$TEST_TMP/out" >/dev/null
export BOT_TEST_MODE=one
run --service-id ServiceAlpha
grep -F 'WorkspaceAlpha' "$TEST_TMP/out" >/dev/null
grep -F 'Default workspace' "$TEST_TMP/out" >/dev/null
grep -F 'ServiceAlpha' "$TEST_TMP/out" >/dev/null
if grep -F "$FASTLY_API_TOKEN" "$TEST_TMP/out" "$TEST_TMP/err" >/dev/null; then
  printf 'Credential appeared in output\n' >&2; exit 1
fi
# Compatibility launcher reaches the same implementation.
"$ROOT/ngwaf" bot workspaces --service-id ServiceAlpha --json >"$TEST_TMP/compat" 2>"$TEST_TMP/err"
jq -e '.result.count==1' "$TEST_TMP/compat" >/dev/null
printf 'Bot workspace tests passed (offline fake API; two synthetic customers).\n'
