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
if [[ -n "${FASTLY_TEST_VCL_SIZE_CURL_ARGS:-}" ]]; then
  printf '%s\n' "$@" >>"$FASTLY_TEST_VCL_SIZE_CURL_ARGS"
fi
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

write_content() {
  local content="$1"
  jq -n --arg content "$content" '{content: $content}' >"$outfile"
}

status=200
case "$url" in
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    ;;
  */service)
    printf '%s\n' '[
      {"id":"service-large","name":"large.example.com","customer_id":"test-customer","type":"vcl","active_version":5,"paused":false},
      {"id":"service-small","name":"small.example.com","customer_id":"test-customer","type":"vcl","active_version":{"number":3},"paused":false},
      {"id":"service-trailing","name":"trailing.example.com","customer_id":"test-customer","type":"vcl","active_version":6,"paused":false},
      {"id":"service-empty","name":"empty.example.com","customer_id":"test-customer","type":"vcl","active_version":7,"paused":false},
      {"id":"service-fail","name":"fail.example.com","customer_id":"test-customer","type":"vcl","active_version":8,"paused":false},
      {"id":"service-malformed","name":"malformed.example.com","customer_id":"test-customer","type":"vcl","active_version":9,"paused":false},
      {"id":"service-missing-version","name":"missing-version.example.com","customer_id":"test-customer","type":"vcl","paused":false},
      {"id":"service-compute","name":"compute.example.com","customer_id":"test-customer","type":"wasm","active_version":2,"paused":false},
      {"id":"other-vcl","name":"other.example.com","customer_id":"other-customer","type":"vcl","active_version":1,"paused":false}
    ]' >"$outfile"
    ;;
  */service/service-small/version/3/generated_vcl)
    write_content $'secret_vcl_marker\n'
    ;;
  */service/service-large/version/5/generated_vcl)
    write_content $'0123456789\n0123456789\n'
    ;;
  */service/service-trailing/version/6/generated_vcl)
    write_content $'a\nb\n'
    ;;
  */service/service-empty/version/7/generated_vcl)
    write_content ''
    ;;
  */service/service-fail/version/8/generated_vcl)
    printf '%s\n' '{"error":"temporarily unavailable"}' >"$outfile"
    status=503
    ;;
  */service/service-malformed/version/9/generated_vcl)
    printf '%s\n' '{"not_content":"oops"}' >"$outfile"
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
export FASTLY_TEST_VCL_SIZE_CURL_ARGS="$TEST_TMP/curl-args"

"$ROOT/fastly-audit" service help >"$TEST_TMP/service-help"
grep -F 'vcl-size <service>' "$TEST_TMP/service-help" >/dev/null
"$ROOT/fastly-audit" customer help >"$TEST_TMP/customer-help"
grep -F 'vcl-size [--json]' "$TEST_TMP/customer-help" >/dev/null

: >"$FASTLY_TEST_VCL_SIZE_CURL_ARGS"
single="$("$ROOT/fastly-audit" service vcl-size small.example.com --json 2>"$TEST_TMP/single-err")"
jq -e '
  .command == "service vcl-size"
  and .service.id == "service-small"
  and .service.active_version == "3"
  and .service.generated_vcl.status == "COMPLETE"
  and .service.generated_vcl.evidence_type == "DIRECT"
  and .service.generated_vcl.source == "GET /service/{service_id}/version/{version}/generated_vcl"
  and .service.generated_vcl.endpoint == "/service/service-small/version/3/generated_vcl"
  and .service.generated_vcl.measurements.evidence_type == "DERIVED"
  and .service.generated_vcl.measurements.bytes == 18
  and .service.generated_vcl.measurements.lines == 1
  and .service.generated_vcl.measurements.kib == 0.02
' >/dev/null <<<"$single"
! grep -F 'secret_vcl_marker' <<<"$single" >/dev/null
grep -F '/service/service-small/version/3/generated_vcl' "$FASTLY_TEST_VCL_SIZE_CURL_ARGS" >/dev/null

"$ROOT/fastly-audit" service vcl-size service-small >"$TEST_TMP/single-human" 2>"$TEST_TMP/single-human-err"
grep -F 'Generated VCL' "$TEST_TMP/single-human" >/dev/null
grep -F 'Status: COMPLETE' "$TEST_TMP/single-human" >/dev/null
! grep -F 'secret_vcl_marker' "$TEST_TMP/single-human" >/dev/null

trailing="$("$ROOT/fastly-audit" service vcl-size service-trailing --json 2>"$TEST_TMP/trailing-err")"
jq -e '
  .service.generated_vcl.status == "COMPLETE"
  and .service.generated_vcl.measurements.bytes == 4
  and .service.generated_vcl.measurements.lines == 2
' >/dev/null <<<"$trailing"

empty="$("$ROOT/fastly-audit" service vcl-size service-empty --json 2>"$TEST_TMP/empty-err")"
jq -e '
  .service.generated_vcl.status == "COMPLETE"
  and .service.generated_vcl.evidence_type == "DIRECT"
  and .service.generated_vcl.measurements.bytes == 0
  and .service.generated_vcl.measurements.lines == 0
  and .service.generated_vcl.measurements.kib == 0
' >/dev/null <<<"$empty"

fail="$("$ROOT/fastly-audit" service vcl-size service-fail --json 2>"$TEST_TMP/fail-err")"
jq -e '
  .service.generated_vcl.status == "UNKNOWN"
  and .service.generated_vcl.evidence_type == "UNKNOWN"
  and .service.generated_vcl.measurements.bytes == null
  and .service.generated_vcl.measurements.lines == null
  and (.service.generated_vcl.reason | contains("HTTP 503"))
' >/dev/null <<<"$fail"

malformed="$("$ROOT/fastly-audit" service vcl-size service-malformed --json 2>"$TEST_TMP/malformed-err")"
jq -e '
  .service.generated_vcl.status == "UNKNOWN"
  and .service.generated_vcl.measurements.bytes == null
  and (.service.generated_vcl.reason | contains("supported content string"))
' >/dev/null <<<"$malformed"

: >"$FASTLY_TEST_VCL_SIZE_CURL_ARGS"
missing_version="$("$ROOT/fastly-audit" service vcl-size service-missing-version --json 2>"$TEST_TMP/missing-version-err")"
jq -e '
  .service.generated_vcl.status == "UNKNOWN"
  and .service.active_version == null
  and (.service.generated_vcl.reason | contains("active version"))
  and .service.generated_vcl.measurements.bytes == null
' >/dev/null <<<"$missing_version"
! grep -F '/service/service-missing-version/version/' "$FASTLY_TEST_VCL_SIZE_CURL_ARGS" >/dev/null

: >"$FASTLY_TEST_VCL_SIZE_CURL_ARGS"
compute="$("$ROOT/fastly-audit" service vcl-size service-compute --json 2>"$TEST_TMP/compute-err")"
jq -e '
  .service.type == "wasm"
  and .service.generated_vcl.status == "NOT_APPLICABLE"
  and .service.generated_vcl.evidence_type == "INFORMATIONAL"
  and .service.generated_vcl.measurements.bytes == null
' >/dev/null <<<"$compute"
! grep -F 'generated_vcl' "$FASTLY_TEST_VCL_SIZE_CURL_ARGS" >/dev/null

: >"$FASTLY_TEST_VCL_SIZE_CURL_ARGS"
customer="$("$ROOT/fastly-audit" customer vcl-size --json 2>"$TEST_TMP/customer-err")"
jq -e '
  .command == "customer vcl-size"
  and .summary.total_token_visible_services == 8
  and .summary.vcl_services == 7
  and .summary.measured == 4
  and .summary.unknown == 3
  and .summary.compute_skipped == 1
  and all(.services[]; .id != "other-vcl")
  and ([.services[] | select(.generated_vcl.status == "COMPLETE") | .generated_vcl.measurements.bytes] == [22,18,4,0])
  and any(.services[]; .id == "service-compute" and .generated_vcl.status == "NOT_APPLICABLE")
  and any(.services[]; .id == "service-fail" and .generated_vcl.status == "UNKNOWN")
  and any(.services[]; .id == "service-malformed" and .generated_vcl.status == "UNKNOWN")
  and any(.services[]; .id == "service-missing-version" and .generated_vcl.status == "UNKNOWN")
' >/dev/null <<<"$customer"
! grep -F 'secret_vcl_marker' <<<"$customer" >/dev/null
grep -F '/service/service-large/version/5/generated_vcl' "$FASTLY_TEST_VCL_SIZE_CURL_ARGS" >/dev/null
! grep -F '/service/service-compute/version/2/generated_vcl' "$FASTLY_TEST_VCL_SIZE_CURL_ARGS" >/dev/null
! grep -F '/service/other-vcl/version/1/generated_vcl' "$FASTLY_TEST_VCL_SIZE_CURL_ARGS" >/dev/null

"$ROOT/fastly-audit" customer vcl-size >"$TEST_TMP/customer-human" 2>"$TEST_TMP/customer-human-err"
grep -F 'VCL services measured: 4' "$TEST_TMP/customer-human" >/dev/null
grep -F 'Unknown: 3' "$TEST_TMP/customer-human" >/dev/null
grep -F 'Compute skipped: 1' "$TEST_TMP/customer-human" >/dev/null
large_line="$(grep -nF 'large.example.com' "$TEST_TMP/customer-human" | head -n1 | cut -d: -f1)"
small_line="$(grep -nF 'small.example.com' "$TEST_TMP/customer-human" | head -n1 | cut -d: -f1)"
[[ -n "$large_line" && -n "$small_line" && "$large_line" -lt "$small_line" ]]
grep -F 'UNKNOWN' "$TEST_TMP/customer-human" >/dev/null
! grep -F 'secret_vcl_marker' "$TEST_TMP/customer-human" >/dev/null

printf 'vcl-size: OK\n'
