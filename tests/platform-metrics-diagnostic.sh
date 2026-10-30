#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=helpers.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_init

mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
outfile='' url='' cursor='' query_start='' query_end='' metric='' limit=''
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    --data-urlencode)
      case "$2" in
        cursor=*) cursor="${2#cursor=}" ;;
        from=*) query_start="${2#from=}" ;;
        to=*) query_end="${2#to=}" ;;
        metric=*) metric="${2#metric=}" ;;
        limit=*) limit="${2#limit=}" ;;
      esac
      shift 2 ;;
    -H|-w|--connect-timeout|--max-time|--retry|--retry-delay|--retry-max-time)
      shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$url" "$cursor" >>"$PM_TEST_LOG"
status=200
case "$url" in
  */customer/customer-test)
    printf '%s\n' '{"id":"customer-test","name":"Synthetic Customer"}' >"$outfile" ;;
  */ngwaf/v1/workspaces/workspace-test)
    case "$PM_TEST_MODE" in
      owner-missing) printf '%s\n' '{"id":"workspace-test"}' >"$outfile" ;;
      owner-mismatch) printf '%s\n' '{"id":"workspace-test","workspace_uid":"metrics-entity-test","customer_id":"other-test"}' >"$outfile" ;;
      id-mismatch) printf '%s\n' '{"id":"other-workspace","workspace_uid":"metrics-entity-test","customer_id":"customer-test"}' >"$outfile" ;;
      detail-404) status=404; printf '%s\n' '{"detail":"Site not found"}' >"$outfile" ;;
      uid-missing) printf '%s\n' '{"id":"workspace-test","customer_id":"customer-test"}' >"$outfile" ;;
      uid-empty) printf '%s\n' '{"id":"workspace-test","customer_id":"customer-test","workspace_uid":""}' >"$outfile" ;;
      uid-malformed) printf '%s\n' '{"id":"workspace-test","customer_id":"customer-test","workspace_uid":"invalid/uid"}' >"$outfile" ;;
      uid-wrong-type) printf '%s\n' '{"id":"workspace-test","customer_id":"customer-test","workspace_uid":123}' >"$outfile" ;;
      *) printf '%s\n' '{"id":"workspace-test","workspace_uid":"metrics-entity-test","customer_id":"customer-test","name":"Synthetic Workspace"}' >"$outfile" ;;
    esac ;;
  */metrics/v2/platform/entities/*/daily)
    entity_id="${url##*/entities/}"
    entity_id="${entity_id%/daily}"
    expected_entity=metrics-entity-test
    [[ "$entity_id" == "$expected_entity" ]] || {
      status=400; printf '%s\n' '{"detail":"Invalid entity ID"}' >"$outfile";
      printf '%s' "$status"; exit 0;
    }
    [[ "$query_start" == "$PM_TEST_START" && "$query_end" == "$PM_TEST_END" &&
       "$metric" == ngwaf_requests_total_count && "$limit" == 100 ]] || {
      status=400; printf '%s\n' '{"detail":"Invalid parameter"}' >"$outfile";
      printf '%s' "$status"; exit 0;
    }
    case "$PM_TEST_MODE" in
      success|zero|explicit-success)
        value=7; [[ "$PM_TEST_MODE" != zero ]] || value=0
        printf '{"meta":{"from":"%s","to":"%s","limit":100,"next_cursor":null},"data":[{"timestamp":"%s","ngwaf_requests_total_count":%s}]}\n' "$PM_TEST_START" "$PM_TEST_END" "$PM_TEST_START" "$value" >"$outfile" ;;
      empty|explicit-empty) printf '{"meta":{"from":"%s","to":"%s","limit":100,"next_cursor":null},"data":[]}\n' "$PM_TEST_START" "$PM_TEST_END" >"$outfile" ;;
      explicit-captured)
        printf '{"data":[{"ngwaf_requests_total_count":11,"timestamp":"%s"}],"meta":{"next_cursor":"","limit":100,"group_by":"timestamp","from":"%s","to":"%s"}}\n' "$PM_TEST_START" "$PM_TEST_START" "$PM_TEST_END" >"$outfile" ;;
      captured-empty)
        printf '{"data":[],"meta":{"next_cursor":"","limit":100,"group_by":"timestamp","from":"%s","to":"%s"}}\n' "$PM_TEST_START" "$PM_TEST_END" >"$outfile" ;;
      omitted) printf '{"meta":{"from":"%s","to":"%s","limit":100,"next_cursor":null},"data":[{"timestamp":"%s"}]}\n' "$PM_TEST_START" "$PM_TEST_END" "$PM_TEST_START" >"$outfile" ;;
      multi|partial|repeat)
        if [[ -z "$cursor" ]]; then
          printf '{"meta":{"from":"%s","to":"%s","limit":100,"next_cursor":"cursor-one"},"data":[]}\n' "$PM_TEST_START" "$PM_TEST_END" >"$outfile"
        elif [[ "$PM_TEST_MODE" == partial ]]; then
          status=500; printf '%s\n' '{"detail":"Server error"}' >"$outfile"
        elif [[ "$PM_TEST_MODE" == repeat ]]; then
          printf '{"meta":{"from":"%s","to":"%s","limit":100,"next_cursor":"cursor-one"},"data":[]}\n' "$PM_TEST_START" "$PM_TEST_END" >"$outfile"
        else
          printf '{"meta":{"from":"%s","to":"%s","limit":100,"next_cursor":null},"data":[{"timestamp":"%s","ngwaf_requests_total_count":7}]}\n' "$PM_TEST_START" "$PM_TEST_END" "$PM_TEST_START" >"$outfile"
        fi ;;
      endless)
        sequence=1
        [[ -z "$cursor" ]] || sequence=$(( ${cursor#cursor-} + 1 ))
        printf '{"meta":{"from":"%s","to":"%s","limit":100,"next_cursor":"cursor-%s"},"data":[]}\n' "$PM_TEST_START" "$PM_TEST_END" "$sequence" >"$outfile" ;;
      bad-json) printf 'not json\n' >"$outfile" ;;
      explicit-raw-invalid) printf 'raw-response-marker\r\n{"not":"metrics-schema"}\n' >"$outfile" ;;
      bad-meta) printf '%s\n' '{"meta":{},"data":[]}' >"$outfile" ;;
      bad-grouping) printf '{"meta":{"from":"%s","to":"%s","limit":100,"group_by":"region","next_cursor":""},"data":[]}\n' "$PM_TEST_START" "$PM_TEST_END" >"$outfile" ;;
      bad-value) printf '{"meta":{"from":"%s","to":"%s","limit":100},"data":[{"timestamp":"%s","ngwaf_requests_total_count":"7"}]}\n' "$PM_TEST_START" "$PM_TEST_END" "$PM_TEST_START" >"$outfile" ;;
      bad-time) printf '{"meta":{"from":"%s","to":"%s","limit":100},"data":[{"timestamp":"%s","ngwaf_requests_total_count":7}]}\n' "$PM_TEST_START" "$PM_TEST_END" "$PM_TEST_END" >"$outfile" ;;
      bad-entity) printf '{"entity_id":"other-workspace","meta":{"from":"%s","to":"%s","limit":100},"data":[]}\n' "$PM_TEST_START" "$PM_TEST_END" >"$outfile" ;;
      bad-cursor) printf '{"meta":{"from":"%s","to":"%s","limit":100,"next_cursor":4},"data":[]}\n' "$PM_TEST_START" "$PM_TEST_END" >"$outfile" ;;
      duplicate) printf '{"meta":{"from":"%s","to":"%s","limit":100},"data":[{"timestamp":"%s","ngwaf_requests_total_count":7},{"timestamp":"%s","ngwaf_requests_total_count":8}]}\n' "$PM_TEST_START" "$PM_TEST_END" "$PM_TEST_START" "$PM_TEST_START" >"$outfile" ;;
      http-400-unsupported) status=400; printf '%s\n' '{"detail":"Unsupported metric"}' >"$outfile" ;;
      http-400-parameter) status=400; printf '%s\n' '{"detail":"Unsupported parameter"}' >"$outfile" ;;
      http-400-nested) status=400; printf '%s\n' '{"errors":[{"source":{"parameter":"from"},"detail":"Invalid parameter: from"}]}' >"$outfile" ;;
      http-400-problem) status=400; printf '%s\n' '{"type":"https://fastly.help/metrics/validation-error","title":"Request parameters were invalid.","status":400,"errors":[{"property":"metric","reason":"Unrecognized metric names: example_value"}],"detail":"Parameters with invalid values: metric"}' >"$outfile" ;;
      http-400-type-only) status=400; printf '%s\n' '{"type":"https://fastly.help/metrics/validation-error","detail":"Validation failed"}' >"$outfile" ;;
      http-400-sensitive) status=400; printf '%s\n' '{"detail":"Invalid parameter: from; token=private-value","request":{"headers":{"Fastly-Key":"private-value"}}}' >"$outfile" ;;
      http-400-other) status=400; printf '%s\n' '{"detail":"Bad request"}' >"$outfile" ;;
      http-400-non-json) status=400; printf '%s\n' 'Invalid parameter: from; token=private-value' >"$outfile" ;;
      http-401) status=401; printf '%s\n' '{"detail":"Unauthorized"}' >"$outfile" ;;
      http-403) status=403; printf '%s\n' '{"detail":"Forbidden"}' >"$outfile" ;;
      http-404) status=404; printf '%s\n' '{"detail":"Not found"}' >"$outfile" ;;
      http-429) status=429; printf '%s\n' '{"detail":"Rate limited"}' >"$outfile" ;;
      http-500) status=500; printf '%s\n' '{"detail":"Server error"}' >"$outfile" ;;
      *) status=599; printf '%s\n' '{}' >"$outfile" ;;
    esac ;;
  *) status=599; printf '%s\n' '{}' >"$outfile" ;;
esac
printf '%s' "$status"
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"
export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN=test-token FASTLY_CUSTOMER_ID=customer-test
export NGWAF_PROGRESS=never NGWAF_COLOR=never NGWAF_CURL_RETRIES=0
export XDG_CONFIG_HOME="$TEST_TMP/config" PM_TEST_LOG="$TEST_TMP/requests"
PM_TEST_START="$(date -u -v-3d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '3 days ago' +%Y-%m-%dT00:00:00Z)"
PM_TEST_END="$(date -u -v-2d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '2 days ago' +%Y-%m-%dT00:00:00Z)"
export PM_TEST_START PM_TEST_END

run_mode() {
  local mode="$1" expected="$2" count="$3" entity_id="${4-metrics-entity-test}" reported_entity mapping source
  local -a entity_arg=()
  [[ "$mode" != explicit-* ]] || entity_arg=(--entity-id "$entity_id")
  reported_entity="$entity_id"
  mapping=verified_public_workspace_detail_uid
  source=public_workspace_detail_workspace_uid
  if [[ "$expected" == ownership_unverified || "$expected" == identity_unverified || "$expected" == identity_conflict ]]; then
    mapping=unverified_cross_api_identity
    source=unavailable
    [[ "$mode" == explicit-* ]] && source=explicit_cli_argument
    [[ "$mode" == explicit-* ]] || reported_entity=''
  elif [[ "$mode" == explicit-* ]]; then
    source=explicit_cli_argument
  fi
  export PM_TEST_MODE="$mode"
  : >"$PM_TEST_LOG"
  if "$ROOT/fastly-audit" ngwaf platform-metrics-diagnostic workspace-test \
    --start "$PM_TEST_START" --end "$PM_TEST_END" "${entity_arg[@]}" --json >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'platform-metrics-diagnostic: %s unexpectedly claimed P0 validation\n' "$mode" >&2
    exit 1
  fi
  jq -e --arg status "$expected" --arg entity "$reported_entity" --arg mapping "$mapping" --arg source "$source" '
    .status == $status and .p0_validated == false and
    .workspace.id == "workspace-test" and .public_workspace_id == "workspace-test" and
    .entity_id == (if $entity == "" then null else $entity end) and
    .metrics_entity_id == (if $entity == "" then null else $entity end) and
    .entity_compatibility == $mapping and .mapping_verification == $mapping and
    .entity_id_source == $source and
    .granularity == "daily" and .endpoint == "GET /metrics/v2/platform/entities/{entity_id}/daily" and
    .metric == "ngwaf_requests_total_count" and
    (.workspace.detail_http_status | test("^[0-9]{3}$"))' "$TEST_TMP/out" >/dev/null
  case "$mode" in
    zero) jq -e '.observations == [{"timestamp":.window.from,"present":true,"value":0}]' "$TEST_TMP/out" >/dev/null ;;
    omitted) jq -e '.observations[0].present == false and .observations[0].value == null' "$TEST_TMP/out" >/dev/null ;;
    empty|captured-empty) jq -e '.bucket_coverage == "no_observation_not_zero" and .observations == []' "$TEST_TMP/out" >/dev/null ;;
    explicit-captured) jq -e '.observations == [{"timestamp":.window.from,"present":true,"value":11}] and
      .pages_fetched == 1 and .pagination_complete == true and .response_meta.next_cursor == "" and
      .mapping_verification == "verified_public_workspace_detail_uid" and .p0_validated == false' "$TEST_TMP/out" >/dev/null ;;
    multi) jq -e '.pages_fetched == 2 and .pagination_complete == true' "$TEST_TMP/out" >/dev/null ;;
    partial|repeat) jq -e '.pagination_complete == false' "$TEST_TMP/out" >/dev/null ;;
    http-400-nested) jq -e '.api_validation_message == "API reports invalid from parameter" and .error_body_format == "json_object"' "$TEST_TMP/out" >/dev/null ;;
    http-400-problem) jq -e '.api_validation_message == "API reports unknown metric parameter" and .error_body_format == "json_object"' "$TEST_TMP/out" >/dev/null ;;
    http-400-type-only) jq -e '.api_validation_message == "Metrics API reports parameter validation error" and .error_category == "unclassified_http_400"' "$TEST_TMP/out" >/dev/null ;;
    http-400-sensitive) jq -e '.api_validation_message == "API reports invalid parameter" and .error_body_format == "json_object"' "$TEST_TMP/out" >/dev/null ;;
    http-400-other) jq -e '.api_validation_message == null and .error_body_format == "json_object"' "$TEST_TMP/out" >/dev/null ;;
    http-400-non-json) jq -e '.api_validation_message == null and .error_body_format == "invalid_json"' "$TEST_TMP/out" >/dev/null ;;
  esac
  if [[ "$expected" == success_with_data || "$expected" == success_empty || "$expected" == metric_omitted ]]; then
    rg -q 'Workspace-to-Metrics entity mapping verified via public workspace_uid; P0 validation remains incomplete' "$TEST_TMP/err"
    if rg -q 'mapping remains unverified' "$TEST_TMP/err"; then
      printf 'platform-metrics-diagnostic: stale mapping message remained\n' >&2
      exit 1
    fi
  fi
  [[ "$(wc -l <"$PM_TEST_LOG" | tr -d ' ')" == "$count" ]]
  rg -q '/ngwaf/v1/workspaces/workspace-test ' "$PM_TEST_LOG"
  if rg -q '/ngwaf/v1/workspaces/metrics-entity-test ' "$PM_TEST_LOG"; then
    printf 'platform-metrics-diagnostic: entity ID was used for workspace ownership lookup\n' >&2
    return 1
  fi
  if (( count > 2 )); then rg -q '/metrics/v2/platform/entities/metrics-entity-test/daily ' "$PM_TEST_LOG"; fi
  [[ "$(wc -l <"$TEST_TMP/out" | tr -d ' ')" == 1 ]]
  ! rg -q 'test-token|private-value|Fastly-Key|Cookie:' "$TEST_TMP/out" "$TEST_TMP/err"
}

for mode_status_count in \
  'success success_with_data 3' 'zero success_with_data 3' 'empty success_empty 3' \
  'omitted metric_omitted 3' 'multi success_with_data 4' \
  'owner-missing ownership_unverified 2' 'owner-mismatch ownership_unverified 2' \
  'id-mismatch ownership_unverified 2' 'detail-404 ownership_unverified 2' \
  'uid-missing identity_unverified 2' 'uid-empty identity_unverified 2' \
  'uid-malformed identity_unverified 2' 'uid-wrong-type identity_unverified 2' \
  'bad-json invalid_response 3' 'bad-meta invalid_response 3' 'bad-grouping invalid_response 3' \
  'bad-value invalid_response 3' 'bad-time invalid_response 3' \
  'bad-entity invalid_response 3' 'bad-cursor invalid_response 3' \
  'duplicate invalid_response 3' 'repeat incomplete 4' 'partial incomplete 4' 'endless incomplete 12' \
  'http-400-unsupported unsupported_entity_or_metric 3' 'http-400-parameter unsupported_parameter 3' \
  'http-400-nested unsupported_parameter 3' 'http-400-problem unsupported_parameter 3' \
  'http-400-type-only invalid_request 3' 'http-400-sensitive unsupported_parameter 3' \
  'http-400-other invalid_request 3' 'http-400-non-json invalid_request 3' \
  'http-401 authorization_failure 3' 'http-403 authorization_failure 3' \
  'http-404 not_found_unclassified 3' 'http-429 rate_limited 3' 'http-500 server_failure 3'; do
  read -r mode status count <<<"$mode_status_count"
  run_mode "$mode" "$status" "$count"
done

run_mode explicit-success success_with_data 3 metrics-entity-test
run_mode explicit-empty success_empty 3 metrics-entity-test
run_mode explicit-captured success_with_data 3 metrics-entity-test
run_mode captured-empty success_empty 3
run_mode explicit-mismatch identity_conflict 2 other-entity-test
run_mode owner-mismatch ownership_unverified 2
if rg -q '/metrics/v2/platform/entities/' "$PM_TEST_LOG"; then
  printf 'platform-metrics-diagnostic: unverified owner reached Metrics API\n' >&2
  exit 1
fi

raw_file="$TEST_TMP/raw-response"
export PM_TEST_MODE=explicit-raw-invalid
: >"$PM_TEST_LOG"
if "$ROOT/fastly-audit" ngwaf platform-metrics-diagnostic workspace-test \
  --start "$PM_TEST_START" --end "$PM_TEST_END" --entity-id metrics-entity-test \
  --save-raw-response "$raw_file" --json >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
  printf 'platform-metrics-diagnostic: malformed raw response claimed P0 validation\n' >&2
  exit 1
fi
printf 'raw-response-marker\r\n{"not":"metrics-schema"}\n' >"$TEST_TMP/expected-raw"
cmp "$TEST_TMP/expected-raw" "$raw_file" >/dev/null
[[ "$(test_file_mode "$raw_file")" == 600 ]]
jq -e '.status == "invalid_response" and .p0_validated == false and .pages_fetched == 0' "$TEST_TMP/out" >/dev/null
[[ "$(wc -l <"$PM_TEST_LOG" | tr -d ' ')" == 3 ]]
if rg -q 'raw-response-marker' "$TEST_TMP/out" "$TEST_TMP/err"; then
  printf 'platform-metrics-diagnostic: raw response leaked to output\n' >&2
  exit 1
fi

: >"$PM_TEST_LOG"
if "$ROOT/fastly-audit" ngwaf platform-metrics-diagnostic workspace-test \
  --start "$PM_TEST_START" --end "$PM_TEST_END" --entity-id metrics-entity-test \
  --save-raw-response "$raw_file" --json >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
  printf 'platform-metrics-diagnostic: existing raw file was accepted\n' >&2
  exit 1
fi
[[ ! -s "$PM_TEST_LOG" && ! -s "$TEST_TMP/out" ]]
rg -q 'refusing to overwrite existing raw response file' "$TEST_TMP/err"
cmp "$TEST_TMP/expected-raw" "$raw_file" >/dev/null

for invalid in '--bad' 'workspace-test --start nope --end nope' \
  "workspace-test --start $PM_TEST_START --end $PM_TEST_END --entity-id invalid/segment" \
  "workspace-test --start $PM_TEST_START --end $PM_TEST_END --entity-id metrics-entity-test --entity-id metrics-entity-test" \
  "workspace-test --start $PM_TEST_START --end $PM_TEST_START" \
  "workspace-test --start $PM_TEST_END --end $PM_TEST_START" \
  "workspace-test --start $(date -u -v-400d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '400 days ago' +%Y-%m-%dT00:00:00Z) --end $(date -u -v-399d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '399 days ago' +%Y-%m-%dT00:00:00Z)" \
  "workspace-test --start $(date -u -v+1d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d 'tomorrow' +%Y-%m-%dT00:00:00Z) --end $(date -u -v+2d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '2 days' +%Y-%m-%dT00:00:00Z)"; do
  : >"$PM_TEST_LOG"
  read -r -a arguments <<<"$invalid"
  if "$ROOT/fastly-audit" ngwaf platform-metrics-diagnostic "${arguments[@]}" >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'platform-metrics-diagnostic: invalid arguments succeeded\n' >&2; exit 1
  fi
  [[ ! -s "$PM_TEST_LOG" && ! -s "$TEST_TMP/out" ]]
done

: >"$PM_TEST_LOG"
env -u FASTLY_API_TOKEN "$ROOT/fastly-audit" ngwaf platform-metrics-diagnostic --help >"$TEST_TMP/out" 2>"$TEST_TMP/err"
[[ ! -s "$PM_TEST_LOG" && ! -s "$TEST_TMP/err" ]]
grep -F 'The exact public workspace detail must contain a valid workspace_uid' "$TEST_TMP/out" >/dev/null
printf 'platform-metrics-diagnostic: OK (offline fake API)\n'
