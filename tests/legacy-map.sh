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
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

status=200
mode="${FASTLY_TEST_LEGACY_MAP_MODE:-ok}"
direct_service_id=""
case "$url" in
  */service/*)
    direct_service_id="${url##*/service/}"
    case "$direct_service_id" in
      */*) direct_service_id="" ;;
    esac
    ;;
esac
lookup_active_file="${FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG:-}.active"
lookup_max_file="${FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG:-}.max"
lookup_lock_dir="${FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG:-}.lock"
lookup_lock() {
  [[ -n "${FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG:-}" && -n "$direct_service_id" ]] || return 0
  while ! mkdir "$lookup_lock_dir" 2>/dev/null; do
    sleep 0.01
  done
}
lookup_unlock() {
  [[ -n "${FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG:-}" && -n "$direct_service_id" ]] || return 0
  rmdir "$lookup_lock_dir"
}
lookup_started() {
  [[ -n "${FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG:-}" && -n "$direct_service_id" ]] || return 0
  lookup_lock
  active=0
  [[ -s "$lookup_active_file" ]] && active="$(cat "$lookup_active_file")"
  active=$((active + 1))
  printf '%s' "$active" >"$lookup_active_file"
  max=0
  [[ -s "$lookup_max_file" ]] && max="$(cat "$lookup_max_file")"
  if (( active > max )); then
    printf '%s' "$active" >"$lookup_max_file"
  fi
  printf 'start %s active=%s\n' "$direct_service_id" "$active" >>"$FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG"
  lookup_unlock
}
lookup_finished() {
  [[ -n "${FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG:-}" && -n "$direct_service_id" ]] || return 0
  lookup_lock
  active=0
  [[ -s "$lookup_active_file" ]] && active="$(cat "$lookup_active_file")"
  if (( active > 0 )); then
    active=$((active - 1))
  fi
  printf '%s' "$active" >"$lookup_active_file"
  printf 'end %s active=%s\n' "$direct_service_id" "$active" >>"$FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG"
  lookup_unlock
}
lookup_started
if [[ -n "$direct_service_id" && "$mode" == "parallel-order" ]]; then
  case "$direct_service_id" in
    ess-prod) sleep 0.20 ;;
    NqBYffdR4mOhuGwMfOnldY) sleep 0.05 ;;
    ess-qa) sleep 0.15 ;;
    ess-mismatch) sleep 0.01 ;;
    ess-amb-1) sleep 0.12 ;;
    ess-amb-2) sleep 0.02 ;;
  esac
fi
case "$url" in
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    ;;
  */service)
    printf '%s\n' '{
      "meta":{"total":10},
      "data":[
        {"id":"cdn-prod","name":"prd-usbcwww","customer_id":"test-customer","type":"vcl","active_version":10},
        {"id":"cdn-live","name":"prod-is","customer_id":"test-customer","type":"vcl","active_version":18},
        {"id":"cdn-qa-1","name":"qa-one","customer_id":"test-customer","type":"vcl","active_version":11},
        {"id":"cdn-qa-2","name":"qa-two","customer_id":"test-customer","type":"vcl","active_version":12},
        {"id":"cdn-qa-3","name":"qa-three","customer_id":"test-customer","type":"vcl","active_version":13},
        {"id":"cdn-no-host","name":"no-host","customer_id":"test-customer","type":"vcl","active_version":14},
        {"id":"cdn-vcl-fail","name":"vcl-fail","customer_id":"test-customer","type":"vcl","active_version":15},
        {"id":"cdn-mismatch","name":"mismatch","customer_id":"test-customer","type":"vcl","active_version":16},
        {"id":"cdn-ambiguous","name":"ambiguous","customer_id":"test-customer","type":"vcl","active_version":17},
        {"id":"compute-source","name":"compute-source","customer_id":"test-customer","type":"wasm","active_version":{"number":2}},
        {"id":"foreign-cdn","name":"foreign","customer_id":"other-customer","type":"vcl","active_version":99}
      ]
    }' >"$outfile"
    ;;
  */service/cdn-prod/version/10/generated_vcl)
    printf '%s\n' '{"content":"set req.backend = F_se--costco--prod.edgecompute.app;"}' >"$outfile"
    ;;
  */service/cdn-live/version/18/generated_vcl)
    printf '%s\n' '{"content":"set req.backend = F_se--costco--69a8b42409aacb23a10bf0ca.edgecompute.app;"}' >"$outfile"
    ;;
  */service/cdn-qa-1/version/11/generated_vcl|*/service/cdn-qa-2/version/12/generated_vcl|*/service/cdn-qa-3/version/13/generated_vcl)
    printf '%s\n' '{"content":"call se--costco--qa.edgecompute.app;"}' >"$outfile"
    ;;
  */service/cdn-no-host/version/14/generated_vcl)
    printf '%s\n' '{"content":"sub vcl_recv { set req.http.X-Test = \"none\"; }"}' >"$outfile"
    ;;
  */service/cdn-vcl-fail/version/15/generated_vcl)
    printf '%s\n' '{"error":"generated VCL unavailable"}' >"$outfile"
    status=503
    ;;
  */service/cdn-mismatch/version/16/generated_vcl)
    printf '%s\n' '{"content":"set req.http.host = \"se--costco--mismatch.edgecompute.app\";"}' >"$outfile"
    ;;
  */service/cdn-ambiguous/version/17/generated_vcl)
    printf '%s\n' '{"content":"set req.http.host = \"se--costco--amb.edgecompute.app\";"}' >"$outfile"
    ;;
  */v0/corps/costco/sites|*/v0/corps/test-corp/sites)
    if [[ "$mode" == "sites-302" ]]; then
      printf '%s\n' '{"error":"redirected"}' >"$outfile"
      status=302
    elif [[ "$mode" == "sites-401" ]]; then
      printf '%s\n' '{"error":"unauthorized"}' >"$outfile"
      status=401
    elif [[ "$mode" == "sites-403" ]]; then
      printf '%s\n' '{"error":"forbidden"}' >"$outfile"
      status=403
    elif [[ "$mode" == "sites-404" ]]; then
      printf '%s\n' '{"error":"not found"}' >"$outfile"
      status=404
    elif [[ "$mode" == "sites-500" ]]; then
      printf '%s\n' '{"error":"internal error"}' >"$outfile"
      status=500
    elif [[ "$mode" == "sites-fail" ]]; then
      printf '%s\n' '{"error":"sites unavailable"}' >"$outfile"
      status=503
    elif [[ "$mode" == "multi-customer" ]]; then
      printf '%s\n' '{
        "data":[
          {"id":"site-prod","name":"gdx-costco-prd-is","customer_id":"test-customer","serviceID":"ess-prod"},
          {"id":"site-other","name":"other","customer_id":"other-customer","serviceID":"ess-qa"}
        ]
      }' >"$outfile"
    elif [[ "$mode" == "missing-customer" ]]; then
      printf '%s\n' '{
        "data":[
          {"id":"site-prod","name":"gdx-costco-prd-is","serviceID":"ess-prod"}
        ]
      }' >"$outfile"
    elif [[ "$mode" == "duplicate-serviceids" ]]; then
      printf '%s\n' '{
        "data":[
          {"id":"site-prod","name":"gdx-costco-prd-is","customer_id":"test-customer","serviceID":"ess-prod"},
          {"id":"site-prod-copy","name":"gdx-costco-prd-is-copy","customer_id":"test-customer","serviceID":"ess-prod"},
          {"id":"site-live","name":"gdx-costco-prd-is-live","customer_id":"test-customer","serviceID":"NqBYffdR4mOhuGwMfOnldY"}
        ]
      }' >"$outfile"
    else
      printf '%s\n' '{
        "data":[
          {"id":"site-prod","name":"gdx-costco-prd-is","customer_id":"test-customer","serviceID":"ess-prod"},
          {"id":"site-live","name":"gdx-costco-prd-is-live","customer_id":"test-customer","serviceID":"NqBYffdR4mOhuGwMfOnldY"},
          {"id":"site-qa","name":"gdx-costco-qa-is","customer_id":"test-customer","serviceID":"ess-qa"},
          {"id":"site-null","name":"gdx-costco-null","customer_id":"test-customer","serviceID":null},
          {"id":"site-mismatch","name":"gdx-costco-mismatch","customer_id":"test-customer","serviceID":"ess-mismatch"},
          {"id":"site-amb-1","name":"gdx-costco-amb-1","customer_id":"test-customer","serviceID":"ess-amb-1"},
          {"id":"site-amb-2","name":"gdx-costco-amb-2","customer_id":"test-customer","serviceID":"ess-amb-2"}
        ]
      }' >"$outfile"
    fi
    ;;
  */v0/corps/cassie_keller/sites)
    printf '%s\n' '{
      "data":[
        {"id":"wrong-site","name":"personal-site","customer_id":"wrong-customer","serviceID":"ess-prod"}
      ]
    }' >"$outfile"
    ;;
  */service/ess-prod)
    printf '%s\n' '{"id":"ess-prod","name":"se--costco--prod","customer_id":"test-customer","type":"wasm"}' >"$outfile"
    ;;
  */service/NqBYffdR4mOhuGwMfOnldY)
    if [[ "$mode" == "ess-lookup-fail" ]]; then
      printf '%s\n' '{"error":"service unavailable"}' >"$outfile"
      status=503
    else
      printf '%s\n' '{"Name":"se--costco--69a8b42409aacb23a10bf0ca","ServiceID":"NqBYffdR4mOhuGwMfOnldY","Type":"wasm"}' >"$outfile"
    fi
    ;;
  */service/ess-qa)
    printf '%s\n' '{"id":"ess-qa","name":"se--costco--qa","customer_id":"test-customer","type":"wasm"}' >"$outfile"
    ;;
  */service/ess-mismatch)
    printf '%s\n' '{"id":"ess-mismatch","name":"se--costco--different","customer_id":"test-customer","type":"wasm"}' >"$outfile"
    ;;
  */service/ess-amb-1)
    printf '%s\n' '{"id":"ess-amb-1","name":"se--costco--amb","customer_id":"test-customer","type":"wasm"}' >"$outfile"
    ;;
  */service/ess-amb-2)
    printf '%s\n' '{"id":"ess-amb-2","name":"se--costco--amb","customer_id":"test-customer","type":"wasm"}' >"$outfile"
    ;;
  *)
    printf '%s\n' '{"error":"unhandled fake endpoint"}' >"$outfile"
    status=404
    ;;
esac
lookup_finished
printf '%s' "$status"
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"

export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN="test-token"
export FASTLY_CUSTOMER_ID="test-customer"
export FASTLY_DSTOKEN="secret-dstoken"
export FASTLY_VOUCH_COOKIE="secret-vouch"
export SIGSCI_CORP="costco"
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0

json="$("$ROOT/fastly-audit" security legacy-map --format json 2>"$TEST_TMP/json-err")"
jq -e '
  .summary.source_cdn_services_scanned == 9
  and .summary.confirmed_workspace_mappings == 5
  and .summary.unique_legacy_ess_services == 3
  and .summary.not_found == 1
  and .summary.unknown == 1
  and .summary.unresolved == 1
  and .summary.ambiguous == 1
  and .sources.internal_ngwaf_sites.status == "COMPLETE"
  and .summary.sigsci_corp == "costco"
  and .summary.sigsci_corp_source == "env"
  and .summary.selected_customer_id == "test-customer"
  and .summary.sigsci_customer_id == "test-customer"
  and .summary.corp_validation_status == "VALID"
  and .sources.internal_ngwaf_sites.corp_validation_status == "VALID"
  and any(.mappings[]; .source_service_id == "cdn-prod" and .status == "CONFIRMED" and .evidence_type == "DIRECT" and .legacy_inspection_service_host == "se--costco--prod.edgecompute.app" and .inspection_service_id == "ess-prod" and .workspace_name == "gdx-costco-prd-is")
  and any(.mappings[]; .source_service_id == "cdn-prod" and .legacy_ess_hostname == .legacy_inspection_service_host and .ess_service_id == .inspection_service_id)
  and any(.mappings[]; .source_service_id == "cdn-live" and .status == "CONFIRMED" and .evidence_type == "DIRECT" and .inspection_service_host == "se--costco--69a8b42409aacb23a10bf0ca.edgecompute.app" and .inspection_service_name == "se--costco--69a8b42409aacb23a10bf0ca" and .inspection_service_id == "NqBYffdR4mOhuGwMfOnldY" and .workspace_name == "gdx-costco-prd-is-live")
  and ([.mappings[] | select(.workspace_name == "gdx-costco-qa-is" and .status == "CONFIRMED")] | length) == 3
  and any(.mappings[]; .source_service_id == "cdn-no-host" and .status == "NOT_FOUND")
  and any(.mappings[]; .source_service_id == "cdn-vcl-fail" and .status == "UNKNOWN" and (.reason | test("HTTP 503")))
  and any(.mappings[]; .source_service_id == "cdn-mismatch" and .status == "UNRESOLVED")
  and any(.mappings[]; .source_service_id == "cdn-ambiguous" and .status == "AMBIGUOUS" and (.candidates | length) == 2)
  and all(.mappings[]; .source_service_id != "foreign-cdn")
' >/dev/null <<<"$json"
! grep -F 'secret-dstoken' <<<"$json" >/dev/null
! grep -F 'secret-vouch' <<<"$json" >/dev/null
! grep -F 'secret-dstoken' "$TEST_TMP/json-err" >/dev/null
! grep -F 'secret-vouch' "$TEST_TMP/json-err" >/dev/null

lookup_log="$TEST_TMP/inspection-lookups.log"
FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG="$lookup_log" "$ROOT/fastly-audit" security legacy-map --format json >"$TEST_TMP/lookup-json" 2>"$TEST_TMP/lookup-err"
for service_id in ess-prod NqBYffdR4mOhuGwMfOnldY ess-qa ess-mismatch ess-amb-1 ess-amb-2; do
  [[ "$(grep -c "^start $service_id " "$lookup_log")" == "1" ]]
  [[ "$(grep -c "^end $service_id " "$lookup_log")" == "1" ]]
done
[[ "$(grep -c '^start ' "$lookup_log")" == "6" ]]
! grep -F '/service' "$lookup_log" >/dev/null
jq -e '
  any(.mappings[]; .source_service_id == "cdn-ambiguous" and .status == "AMBIGUOUS" and (.candidates | length) == 2)
' >/dev/null <"$TEST_TMP/lookup-json"
! grep -F 'secret-dstoken' "$lookup_log" >/dev/null
! grep -F 'secret-vouch' "$lookup_log" >/dev/null

duplicate_log="$TEST_TMP/inspection-lookups-duplicates.log"
FASTLY_TEST_LEGACY_MAP_MODE=duplicate-serviceids \
FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG="$duplicate_log" \
  "$ROOT/fastly-audit" security legacy-map cdn-prod --format json >"$TEST_TMP/duplicate-json" 2>"$TEST_TMP/duplicate-err"
[[ "$(grep -c '^start ess-prod ' "$duplicate_log")" == "1" ]]
[[ "$(grep -c '^start NqBYffdR4mOhuGwMfOnldY ' "$duplicate_log")" == "1" ]]
[[ "$(grep -c '^start ' "$duplicate_log")" == "2" ]]

bounded_log="$TEST_TMP/inspection-lookups-bounded.log"
FASTLY_TEST_LEGACY_MAP_MODE=parallel-order \
FASTLY_TEST_LEGACY_MAP_LOOKUP_LOG="$bounded_log" \
FASTLY_AUDIT_LOOKUP_CONCURRENCY=2 \
FASTLY_AUDIT_LEGACY_MAP_TRACE=1 \
  "$ROOT/fastly-audit" security legacy-map --format json >"$TEST_TMP/bounded-json-a" 2>"$TEST_TMP/bounded-err-a"
[[ "$(cat "$bounded_log.max")" -le 2 ]]
[[ "$(grep -c '^start ' "$bounded_log")" == "6" ]]
[[ "$(grep -c '^end ' "$bounded_log")" == "6" ]]
grep -F 'Inspection Service lookup concurrency: 2' "$TEST_TMP/bounded-err-a" >/dev/null
grep -F 'direct lookups started: 6' "$TEST_TMP/bounded-err-a" >/dev/null
grep -F 'direct lookups completed: 6' "$TEST_TMP/bounded-err-a" >/dev/null
grep -F 'direct lookup failures: 0' "$TEST_TMP/bounded-err-a" >/dev/null
grep -F 'worker process failures: 0' "$TEST_TMP/bounded-err-a" >/dev/null
grep -F 'Inspection Service resolver completed in ' "$TEST_TMP/bounded-err-a" >/dev/null
! grep -F 'secret-dstoken' "$TEST_TMP/bounded-err-a" >/dev/null
! grep -F 'secret-vouch' "$TEST_TMP/bounded-err-a" >/dev/null

FASTLY_TEST_LEGACY_MAP_MODE=parallel-order \
FASTLY_AUDIT_LOOKUP_CONCURRENCY=2 \
  "$ROOT/fastly-audit" security legacy-map --format json >"$TEST_TMP/bounded-json-b" 2>"$TEST_TMP/bounded-err-b"
jq -S '.mappings' "$TEST_TMP/bounded-json-a" >"$TEST_TMP/bounded-mappings-a"
jq -S '.mappings' "$TEST_TMP/bounded-json-b" >"$TEST_TMP/bounded-mappings-b"
cmp "$TEST_TMP/bounded-mappings-a" "$TEST_TMP/bounded-mappings-b" >/dev/null

FASTLY_AUDIT_LOOKUP_CONCURRENCY=99 \
FASTLY_AUDIT_LEGACY_MAP_TRACE=1 \
  "$ROOT/fastly-audit" security legacy-map cdn-prod --format json >"$TEST_TMP/capped-json" 2>"$TEST_TMP/capped-err"
grep -F 'Inspection Service lookup concurrency: 16' "$TEST_TMP/capped-err" >/dev/null

single="$("$ROOT/fastly-audit" security legacy-map prd-usbcwww --format json 2>"$TEST_TMP/single-err")"
jq -e '
  (.mappings | length) == 1
  and .mappings[0].source_service_id == "cdn-prod"
  and .mappings[0].status == "CONFIRMED"
' >/dev/null <<<"$single"

live="$("$ROOT/fastly-audit" security legacy-map prod-is --format json 2>"$TEST_TMP/live-err")"
jq -e '
  (.mappings | length) == 1
  and .mappings[0].source_service_id == "cdn-live"
  and .mappings[0].inspection_service_host == "se--costco--69a8b42409aacb23a10bf0ca.edgecompute.app"
  and .mappings[0].inspection_service_name == "se--costco--69a8b42409aacb23a10bf0ca"
  and .mappings[0].legacy_inspection_service_name == "se--costco--69a8b42409aacb23a10bf0ca"
  and .mappings[0].legacy_ess_service_name == "se--costco--69a8b42409aacb23a10bf0ca"
  and .mappings[0].inspection_service_id == "NqBYffdR4mOhuGwMfOnldY"
  and .mappings[0].ess_service_id == "NqBYffdR4mOhuGwMfOnldY"
  and .mappings[0].workspace_name == "gdx-costco-prd-is-live"
  and .mappings[0].evidence_type == "DIRECT"
  and .mappings[0].status == "CONFIRMED"
  and .mappings[0].candidates[0].inspection_service_name == "se--costco--69a8b42409aacb23a10bf0ca"
' >/dev/null <<<"$live"

override="$(SIGSCI_CORP="cassie_keller" "$ROOT/fastly-audit" security legacy-map prod-is --sigsci-corp costco --format json 2>"$TEST_TMP/override-err")"
jq -e '
  .summary.sigsci_corp == "costco"
  and .summary.sigsci_corp_source == "cli"
  and .summary.corp_validation_status == "VALID"
  and .mappings[0].status == "CONFIRMED"
' >/dev/null <<<"$override"

if SIGSCI_CORP="cassie_keller" "$ROOT/fastly-audit" security legacy-map prod-is --format json >"$TEST_TMP/wrong-corp-out" 2>"$TEST_TMP/wrong-corp-err"; then
  printf 'legacy-map test: wrong SIGSCI corp unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'SIGSCI corp/customer mismatch' "$TEST_TMP/wrong-corp-err" >/dev/null
grep -F 'queried SIGSCI corp: cassie_keller (env)' "$TEST_TMP/wrong-corp-err" >/dev/null
grep -F 'returned site customer_id: wrong-customer' "$TEST_TMP/wrong-corp-err" >/dev/null
! grep -F 'UNRESOLVED' "$TEST_TMP/wrong-corp-out" >/dev/null
! grep -F 'secret-dstoken' "$TEST_TMP/wrong-corp-err" >/dev/null
! grep -F 'secret-vouch' "$TEST_TMP/wrong-corp-err" >/dev/null

export FASTLY_TEST_LEGACY_MAP_MODE=multi-customer
if "$ROOT/fastly-audit" security legacy-map prod-is --format json >"$TEST_TMP/multi-customer-out" 2>"$TEST_TMP/multi-customer-err"; then
  printf 'legacy-map test: multiple site customer IDs unexpectedly succeeded\n' >&2
  exit 1
fi
unset FASTLY_TEST_LEGACY_MAP_MODE
grep -F 'validation status: AMBIGUOUS' "$TEST_TMP/multi-customer-err" >/dev/null
grep -F 'returned site customer_id: other-customer,test-customer' "$TEST_TMP/multi-customer-err" >/dev/null
! grep -F 'UNRESOLVED' "$TEST_TMP/multi-customer-out" >/dev/null

export FASTLY_TEST_LEGACY_MAP_MODE=missing-customer
if "$ROOT/fastly-audit" security legacy-map prod-is --format json >"$TEST_TMP/missing-customer-out" 2>"$TEST_TMP/missing-customer-err"; then
  printf 'legacy-map test: missing site customer ID unexpectedly succeeded\n' >&2
  exit 1
fi
unset FASTLY_TEST_LEGACY_MAP_MODE
grep -F 'validation status: UNKNOWN' "$TEST_TMP/missing-customer-err" >/dev/null
grep -F 'returned site customer_id: none' "$TEST_TMP/missing-customer-err" >/dev/null
! grep -F 'UNRESOLVED' "$TEST_TMP/missing-customer-out" >/dev/null

compute="$("$ROOT/fastly-audit" security legacy-map compute-source --format json 2>"$TEST_TMP/compute-err")"
jq -e '
  (.mappings | length) == 1
  and .mappings[0].status == "NOT_APPLICABLE"
  and .mappings[0].evidence_type == "INFORMATIONAL"
' >/dev/null <<<"$compute"

export FASTLY_TEST_LEGACY_MAP_MODE=sites-fail
failed_sites="$("$ROOT/fastly-audit" security legacy-map cdn-prod --format json 2>"$TEST_TMP/sites-fail-err")"
unset FASTLY_TEST_LEGACY_MAP_MODE
jq -e '
  .sources.internal_ngwaf_sites.status == "UNKNOWN"
  and .sources.internal_ngwaf_sites.internal_ngwaf_http_status == 503
  and .sources.internal_ngwaf_sites.internal_ngwaf_error_type == "HTTP_ERROR"
  and (.sources.internal_ngwaf_sites.internal_ngwaf_error_reason | test("internal NGWAF sites query failed"))
  and .mappings[0].status == "UNKNOWN"
  and (.mappings[0].reason | test("HTTP 503"))
' >/dev/null <<<"$failed_sites"

export FASTLY_TEST_LEGACY_MAP_MODE=sites-302
redirect_sites="$("$ROOT/fastly-audit" security legacy-map cdn-prod --format json 2>"$TEST_TMP/sites-302-json-err")"
redirect_human="$("$ROOT/fastly-audit" security legacy-map cdn-prod 2>"$TEST_TMP/sites-302-human-err")"
unset FASTLY_TEST_LEGACY_MAP_MODE
jq -e '
  .sources.internal_ngwaf_sites.status == "UNKNOWN"
  and .sources.internal_ngwaf_sites.internal_ngwaf_http_status == 302
  and .sources.internal_ngwaf_sites.internal_ngwaf_error_type == "AUTH_REDIRECT"
  and (.sources.internal_ngwaf_sites.internal_ngwaf_error_reason | test("likely expired or invalid"))
  and (.sources.internal_ngwaf_sites.internal_ngwaf_recommended_action | test("refresh FASTLY_DSTOKEN and FASTLY_VOUCH_COOKIE"))
  and (.sources.internal_ngwaf_sites.internal_ngwaf_recommended_action | test("legacy Signal Sciences dashboard session"))
' >/dev/null <<<"$redirect_sites"
grep -F 'Internal NGWAF auth/session problem' <<<"$redirect_human" >/dev/null
grep -F 'HTTP 302 from internal NGWAF API' <<<"$redirect_human" >/dev/null
grep -F 'likely expired or invalid internal session cookies' <<<"$redirect_human" >/dev/null
grep -F 'refresh FASTLY_DSTOKEN and FASTLY_VOUCH_COOKIE' <<<"$redirect_human" >/dev/null
grep -F 'legacy Signal Sciences dashboard session' <<<"$redirect_human" >/dev/null
! grep -F 'secret-dstoken' <<<"$redirect_sites" >/dev/null
! grep -F 'secret-vouch' <<<"$redirect_sites" >/dev/null
! grep -F 'secret-dstoken' <<<"$redirect_human" >/dev/null
! grep -F 'secret-vouch' <<<"$redirect_human" >/dev/null
! grep -F 'secret-dstoken' "$TEST_TMP/sites-302-json-err" >/dev/null
! grep -F 'secret-vouch' "$TEST_TMP/sites-302-json-err" >/dev/null
! grep -F 'secret-dstoken' "$TEST_TMP/sites-302-human-err" >/dev/null
! grep -F 'secret-vouch' "$TEST_TMP/sites-302-human-err" >/dev/null

export FASTLY_TEST_LEGACY_MAP_MODE=sites-401
auth_failed_sites="$("$ROOT/fastly-audit" security legacy-map cdn-prod --format json 2>"$TEST_TMP/sites-401-err")"
unset FASTLY_TEST_LEGACY_MAP_MODE
jq -e '
  .sources.internal_ngwaf_sites.internal_ngwaf_http_status == 401
  and .sources.internal_ngwaf_sites.internal_ngwaf_error_type == "AUTH_FAILED"
  and (.sources.internal_ngwaf_sites.internal_ngwaf_error_reason | test("authentication failed"))
  and (.sources.internal_ngwaf_sites.internal_ngwaf_recommended_action | test("refresh FASTLY_DSTOKEN and FASTLY_VOUCH_COOKIE"))
  and (.sources.internal_ngwaf_sites.internal_ngwaf_recommended_action | test("legacy Signal Sciences dashboard session"))
' >/dev/null <<<"$auth_failed_sites"

export FASTLY_TEST_LEGACY_MAP_MODE=sites-403
access_denied_sites="$("$ROOT/fastly-audit" security legacy-map cdn-prod --format json 2>"$TEST_TMP/sites-403-err")"
unset FASTLY_TEST_LEGACY_MAP_MODE
jq -e '
  .sources.internal_ngwaf_sites.internal_ngwaf_http_status == 403
  and .sources.internal_ngwaf_sites.internal_ngwaf_error_type == "ACCESS_DENIED"
  and (.sources.internal_ngwaf_sites.internal_ngwaf_error_reason | test("access was denied"))
  and (.sources.internal_ngwaf_sites.internal_ngwaf_recommended_action | test("permissions"))
' >/dev/null <<<"$access_denied_sites"

export FASTLY_TEST_LEGACY_MAP_MODE=sites-404
not_found_sites="$("$ROOT/fastly-audit" security legacy-map cdn-prod --format json 2>"$TEST_TMP/sites-404-json-err")"
not_found_human="$("$ROOT/fastly-audit" security legacy-map cdn-prod 2>"$TEST_TMP/sites-404-human-err")"
unset FASTLY_TEST_LEGACY_MAP_MODE
jq -e '
  .sources.internal_ngwaf_sites.internal_ngwaf_http_status == 404
  and .sources.internal_ngwaf_sites.internal_ngwaf_error_type == "NOT_FOUND"
  and (.sources.internal_ngwaf_sites.internal_ngwaf_error_reason | test("not found"))
  and .sources.internal_ngwaf_sites.internal_ngwaf_recommended_action == null
' >/dev/null <<<"$not_found_sites"
grep -F 'Internal NGWAF request problem' <<<"$not_found_human" >/dev/null
grep -F 'HTTP 404 from internal NGWAF API' <<<"$not_found_human" >/dev/null
! grep -F 'refresh FASTLY_DSTOKEN' <<<"$not_found_human" >/dev/null
! grep -F 'refresh FASTLY_VOUCH_COOKIE' <<<"$not_found_human" >/dev/null

export FASTLY_TEST_LEGACY_MAP_MODE=sites-500
server_error_sites="$("$ROOT/fastly-audit" security legacy-map cdn-prod --format json 2>"$TEST_TMP/sites-500-err")"
unset FASTLY_TEST_LEGACY_MAP_MODE
jq -e '
  .sources.internal_ngwaf_sites.internal_ngwaf_http_status == 500
  and .sources.internal_ngwaf_sites.internal_ngwaf_error_type == "HTTP_ERROR"
  and (.sources.internal_ngwaf_sites.reason | test("HTTP 500"))
  and (.mappings[0].reason | test("HTTP 500"))
' >/dev/null <<<"$server_error_sites"

for artifact in "$auth_failed_sites" "$access_denied_sites" "$not_found_sites" "$server_error_sites"; do
  ! grep -F 'secret-dstoken' <<<"$artifact" >/dev/null
  ! grep -F 'secret-vouch' <<<"$artifact" >/dev/null
done

export FASTLY_TEST_LEGACY_MAP_MODE=ess-lookup-fail
failed_ess="$(FASTLY_AUDIT_LEGACY_MAP_TRACE=1 "$ROOT/fastly-audit" security legacy-map prod-is --format json 2>"$TEST_TMP/ess-fail-err")"
unset FASTLY_TEST_LEGACY_MAP_MODE
jq -e '
  .mappings[0].status == "UNKNOWN"
  and .mappings[0].evidence_type == "UNKNOWN"
  and (.mappings[0].reason | test("direct Fastly Inspection Service lookups were unavailable"))
  and (.mappings[0].lookup_failures | length) == 1
  and .mappings[0].lookup_failures[0].serviceID == "NqBYffdR4mOhuGwMfOnldY"
  and (.mappings[0].lookup_failures[0].reason | test("HTTP 503"))
' >/dev/null <<<"$failed_ess"
grep -F 'direct lookup failures: 1' "$TEST_TMP/ess-fail-err" >/dev/null
grep -F 'worker process failures: 1' "$TEST_TMP/ess-fail-err" >/dev/null
! grep -F 'secret-dstoken' "$TEST_TMP/ess-fail-err" >/dev/null
! grep -F 'secret-vouch' "$TEST_TMP/ess-fail-err" >/dev/null

csv="$("$ROOT/fastly-audit" security legacy-map cdn-prod --format csv 2>"$TEST_TMP/csv-err")"
grep -F '"cdn_service","service_id","active_version","inspection_service_host","inspection_service_id","workspace","evidence","status","reason"' <<<"$csv" >/dev/null
grep -F '"prd-usbcwww","cdn-prod","10","se--costco--prod.edgecompute.app","ess-prod","gdx-costco-prd-is","DIRECT","CONFIRMED"' <<<"$csv" >/dev/null
! grep -F $'\033[' <<<"$csv" >/dev/null
! grep -F 'secret-dstoken' <<<"$csv" >/dev/null
! grep -F 'secret-vouch' <<<"$csv" >/dev/null

out_file="$TEST_TMP/legacy-map-output.json"
written="$("$ROOT/fastly-audit" security legacy-map cdn-prod --format json --output "$out_file" 2>"$TEST_TMP/output-err")"
[[ -z "$written" ]]
[[ -s "$out_file" ]]
jq -e '.mappings[0].status == "CONFIRMED"' "$out_file" >/dev/null
grep -F 'wrote 1 legacy-map row' "$TEST_TMP/output-err" >/dev/null
if "$ROOT/fastly-audit" security legacy-map cdn-prod --format json --output "$out_file" >"$TEST_TMP/overwrite-out" 2>"$TEST_TMP/overwrite-err"; then
  printf 'legacy-map test: overwrite unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'refusing to overwrite existing legacy-map output' "$TEST_TMP/overwrite-err" >/dev/null

printf 'legacy-map: OK\n'
