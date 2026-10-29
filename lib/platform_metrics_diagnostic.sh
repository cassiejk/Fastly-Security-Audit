# shellcheck shell=bash
# PLATFORM_METRICS_DIAGNOSTIC_* values are consumed by lib/dispatch.sh.
# shellcheck disable=SC2034
# Sourced by fastly-audit; this P0 probe does not change legacy collectors.

platform_metrics_diagnostic_usage() {
  cat <<'HELP'
Probe one exact NGWAF workspace ID against Platform Metrics v2 (read-only P0).

Usage:
  fastly-audit ngwaf platform-metrics-diagnostic <workspace-id> --start YYYY-MM-DDT00:00:00Z --end YYYY-MM-DDT00:00:00Z [--json]

The range must be one completed UTC day within daily retention. The selected
customer is checked first. One exact workspace detail GET must return matching
customer ownership metadata before the entity metrics GET is attempted.
The public API documentation does not explicitly bind workspace id or
workspace_uid to Metrics entity_id. The workspace id is a diagnostic candidate;
even an HTTP 200 is reported as candidate compatibility, not a verified join.
The command exits nonzero until an authoritative cross-API identity binding is
established; its JSON distinguishes response outcomes from P0 validation.
One metrics GET is made, followed only by advertised cursor pages (at most 10).
No aggregate endpoint, service inventory, legacy API, or Salt API is called.
Help and invalid arguments make no API requests. Errors are sanitized.
HELP
}

platform_metrics_diagnostic_parse_args() {
  PLATFORM_METRICS_DIAGNOSTIC_HELP=0
  PLATFORM_METRICS_DIAGNOSTIC_ID=''
  PLATFORM_METRICS_DIAGNOSTIC_START=''
  PLATFORM_METRICS_DIAGNOSTIC_END=''
  PLATFORM_METRICS_DIAGNOSTIC_JSON=0
  if [[ $# -eq 1 && ( "$1" == -h || "$1" == --help || "$1" == help ) ]]; then
    PLATFORM_METRICS_DIAGNOSTIC_HELP=1
    return
  fi
  [[ $# -ge 1 && "$1" =~ ^[A-Za-z0-9._-]{1,120}$ ]] ||
    die 'platform-metrics-diagnostic requires one exact workspace ID'
  PLATFORM_METRICS_DIAGNOSTIC_ID="$1"
  shift
  while (( $# > 0 )); do
    case "$1" in
      --start|--end)
        (( $# >= 2 )) || die "missing value for $1"
        if [[ "$1" == --start ]]; then
          [[ -z "$PLATFORM_METRICS_DIAGNOSTIC_START" ]] || die 'duplicate --start'
          PLATFORM_METRICS_DIAGNOSTIC_START="$2"
        else
          [[ -z "$PLATFORM_METRICS_DIAGNOSTIC_END" ]] || die 'duplicate --end'
          PLATFORM_METRICS_DIAGNOSTIC_END="$2"
        fi
        shift 2 ;;
      --json)
        (( PLATFORM_METRICS_DIAGNOSTIC_JSON == 0 )) || die 'duplicate --json'
        PLATFORM_METRICS_DIAGNOSTIC_JSON=1
        shift ;;
      *) die "unsupported platform-metrics-diagnostic argument: $1" ;;
    esac
  done
  local start_epoch end_epoch now
  start_epoch="$(jq -nr --arg value "$PLATFORM_METRICS_DIAGNOSTIC_START" '
    try (if ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00Z$"))
         then ($value | fromdateiso8601) else empty end) catch empty')"
  end_epoch="$(jq -nr --arg value "$PLATFORM_METRICS_DIAGNOSTIC_END" '
    try (if ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00Z$"))
         then ($value | fromdateiso8601) else empty end) catch empty')"
  [[ "$start_epoch" =~ ^[0-9]+$ && "$end_epoch" =~ ^[0-9]+$ ]] ||
    die 'start and end must be valid UTC midnight timestamps'
  [[ "$(date -u -r "$start_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)" == "$PLATFORM_METRICS_DIAGNOSTIC_START" ]] ||
    die 'invalid start calendar date'
  [[ "$(date -u -r "$end_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$end_epoch" +%Y-%m-%dT%H:%M:%SZ)" == "$PLATFORM_METRICS_DIAGNOSTIC_END" ]] ||
    die 'invalid end calendar date'
  (( end_epoch - start_epoch == 86400 )) || die 'range must be exactly one UTC day'
  now="$(date -u +%s)"
  (( end_epoch + 7200 <= now )) || die 'UTC day is unfinished or not yet settled'
  (( start_epoch >= now - 365 * 86400 )) || die 'UTC day exceeds Platform Metrics daily retention'
}

platform_metrics_diagnostic_emit() {
  local payload="$1"
  if (( PLATFORM_METRICS_DIAGNOSTIC_JSON )); then
    jq -c . <<<"$payload"
  else
    jq -r '
      "Customer: \(.customer.name) (\(.customer.id))",
      "Workspace: \(.workspace.id) [\(.workspace.ownership)]",
      "Entity candidate: \(.entity_id)",
      "Metric: \(.metric) (\(.unit)); \(.window.from) to \(.window.to)",
      "HTTP: \(.http_status // "not requested"); status: \(.status)",
      "Pages: \(.pages_fetched); pagination: \(.pagination_complete)",
      (if .api_validation_message then "API validation: \(.api_validation_message)" else empty end),
      (.observations[]? | "  \(.timestamp): \(if .present then (.value | tostring) else "omitted" end)"),
      "P0 compatibility: \(.entity_compatibility)"
    ' <<<"$payload"
  fi
}

platform_metrics_diagnostic_payload() {
  local cid="$1" customer="$2" id="$3" ownership="$4" status="$5" http_status="$6" pages="$7" complete="$8" observations="$9" metadata="${10}" error="${11}" detail_http="${12}" error_format="${13:-}" validation_message="${14:-}"
  jq -nc --arg cid "$cid" --arg customer "$customer" --arg id "$id" \
    --arg ownership "$ownership" --arg status "$status" --arg http "$http_status" \
    --argjson pages "$pages" --argjson complete "$complete" \
    --argjson observations "$observations" --argjson metadata "$metadata" \
    --arg error "$error" --arg detail_http "$detail_http" --arg error_format "$error_format" \
    --arg validation_message "$validation_message" --arg start "$PLATFORM_METRICS_DIAGNOSTIC_START" \
    --arg end "$PLATFORM_METRICS_DIAGNOSTIC_END" '
    {schema_version:1, command:"ngwaf platform-metrics-diagnostic",
     customer:{id:$cid,name:$customer}, workspace:{id:$id,ownership:$ownership,
       detail_http_status:$detail_http},
     entity_id:$id, entity_id_basis:"public_workspace_detail_id_candidate",
     entity_compatibility:"unverified_cross_api_identity",
     metric:"ngwaf_requests_total_count",unit:"requests",granularity:"day",
     window:{from:$start,to:$end,to_exclusive:true},
     endpoint:"GET /metrics/v2/platform/entities/{entity_id}/day",
     http_status:(if $http == "" then null else $http end),content_type:null,
     status:$status,error_category:(if $error == "" then null else $error end),
     error_body_format:(if $error_format == "" then null else $error_format end),
     api_validation_message:(if $validation_message == "" then null else $validation_message end),
     response_meta:$metadata,observations:$observations,
     pages_fetched:$pages,pagination_complete:$complete,
     bucket_coverage:(if ($observations | length) == 0 then "no_observation_not_zero"
                      elif any($observations[]; .present == false) then "metric_omitted_in_row"
                      else "requested_bucket_observed" end),
     p0_validated:false}'
}

# Map only known validation words and parameter names to fixed labels. Never
# echo API error text: it may contain identifiers, request data, or credentials.
platform_metrics_diagnostic_error_summary() {
  local file="$1" format
  format="$(agent_diagnostic_error_format "$file")"
  jq -c -s --arg format "$format" '
    def issue($text):
      if $text | test("(^|[^a-z])unsupported([^a-z]|$)"; "i") then "unsupported"
      elif $text | test("(^|[^a-z])(unknown|unrecognized)([^a-z]|$)"; "i") then "unknown"
      elif $text | test("(^|[^a-z])invalid([^a-z]|$)"; "i") then "invalid"
      else null end;
    def field($entry):
      ($entry.field // $entry.parameter // $entry.property //
        ($entry.source | if type == "object" then .parameter else null end) // null) as $field
      | if ($field | type) == "string" and
           (["from","to","metric","metric_set","limit","cursor","granularity","entity_id"] | index($field) != null)
        then $field else null end;
    if length != 1 or (.[0] | type) != "object" then
      {body_format:$format,classification:null,validation_message:null}
    else
      .[0] as $body
      | ($body.type == "https://fastly.help/metrics/validation-error") as $validation_type
      | [$body] + (if ($body.errors | type) == "array" then [$body.errors[] | select(type == "object")] else [] end)
      | [ .[] as $entry
          | [$entry.title?, $entry.detail?, $entry.message?, $entry.error?, $entry.reason?][]
          | select(type == "string" and length <= 500)
          | issue(.) as $issue
          | select($issue != null)
          | (field($entry)) as $field
          | (if $field != null then "parameter"
             elif test("(^|[^a-z])(entity|entity_id)([^a-z]|$)"; "i") then "entity"
             elif test("(^|[^a-z])metric([^a-z]|$)"; "i") then "metric"
             elif test("(^|[^a-z])parameters?([^a-z]|$)"; "i") then "parameter"
             else null end) as $subject
          | select($subject != null)
          | {issue:$issue,subject:$subject,field:$field} ]
      | (sort_by(.field == null) | .[0] // null) as $match
      | {body_format:$format,
         classification:(if $match == null then null elif $match.subject == "parameter" then "unsupported_parameter" else "unsupported_entity_or_metric" end),
         validation_message:(if $match == null and $validation_type then "Metrics API reports parameter validation error"
           elif $match == null then null
           elif $match.subject == "parameter" and $match.field != null then
             "API reports \($match.issue) \($match.field) parameter"
           else "API reports \($match.issue) \($match.subject)" end)}
    end
  ' "$file" 2>/dev/null || printf '{"body_format":"%s","classification":null,"validation_message":null}\n' "$format"
}

platform_metrics_diagnostic_page_json() {
  local file="$1" start="$2" end="$3" id="$4"
  jq -c -s --arg start "$start" --arg end "$end" --arg id "$id" '
    if length != 1 or (.[0] | type) != "object" then error("shape") else .[0] end
    | if (.meta | type) != "object" or (.data | type) != "array" then error("shape") else . end
    | if .meta.from != $start or .meta.to != $end or
         (.meta.limit | type) != "number" or .meta.limit < 1 or .meta.limit > 10000 or
         .meta.limit != (.meta.limit | floor) or (.data | length) > .meta.limit or
         ((.meta.group_by // "") != "") or
         (has("entity_id") and .entity_id != $id) or
         ((.meta | has("next_cursor")) and ((.meta.next_cursor | type) != "null" and
           ((.meta.next_cursor | type) != "string" or (.meta.next_cursor | length) == 0 or
             (.meta.next_cursor | length) > 512 or
             ((.meta.next_cursor | test("^[[:print:]]+$")) | not))))
      then error("metadata") else . end
    | if all(.data[];
        type == "object" and .timestamp == $start and
        (if has("ngwaf_requests_total_count") then
          (.ngwaf_requests_total_count | type) == "number" and
          .ngwaf_requests_total_count >= 0 and
          .ngwaf_requests_total_count == (.ngwaf_requests_total_count | floor)
        else true end))
      then {meta:{from:.meta.from,to:.meta.to,limit:.meta.limit,
                   next_cursor:(.meta.next_cursor // null)},
            observations:[.data[] | {timestamp,
              present:has("ngwaf_requests_total_count"),
              value:(.ngwaf_requests_total_count // null)}]}
      else error("observations") end
  ' "$file" 2>/dev/null
}

cmd_platform_metrics_diagnostic() {
  local cid customer id detail_file detail_code detail_valid path file code page cursor next_cursor
  local page_json observations='[]' metadata='null' pages=0 status error='' payload
  local error_format='' validation_message=''
  local -a seen=()
  cid="$(current_cid)"
  customer="$(current_customer_name)"
  id="$PLATFORM_METRICS_DIAGNOSTIC_ID"
  detail_file="$(mktemp)"
  detail_code="$(CURL_RETRIES=0 http_get_to_file "$(workspace_path "$id")" "$detail_file" \
    --data-urlencode "customer_id=$cid")"
  detail_valid=false
  if [[ "$detail_code" == 2* ]]; then
    if jq -e -s --arg id "$id" --arg cid "$cid" '
      length == 1 and (.[0] | type) == "object" and
      .[0].id == $id and
      ((.[0].customer_id? == $cid) or (.[0].customer.id? == $cid)) and
      (.[0].customer_id? == null or .[0].customer_id == $cid) and
      (.[0].customer.id? == null or .[0].customer.id == $cid)
    ' "$detail_file" >/dev/null 2>&1; then detail_valid=true; fi
  fi
  rm -f "$detail_file"
  if [[ "$detail_valid" != true ]]; then
    printf '%s: platform-metrics-diagnostic: exact workspace ownership unverified (detail HTTP %s); Metrics request skipped\n' \
      "${PROGRAM_NAME:-fastly-audit}" "$detail_code" >&2
    payload="$(platform_metrics_diagnostic_payload "$cid" "$customer" "$id" unverified ownership_unverified '' 0 false '[]' null 'workspace_detail_unverified' "$detail_code")"
    platform_metrics_diagnostic_emit "$payload"
    return 1
  fi

  # P0 blocker: scoped Metrics requests returned HTTP 400 (invalid parameter;
  # cause unknown). Workspace id -> entity_id is unverified; see NG-13 in
  # docs/known-limitations.md and docs/roadmap-platform-metrics.md.
  path="/metrics/v2/platform/entities/$(urlencode "$id")/day"
  cursor=''
  while :; do
    file="$(mktemp)"
    local -a query=(--data-urlencode "from=$PLATFORM_METRICS_DIAGNOSTIC_START"
                    --data-urlencode "to=$PLATFORM_METRICS_DIAGNOSTIC_END"
                    --data-urlencode 'metric=ngwaf_requests_total_count'
                    --data-urlencode 'limit=100')
    [[ -z "$cursor" ]] || query+=(--data-urlencode "cursor=$cursor")
    code="$(CURL_RETRIES=0 http_get_to_file "$path" "$file" "${query[@]}")"
    if [[ "$code" != 2* ]]; then
      case "$code" in
        401|403) status=authorization_failure; error=authentication_or_permission ;;
        400) status=invalid_request; error=unclassified_http_400 ;;
        404) status=not_found_unclassified; error=unclassified_http_404 ;;
        429) status=rate_limited; error=http_429 ;;
        5*) status=server_failure; error=http_5xx ;;
        *) status=request_failure; error=http_or_transport_failure ;;
      esac
      if [[ "$code" == 400 ]]; then
        local error_summary classification
        error_summary="$(platform_metrics_diagnostic_error_summary "$file")"
        error_format="$(jq -r '.body_format' <<<"$error_summary")"
        validation_message="$(jq -r '.validation_message // empty' <<<"$error_summary")"
        classification="$(jq -r '.classification // empty' <<<"$error_summary")"
        if [[ -n "$classification" ]]; then status="$classification"; error=explicit_api_error; fi
      fi
      if (( pages > 0 )); then
        error="pagination_$error"
        status=incomplete
      fi
      rm -f "$file"
      break
    fi
    page_json="$(platform_metrics_diagnostic_page_json "$file" "$PLATFORM_METRICS_DIAGNOSTIC_START" "$PLATFORM_METRICS_DIAGNOSTIC_END" "$id")" || page_json=''
    rm -f "$file"
    if [[ -z "$page_json" ]]; then status=invalid_response; error=malformed_metrics_response; break; fi
    observations="$(jq -nc --argjson old "$observations" --argjson new "$(jq -c '.observations' <<<"$page_json")" '$old + $new')"
    metadata="$(jq -c '.meta' <<<"$page_json")"
    pages=$(( pages + 1 ))
    if (( $(jq 'length' <<<"$observations") > 1 )); then
      status=invalid_response; error=duplicate_observation_key; break
    fi
    next_cursor="$(jq -r '.meta.next_cursor // empty' <<<"$page_json")"
    if [[ -z "$next_cursor" ]]; then
      if [[ "$observations" == '[]' ]]; then status=success_empty
      elif jq -e 'any(.[]; .present == false)' >/dev/null <<<"$observations"; then status=metric_omitted
      else status=success_with_data; fi
      break
    fi
    if (( pages >= 10 )); then status=incomplete; error=page_limit; break; fi
    if [[ "$next_cursor" == "$cursor" ]] ||
      printf '%s\n' "${seen[@]}" | rg -Fqx -- "$next_cursor"; then
      status=incomplete; error=repeated_cursor; break
    fi
    seen+=("$next_cursor")
    cursor="$next_cursor"
  done
  if [[ "$status" == success_with_data || "$status" == success_empty || "$status" == metric_omitted ]]; then
    payload="$(platform_metrics_diagnostic_payload "$cid" "$customer" "$id" verified "$status" "$code" "$pages" true "$observations" "$metadata" '' "$detail_code")"
  else
    printf '%s: platform-metrics-diagnostic: %s (HTTP %s); result incomplete or unavailable\n' \
      "${PROGRAM_NAME:-fastly-audit}" "$status" "$code" >&2
    payload="$(platform_metrics_diagnostic_payload "$cid" "$customer" "$id" verified "$status" "$code" "$pages" false '[]' null "$error" "$detail_code" "$error_format" "$validation_message")"
  fi
  platform_metrics_diagnostic_emit "$payload"
  # A 200 response tests this candidate path; it does not prove the cross-API
  # entity-ID mapping because the published response has no ownership binding.
  if [[ "$status" == success_with_data || "$status" == success_empty || "$status" == metric_omitted ]]; then
    printf '%s: platform-metrics-diagnostic: Metrics entity ID mapping remains unverified; P0 validation is incomplete\n' \
      "${PROGRAM_NAME:-fastly-audit}" >&2
  fi
  return 1
}
