#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"

cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
outfile='' url='' retry_seen='' customer_filter='' get_seen=false
while (( $# > 0 )); do
  case "$1" in
    -G) get_seen=true; shift ;;
    --data-urlencode)
      [[ "$2" != customer_id=* ]] || customer_filter="$2"
      shift 2 ;;
    -o|-w|-H|--connect-timeout|--max-time|--retry|--retry-delay|--retry-max-time)
      [[ "$1" != --retry ]] || retry_seen="$2"
      [[ "$1" != -o ]] || outfile="$2"
      shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ "$url" != */agents || "$retry_seen" == 0 ]] || exit 91
if [[ "$url" == */ngwaf/v1/workspaces/workspace-example* ]]; then
  [[ "$get_seen" == true && "$customer_filter" == 'customer_id=test-customer' ]] || exit 92
fi
printf '%s\n' "$url" >>"$AGENT_DIAGNOSTIC_CURL_LOG"
printf 'query:%s\n' "$customer_filter" >>"$AGENT_DIAGNOSTIC_CURL_LOG"
status=200
case "$url" in
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile" ;;
  */ngwaf/v1/workspaces)
    case "${AGENT_DIAGNOSTIC_MODE:-}" in
      inventory-foreign)
        printf '%s\n' '{"meta":{"total":1},"data":[{"id":"workspace-example","workspace_uid":"","customer_id":"other-customer"}]}' >"$outfile" ;;
      inventory-duplicate)
        printf '%s\n' '{"meta":{"total":2},"data":[{"id":"workspace-example"},{"id":"workspace-example"}]}' >"$outfile" ;;
      uid-present|uid-mismatch)
        printf '%s\n' '{"meta":{"total":1},"data":[{"id":"workspace-example","workspace_uid":"UID-123","customer_id":"test-customer"}]}' >"$outfile" ;;
      *) printf '%s\n' '{"meta":{"total":1},"data":[{"id":"workspace-example","workspace_uid":"","customer_id":"test-customer"}]}' >"$outfile" ;;
    esac ;;
  */ngwaf/v1/workspaces/workspace-example)
    if [[ "$customer_filter" != 'customer_id=test-customer' ]]; then
      status=404; printf '%s\n' '{"title":"This resource does not exist","detail":"Site not found"}' >"$outfile"
    else
      case "${AGENT_DIAGNOSTIC_MODE:-}" in
        detail-foreign) printf '%s\n' '{"id":"workspace-example","workspace_uid":"","customer_id":"other-customer"}' >"$outfile" ;;
        detail-other-id) printf '%s\n' '{"id":"different-workspace","workspace_uid":"","customer_id":"test-customer"}' >"$outfile" ;;
        detail-failure) status=503; printf '%s\n' '{"title":"Service unavailable","detail":"Workspace lookup failed","private":"do not print"}' >"$outfile" ;;
        detail-site-not-found) status=404; printf '%s\n' '{"title":"This resource does not exist","detail":"Site not found"}' >"$outfile" ;;
        detail-message) status=404; printf '%s\n' '{"message":"Site not found"}' >"$outfile" ;;
        detail-malformed) status=404; printf 'not-json Bearer test-secret-token\n' >"$outfile" ;;
        detail-secret) status=404; printf '%s\n' '{"detail":"Bearer test-secret-token"}' >"$outfile" ;;
        uid-present) printf '%s\n' '{"id":"workspace-example","workspace_uid":"UID-123","customer_id":"test-customer"}' >"$outfile" ;;
        uid-mismatch) printf '%s\n' '{"id":"workspace-example","workspace_uid":"UID-OTHER","customer_id":"test-customer"}' >"$outfile" ;;
        *) printf '%s\n' '{"id":"workspace-example","workspace_uid":"","customer_id":"test-customer"}' >"$outfile" ;;
      esac
    fi ;;
  */ngwaf/v1/workspaces/workspace-example/agents)
    case "${AGENT_DIAGNOSTIC_MODE:-}" in
      agents-match|detail-site-not-found) printf '%s\n' '{"meta":{"total":1},"data":[{"workspace_id":"workspace-example","agent_active":true,"module_detected":true,"host_remote_ip":"192.0.2.1"}]}' >"$outfile" ;;
      agents-health-mixed) printf '%s\n' '{"meta":{"total":8},"data":[{"workspace_id":"workspace-example","agent_active":true,"agent_enabled":true,"agent_version":"v99.12.3"},{"workspace_id":"workspace-example","agent_active":false,"agent_enabled":true,"agent_version":"v99.12.3"},{"workspace_id":"workspace-example","agent_active":null,"agent_enabled":false,"agent_version":"v99.13.0"},{"workspace_id":"workspace-example","agent_enabled":null,"agent_version":"private value"},{"workspace_id":"workspace-example","agent_version":null}]}' >"$outfile" ;;
      agents-many-versions) jq -nc '[range(0;21) | {workspace_id:"workspace-example", agent_version:("4.0." + tostring)}] | {meta:{total:length},data:.}' >"$outfile" ;;
      agents-bad-state) printf '%s\n' '{"meta":{"total":1},"data":[{"workspace_id":"workspace-example","agent_active":"yes"}]}' >"$outfile" ;;
      agents-mismatch) printf '%s\n' '{"meta":{"total":1},"data":[{"workspace_id":"different-workspace","module_detected":true}]}' >"$outfile" ;;
      agents-no-id) printf '%s\n' '{"meta":{"total":1},"data":[{"module_detected":true}]}' >"$outfile" ;;
      agents-incomplete) printf '%s\n' '{"meta":{"total":2},"data":[{"workspace_id":"workspace-example"}]}' >"$outfile" ;;
      agents-seven-two) printf '%s\n' '{"meta":{"total":7},"data":[{"workspace_id":"workspace-example"},{"workspace_id":"workspace-example"}]}' >"$outfile" ;;
      agents-nine-three) printf '%s\n' '{"meta":{"total":9},"data":[{"workspace_id":"workspace-example"},{"workspace_id":"workspace-example"},{"workspace_id":"workspace-example"}]}' >"$outfile" ;;
      agents-empty) printf '%s\n' '{"meta":{"total":0},"data":[]}' >"$outfile" ;;
      agents-empty-inflated) printf '%s\n' '{"meta":{"total":5},"data":[]}' >"$outfile" ;;
      agents-no-total) printf '%s\n' '{"meta":{},"data":[]}' >"$outfile" ;;
      agents-bad-total) printf '%s\n' '{"meta":{"total":"5"},"data":[]}' >"$outfile" ;;
      agents-invalid-record) printf '%s\n' '{"meta":{"total":1},"data":["bad-record"]}' >"$outfile" ;;
      agents-failed) status=503; printf '%s\n' '{"detail":"Service unavailable"}' >"$outfile" ;;
      agents-malformed) printf 'not-json\n' >"$outfile" ;;
      agents-secret) status=400; printf '%s\n' '{"title":"Bad Request","detail":"Bearer test-secret-token"}' >"$outfile" ;;
      *) status=400; printf '%s\n' '{"status":400,"title":"Bad Request","detail":"Site not found","errors":[],"private":"do not print"}' >"$outfile" ;;
    esac ;;
  *) status=599; printf '%s\n' '{"error":"unexpected endpoint"}' >"$outfile" ;;
esac
printf '%s' "$status"
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"
export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN='test-token-secret' FASTLY_CUSTOMER_ID=test-customer
export NGWAF_COLOR=never NGWAF_PROGRESS=never NGWAF_CURL_RETRIES=0
export XDG_CONFIG_HOME="$TEST_TMP/config"
export AGENT_DIAGNOSTIC_CURL_LOG="$TEST_TMP/curl-log"
workspace_id='workspace-example'

for launcher in fastly-audit ngwaf; do
  : >"$AGENT_DIAGNOSTIC_CURL_LOG"
  env -u FASTLY_API_TOKEN -u FASTLY_CUSTOMER_ID "$ROOT/$launcher" ngwaf agent-diagnostic --help >"$TEST_TMP/help" 2>"$TEST_TMP/err"
  grep -F 'agent-diagnostic <workspace-id>' "$TEST_TMP/help" >/dev/null
  grep -F 'Limitations:' "$TEST_TMP/help" >/dev/null
  grep -F 'raw meta.total may be inflated' "$TEST_TMP/help" >/dev/null
  grep -F 'previous two days' "$TEST_TMP/help" >/dev/null
  grep -F 'it omits individual agent and host data.' "$TEST_TMP/help" >/dev/null
  [[ ! -s "$TEST_TMP/err" && ! -s "$AGENT_DIAGNOSTIC_CURL_LOG" ]]
done
for args in '' '--bad' 'workspace-example --bad'; do
  : >"$AGENT_DIAGNOSTIC_CURL_LOG"
  read -r -a invalid <<<"$args"
  if "$ROOT/fastly-audit" ngwaf agent-diagnostic "${invalid[@]}" >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'agent-diagnostic: invalid input succeeded: %s\n' "$args" >&2; exit 1
  fi
  [[ ! -s "$TEST_TMP/out" && ! -s "$AGENT_DIAGNOSTIC_CURL_LOG" ]]
done

: >"$AGENT_DIAGNOSTIC_CURL_LOG"
if "$ROOT/fastly-audit" ngwaf agent-diagnostic partial --json >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
  printf 'agent-diagnostic: partial ID unexpectedly succeeded\n' >&2; exit 1
fi
[[ ! -s "$TEST_TMP/out" ]]
if rg -q '/ngwaf/v1/workspaces/[^/]+$|/agents$' "$AGENT_DIAGNOSTIC_CURL_LOG"; then
  printf 'agent-diagnostic: partial ID reached detail or agents\n' >&2; exit 1
fi

run_diagnostic() {
  : >"$AGENT_DIAGNOSTIC_CURL_LOG"
  "$ROOT/fastly-audit" ngwaf agent-diagnostic "$workspace_id" --json >"$TEST_TMP/json" 2>"$TEST_TMP/err"
  jq -e -s 'length == 1 and .[0].schema_version == 1' "$TEST_TMP/json" >/dev/null
  jq -e '.source_context.api_surface == "public_fastly_ngwaf" and
    .source_context.api_host == "api.fastly.com" and
    .source_context.credential_source == "FASTLY_API_TOKEN" and
    .source_context.resource_type == "ngwaf_workspace_agents" and
    .source_context.evidence_class == "agent_observation" and
    .source_context.retrieval_status == .agents_request.status and
    .source_context.evidence_status == (if .agent_health == null then "unavailable" else "observed" end) and
    .source_context.limitations == ["not_complete_deployed_agent_inventory",
      "deployment_architecture_unverified","cdn_attachment_unverified",
      "traffic_inspection_unverified","enforcement_effectiveness_unverified"]' "$TEST_TMP/json" >/dev/null
  [[ "$(rg -c '/agents$' "$AGENT_DIAGNOSTIC_CURL_LOG")" == 1 ]]
  [[ "$(rg -c '/ngwaf/v1/workspaces/workspace-example$' "$AGENT_DIAGNOSTIC_CURL_LOG")" == 1 ]]
  [[ "$(rg -c '^query:customer_id=test-customer$' "$AGENT_DIAGNOSTIC_CURL_LOG")" == 3 ]]
  if ! rg -Uq '/agents\nquery:customer_id=test-customer' "$AGENT_DIAGNOSTIC_CURL_LOG"; then
    printf 'agent-diagnostic: Agents request omitted selected customer_id\n' >&2; exit 1
  fi
  if rg -q 'test-token-secret|host_remote_ip|192.0.2.1|do not print' "$TEST_TMP/json" "$TEST_TMP/err"; then
    printf 'agent-diagnostic: sensitive value leaked\n' >&2; exit 1
  fi
}

run_diagnostic
jq -e '.requested_workspace_id == "workspace-example" and
  .workspace_detail_request.method == "GET" and
  .workspace_detail_request.url == "https://api.fastly.com/ngwaf/v1/workspaces/workspace-example?customer_id=test-customer" and
  .workspace_detail_request.path == "/ngwaf/v1/workspaces/workspace-example" and
  .workspace_detail_request.status == "verified" and
  .workspace_metadata.inventory.id == .workspace_metadata.detail.id and
  .workspace_metadata.inventory.workspace_uid == "" and
  .workspace_metadata.detail.workspace_uid == "" and
  .workspace_metadata.workspace_uid_match == null and
  .agents_request.identifier_field == "workspace detail id" and
  .agents_request.url == "https://api.fastly.com/ngwaf/v1/workspaces/workspace-example/agents?customer_id=test-customer" and
  .agents_request.path == "/ngwaf/v1/workspaces/workspace-example/agents" and
  .agents_request.http_status == "400" and
  .agents_request.api_error == {title:"Bad Request",detail:"Site not found"} and
  .agents_request.response_workspace_match == "unverifiable" and
  .agent_health == null' "$TEST_TMP/json" >/dev/null

export AGENT_DIAGNOSTIC_MODE=agents-match
run_diagnostic
jq -e '.agents_request.http_status == "200" and .agents_request.agent_count == 1 and
  .agents_request.reported_total == 1 and
  .agents_request.reported_total_status == "matches_returned_count" and
  .agents_request.response_workspace_match == "matched" and .agents_request.response_complete == null and
  .agents_request.total_matches_returned_count == true and
  .agents_request.api_error == null and
  .agent_health.status == "observed" and .agent_health.returned_agents == 1 and
  .agent_health.activity == {active:1,inactive:0,unknown:0} and
  .agent_health.enablement == {enabled:0,disabled:0,unknown:1} and
  .agent_health.versions.reported == 0 and .agent_health.versions.unknown == 1' "$TEST_TMP/json" >/dev/null

export AGENT_DIAGNOSTIC_MODE=agents-health-mixed
run_diagnostic
jq -e '.agents_request.agent_count == 5 and .agents_request.reported_total == 8 and
  .agents_request.reported_total_status == "inflated_total_consistent_with_sds_5073" and
  .agents_request.response_complete == null and
  .agent_health.status == "observed" and
  .agent_health.population == "agents_returned_by_api" and
  .agent_health.observation_window == "previous_2_days" and
  .agent_health.returned_agents == 5 and
  .agent_health.activity == {active:1,inactive:1,unknown:3} and
  .agent_health.enablement == {enabled:2,disabled:1,unknown:2} and
  .agent_health.versions.reported == 3 and .agent_health.versions.unknown == 2 and
  .agent_health.versions.distribution == [{version:"v99.12.3",count:2},{version:"v99.13.0",count:1}] and
  .agent_health.versions.distinct_versions == 2 and
  .agent_health.versions.truncated == false and
  .agent_health.versions.other_reported_count == 0' "$TEST_TMP/json" >/dev/null
if rg -q 'private value' "$TEST_TMP/json"; then
  printf 'agent-diagnostic: malformed version leaked\n' >&2; exit 1
fi

export AGENT_DIAGNOSTIC_MODE=agents-many-versions
run_diagnostic
jq -e '.agent_health.returned_agents == 21 and
  .agent_health.versions.reported == 21 and
  .agent_health.versions.unknown == 0 and
  (.agent_health.versions.distribution | length) == 20 and
  .agent_health.versions.distinct_versions == 21 and
  .agent_health.versions.truncated == true and
  .agent_health.versions.other_reported_count == 1' "$TEST_TMP/json" >/dev/null

export AGENT_DIAGNOSTIC_MODE=detail-site-not-found
run_diagnostic
jq -e '.workspace_detail_request.http_status == "404" and
  .workspace_detail_request.status == "lookup_failed" and
  .workspace_detail_request.api_error.detail == "Site not found" and
  .workspace_metadata.detail == null and .workspace_metadata.id_match == null and
  .workspace_metadata.ownership_verified == true and
  .workspace_metadata.ownership_evidence == "selected_customer_workspace_inventory" and
  .agents_request.identifier_field == "selected-customer inventory id" and
  .agents_request.identifier == "workspace-example" and
  .agents_request.http_status == "200" and .agents_request.status == "returned"' "$TEST_TMP/json" >/dev/null

export AGENT_DIAGNOSTIC_MODE=agents-mismatch
run_diagnostic
jq -e '.agents_request.response_workspace_match == "mismatch" and .agent_health == null' "$TEST_TMP/json" >/dev/null

export AGENT_DIAGNOSTIC_MODE=agents-no-id
run_diagnostic
jq -e '.agents_request.response_workspace_match == "unverifiable"' "$TEST_TMP/json" >/dev/null

export AGENT_DIAGNOSTIC_MODE=agents-incomplete
run_diagnostic
jq -e '.agents_request.response_complete == null and .agents_request.total_matches_returned_count == false and .agents_request.agent_count == 1 and
  .agents_request.reported_total == 2 and .agents_request.response_workspace_match == "matched"' "$TEST_TMP/json" >/dev/null

for mode_count_total in 'agents-seven-two 2 7' 'agents-nine-three 3 9' 'agents-empty-inflated 0 5'; do
  read -r mode count total <<<"$mode_count_total"
  export AGENT_DIAGNOSTIC_MODE="$mode"
  run_diagnostic
  jq -e --argjson count "$count" --argjson total "$total" '
    .agents_request.status == "returned" and
    .agents_request.agent_count == $count and .agents_request.reported_total == $total and
    .agents_request.total_matches_returned_count == false and
    .agents_request.reported_total_status == "inflated_total_consistent_with_sds_5073" and
    .agents_request.response_complete == null' "$TEST_TMP/json" >/dev/null
done

export AGENT_DIAGNOSTIC_MODE=agents-empty
run_diagnostic
jq -e '.agents_request.agent_count == 0 and .agents_request.reported_total == 0 and
  .agents_request.total_matches_returned_count == true and
  .agents_request.reported_total_status == "matches_returned_count" and
  .agents_request.response_complete == null and
  .agent_health.returned_agents == 0 and
  .agent_health.activity == {active:0,inactive:0,unknown:0} and
  .agent_health.enablement == {enabled:0,disabled:0,unknown:0} and
  .agent_health.versions.reported == 0 and .agent_health.versions.unknown == 0' "$TEST_TMP/json" >/dev/null

for mode in agents-no-total agents-bad-total agents-invalid-record agents-bad-state; do
  export AGENT_DIAGNOSTIC_MODE="$mode"
  run_diagnostic
  jq -e '.agents_request.status == "unusable_response" and .agents_request.agent_count == null and
    .agents_request.reported_total_status == null and .agent_health == null' "$TEST_TMP/json" >/dev/null
done

export AGENT_DIAGNOSTIC_MODE=agents-failed
run_diagnostic
jq -e '.agents_request.status == "unavailable" and .agents_request.agent_count == null and .agent_health == null' "$TEST_TMP/json" >/dev/null

export AGENT_DIAGNOSTIC_MODE=agents-malformed
run_diagnostic
jq -e '.agents_request.status == "unusable_response" and .agents_request.agent_count == null and .agent_health == null' "$TEST_TMP/json" >/dev/null

export AGENT_DIAGNOSTIC_MODE=agents-secret
run_diagnostic
jq -e '.agents_request.api_error == {title:"Bad Request"}' "$TEST_TMP/json" >/dev/null

export AGENT_DIAGNOSTIC_MODE=uid-present
run_diagnostic
jq -e '.workspace_metadata.workspace_uid_match == true and
  .agents_request.identifier == "workspace-example" and
  .agents_request.http_status == "400"' "$TEST_TMP/json" >/dev/null
if rg -q 'UID-123/agents' "$AGENT_DIAGNOSTIC_CURL_LOG"; then
  printf 'agent-diagnostic: tried workspace UID substitution\n' >&2; exit 1
fi

for mode in inventory-foreign inventory-duplicate detail-foreign detail-other-id detail-failure detail-message detail-malformed detail-secret uid-mismatch; do
  export AGENT_DIAGNOSTIC_MODE="$mode"
  : >"$AGENT_DIAGNOSTIC_CURL_LOG"
  if "$ROOT/fastly-audit" ngwaf agent-diagnostic "$workspace_id" --json >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'agent-diagnostic: %s unexpectedly succeeded\n' "$mode" >&2; exit 1
  fi
  if [[ "$mode" == inventory-* ]]; then
    [[ ! -s "$TEST_TMP/out" ]]
  else
    jq -e '.status == "blocked" and .agent_health == null and
      .source_context.api_surface == "public_fastly_ngwaf" and
      .source_context.retrieval_status == "skipped" and
      .source_context.evidence_status == "unavailable" and
      .agents_request.status == "skipped" and
      .agents_request.http_status == null and .workspace_metadata.ownership_verified == false and
      .workspace_detail_request.method == "GET" and
      .workspace_detail_request.url == "https://api.fastly.com/ngwaf/v1/workspaces/workspace-example?customer_id=test-customer" and
      .workspace_detail_request.path == "/ngwaf/v1/workspaces/workspace-example"' "$TEST_TMP/out" >/dev/null
    case "$mode" in
      detail-failure)
        jq -e '.workspace_detail_request.status == "lookup_failed" and
          .workspace_detail_request.http_status == "503" and
          .workspace_metadata.detail_http_status == "503" and
          .workspace_detail_request.error_body_format == "json_object" and
          .workspace_detail_request.api_error == {title:"Service unavailable",detail:"Workspace lookup failed"} and
          .workspace_metadata.id_match == null' "$TEST_TMP/out" >/dev/null ;;
      detail-message)
        jq -e '.workspace_detail_request.status == "lookup_failed" and
          .workspace_detail_request.api_error == {message:"Site not found"}' "$TEST_TMP/out" >/dev/null ;;
      detail-malformed)
        jq -e '.workspace_detail_request.status == "lookup_failed" and
          .workspace_detail_request.error_body_format == "invalid_json" and
          .workspace_detail_request.api_error == {} and .workspace_metadata.id_match == null' "$TEST_TMP/out" >/dev/null ;;
      detail-secret)
        jq -e '.workspace_detail_request.api_error == {}' "$TEST_TMP/out" >/dev/null ;;
      detail-other-id)
        jq -e '.workspace_detail_request.status == "identifier_mismatch" and
          .workspace_detail_request.http_status == "200" and
          .workspace_detail_request.api_error == null and
          .workspace_metadata.id_match == false and .workspace_metadata.detail.id == "different-workspace"' "$TEST_TMP/out" >/dev/null ;;
      detail-foreign)
        jq -e '.workspace_detail_request.status == "ownership_mismatch" and
          .workspace_metadata.id_match == true' "$TEST_TMP/out" >/dev/null ;;
      uid-mismatch)
        jq -e '.workspace_detail_request.status == "workspace_uid_mismatch" and
          .workspace_metadata.workspace_uid_match == false' "$TEST_TMP/out" >/dev/null ;;
    esac
    if rg -q 'test-secret-token|do not print' "$TEST_TMP/out" "$TEST_TMP/err"; then
      printf 'agent-diagnostic: detail error leaked sensitive content\n' >&2; exit 1
    fi
  fi
  if rg -q '/agents$' "$AGENT_DIAGNOSTIC_CURL_LOG"; then
    printf 'agent-diagnostic: %s probed agents without verified ownership\n' "$mode" >&2; exit 1
  fi
done

printf 'agent-diagnostic: OK\n'
