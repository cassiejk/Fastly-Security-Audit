#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
fail() { printf 'ngwaf-architecture: %s\n' "$1" >&2; exit 1; }
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
printf '%s\n' "$url" >>"$ARCH_CURL_LOG"
mode="${ARCH_MODE:-true}" status=200
case "$url" in
  */customer/customer-a) printf '%s\n' '{"id":"customer-a","name":"Customer A"}' >"$outfile" ;;
  */service/Service%20A) status=404; printf '%s\n' '{"title":"Not Found"}' >"$outfile" ;;
  */service) printf '%s\n' '{"meta":{"total":1},"data":[{"id":"aaaaaaaaaaaaaaaaaaaaaa","name":"Service A","type":"vcl","customer_id":"customer-a"}]}' >"$outfile" ;;
  */service/aaaaaaaaaaaaaaaaaaaaaa)
    case "$mode" in
      compute) kind=wasm; owner=customer-a; version='"active_version":7,' ;;
      no-active|fallback|fallback-ambiguous|fallback-conflict|fallback-duplicate|fallback-malformed|fallback-http|product-400) kind=vcl; owner=customer-a; version='"version":99,' ;;
      active-object) kind=vcl; owner=customer-a; version='"active_version":{"number":7},' ;;
      active-conflict) kind=vcl; owner=customer-a; version='"active_version":{"number":7,"active":false},' ;;
      foreign) kind=vcl; owner=customer-b; version='"active_version":7,' ;;
      *) kind=vcl; owner=customer-a; version='"active_version":7,' ;;
    esac
    printf '{"id":"aaaaaaaaaaaaaaaaaaaaaa","name":"Service A","customer_id":"%s","type":"%s",%s"paused":false}\n' "$owner" "$kind" "$version" >"$outfile" ;;
  */service/aaaaaaaaaaaaaaaaaaaaaa/version)
    case "$mode" in
      fallback|product-400) printf '%s\n' '[{"number":7,"active":true,"service_id":"aaaaaaaaaaaaaaaaaaaaaa"},{"number":99,"active":false,"service_id":"aaaaaaaaaaaaaaaaaaaaaa"}]' >"$outfile" ;;
      fallback-ambiguous) printf '%s\n' '[{"number":7,"active":true,"service_id":"aaaaaaaaaaaaaaaaaaaaaa"},{"number":8,"active":true,"service_id":"aaaaaaaaaaaaaaaaaaaaaa"}]' >"$outfile" ;;
      fallback-conflict) printf '%s\n' '[{"number":7,"active":true,"service_id":"bbbbbbbbbbbbbbbbbbbbbb"}]' >"$outfile" ;;
      fallback-duplicate) printf '%s\n' '[{"number":7,"active":true,"service_id":"aaaaaaaaaaaaaaaaaaaaaa"},{"number":7,"active":false,"service_id":"aaaaaaaaaaaaaaaaaaaaaa"}]' >"$outfile" ;;
      fallback-malformed) printf '%s\n' '{"data":[]}' >"$outfile" ;;
      fallback-http) status=503; printf '%s\n' '{"title":"Unavailable"}' >"$outfile" ;;
      *) printf '%s\n' '[{"number":7,"active":false,"service_id":"aaaaaaaaaaaaaaaaaaaaaa"}]' >"$outfile" ;;
    esac ;;
  */enabled-products/v1/ngwaf/services/aaaaaaaaaaaaaaaaaaaaaa)
    case "$mode" in
      unverified) status=404; printf '%s\n' '{"title":"Not Found"}' >"$outfile" ;;
      product-400) status=400; printf '%s\n' '{"title":"Bad Request"}' >"$outfile" ;;
      product-foreign) printf '%s\n' '{"customer_id":"customer-b"}' >"$outfile" ;;
      product-disabled) printf '%s\n' '{"enabled":false}' >"$outfile" ;;
      *) printf '%s\n' '{}' >"$outfile" ;;
    esac ;;
  */service/aaaaaaaaaaaaaaaaaaaaaa/version/*/generated_vcl)
    case "$mode" in
      true|active-object|unverified|product-foreign|product-disabled|historical|fallback|product-400)
        jq -n --arg content $'sub vcl_recv {\n  set req.http.token = "sensitive-value";\n  pragma optional_param ngwaf_oob_enabled = true;\n  return(pass);\n}' '{content:$content}' >"$outfile" ;;
      false) jq -n --arg content $'sub vcl_recv {\n pragma optional_param\n   ngwaf_oob_enabled\n = false ;\n}' '{content:$content}' >"$outfile" ;;
      absent) printf '%s\n' '{"content":"sub vcl_recv { return(pass); }"}' >"$outfile" ;;
      comment) printf '%s\n' '{"content":"# pragma optional_param ngwaf_oob_enabled = true;\n/* pragma optional_param ngwaf_oob_enabled = false; */"}' >"$outfile" ;;
      string) printf '%s\n' '{"content":"set req.http.X = \"pragma optional_param ngwaf_oob_enabled = true;\";"}' >"$outfile" ;;
      long-string) jq -n --arg content $'set req.http.X = {"pragma optional_param ngwaf_oob_enabled = true;"};' '{content:$content}' >"$outfile" ;;
      tagged-long-string) jq -n --arg content $'set req.http.X = {tag"pragma optional_param ngwaf_oob_enabled = true;"tag};' '{content:$content}' >"$outfile" ;;
      multiple) printf '%s\n' '{"content":"pragma optional_param ngwaf_oob_enabled = true;\npragma optional_param ngwaf_oob_enabled = true;"}' >"$outfile" ;;
      conflict) printf '%s\n' '{"content":"pragma optional_param ngwaf_oob_enabled = true;\npragma optional_param ngwaf_oob_enabled = false;"}' >"$outfile" ;;
      invalid-value) printf '%s\n' '{"content":"pragma optional_param ngwaf_oob_enabled = maybe;"}' >"$outfile" ;;
      unrelated-identifier) printf '%s\n' '{"content":"pragma optional_param other_ngwaf_oob_enabled = true;"}' >"$outfile" ;;
      missing-content) printf '%s\n' '{}' >"$outfile" ;;
      empty-content) printf '%s\n' '{"content":""}' >"$outfile" ;;
      mismatched-vcl) printf '%s\n' '{"service_id":"bbbbbbbbbbbbbbbbbbbbbb","content":"pragma optional_param ngwaf_oob_enabled = true;"}' >"$outfile" ;;
      vcl-error) status=503; printf '%s\n' '{"title":"Unavailable"}' >"$outfile" ;;
      *) printf '%s\n' '{"content":""}' >"$outfile" ;;
    esac ;;
  *) status=599; printf '%s\n' '{"title":"unexpected endpoint"}' >"$outfile" ;;
esac
printf '%s' "$status"
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"
export PATH="$TEST_TMP/bin:$PATH" FASTLY_API_TOKEN=fake-token FASTLY_CUSTOMER_ID=customer-a
export XDG_CONFIG_HOME="$TEST_TMP/config" NGWAF_COLOR=never NGWAF_PROGRESS=never NGWAF_CURL_RETRIES=0
export ARCH_CURL_LOG="$TEST_TMP/calls"
sid=aaaaaaaaaaaaaaaaaaaaaa
run_case() {
  export ARCH_MODE="$1"
  : >"$ARCH_CURL_LOG"
  "$ROOT/fastly-audit" service ngwaf-architecture "$sid" --json >"$TEST_TMP/result.json" 2>"$TEST_TMP/err" || { cat "$TEST_TMP/err" >&2; fail "$1 failed"; }
  jq -e '.service.id == "aaaaaaaaaaaaaaaaaaaaaa" and .service.name == "Service A"' "$TEST_TMP/result.json" >/dev/null
  ! rg -q '/search/services|/service$|/ngwaf/v1/workspaces|/sites|/agents' "$ARCH_CURL_LOG" || fail 'broad or unrelated request made'
  [[ "$(rg -c '/service/aaaaaaaaaaaaaaaaaaaaaa$' "$ARCH_CURL_LOG")" == 1 ]] || fail 'service detail requested more than once'
}
run_case true
[[ "$(wc -l <"$ARCH_CURL_LOG" | tr -d ' ')" == 4 ]] || fail 'exact CDN service made an unexpected number of requests'
run_case active-object
jq -e '.service.active_version == 7 and .ngwaf_architecture.inspection_architecture == "out_of_band"' "$TEST_TMP/result.json" >/dev/null
run_case true
jq -e '.ngwaf_architecture.deployment_status == "CONFIRMED" and .ngwaf_architecture.inspection_architecture == "out_of_band" and .ngwaf_architecture.parameter.declarations[0].line_start == 3 and .ngwaf_architecture.parameter.declarations[0].raw_text == "pragma optional_param ngwaf_oob_enabled = true;"' "$TEST_TMP/result.json" >/dev/null
[[ "$(rg -c '/generated_vcl$' "$ARCH_CURL_LOG")" == 1 ]] || fail 'VCL requested more than once'
! rg -q 'sensitive-value|fake-token' "$TEST_TMP/result.json" "$TEST_TMP/err" || fail 'unrelated sensitive VCL or token leaked'
: >"$ARCH_CURL_LOG"
"$ROOT/fastly-audit" service ngwaf-architecture 'Service A' --json >"$TEST_TMP/by-name.json" 2>"$TEST_TMP/err" || fail 'exact service name failed'
jq -e '.service.id == "aaaaaaaaaaaaaaaaaaaaaa" and .ngwaf_architecture.inspection_architecture == "out_of_band"' "$TEST_TMP/by-name.json" >/dev/null
[[ "$(wc -l <"$ARCH_CURL_LOG" | tr -d ' ')" == 6 ]] || fail 'name resolution made an unexpected number of requests'
"$ROOT/fastly-audit" service ngwaf-architecture "$sid" >"$TEST_TMP/default-human" 2>"$TEST_TMP/err"
rg -q 'Actual Generated VCL .*pragma optional_param ngwaf_oob_enabled = true;' "$TEST_TMP/default-human" || fail 'default human output omitted raw VCL evidence'
"$ROOT/fastly-audit" service ngwaf-architecture "$sid" --show-vcl >"$TEST_TMP/human" 2>"$TEST_TMP/err"
rg -q 'Actual Generated VCL .*pragma optional_param ngwaf_oob_enabled = true;' "$TEST_TMP/human" || { cat "$TEST_TMP/human" >&2; fail 'human evidence missing'; }
rg -q 'Line 1: sub vcl_recv' "$TEST_TMP/human" || fail '--show-vcl did not expand context'
! rg -q 'Line 1: sub vcl_recv' "$TEST_TMP/default-human" || fail 'default context was not narrower'
! rg -q 'sensitive-value' "$TEST_TMP/human" || fail 'context leaked sensitive value'
run_case false
jq -e '.ngwaf_architecture.inspection_architecture == "in_band" and .ngwaf_architecture.parameter.declarations[0].line_start == 2 and .ngwaf_architecture.parameter.declarations[0].line_end == 4 and .ngwaf_architecture.parameter.declarations[0].value == false' "$TEST_TMP/result.json" >/dev/null
run_case absent
jq -e '.ngwaf_architecture.parameter.status == "ABSENT" and .ngwaf_architecture.inspection_architecture == "in_band" and .ngwaf_architecture.evidence.line_count == 1 and .ngwaf_architecture.parameter.declarations == []' "$TEST_TMP/result.json" >/dev/null
for mode in comment string long-string tagged-long-string; do
  run_case "$mode"
  jq -e '.ngwaf_architecture.parameter.status == "ABSENT"' "$TEST_TMP/result.json" >/dev/null
done
for mode in multiple conflict; do
  run_case "$mode"
  jq -e '.ngwaf_architecture.parameter.status == "AMBIGUOUS" and .ngwaf_architecture.inspection_architecture == "unknown" and (.ngwaf_architecture.parameter.declarations | length) == 2' "$TEST_TMP/result.json" >/dev/null
done
run_case invalid-value
jq -e '.ngwaf_architecture.parameter.status == "AMBIGUOUS" and .ngwaf_architecture.inspection_architecture == "unknown"' "$TEST_TMP/result.json" >/dev/null
run_case unrelated-identifier
jq -e '.ngwaf_architecture.parameter.status == "ABSENT"' "$TEST_TMP/result.json" >/dev/null
for mode in missing-content empty-content mismatched-vcl vcl-error; do
  export ARCH_MODE="$mode"
  : >"$ARCH_CURL_LOG"
  if "$ROOT/fastly-audit" service ngwaf-architecture "$sid" --json >"$TEST_TMP/result.json" 2>"$TEST_TMP/err"; then fail "$mode should fail"; fi
  jq -e '.ngwaf_architecture.parameter.status == "UNKNOWN" and .ngwaf_architecture.inspection_architecture == "unknown"' "$TEST_TMP/result.json" >/dev/null
done
export ARCH_MODE=no-active
: >"$ARCH_CURL_LOG"
if "$ROOT/fastly-audit" service ngwaf-architecture "$sid" --json >"$TEST_TMP/result.json" 2>"$TEST_TMP/err"; then fail 'missing active version should fail'; fi
jq -e '.service.active_version == null and .ngwaf_architecture.parameter.status == "UNKNOWN" and .service.active_version_resolution.status == "UNRESOLVED"' "$TEST_TMP/result.json" >/dev/null
! rg -q '/generated_vcl$' "$ARCH_CURL_LOG" || fail 'generated VCL requested without active version'
rg -q 'Skipping generated VCL' "$TEST_TMP/err" || fail 'missing active version did not report skipped VCL phase'
[[ "$(rg -c '/service/aaaaaaaaaaaaaaaaaaaaaa/version$' "$ARCH_CURL_LOG")" == 1 ]] || fail 'version fallback not requested exactly once'
run_case fallback
jq -e '.service.active_version == 7 and .service.active_version_resolution.source == "GET /service/{service_id}/version" and .ngwaf_architecture.evidence.endpoint == "/service/aaaaaaaaaaaaaaaaaaaaaa/version/7/generated_vcl" and .ngwaf_architecture.parameter.value == true' "$TEST_TMP/result.json" >/dev/null
[[ "$(wc -l <"$ARCH_CURL_LOG" | tr -d ' ')" == 5 ]] || fail 'fallback added an unexpected number of requests'
run_case product-400
jq -e '.ngwaf_architecture.deployment_status == "UNVERIFIED" and .ngwaf_architecture.inspection_architecture == "unknown" and .ngwaf_architecture.parameter.value == true and .ngwaf_architecture.evidence.retrieval_status == "COMPLETE" and .ngwaf_architecture.deployment_evidence.http_status == 400' "$TEST_TMP/result.json" >/dev/null
rg -q 'Retrieving the selected generated VCL' "$TEST_TMP/err" || fail 'VCL phase not reported on product HTTP 400'
[[ "$(rg -n '/generated_vcl$' "$ARCH_CURL_LOG" | cut -d: -f1)" -lt "$(rg -n '/enabled-products/' "$ARCH_CURL_LOG" | cut -d: -f1)" ]] || fail 'VCL retrieval did not precede product check'
[[ ! -s "$TEST_TMP/result.json" ]] && fail 'product HTTP 400 lost JSON output'
! rg -q '\[[123]/3\]|Active Version:|VCL Retrieval:' "$TEST_TMP/result.json" || fail 'progress leaked to JSON stdout'
export ARCH_MODE=active-conflict
: >"$ARCH_CURL_LOG"
if "$ROOT/fastly-audit" service ngwaf-architecture "$sid" --json >"$TEST_TMP/result.json" 2>"$TEST_TMP/err"; then fail 'conflicting detail version should fail'; fi
jq -e '.service.active_version_resolution.status == "CONFLICT" and .service.active_version == null' "$TEST_TMP/result.json" >/dev/null
! rg -q '/version$|/generated_vcl$' "$ARCH_CURL_LOG" || fail 'conflicting detail evidence was overridden'
for mode in fallback-ambiguous fallback-conflict fallback-duplicate fallback-malformed fallback-http; do
  export ARCH_MODE="$mode"
  : >"$ARCH_CURL_LOG"
  if "$ROOT/fastly-audit" service ngwaf-architecture "$sid" --json >"$TEST_TMP/result.json" 2>"$TEST_TMP/err"; then fail "$mode should fail"; fi
  jq -e '.service.active_version == null and .service.active_version_resolution.status == "UNRESOLVED"' "$TEST_TMP/result.json" >/dev/null
  if [[ "$mode" == fallback-http ]]; then
    jq -e '.service.active_version_resolution.http_status == 503' "$TEST_TMP/result.json" >/dev/null
  fi
  ! rg -q '/generated_vcl$' "$ARCH_CURL_LOG" || fail "$mode requested VCL without active version"
done
run_case unverified
jq -e '.ngwaf_architecture.parameter.value == true and .ngwaf_architecture.deployment_type == null and .ngwaf_architecture.deployment_status == "UNVERIFIED" and .ngwaf_architecture.inspection_architecture == "unknown"' "$TEST_TMP/result.json" >/dev/null
run_case product-foreign
jq -e '.ngwaf_architecture.deployment_status == "UNVERIFIED" and .ngwaf_architecture.inspection_architecture == "unknown"' "$TEST_TMP/result.json" >/dev/null
run_case product-disabled
jq -e '.ngwaf_architecture.deployment_status == "UNVERIFIED" and .ngwaf_architecture.inspection_architecture == "unknown"' "$TEST_TMP/result.json" >/dev/null
run_case compute
jq -e '.ngwaf_architecture.deployment_status == "CONFIRMED" and .ngwaf_architecture.inspection_architecture == "out_of_band" and .ngwaf_architecture.evidence.retrieval_status == "NOT_APPLICABLE"' "$TEST_TMP/result.json" >/dev/null
! rg -q '/generated_vcl$' "$ARCH_CURL_LOG" || fail 'Compute generated VCL requested'
[[ "$(wc -l <"$ARCH_CURL_LOG" | tr -d ' ')" == 3 ]] || fail 'Compute service made an unexpected number of requests'
run_case historical
"$ROOT/fastly-audit" service ngwaf-architecture "$sid" --version 6 --json >"$TEST_TMP/result.json" 2>"$TEST_TMP/err"
jq -e '.service.inspected_version == 6 and .service.active_version == 7 and .service.inspected_version_is_active == false and .ngwaf_architecture.deployment_status == "UNVERIFIED" and .ngwaf_architecture.parameter.value == true' "$TEST_TMP/result.json" >/dev/null
ARCH_MODE=foreign
: >"$ARCH_CURL_LOG"
if "$ROOT/fastly-audit" service ngwaf-architecture "$sid" --json >"$TEST_TMP/foreign.json" 2>"$TEST_TMP/err"; then fail 'foreign service accepted'; fi
[[ ! -s "$TEST_TMP/foreign.json" ]] || fail 'foreign service emitted JSON'
! rg -q '/enabled-products|/generated_vcl' "$ARCH_CURL_LOG" || fail 'foreign service queried beyond detail'
printf 'ngwaf-architecture: OK\n'
