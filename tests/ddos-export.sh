#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/config"

cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

outfile=''
url=''
cursor=''
args_file="${FASTLY_TEST_DDOS_EXPORT_CURL_ARGS:?}"
{
  printf '%s\n' '--- request ---'
  for arg in "$@"; do
    printf '%s\n' "${arg//test-token-secret/[redacted]}"
  done
} >>"$args_file"

while (( $# > 0 )); do
  case "$1" in
    -o)
      outfile="$2"
      shift 2
      ;;
    --data-urlencode)
      case "$2" in
        cursor=*) cursor="${2#cursor=}" ;;
      esac
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

event_id_from_url() {
  local path="${url##*/events/}"
  printf '%s\n' "${path%%/*}"
}

rule_id_from_url() {
  local path="${url##*/rules/}"
  printf '%s\n' "${path%%/*}"
}

write_event() {
  local event_id
  event_id="$(event_id_from_url)"
  case "${FASTLY_TEST_DDOS_EXPORT_MODE:-success}" in
    event-id-mismatch)
      event_id='different-event'
      ;;
    customer-mismatch)
      jq -n --arg id "$event_id" '{
        id: $id,
        customer_id: "other-customer",
        service_id: "service-1",
        started_at: "2026-09-22T00:00:00Z"
      }' >"$outfile"
      printf '200'
      return
      ;;
    missing-identifiers)
      jq -n --arg id "$event_id" '{id: $id, started_at: "2026-09-22T00:00:00Z"}' >"$outfile"
      printf '200'
      return
      ;;
    malformed-event)
      printf '%s\n' '{"id":' >"$outfile"
      printf '200'
      return
      ;;
    auth-failure)
      printf '%s\n' '{"detail":"authentication failed"}' >"$outfile"
      printf '401'
      return
      ;;
    rate-limit)
      printf '%s\n' '{"detail":"rate limited"}' >"$outfile"
      printf '429'
      return
      ;;
  esac

  jq -n --arg id "$event_id" '{
    id: $id,
    customer_id: "test-customer",
    service_id: "service-1",
    started_at: "2026-09-22T00:00:00Z",
    ended_at: null,
    created_at: "2026-09-22T00:01:00Z",
    requests_detected: 0,
    requests_allowed: 42
  }' >"$outfile"
  printf '200'
}

write_event_rules() {
  case "${FASTLY_TEST_DDOS_EXPORT_MODE:-success}" in
    no-rules)
      printf '%s\n' '{"meta":{"next_cursor":null},"data":[]}' >"$outfile"
      ;;
    multi-page)
      if [[ -z "$cursor" ]]; then
        printf '%s\n' '{"meta":{"next_cursor":"cursor-2"},"data":[{"id":"rule-a","action":"block","asn":"64500","traffic_percentage":12.5}]}' >"$outfile"
      else
        printf '%s\n' '{"meta":{},"data":[{"rule_id":"rule-b","action":"log","country_code":"US","additional_attributes":["method_path"]}]}' >"$outfile"
      fi
      ;;
    repeated-cursor)
      if [[ -z "$cursor" ]]; then
        printf '%s\n' '{"meta":{"next_cursor":"cursor-loop"},"data":[{"id":"rule-a"}]}' >"$outfile"
      else
        printf '%s\n' '{"meta":{"next_cursor":"cursor-loop"},"data":[{"id":"rule-b"}]}' >"$outfile"
      fi
      ;;
    duplicate-rules)
      printf '%s\n' '{"meta":{},"data":[{"id":"rule-a"},{"rule_id":"rule-a"}]}' >"$outfile"
      ;;
    missing-rule-id)
      printf '%s\n' '{"meta":{},"data":[{"action":"block"}]}' >"$outfile"
      ;;
    invalid-pagination)
      printf '%s\n' '{"meta":{"next_cursor":{"bad":true}},"data":[{"id":"rule-a"}]}' >"$outfile"
      ;;
    *)
      printf '%s\n' '{"meta":{},"data":[{"id":"rule-a","action":"block","source_ip":"203.0.113.10","traffic_percentage":33.3}]}' >"$outfile"
      ;;
  esac
  printf '200'
}

write_rule_detail() {
  local rule_id
  rule_id="$(rule_id_from_url)"
  jq -n --arg id "$rule_id" '{
    id: $id,
    service_id: "service-1",
    action: "default",
    host: "www.example.test",
    source_ip_prefix: "203.0.113.0/24"
  }' >"$outfile"
  printf '200'
}

write_traffic_stats() {
  local rule_id
  rule_id="$(rule_id_from_url)"
  if [[ "${FASTLY_TEST_DDOS_EXPORT_MODE:-success}" == 'traffic-failure' ]]; then
    printf '%s\n' '{"detail":"traffic stats unavailable"}' >"$outfile"
    printf '503'
    return
  fi

  jq -n --arg id "$rule_id" '{
    traffic_stats: [
      {name: "source_ip", values: ["203.0.113.10"], percentage: 80},
      {name: "method_path", values: ["GET /"], percentage: 20}
    ],
    rule_id: $id,
    traffic_percentage: 33.3
  }' >"$outfile"
  printf '200'
}

case "$url" in
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    printf '200'
    ;;
  */ddos-protection/v1/events/*/rules/*/traffic-stats)
    write_traffic_stats
    ;;
  */ddos-protection/v1/events/*/rules)
    write_event_rules
    ;;
  */ddos-protection/v1/rules/*)
    write_rule_detail
    ;;
  */ddos-protection/v1/events/*)
    write_event
    ;;
  */service/service-1)
    printf '%s\n' '{"id":"service-1","name":"Example service","customer_id":"test-customer","type":"vcl"}' >"$outfile"
    printf '200'
    ;;
  *)
    printf '%s\n' '{"error":"unhandled fake endpoint"}' >"$outfile"
    printf '404'
    ;;
esac
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"

export PATH="$TEST_TMP/bin:$PATH"
export XDG_CONFIG_HOME="$TEST_TMP/config"
export FASTLY_API_TOKEN='test-token-secret'
export FASTLY_CUSTOMER_ID='test-customer'
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0
export FASTLY_TEST_DDOS_EXPORT_CURL_ARGS="$TEST_TMP/curl-args"
: >"$FASTLY_TEST_DDOS_EXPORT_CURL_ARGS"

assert_export_failure() {
  local name="$1" expected="$2"
  shift 2
  if "$ROOT/fastly-audit" ddos export-event "$@" >"$TEST_TMP/$name-out" 2>"$TEST_TMP/$name-err"; then
    printf 'ddos-export test: %s unexpectedly succeeded\n' "$name" >&2
    exit 1
  fi
  grep -F "$expected" "$TEST_TMP/$name-err" >/dev/null
}

event_id='event-1'
output_file="$TEST_TMP/evidence.json"
if ! "$ROOT/fastly-audit" ddos export-event "$event_id" --output "$output_file" \
  >"$TEST_TMP/success-out" 2>"$TEST_TMP/success-err"; then
  sed 's/^/ddos-export success stderr: /' "$TEST_TMP/success-err" >&2
  exit 1
fi
[[ ! -s "$TEST_TMP/success-out" ]]
[[ -r "$output_file" ]]
[[ "$(test_file_mode "$output_file")" == "600" ]]
grep -F 'wrote DDoS evidence for 1 event rule' "$TEST_TMP/success-err" >/dev/null
jq -e '
  .schema == "fastly-ddos-evidence"
  and .schema_version == 1
  and .collector.name == "fastly-audit"
  and .scope.event_id == "event-1"
  and .scope.customer_id == "test-customer"
  and .scope.service_id == "service-1"
  and .collection.status == "complete"
  and .collection.api_access == "read_only_GET_requests"
  and .collection.pagination.event_rules.pages_fetched == 1
  and .data.event.response.ended_at == null
  and (.data.event.response | has("updated_at") | not)
  and .data.event_rules.records[0].rule_id == "rule-a"
  and .data.rule_details[0].rule_id == "rule-a"
  and .data.traffic_stats[0].event_id == "event-1"
' "$output_file" >/dev/null

stdout_json="$("$ROOT/fastly-audit" ddos export-event "$event_id" --output - 2>"$TEST_TMP/stdout-err")"
jq -e '.schema == "fastly-ddos-evidence" and (.data.event_rules.records | length == 1)' <<<"$stdout_json" >/dev/null
grep -F 'customer scope: Test Customer (test-customer; source=environment)' "$TEST_TMP/stdout-err" >/dev/null
! grep -F 'test-token-secret' <<<"$stdout_json" >/dev/null

export FASTLY_TEST_DDOS_EXPORT_MODE=no-rules
no_rules="$("$ROOT/fastly-audit" ddos export-event "$event_id" --output - 2>"$TEST_TMP/no-rules-err")"
jq -e '
  .data.event_rules.records == []
  and .data.rule_details == []
  and .data.traffic_stats == []
  and .collection.pagination.event_rules.total_records == 0
' <<<"$no_rules" >/dev/null

export FASTLY_TEST_DDOS_EXPORT_MODE=multi-page
multi="$("$ROOT/fastly-audit" ddos export-event "$event_id" --output - 2>"$TEST_TMP/multi-err")"
jq -e '
  .collection.pagination.event_rules.pages_fetched == 2
  and (.data.event_rules.records | length) == 2
  and (.data.rule_details | length) == 2
  and (.data.traffic_stats | length) == 2
  and [.data.event_rules.records[].rule_id] == ["rule-a", "rule-b"]
' <<<"$multi" >/dev/null

export FASTLY_TEST_DDOS_EXPORT_MODE=repeated-cursor
assert_export_failure repeated-cursor 'pagination repeated cursor' "$event_id" --output -

export FASTLY_TEST_DDOS_EXPORT_MODE=duplicate-rules
assert_export_failure duplicate-rules 'missing or duplicate rule IDs' "$event_id" --output -

export FASTLY_TEST_DDOS_EXPORT_MODE=missing-rule-id
assert_export_failure missing-rule-id 'missing or duplicate rule IDs' "$event_id" --output -

export FASTLY_TEST_DDOS_EXPORT_MODE=event-id-mismatch
assert_export_failure event-id-mismatch 'mismatched event ID' "$event_id" --output -

export FASTLY_TEST_DDOS_EXPORT_MODE=customer-mismatch
assert_export_failure customer-mismatch 'does not belong to selected customer' "$event_id" --output -

export FASTLY_TEST_DDOS_EXPORT_MODE=success
assert_export_failure service-mismatch 'does not match requested service service-2' \
  "$event_id" --service service-2 --output -

export FASTLY_TEST_DDOS_EXPORT_MODE=missing-identifiers
assert_export_failure missing-identifiers 'ownership could not be established' "$event_id" --output -

export FASTLY_TEST_DDOS_EXPORT_MODE=malformed-event
assert_export_failure malformed-event 'Fastly API returned invalid JSON' "$event_id" --output -

export FASTLY_TEST_DDOS_EXPORT_MODE=auth-failure
assert_export_failure auth-failure 'Fastly API returned HTTP 401' "$event_id" --output -

export FASTLY_TEST_DDOS_EXPORT_MODE=rate-limit
assert_export_failure rate-limit 'Fastly API returned HTTP 429' "$event_id" --output -

export FASTLY_TEST_DDOS_EXPORT_MODE=traffic-failure
failed_output="$TEST_TMP/failed-evidence.json"
assert_export_failure traffic-failure 'Fastly API returned HTTP 503' "$event_id" --output "$failed_output"
[[ ! -e "$failed_output" ]]

export FASTLY_TEST_DDOS_EXPORT_MODE=success
existing="$TEST_TMP/existing.json"
printf '%s\n' 'do-not-overwrite' >"$existing"
assert_export_failure overwrite 'refusing to overwrite existing DDoS evidence output' "$event_id" --output "$existing"
[[ "$(cat "$existing")" == 'do-not-overwrite' ]]

assert_export_failure selected-customer-mismatch 'does not match selected customer' \
  "$event_id" --customer other-customer --output -

while IFS= read -r -d '' file; do
  if grep -F 'test-token-secret' "$file" >/dev/null; then
    printf 'ddos-export test: token value leaked into output: %s\n' "$file" >&2
    exit 1
  fi
done < <(find "$TEST_TMP" -type f ! -path "$TEST_TMP/bin/*" -print0)

printf 'ddos-export: OK\n'
