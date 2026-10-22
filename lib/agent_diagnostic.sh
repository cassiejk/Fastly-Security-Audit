# shellcheck shell=bash
# AGENT_DIAGNOSTIC_* parser results are consumed by lib/dispatch.sh.
# shellcheck disable=SC2034
# Sourced by the fastly-audit entry point; do not execute directly.

agent_diagnostic_usage() {
  cat <<'HELP'
Inspect one selected-customer workspace's identity and Agents API response.

Usage:
  fastly-audit ngwaf agent-diagnostic <workspace-id> [--json]

The ID must match an id in the selected customer's workspace inventory exactly.
This read-only diagnostic retrieves that workspace's detail with the selected
customer_id, then makes one Agents API request using the verified detail id
when available.
If detail returns 404 Site not found, it uses the exact ID from the validated,
selected-customer workspace inventory and reports the detail failure separately.
It does not try workspace_uid, other identifiers, or legacy APIs. The sanitized
JSON reports HTTP status, identity checks, the count of returned data records,
and the raw API meta.total value; it omits individual agent and host data.

Limitations:
  Agent observations do not establish deployment architecture, active traffic
  inspection, CDN attachments, WAFD migration, or enforcement effectiveness.
  An empty response does not prove the workspace is undeployed or inactive.
  Agreement or disagreement between data length and meta.total does not prove
  inventory completeness; the meaning of meta.total is unverified.

Authentication headers are never included in the output.
Help and usage errors make no API requests.
HELP
}

agent_diagnostic_parse_args() {
  AGENT_DIAGNOSTIC_ID=''
  if [[ $# -eq 1 && ( "$1" == help || "$1" == -h || "$1" == --help ) ]]; then
    AGENT_DIAGNOSTIC_HELP=1
    return
  fi
  AGENT_DIAGNOSTIC_HELP=0
  [[ $# -eq 1 || ( $# -eq 2 && "$2" == --json ) ]] ||
    die 'usage: fastly-audit ngwaf agent-diagnostic <workspace-id> [--json]'
  [[ -n "$1" && "$1" != -* && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* ]] ||
    die 'agent-diagnostic requires one exact workspace ID'
  AGENT_DIAGNOSTIC_ID="$1"
}

# Pass through only simple, short API error text. Unknown response fields, host
# data, URLs, and strings resembling credentials never enter the report.
agent_diagnostic_error_json() {
  local body_file="$1"
  jq -c '
    def safe_text:
      if type == "string" and length > 0 and length <= 120 and
         test("^[A-Za-z][A-Za-z0-9 ._-]*$") and
         (test("token|secret|password|cookie|authorization|bearer|credential|session|api.?key"; "i") | not)
      then . else null end;
    if type == "object" then
      {title: ((.title // null) | safe_text),
       detail: ((.detail // null) | safe_text),
       message: ((.message // .error // null) | safe_text)}
      | with_entries(select(.value != null))
    else {} end
  ' "$body_file" 2>/dev/null || printf '{}\n'
}

agent_diagnostic_error_format() {
  local body_file="$1"
  if [[ ! -s "$body_file" ]]; then
    printf 'empty\n'
  elif jq -e -s 'length == 1 and (.[0] | type) == "object"' "$body_file" >/dev/null 2>&1; then
    printf 'json_object\n'
  elif jq -e -s 'length == 1' "$body_file" >/dev/null 2>&1; then
    printf 'other_json\n'
  else
    printf 'invalid_json\n'
  fi
}

cmd_ngwaf_agent_diagnostic() {
  local id="$AGENT_DIAGNOSTIC_ID" cid inventory row detail_file agent_file
  local detail_path detail_url agent_path agent_url detail_code agent_code detail detail_projection detail_validation
  local detail_error='{}' detail_error_format='null' agent_error='{}' agent_summary='null'
  local inventory_fallback=false
  cid="$(current_cid)"

  inventory="$(get_all_pages /ngwaf/v1/workspaces --data-urlencode "customer_id=$cid")" || return 1
  jq -e --arg cid "$cid" '
    type == "object" and (.data | type == "array") and
    (.meta.total | type == "number" and . >= 0 and floor == .) and
    .meta.total == (.data | length) and
    all(.data[]; type == "object" and (.id | type == "string" and length > 0) and
      (if has("customer_id") then .customer_id == $cid else true end) and
      (if (.customer | type) == "object" and (.customer | has("id"))
       then .customer.id == $cid else true end)) and
    ([.data[].id] | length == (unique | length))
  ' >/dev/null <<<"$inventory" || die 'agent-diagnostic: workspace inventory is incomplete or has conflicting ownership metadata'

  row="$(jq -c --arg id "$id" '[.data[] | select(.id == $id)] | if length == 1 then .[0] else empty end' <<<"$inventory")"
  [[ -n "$row" ]] || die 'agent-diagnostic: exact workspace ID not found in selected customer inventory'

  detail_path="$(workspace_path "$id")"
  detail_url="$API_BASE$detail_path?customer_id=$(urlencode "$cid")"
  detail_file="$(mktemp)"
  detail_code="$(CURL_RETRIES=0 http_get_to_file "$detail_path" "$detail_file" \
    --data-urlencode "customer_id=$cid")"
  detail_validation='lookup_failed'
  detail_projection='null'
  if [[ "$detail_code" == 2* ]]; then
    detail_validation="$(jq -r -s --arg id "$id" --arg cid "$cid" --argjson row "$row" '
      if length != 1 or (.[0] | type) != "object" then "malformed_response"
      else .[0] |
        if (.id | type) != "string" then "malformed_response"
        elif .id != $id then "identifier_mismatch"
        elif has("customer_id") and .customer_id != $cid then "ownership_mismatch"
        elif (.customer | type) == "object" and (.customer | has("id")) and .customer.id != $cid
          then "ownership_mismatch"
        elif (($row.workspace_uid // "") | length) > 0 and ((.workspace_uid // "") | length) > 0 and
             .workspace_uid != $row.workspace_uid then "workspace_uid_mismatch"
        else "verified" end
      end
    ' "$detail_file" 2>/dev/null)" || detail_validation='malformed_response'
    detail_projection="$(jq -c -s '
      if length == 1 and (.[0] | type) == "object" then .[0] |
      if type == "object" then
        {id:(if (.id | type) == "string" and (.id | test("^[A-Za-z0-9._-]{1,120}$")) then .id else null end),
         workspace_uid:(if (.workspace_uid | type) == "string" and
                           (.workspace_uid | test("^[A-Za-z0-9._-]{0,120}$"))
                        then .workspace_uid else null end)}
        else null end
      else null end
    ' "$detail_file" 2>/dev/null)" || detail_projection='null'
  else
    detail_error="$(agent_diagnostic_error_json "$detail_file")"
    detail_error_format="$(agent_diagnostic_error_format "$detail_file")"
  fi
  if [[ "$detail_validation" == lookup_failed && "$detail_code" == 404 ]] &&
    jq -e '.detail == "Site not found"' >/dev/null <<<"$detail_error"; then
    inventory_fallback=true
  fi
  if [[ "$detail_validation" != verified && "$inventory_fallback" != true ]]; then
    rm -f "$detail_file"
    printf '%s: agent-diagnostic: workspace detail %s (HTTP %s); no Agents request made\n' \
      "${PROGRAM_NAME:-fastly-audit}" "$detail_validation" "$detail_code" >&2
    jq -nc --arg cid "$cid" --arg id "$id" --arg code "$detail_code" \
      --arg path "$detail_path" --arg url "$detail_url" --arg detail_status "$detail_validation" \
      --arg error_format "$detail_error_format" --argjson api_error "$detail_error" \
      --argjson row "$row" --argjson detail "$detail_projection" '
      {schema_version:1, command:"ngwaf agent-diagnostic", customer_id:$cid,
       requested_workspace_id:$id, status:"blocked",
       workspace_detail_request:{method:"GET",url:$url,path:$path,http_status:$code,
         status:$detail_status,api_error:(if $detail_status == "lookup_failed" then $api_error else null end),
         error_body_format:(if $detail_status == "lookup_failed" then $error_format else null end)},
       workspace_metadata:{inventory:{id:$row.id,workspace_uid:($row.workspace_uid // null)},
         detail:$detail, id_match:(if $detail == null or $detail.id == null then null else $row.id == $detail.id end),
         workspace_uid_match:(if $detail != null and (($row.workspace_uid // "") | length) > 0 and
                                   (($detail.workspace_uid // "") | length) > 0
                              then $row.workspace_uid == $detail.workspace_uid else null end),
         detail_http_status:$code, ownership_verified:false},
       agents_request:{status:"skipped",reason:("workspace detail " + $detail_status + "; no Agents request made"),
         http_status:null, path:null}}
    '
    return 1
  fi
  if [[ "$inventory_fallback" == true ]]; then
    detail='null'
    printf '%s: agent-diagnostic: workspace detail HTTP 404 (Site not found); using selected-customer inventory ID for Agents request\n' \
      "${PROGRAM_NAME:-fastly-audit}" >&2
  else
    detail="$(jq -c '{id,workspace_uid:(.workspace_uid // null)}' "$detail_file")"
  fi
  rm -f "$detail_file"

  agent_path="$detail_path/agents"
  agent_url="$API_BASE$agent_path?customer_id=$(urlencode "$cid")"
  agent_file="$(mktemp)"
  agent_code="$(CURL_RETRIES=0 http_get_to_file "$agent_path" "$agent_file" \
    --data-urlencode "customer_id=$cid")"
  if [[ "$agent_code" != 2* ]]; then
    agent_error="$(agent_diagnostic_error_json "$agent_file")"
  else
    agent_summary="$(jq -c --arg id "$id" '
      if type == "object" and (.data | type) == "array" then
        {agent_count:(.data | length),
         reported_total:(if (.meta.total | type) == "number" and .meta.total >= 0 and (.meta.total | floor) == .meta.total
                         then .meta.total else null end),
         response_workspace_match:(
           if (.data | length) == 0 then "unverifiable"
           elif any(.data[]; type == "object" and has("workspace_id") and .workspace_id != $id) then "mismatch"
           elif all(.data[]; type == "object" and has("workspace_id") and .workspace_id == $id) then "matched"
           else "unverifiable" end),
         total_matches_returned_count:(if (.meta.total | type) == "number" then .meta.total == (.data | length) else null end)}
      else null end
    ' "$agent_file" 2>/dev/null)" || agent_summary='null'
  fi

  jq -nc --arg cid "$cid" --arg id "$id" --arg path "$agent_path" --arg agent_url "$agent_url" \
    --arg detail_path "$detail_path" --arg detail_url "$detail_url" --arg detail_code "$detail_code" \
    --arg detail_status "$detail_validation" --arg detail_error_format "$detail_error_format" \
    --argjson detail_error "$detail_error" \
    --argjson inventory_fallback "$inventory_fallback" \
    --arg code "$agent_code" --argjson inventory_row "$row" \
    --argjson detail "$detail" --argjson api_error "$agent_error" --argjson agent_summary "$agent_summary" '
      ($code | startswith("2")) as $http_ok
      | ($agent_summary.response_workspace_match // "unverifiable") as $agent_reference
      | {
          schema_version: 1,
          command: "ngwaf agent-diagnostic",
          customer_id: $cid,
          requested_workspace_id: $id,
          workspace_detail_request:{method:"GET",url:$detail_url,path:$detail_path,
            http_status:$detail_code,status:$detail_status,
            api_error:(if $inventory_fallback then $detail_error else null end),
            error_body_format:(if $inventory_fallback then $detail_error_format else null end)},
          workspace_metadata: {
            inventory: {id:$inventory_row.id, workspace_uid:($inventory_row.workspace_uid // null)},
            detail: $detail,
            id_match: (if $detail == null then null else $inventory_row.id == $detail.id end),
            workspace_uid_match: (if $detail != null and (($inventory_row.workspace_uid // "") | length) > 0 and
                                    (($detail.workspace_uid // "") | length) > 0
                                  then $inventory_row.workspace_uid == $detail.workspace_uid
                                  else null end),
            ownership_verified:true,
            ownership_evidence:(if $inventory_fallback then "selected_customer_workspace_inventory"
                                else "workspace_detail_and_inventory" end)
          },
          agents_request: {
            method: "GET", url:$agent_url, path:$path,
            identifier_field:(if $inventory_fallback then "selected-customer inventory id" else "workspace detail id" end),
            identifier:$id, http_status:$code,
            status:(if $http_ok and $agent_summary != null then "returned"
                    elif $http_ok then "unusable_response" else "unavailable" end),
            api_error:(if $http_ok then null else $api_error end),
            agent_count:($agent_summary.agent_count // null),
            reported_total:($agent_summary.reported_total // null),
            response_complete:null,
            total_matches_returned_count:(if $agent_summary != null and ($agent_summary | has("total_matches_returned_count"))
                                          then $agent_summary.total_matches_returned_count else null end),
            response_workspace_match:$agent_reference
          },
          interpretation:(if $agent_reference == "matched" then "Agent records explicitly reference the verified workspace ID."
            elif $agent_reference == "mismatch" then "Agent records contain a different workspace ID; do not use them as deployment evidence."
            elif $http_ok then "The request used the verified workspace ID, but the response does not prove agent-to-workspace identity."
            else "The request used the verified workspace ID, but the Agents API did not return usable deployment evidence." end)
        }
    '
  rm -f "$agent_file"
}
