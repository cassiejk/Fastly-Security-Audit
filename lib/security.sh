# shellcheck shell=bash
# Sourced by the fastly-audit entry point; do not execute directly.

collect_security_products_json() {
  [[ $# -ge 1 && $# -le 2 ]] || die 'collect_security_products_json requires <services-json> [config-mode]'

  local services_body="$1"
  local config_mode="${2:-summary}"
  local tmp product_id label config_kind category request_config checked=0 total
  [[ "$config_mode" == 'summary' || "$config_mode" == 'detailed' ]] ||
    die 'collect_security_products_json config mode must be summary or detailed'
  tmp="$(mktemp)"
  total="$(service_product_specs | awk -F '\t' '$4 == "security" {n++} END {print n+0}')"

  while IFS=$'\t' read -r product_id label config_kind category; do
    [[ -n "$product_id" && "$category" == 'security' ]] || continue
    request_config='true'
    if [[ "$config_mode" != 'detailed' && ( "$product_id" == 'bot_management' || "$product_id" == 'ddos_protection' ) ]]; then
      request_config='false'
    fi
    discover_product_json "$product_id" "$label" "$config_kind" "$category" "$services_body" "$request_config" >>"$tmp"
    checked=$((checked + 1))
    progress_job_milestone 'Security product checks' "$checked" "$total"
  done < <(service_product_specs)

  jq -s '.' "$tmp"
  rm -f "$tmp"
}

legacy_map_usage() {
  die 'usage: fastly-audit security legacy-map [service-name-or-id] [--sigsci-corp CORP] [--format human|json|csv] [--output FILE]'
}

# TODO(legacy-sigsci-auth): Internal Fastly-only SigSci/Salt API; browser-session
# dstoken/VouchCookie are passed via FASTLY_DSTOKEN/FASTLY_VOUCH_COOKIE. This is
# not the public NGWAF Agents API authenticated with FASTLY_API_TOKEN.
# manage.fastly.com uses OIDC/OAuth and does not provide these cookies. Replace
# this dependency if the legacy dashboard/auth flow is retired.
internal_ngwaf_require_credentials() {
  local context="${1:-internal NGWAF site inventory}"
  local -a missing=()
  [[ -n "${FASTLY_DSTOKEN:-}" ]] || missing+=(FASTLY_DSTOKEN)
  [[ -n "${FASTLY_VOUCH_COOKIE:-}" ]] || missing+=(FASTLY_VOUCH_COOKIE)
  (( ${#missing[@]} > 0 )) || return 0
  printf '%s: missing required credentials for %s:\n' "${PROGRAM_NAME:-fastly-audit}" "$context" >&2
  printf '  %s\n' "${missing[@]}" >&2
  printf '\nSet the missing credential(s) from a legacy Signal Sciences dashboard session and retry.\n' >&2
  return 1
}

legacy_map_internal_get_to_file() {
  [[ $# -eq 2 ]] || die 'legacy_map_internal_get_to_file requires <path> <output-file>'

  local path="$1"
  local outfile="$2"
  local base="${FASTLY_NGWAF_INTERNAL_API_BASE:-https://sigsci-console-internal.secretcdn.net/api}"
  local url code err_tmp curl_rc=0
  local -a retry_args=(--retry "$CURL_RETRIES")

  internal_ngwaf_require_credentials 'internal NGWAF site inventory' || return 1

  validate_http_settings
  if (( CURL_RETRIES > 0 )); then
    retry_args+=(
      --retry-delay 1
      --retry-max-time "$CURL_RETRY_MAX_TIME"
      --retry-connrefused
    )
  fi

  err_tmp="$(mktemp)"
  url="${base%/}/$path"
  if code="$(
    curl -sS \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      "${retry_args[@]}" \
      -o "$outfile" \
      -w '%{http_code}' \
      -H "Accept: application/json" \
      -H "Cookie: dstoken=$FASTLY_DSTOKEN; VouchCookie=$FASTLY_VOUCH_COOKIE" \
      "$url" \
      2>"$err_tmp"
  )"; then
    curl_rc=0
  else
    curl_rc=$?
  fi

  if (( curl_rc != 0 )); then
    printf '%s: internal NGWAF API transport failed (curl exit %s): GET %s\n' \
      "${PROGRAM_NAME:-ngwaf}" "$curl_rc" "$path" >&2
    if [[ -s "$err_tmp" ]]; then
      sed "s/^/${PROGRAM_NAME:-ngwaf}: curl: /" "$err_tmp" >&2
    fi
    rm -f "$err_tmp"
    printf '000\n'
    return
  fi

  rm -f "$err_tmp"
  printf '%s\n' "$code"
}

legacy_map_fetch_sites_json() {
  [[ $# -eq 1 ]] || die 'legacy_map_fetch_sites_json requires <corp>'

  local corp="$1"
  local tmp code retrieved_at error_type error_reason recommended_action
  tmp="$(mktemp)"
  retrieved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  code="$(legacy_map_internal_get_to_file "v0/corps/$(urlencode "$corp")/sites" "$tmp")"
  if [[ "$code" == 2* ]] && jq -e '.data | type == "array"' >/dev/null 2>&1 <"$tmp"; then
    jq --arg retrieved_at "$retrieved_at" '
      {
        status: "COMPLETE",
        evidence_type: "DIRECT",
        source: "GET internal-ngwaf/v0/corps/{corp}/sites",
        retrieved_at: $retrieved_at,
        reason: "internal NGWAF sites retrieved",
        data: (.data // [])
      }
    ' "$tmp"
  elif [[ "$code" == 2* ]]; then
    jq -n --arg retrieved_at "$retrieved_at" \
      '{
        status: "UNKNOWN",
        evidence_type: "UNKNOWN",
        source: "GET internal-ngwaf/v0/corps/{corp}/sites",
        retrieved_at: $retrieved_at,
        reason: "internal NGWAF sites response did not contain a data array",
        data: []
      }'
  else
    case "$code" in
      302)
        error_type='AUTH_REDIRECT'
        error_reason='internal NGWAF session was redirected; likely expired or invalid internal session cookies'
        recommended_action='refresh FASTLY_DSTOKEN and FASTLY_VOUCH_COOKIE from a legacy Signal Sciences dashboard session, then retry'
        ;;
      401)
        error_type='AUTH_FAILED'
        error_reason='internal NGWAF authentication failed'
        recommended_action='refresh FASTLY_DSTOKEN and FASTLY_VOUCH_COOKIE from a legacy Signal Sciences dashboard session'
        ;;
      403)
        error_type='ACCESS_DENIED'
        error_reason='internal NGWAF authentication succeeded but access was denied'
        recommended_action='verify account access / permissions for the requested corp'
        ;;
      404)
        error_type='NOT_FOUND'
        error_reason='requested internal NGWAF resource was not found'
        recommended_action=''
        ;;
      3*)
        error_type='AUTH_REDIRECT'
        error_reason='internal NGWAF request was redirected unexpectedly'
        recommended_action='verify the internal NGWAF endpoint; if redirected to authentication, refresh FASTLY_DSTOKEN and FASTLY_VOUCH_COOKIE from a legacy Signal Sciences dashboard session'
        ;;
      4*|5*)
        error_type='HTTP_ERROR'
        error_reason='internal NGWAF sites query failed'
        recommended_action=''
        ;;
      *)
        error_type='UNKNOWN'
        error_reason='internal NGWAF sites query failed'
        recommended_action=''
        ;;
    esac
    jq -n --arg retrieved_at "$retrieved_at" --arg code "$code" \
      --arg error_type "$error_type" \
      --arg error_reason "$error_reason" \
      --arg recommended_action "$recommended_action" \
      '{
        status: "UNKNOWN",
        evidence_type: "UNKNOWN",
        source: "GET internal-ngwaf/v0/corps/{corp}/sites",
        retrieved_at: $retrieved_at,
        reason: ($error_reason + " (HTTP " + $code + " from internal NGWAF sites API)"),
        internal_ngwaf_http_status: ($code | tonumber? // $code),
        internal_ngwaf_error_type: $error_type,
        internal_ngwaf_error_reason: $error_reason,
        internal_ngwaf_recommended_action: (if $recommended_action == "" then null else $recommended_action end),
        data: []
      }'
  fi
  rm -f "$tmp"
}

legacy_map_trace_enabled() {
  [[ "${FASTLY_AUDIT_LEGACY_MAP_TRACE:-0}" == "1" ]]
}

legacy_map_trace() {
  legacy_map_trace_enabled || return 0
  printf '%s: legacy-map trace: %s\n' "${PROGRAM_NAME:-ngwaf}" "$*" >&2
}

# Only these scoped mapping probes use this projection. Never copy API error
# text into output: even an error response can contain customer configuration.
workspace_services_failure_json() {
  [[ $# -eq 4 ]] || die 'workspace_services_failure_json requires <endpoint-template> <http-status> <body-file> <failure-kind>'
  local endpoint="$1" code="$2" body="$3" kind="$4" format category=unavailable
  if [[ ! -s "$body" ]]; then
    format=empty
  elif jq -e -s 'length == 1 and (.[0] | type) == "object"' "$body" >/dev/null 2>&1; then
    format=json_object
  elif jq -e -s 'length == 1' "$body" >/dev/null 2>&1; then
    format=other_json
  else
    format=invalid_json
  fi
  if [[ "$format" == json_object ]]; then
    category="$(jq -r '
      [.title?, .detail?, .message?, .error?] | map(select(type == "string")) as $values
      | if ($values | index("Site not found")) != null then "site_not_found"
        elif ($values | index("This resource does not exist")) != null or
             ($values | index("Not Found")) != null then "resource_not_found"
        elif ($values | index("The request is not valid")) != null or
             ($values | index("Bad Request")) != null then "invalid_request"
        elif ($values | index("Forbidden")) != null or
             ($values | index("Access denied")) != null then "access_denied"
        elif ($values | index("Unauthorized")) != null then "unauthorized"
        else "unrecognized" end
    ' "$body")" || return 1
  fi
  jq -nc --arg endpoint "$endpoint" --arg code "$code" --arg format "$format" \
    --arg category "$category" --arg kind "$kind" '
      {endpoint:$endpoint,
       http_status:(if ($code | test("^[1-5][0-9]{2}$")) then ($code | tonumber) else null end),
       transport_failure_category:(if $code == "000" then "no_http_response" else null end),
       response_format:$format,api_error_category:$category,failure_kind:$kind}'
}

legacy_map_lookup_inspection_service_json() {
  [[ $# -eq 4 ]] || die 'legacy_map_lookup_inspection_service_json requires <service-id> <retrieved-at> <services-file> <output-file>'

  local sid="$1"
  local retrieved_at="$2"
  local services_file="$3"
  local outfile="$4"
  local detail_tmp code normalized inventory_hit started_at elapsed returned_id failure kind

  legacy_map_trace "resolving serviceID: $sid"
  inventory_hit="unknown"
  if [[ -n "$services_file" && -s "$services_file" ]]; then
    if jq -e --arg sid "$sid" 'any(.data[]?; (.id // "") == $sid)' >/dev/null <"$services_file"; then
      inventory_hit="yes"
    else
      inventory_hit="no"
    fi
    legacy_map_trace "canonical customer service inventory hit for $sid: $inventory_hit"
  fi

  detail_tmp="$(mktemp)"
  started_at="$(date +%s)"
  legacy_map_trace "direct Fastly API lookup: GET /service/$sid"
  code="$(NGWAF_HTTP_REDACT_CURL_STDERR=1 http_get_to_file "/service/$sid" "$detail_tmp")"
  elapsed=$(( $(date +%s) - started_at ))
  legacy_map_trace "direct Fastly API lookup completed: /service/$sid HTTP $code in ${elapsed}s"
  if [[ "$code" == 2* ]] && normalized="$(
    jq --arg service_id "$sid" '
      def service_object:
        if type == "object" and (.id | type) == "string" then .
        elif type == "object" and (.ServiceID | type) == "string" then
          {
            id: .ServiceID,
            name: (.Name // ""),
            type: (.Type // "unknown"),
            customer_id: (.CustomerID // .CustomerId // null)
          }
        elif type == "object" and ((.service // null) | type) == "object" and (.service.id | type) == "string" then .service
        elif type == "object" and ((.data // null) | type) == "object" and (.data.id | type) == "string" then
          (.data
           | if ((.attributes // null) | type) == "object" then (. + .attributes) else . end)
        else empty
        end;
      service_object
      | select((.id // "") == $service_id)
      | {
          id,
          service_id: .id,
          name: (.name // ""),
          type: (.type // "unknown"),
          customer_id: (.customer_id // null)
        }
    ' "$detail_tmp"
  )" && [[ -n "$normalized" ]]; then
    jq -n --arg service_id "$sid" --arg retrieved_at "$retrieved_at" \
      --arg code "$code" --argjson service "$normalized" \
      '{service_id: $service_id, status: "COMPLETE", evidence_type: "DIRECT", source: "GET /service/{serviceID}", retrieved_at: $retrieved_at, reason: "Fastly Inspection Service resolved directly from NGWAF site serviceID", service: $service,
        lookup_http_status:($code | tonumber),lookup_response_format:"json_object"}' >"$outfile"
    rm -f "$detail_tmp"
    return 0
  elif [[ "$code" == 2* ]]; then
    if ! jq -e -s 'length == 1' "$detail_tmp" >/dev/null 2>&1; then
      kind=malformed_response
    else
      returned_id="$(jq -r 'try (if type == "object" then .id // .ServiceID // .service.id // .data.id // empty else empty end) catch empty' "$detail_tmp")"
      if [[ -n "$returned_id" && "$returned_id" != "$sid" ]]; then
        kind=identity_mismatch
      else
        kind=unexpected_schema
      fi
    fi
    failure="$(workspace_services_failure_json 'GET /service/{serviceID}' "$code" "$detail_tmp" "$kind")" || return 1
    jq -n --arg service_id "$sid" --arg retrieved_at "$retrieved_at" --argjson failure "$failure" \
      '{service_id: $service_id, status: "UNKNOWN", evidence_type: "UNKNOWN", source: "GET /service/{serviceID}", retrieved_at: $retrieved_at, reason: "Fastly direct Inspection Service lookup returned an unrecognized service shape or mismatched id", service: null, failure:$failure}' >"$outfile"
  else
    if [[ "$code" == 000 ]]; then kind=transport_failure; else kind=http_status; fi
    failure="$(workspace_services_failure_json 'GET /service/{serviceID}' "$code" "$detail_tmp" "$kind")" || return 1
    jq -n --arg service_id "$sid" --arg status "$code" --arg retrieved_at "$retrieved_at" --argjson failure "$failure" \
      '{service_id: $service_id, status: "UNKNOWN", evidence_type: "UNKNOWN", source: "GET /service/{serviceID}", retrieved_at: $retrieved_at, reason: ("Fastly direct Inspection Service lookup failed: HTTP " + $status), service: null, failure:$failure}' >"$outfile"
  fi
  rm -f "$detail_tmp"
  return 1
}

legacy_map_validate_inspection_services_json() {
  [[ $# -eq 2 ]] || die 'legacy_map_validate_inspection_services_json requires <inspection-services-json> <selected-customer-id>'
  jq --arg cid "$2" '
    map(if .status != "COMPLETE" then .
      else
        (if (.service.customer_id | type) != "string" or .service.customer_id == "" then "ownership_unverified"
         elif .service.customer_id == $cid then "verified"
         else "ownership_mismatch" end) as $ownership
        | .ownership_validation_status = $ownership
        | if $ownership == "verified" then .
          else
            .failure = {endpoint:"GET /service/{serviceID}",http_status:(.lookup_http_status // null),
              transport_failure_category:null,response_format:(.lookup_response_format // null),
              api_error_category:"none",failure_kind:$ownership}
            | .status = "UNKNOWN"
            | .reason = "Inspection Service customer ownership could not be verified"
            | .service = null
          end
      end)
  ' <<<"$1"
}

legacy_map_validate_sites_customer_json() {
  [[ $# -eq 5 ]] || die 'legacy_map_validate_sites_customer_json requires <sites-result-json> <selected-customer-id> <selected-customer-name> <corp> <corp-source>'

  local sites_result="$1"
  local selected_cid="$2"
  local selected_name="$3"
  local corp="$4"
  local corp_source="$5"
  local validation status reason returned_ids returned_count returned_display

  validation="$(
    jq --arg selected_cid "$selected_cid" --arg corp "$corp" --arg corp_source "$corp_source" '
      def site_customer_ids:
        [.customer_id, .customerID, .customerId, .customer.id?]
        | map(select(type == "string" and length > 0)) | unique;
      def site_ownership:
        site_customer_ids as $ids
        | if ($ids | length) == 0 then "ownership_unverified"
          elif any($ids[]; . != $selected_cid) then "ownership_mismatch"
          else "verified" end;
      (.status // "UNKNOWN") as $status
      | ([.data[]? | site_customer_ids[]] | unique) as $ids
      | ([.data[]? | select(site_ownership == "verified")] | length) as $verified
      | ([.data[]? | select(site_ownership == "ownership_unverified")] | length) as $unverified
      | ([.data[]? | select(site_ownership == "ownership_mismatch")] | length) as $conflicting
      | {verified:$verified,unverified:$unverified,conflicting:$conflicting} as $counts
      | if $status != "COMPLETE" then
          {
            corp_validation_status: "UNKNOWN",
            status: $status,
            reason: (.reason // "internal NGWAF sites unavailable"),
            selected_customer_id: $selected_cid,
            sigsci_corp: $corp,
            sigsci_corp_source: $corp_source,
            sigsci_customer_id: null,
            returned_customer_ids: $ids,
            site_ownership_counts: $counts
          }
        elif $conflicting == 0 and $verified > 0 and $unverified > 0 then
          {
            corp_validation_status: "PARTIAL", status: "PARTIAL",
            reason: "SIGSCI corp site ownership is only partially verified",
            selected_customer_id: $selected_cid, sigsci_corp: $corp,
            sigsci_corp_source: $corp_source, sigsci_customer_id: $selected_cid,
            returned_customer_ids: $ids, site_ownership_counts: $counts
          }
        elif $conflicting == 0 and $verified > 0 and $unverified == 0 then
          {
            corp_validation_status: "VALID",
            status: $status,
            reason: "SIGSCI corp site customer_id matches selected Fastly customer",
            selected_customer_id: $selected_cid,
            sigsci_corp: $corp,
            sigsci_corp_source: $corp_source,
            sigsci_customer_id: $ids[0],
            returned_customer_ids: $ids,
            site_ownership_counts: $counts
          }
        elif ($ids | length) == 1 then
          {
            corp_validation_status: "MISMATCH",
            status: $status,
            reason: "SIGSCI corp returned NGWAF sites for a different customer_id",
            selected_customer_id: $selected_cid,
            sigsci_corp: $corp,
            sigsci_corp_source: $corp_source,
            sigsci_customer_id: $ids[0],
            returned_customer_ids: $ids,
            site_ownership_counts: $counts
          }
        elif ($ids | length) > 1 then
          {
            corp_validation_status: "AMBIGUOUS",
            status: $status,
            reason: "SIGSCI corp returned NGWAF sites with multiple customer_id values",
            selected_customer_id: $selected_cid,
            sigsci_corp: $corp,
            sigsci_corp_source: $corp_source,
            sigsci_customer_id: null,
            returned_customer_ids: $ids,
            site_ownership_counts: $counts
          }
        else
          {
            corp_validation_status: "UNKNOWN",
            status: $status,
            reason: "SIGSCI corp returned NGWAF sites without customer_id evidence",
            selected_customer_id: $selected_cid,
            sigsci_corp: $corp,
            sigsci_corp_source: $corp_source,
            sigsci_customer_id: null,
            returned_customer_ids: $ids,
            site_ownership_counts: $counts
          }
        end
    ' <<<"$sites_result"
  )"

  status="$(jq -r '.corp_validation_status' <<<"$validation")"
  if [[ "$status" != "VALID" && "$(jq -r '.status' <<<"$validation")" == "COMPLETE" ]]; then
    reason="$(jq -r '.reason' <<<"$validation")"
    returned_ids="$(jq -r '.returned_customer_ids[]?' <<<"$validation" | paste -sd ',' -)"
    returned_count="$(jq '.returned_customer_ids | length' <<<"$validation")"
    if [[ -z "$returned_ids" ]]; then
      returned_display="none"
    else
      returned_display="$returned_ids"
    fi
    {
      printf '%s: SIGSCI corp/customer mismatch:\n' "${PROGRAM_NAME:-ngwaf}"
      printf '%s:   selected Fastly customer: %s (%s)\n' "${PROGRAM_NAME:-ngwaf}" "$selected_name" "$selected_cid"
      printf '%s:   queried SIGSCI corp: %s (%s)\n' "${PROGRAM_NAME:-ngwaf}" "$corp" "$corp_source"
      printf '%s:   returned site customer_id: %s\n' "${PROGRAM_NAME:-ngwaf}" "$returned_display"
      printf '%s:   validation status: %s\n' "${PROGRAM_NAME:-ngwaf}" "$status"
      printf '%s:   reason: %s\n' "${PROGRAM_NAME:-ngwaf}" "$reason"
      if [[ "$returned_count" != "1" ]]; then
        printf '%s: Use --sigsci-corp <corp> or set SIGSCI_CORP for this customer; refusing ambiguous or unvalidated internal site evidence.\n' "${PROGRAM_NAME:-ngwaf}"
      else
        printf '%s: Use --sigsci-corp <corp> or set SIGSCI_CORP for this customer.\n' "${PROGRAM_NAME:-ngwaf}"
      fi
    } >&2
    return 1
  fi

  printf '%s\n%s\n' "$sites_result" "$validation" |
    jq -s '
      def site_customer_ids:
        [.customer_id, .customerID, .customerId, .customer.id?]
        | map(select(type == "string" and length > 0)) | unique;
      .[0] as $sites
      | .[1] as $validation
      | $sites + {
          status: $validation.status,
          sigsci_corp: $validation.sigsci_corp,
          sigsci_corp_source: $validation.sigsci_corp_source,
          selected_customer_id: $validation.selected_customer_id,
          sigsci_customer_id: $validation.sigsci_customer_id,
          returned_customer_ids: $validation.returned_customer_ids,
          site_ownership_counts: $validation.site_ownership_counts,
          corp_validation_status: $validation.corp_validation_status,
          corp_validation_reason: $validation.reason,
          data: ($sites.data | map(. + {ownership_validation_status:
            (site_customer_ids as $ids
             | if ($ids | length) == 0 then "ownership_unverified"
               elif any($ids[]; . != $validation.selected_customer_id) then "ownership_mismatch"
               else "verified" end)}))
        }
    '
}

legacy_map_resolve_inspection_services_json() {
  [[ $# -ge 1 && $# -le 2 ]] || die 'legacy_map_resolve_inspection_services_json requires <sites-result-json> [services-json]'

  local sites_result="$1"
  local services_body="${2:-}"
  local tmp ids_tmp work_dir services_tmp sid retrieved_at
  local sites_count service_id_count unique_service_id_count concurrency started_count completed_count
  local failure_count worker_failure_count
  local active_jobs idx result_file status_file resolver_started_at resolver_elapsed
  tmp="$(mktemp)"
  ids_tmp="$(mktemp)"
  work_dir="$(mktemp -d)"
  services_tmp=""
  retrieved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  resolver_started_at="$(date +%s)"
  cleanup_legacy_map_resolver_tmp() {
    rm -f "$tmp" "$ids_tmp"
    [[ -z "$services_tmp" ]] || rm -f "$services_tmp"
    rm -rf "$work_dir"
  }
  trap cleanup_legacy_map_resolver_tmp RETURN

  sites_count="$(jq '.data | length' <<<"$sites_result")"
  service_id_count="$(jq '[.status as $status | .data[]? | select($status != "PARTIAL" or .ownership_validation_status == "verified") | .serviceID // empty] | length' <<<"$sites_result")"
  unique_service_id_count="$(jq '[.status as $status | .data[]? | select($status != "PARTIAL" or .ownership_validation_status == "verified") | .serviceID // empty] | unique | length' <<<"$sites_result")"
  jq -r '.status as $status | .data[]? | select($status != "PARTIAL" or .ownership_validation_status == "verified") | .serviceID // empty' <<<"$sites_result" | sort -u >"$ids_tmp"

  concurrency="${FASTLY_AUDIT_LOOKUP_CONCURRENCY:-${FASTLY_AUDIT_LEGACY_MAP_CONCURRENCY:-8}}"
  if ! [[ "$concurrency" =~ ^[1-9][0-9]*$ ]]; then
    concurrency=8
  elif (( concurrency > 16 )); then
    concurrency=16
  fi
  legacy_map_trace "NGWAF sites returned: $sites_count"
  legacy_map_trace "site records with non-null serviceID: $service_id_count"
  legacy_map_trace "unique site serviceIDs after dedupe: $unique_service_id_count"
  legacy_map_trace "Inspection Service lookup concurrency: $concurrency"

  if [[ -n "$services_body" ]]; then
    services_tmp="$(mktemp)"
    printf '%s\n' "$services_body" >"$services_tmp"
  fi

  started_count=0
  active_jobs=0
  idx=0
  while IFS= read -r sid; do
    [[ -n "$sid" ]] || continue
    result_file="$work_dir/$(printf '%05d' "$idx").json"
    status_file="$work_dir/$(printf '%05d' "$idx").status"
    (
      rc=0
      legacy_map_lookup_inspection_service_json "$sid" "$retrieved_at" "$services_tmp" "$result_file" || rc=$?
      if (( rc != 0 )) && [[ ! -s "$result_file" ]]; then
        jq -n --arg service_id "$sid" --arg retrieved_at "$retrieved_at" \
          '{service_id: $service_id, status: "UNKNOWN", evidence_type: "UNKNOWN", source: "GET /service/{serviceID}", retrieved_at: $retrieved_at, reason: "Fastly direct Inspection Service lookup worker failed before producing a result", service: null}' >"$result_file"
      fi
      printf '%s\n' "$rc" >"$status_file"
      exit 0
    ) &
    started_count=$((started_count + 1))
    active_jobs=$((active_jobs + 1))
    idx=$((idx + 1))
    if (( active_jobs >= concurrency )); then
      wait -n || true
      active_jobs=$((active_jobs - 1))
    fi
  done <"$ids_tmp"

  while (( active_jobs > 0 )); do
    wait -n || true
    active_jobs=$((active_jobs - 1))
  done

  completed_count="$(find "$work_dir" -type f -name '*.json' | wc -l | tr -d '[:space:]')"
  failure_count="$(jq -s '[.[] | select((.status // "UNKNOWN") != "COMPLETE")] | length' "$work_dir"/*.json 2>/dev/null || printf '0\n')"
  worker_failure_count="$(awk '($1 != 0) { count++ } END { print count + 0 }' "$work_dir"/*.status 2>/dev/null || printf '0\n')"
  legacy_map_trace "direct lookups started: $started_count"
  legacy_map_trace "direct lookups completed: $completed_count"
  legacy_map_trace "direct lookup failures: $failure_count"
  legacy_map_trace "worker process failures: $worker_failure_count"
  idx=0
  while IFS= read -r sid; do
    [[ -n "$sid" ]] || continue
    result_file="$work_dir/$(printf '%05d' "$idx").json"
    if [[ -s "$result_file" ]]; then
      cat "$result_file" >>"$tmp"
    else
      jq -n --arg service_id "$sid" --arg retrieved_at "$retrieved_at" \
        '{service_id: $service_id, status: "UNKNOWN", evidence_type: "UNKNOWN", source: "GET /service/{serviceID}", retrieved_at: $retrieved_at, reason: "Fastly direct Inspection Service lookup worker failed before producing a result", service: null}' >>"$tmp"
    fi
    idx=$((idx + 1))
  done <"$ids_tmp"
  resolver_elapsed=$(( $(date +%s) - resolver_started_at ))
  legacy_map_trace "Inspection Service resolver completed in ${resolver_elapsed}s"

  jq -s '.' "$tmp"
  trap - RETURN
  cleanup_legacy_map_resolver_tmp
}

legacy_map_extract_ess_host_json() {
  [[ $# -eq 1 ]] || die 'legacy_map_extract_ess_host_json requires <service-json>'

  local service_json="$1"
  local sid active_version endpoint tmp code content_tmp retrieved_at host_count
  local -a hosts=()
  sid="$(jq -r '.id // empty' <<<"$service_json")"
  active_version="$(jq -r '.active_version // empty' <<<"$service_json")"
  retrieved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -z "$active_version" || "$active_version" == "null" ]]; then
    jq -n --arg retrieved_at "$retrieved_at" \
      '{status: "UNKNOWN", evidence_type: "UNKNOWN", retrieved_at: $retrieved_at, reason: "active version could not be established", hosts: []}'
    return
  fi

  endpoint="/service/$sid/version/$active_version/generated_vcl"
  tmp="$(mktemp)"
  content_tmp="$(mktemp)"
  chmod 600 "$tmp" "$content_tmp" 2>/dev/null || true
  local started_at elapsed
  started_at="$(date +%s)"
  legacy_map_trace "generated VCL lookup: GET $endpoint"
  code="$(http_get_to_file "$endpoint" "$tmp")"
  elapsed=$(( $(date +%s) - started_at ))
  legacy_map_trace "generated VCL lookup completed: $endpoint HTTP $code in ${elapsed}s"

  if [[ "$code" == 2* ]] && jq -e '((type == "object" and (.content | type) == "string") or type == "string")' >/dev/null 2>&1 <"$tmp"; then
    if jq -j 'if type == "object" then .content else . end' "$tmp" >"$content_tmp" 2>/dev/null; then
      mapfile -t hosts < <(LC_ALL=C grep -Eo 'se--[A-Za-z0-9_-]+--[A-Za-z0-9_-]+\.edgecompute\.app' "$content_tmp" | sort -u || true)
      host_count="${#hosts[@]}"
      if (( host_count == 0 )); then
        jq -n --arg retrieved_at "$retrieved_at" --arg endpoint "$endpoint" \
          '{status: "NOT_FOUND", evidence_type: "DIRECT", source: "GET /service/{service_id}/version/{version}/generated_vcl", endpoint: $endpoint, retrieved_at: $retrieved_at, reason: "no in-band Inspection Service hostname found in generated VCL", hosts: []}'
      else
        printf '%s\n' "${hosts[@]}" | jq -Rn --arg retrieved_at "$retrieved_at" --arg endpoint "$endpoint" \
          '{status: "COMPLETE", evidence_type: "DIRECT", source: "GET /service/{service_id}/version/{version}/generated_vcl", endpoint: $endpoint, retrieved_at: $retrieved_at, reason: "in-band Inspection Service hostname found in generated VCL", hosts: [inputs | select(length > 0)]}'
      fi
    else
      jq -n --arg retrieved_at "$retrieved_at" --arg endpoint "$endpoint" \
        '{status: "UNKNOWN", evidence_type: "UNKNOWN", source: "GET /service/{service_id}/version/{version}/generated_vcl", endpoint: $endpoint, retrieved_at: $retrieved_at, reason: "generated VCL response content could not be decoded", hosts: []}'
    fi
  elif [[ "$code" == 2* ]]; then
    jq -n --arg retrieved_at "$retrieved_at" --arg endpoint "$endpoint" \
      '{status: "UNKNOWN", evidence_type: "UNKNOWN", source: "GET /service/{service_id}/version/{version}/generated_vcl", endpoint: $endpoint, retrieved_at: $retrieved_at, reason: "generated VCL response did not contain a supported content string", hosts: []}'
  else
    jq -n --arg retrieved_at "$retrieved_at" --arg endpoint "$endpoint" --arg code "$code" \
      '{status: "UNKNOWN", evidence_type: "UNKNOWN", source: "GET /service/{service_id}/version/{version}/generated_vcl", endpoint: $endpoint, retrieved_at: $retrieved_at, reason: ("generated VCL query failed: HTTP " + $code), hosts: []}'
  fi

  rm -f "$tmp" "$content_tmp"
}

legacy_map_row_for_non_vcl_json() {
  [[ $# -eq 1 ]] || die 'legacy_map_row_for_non_vcl_json requires <service-json>'

  jq '
    {
      source_service_id: .id,
      source_service_name: (.name // ""),
      source_service_type: (.type // "unknown"),
      source_platform: (.platform // "unknown"),
      active_version: (.active_version // null),
      inspection_service_host: null,
      inspection_service_name: null,
      inspection_service_id: null,
      legacy_inspection_service_host: null,
      legacy_inspection_service_name: null,
      legacy_ess_hostname: null,
      legacy_ess_service_name: null,
      ess_service_id: null,
      workspace_name: null,
      workspace_id: null,
      evidence_type: "INFORMATIONAL",
      status: "NOT_APPLICABLE",
      reason: "Only CDN/VCL services are inspected for generated VCL in-band Inspection Service hostnames",
      candidates: []
    }
  ' <<<"$1"
}

legacy_map_rows_for_service_json() {
  [[ $# -eq 4 ]] || die 'legacy_map_rows_for_service_json requires <service-json> <vcl-result-json> <sites-result-json> <inspection-services-json>'

  local service_json="$1"
  local vcl_result="$2"
  local sites_result="$3"
  local inspection_services="$4"

  printf '%s\n%s\n%s\n%s\n' "$service_json" "$vcl_result" "$sites_result" "$inspection_services" |
    jq -s '
      def workspace_name($site):
        $site.name // $site.display_name // $site.displayName // $site.shortName // $site.id // null;
      def normalized_ess_name($host):
        if ($host | endswith(".edgecompute.app")) then ($host | rtrimstr(".edgecompute.app")) else $host end;
      def base_row($service):
        {
          source_service_id: $service.id,
          source_service_name: ($service.name // ""),
          source_service_type: ($service.type // "unknown"),
          source_platform: ($service.platform // "unknown"),
          active_version: ($service.active_version // null),
          inspection_service_host: null,
          inspection_service_name: null,
          inspection_service_id: null,
          legacy_inspection_service_host: null,
          legacy_inspection_service_name: null,
          ess_host: null,
          ess_service_name: null,
          legacy_ess_hostname: null,
          legacy_ess_service_name: null,
          ess_service_id: null,
          workspace_name: null,
          workspace_id: null,
          evidence_type: "UNKNOWN",
          status: "UNKNOWN",
          reason: null,
          candidates: []
        };
      .[0] as $service
      | .[1] as $vcl
      | .[2] as $sites
      | .[3] as $inspection_services
      | if ($vcl.status // "UNKNOWN") == "UNKNOWN" then
          [
            base_row($service)
            + {
              evidence_type: "UNKNOWN",
              status: "UNKNOWN",
              reason: ($vcl.reason // "generated VCL hostname discovery unavailable")
            }
          ]
        elif ($vcl.status // "UNKNOWN") == "NOT_FOUND" then
          [
            base_row($service)
            + {
              evidence_type: "DIRECT",
              status: "NOT_FOUND",
              reason: ($vcl.reason // "no in-band Inspection Service hostname found in generated VCL")
            }
          ]
        else
          [
            ($vcl.hosts[]? | select(type == "string" and length > 0)) as $host
            | (normalized_ess_name($host)) as $ess_name
            | [
                $sites.data[]?
                | . as $site
                | select(.ownership_validation_status == "verified")
                | ($site.serviceID // null) as $site_service_id
                | select($site_service_id != null and $site_service_id != "")
                | [
                    $inspection_services[]
                    | select(.service_id == $site_service_id and (.status // "UNKNOWN") == "COMPLETE" and .ownership_validation_status == "verified")
                    | .service
                    | select((.name // "") == $ess_name and (.type // "") == "wasm")
                  ][] as $ess
                | {
                    ess_service_id: $site_service_id,
                    ess_service_name: ($ess.name // null),
                    inspection_service_id: $site_service_id,
                    inspection_service_name: ($ess.name // null),
                    workspace_name: workspace_name($site),
                    workspace_id: ($site.id // null),
                    site: {
                      id: ($site.id // null),
                      name: workspace_name($site),
                      serviceID: $site_service_id
                    }
                  }
              ] as $candidates
            | [
                $sites.data[]?
                | select(.ownership_validation_status != "verified")
                | .serviceID // empty
                | . as $unverified_service_id
                | ([$inspection_services[] | select(.service_id == $unverified_service_id)]) as $lookups
                | select(($lookups | length) == 0 or
                    any($lookups[]; .status != "COMPLETE" or (.service.name // "") == $ess_name))
              ] as $ownership_uncertainty
            | [
                $sites.data[]?
                | . as $site
                | ($site.serviceID // null) as $site_service_id
                | select($site_service_id != null and $site_service_id != "")
                | [
                    $inspection_services[]
                    | select(.service_id == $site_service_id and (.status // "UNKNOWN") != "COMPLETE")
                    | {
                        serviceID: $site_service_id,
                        workspace_name: workspace_name($site),
                        workspace_id: ($site.id // null),
                        status: (.status // "UNKNOWN"),
                        reason: (.reason // "Fastly direct Inspection Service lookup unavailable"),
                        failure: (.failure // null)
                      }
                  ][]
              ] as $lookup_failures
            | base_row($service)
              + {
                  ess_host: $host,
                  ess_service_name: $ess_name,
                  inspection_service_host: $host,
                  inspection_service_name: $ess_name,
                  legacy_inspection_service_host: $host,
                  legacy_inspection_service_name: $ess_name,
                  legacy_ess_hostname: $host,
                  legacy_ess_service_name: $ess_name,
                  candidates: $candidates
                }
              + (
                  if ($sites.status // "UNKNOWN") != "COMPLETE" and ($sites.status // "UNKNOWN") != "PARTIAL" then
                    {
                      evidence_type: "UNKNOWN",
                      status: "UNKNOWN",
                      reason: ($sites.reason // "internal NGWAF site inventory unavailable")
                    }
                  elif ($ownership_uncertainty | length) > 0 then
                    {evidence_type:"UNKNOWN",status:"UNKNOWN",
                     reason:"unverified NGWAF site ownership could affect the Inspection Service join",
                     lookup_failures:$lookup_failures}
                  elif ($candidates | length) == 0 then
                    if ($lookup_failures | length) > 0 then
                      {
                        evidence_type: "UNKNOWN",
                        status: "UNKNOWN",
                        reason: "one or more NGWAF site serviceID direct Fastly Inspection Service lookups were unavailable; exact Inspection Service name join could not be fully evaluated",
                        lookup_failures: $lookup_failures
                      }
                    else
                      {
                        evidence_type: "UNKNOWN",
                        status: "UNRESOLVED",
                        reason: "direct Inspection Service lookups succeeded but no returned service name exactly matched the generated VCL Inspection Service hostname"
                      }
                    end
                  elif ($candidates | length) == 1 then
                    {
                      evidence_type: "DIRECT",
                      status: "CONFIRMED",
                      ess_service_id: $candidates[0].ess_service_id,
                      inspection_service_id: $candidates[0].inspection_service_id,
                      workspace_name: $candidates[0].workspace_name,
                      workspace_id: $candidates[0].workspace_id,
                      reason: "generated VCL Inspection Service hostname joined exactly to the Fastly Inspection Service name and NGWAF workspace site serviceID"
                    }
                  else
                    {
                      evidence_type: "UNKNOWN",
                      status: "AMBIGUOUS",
                      reason: "multiple internal NGWAF sites matched the generated VCL Inspection Service hostname"
                    }
                  end
                )
          ]
        end
    '
}

legacy_map_payload_json() {
  [[ $# -eq 5 ]] || die 'legacy_map_payload_json requires <customer-json> <services-json> <sites-result-json> <rows-json> <selector>'

  local customer="$1"
  local services_body="$2"
  local sites_result="$3"
  local rows="$4"
  local selector="$5"

  printf '%s\n%s\n%s\n%s\n' "$customer" "$services_body" "$sites_result" "$rows" |
    jq -s --arg selector "$selector" '
      (now | todateiso8601) as $generated_at
      | .[0] as $customer
      | .[1] as $services_body
      | .[2] as $sites
      | .[3] as $rows
      | ($rows | map(select(.source_service_type == "vcl"))) as $vcl_rows
      | ($rows | map(select(.status == "CONFIRMED").ess_service_id) | map(select(. != null and . != "")) | unique | length) as $unique_ess_services
      | ($rows | map(select(.status == "CONFIRMED").inspection_service_id // .ess_service_id) | map(select(. != null and . != "")) | unique | length) as $unique_inspection_services
      | {
          schema_version: 1,
          command: "security legacy-map",
          generated_at: $generated_at,
          customer: {
            id: ($customer.id // null),
            name: ($customer.name // null)
          },
          selector: (if $selector == "" then null else $selector end),
          summary: {
            source_cdn_services_scanned: ($vcl_rows | map(.source_service_id) | unique | length),
            delivery_services_scanned: ($vcl_rows | map(.source_service_id) | unique | length),
            source_non_vcl_services_skipped: ($rows | map(select(.status == "NOT_APPLICABLE")) | length),
            legacy_inspection_service_hosts_found: ($rows | map(select(.inspection_service_host != null).inspection_service_host) | unique | length),
            legacy_ess_hosts_found: ($rows | map(select(.legacy_ess_hostname != null).legacy_ess_hostname) | unique | length),
            unique_inspection_services: $unique_inspection_services,
            unique_legacy_ess_services: $unique_ess_services,
            confirmed_workspace_mappings: ($rows | map(select(.status == "CONFIRMED")) | length),
            unresolved: ($rows | map(select(.status == "UNRESOLVED")) | length),
            ambiguous: ($rows | map(select(.status == "AMBIGUOUS")) | length),
            not_found: ($rows | map(select(.status == "NOT_FOUND")) | length),
            unknown: ($rows | map(select(.status == "UNKNOWN")) | length),
            sites_inventory_status: ($sites.status // "UNKNOWN"),
            sigsci_corp: ($sites.sigsci_corp // null),
            sigsci_corp_source: ($sites.sigsci_corp_source // null),
            selected_customer_id: ($sites.selected_customer_id // null),
            sigsci_customer_id: ($sites.sigsci_customer_id // null),
            corp_validation_status: ($sites.corp_validation_status // "UNKNOWN")
          },
          sources: {
            service_inventory: ($services_body.meta.result // $services_body.meta // {}),
            generated_vcl: {
              source: "GET /service/{service_id}/version/{version}/generated_vcl",
              evidence_type: "DIRECT",
              retrieval: "per CDN/VCL source service active version"
            },
            internal_ngwaf_sites: ($sites | del(.data))
          },
          mappings: $rows,
          limitations: [
            "This command is read-only and does not perform migration actions.",
            "Only CDN/VCL source services are inspected for generated VCL hostnames.",
            "CONFIRMED requires an exact generated VCL Inspection Service name and site serviceID join with verified site and Inspection Service customer ownership.",
            "UNRESOLVED means an in-band Inspection Service hostname was present but no exact workspace join was established; it is not treated as a disabled or absent workspace.",
            "Fields named legacy_ess_* or ess_service_id are compatibility aliases for Inspection Service fields.",
            "The internal NGWAF site inventory requires FASTLY_DSTOKEN, FASTLY_VOUCH_COOKIE, and SIGSCI_CORP."
          ]
        }
    '
}

legacy_map_payload_csv() {
  [[ $# -eq 1 ]] || die 'legacy_map_payload_csv requires <payload-json>'

  jq -r '
    def cell:
      if . == null then "" else tostring end;
    [
      "cdn_service",
      "service_id",
      "active_version",
      "inspection_service_host",
      "inspection_service_id",
      "workspace",
      "evidence",
      "status",
      "reason"
    ],
    (
      .mappings[]
      | [
          .source_service_name,
          .source_service_id,
          .active_version,
          .inspection_service_host,
          .inspection_service_id,
          .workspace_name,
          .evidence_type,
          .status,
          .reason
        ]
    )
    | map(cell)
    | @csv
  ' <<<"$1"
}

legacy_map_payload_human() {
  [[ $# -eq 1 ]] || die 'legacy_map_payload_human requires <payload-json>'

  local payload="$1"
  jq -r '
    "Customer: \(.customer.name) (\(.customer.id))",
    "SIGSCI corp: \(.summary.sigsci_corp // "UNKNOWN") (\(.summary.sigsci_corp_source // "unknown"))",
    "Corp validation: \(.summary.corp_validation_status // "UNKNOWN")",
    "CDN services scanned: \(.summary.delivery_services_scanned // .summary.source_cdn_services_scanned)",
    "Unique Inspection Services: \(.summary.unique_inspection_services // .summary.unique_legacy_ess_services)",
    "Confirmed workspace mappings: \(.summary.confirmed_workspace_mappings)",
    "Unresolved: \(.summary.unresolved)",
    "Ambiguous: \(.summary.ambiguous)",
    "Unknown: \(.summary.unknown)",
    "Internal NGWAF sites: \(.summary.sites_inventory_status)"
  ' <<<"$payload"

  if jq -e '.sources.internal_ngwaf_sites.internal_ngwaf_error_type != null' >/dev/null <<<"$payload"; then
    printf '\n'
    jq -r '
      (if ((.sources.internal_ngwaf_sites.internal_ngwaf_error_type // "") as $type | ($type == "AUTH_REDIRECT" or $type == "AUTH_FAILED"))
       then "Internal NGWAF auth/session problem"
       else "Internal NGWAF request problem"
       end),
      "HTTP \(.sources.internal_ngwaf_sites.internal_ngwaf_http_status // "unknown") from internal NGWAF API",
      "reason: \(.sources.internal_ngwaf_sites.internal_ngwaf_error_reason // "internal NGWAF request failed")",
      (
        .sources.internal_ngwaf_sites.internal_ngwaf_recommended_action
        | if . == null or . == "" then empty else "suggested action: \(.)" end
      )
    ' <<<"$payload"
  fi

  printf '\n'
  jq -r '
    def cell:
      if . == null then "-" else tostring end;
    ["CDN SERVICE", "VERSION", "INSPECTION SERVICE HOST", "INSPECTION SERVICE ID", "WORKSPACE", "EVIDENCE", "STATUS", "REASON"],
    (
      .mappings[]
      | [
          .source_service_name,
          .active_version,
          .inspection_service_host,
          .inspection_service_id,
          .workspace_name,
          .evidence_type,
          .status,
          .reason
        ]
    )
    | map(cell)
    | @tsv
  ' <<<"$payload" | human_table

  printf '\nNOTE: CONFIRMED requires exact generated-VCL Inspection Service hostname to Fastly Inspection Service name to NGWAF workspace site serviceID evidence.\n'
}

legacy_map_emit_output() {
  [[ $# -eq 3 ]] || die 'legacy_map_emit_output requires <content> <output-file> <rows>'

  local content="$1"
  local output="$2"
  local rows="$3"
  local parent temp_file old_umask

  if [[ -z "$output" ]]; then
    printf '%s\n' "$content"
    return
  fi

  parent="$(dirname "$output")"
  [[ -d "$parent" ]] || die "legacy-map output directory does not exist: $parent"
  [[ ! -e "$output" ]] || die "refusing to overwrite existing legacy-map output: $output"

  old_umask="$(umask)"
  umask 077
  temp_file="$(mktemp "$parent/.fastly-audit-legacy-map.XXXXXX")"
  umask "$old_umask"

  if ! printf '%s\n' "$content" >"$temp_file"; then
    rm -f "$temp_file"
    die "failed to write legacy-map output: $output"
  fi

  chmod 600 "$temp_file"
  if ! ln "$temp_file" "$output"; then
    rm -f "$temp_file"
    die "refusing to overwrite existing legacy-map output: $output"
  fi
  rm -f "$temp_file"

  if [[ "$rows" == "1" ]]; then
    printf '%s: wrote 1 legacy-map row to %s\n' "${PROGRAM_NAME:-ngwaf}" "$output" >&2
  else
    printf '%s: wrote %s legacy-map rows to %s\n' "${PROGRAM_NAME:-ngwaf}" "$rows" "$output" >&2
  fi
}

cmd_security_legacy_map() {
  local format="human" output="" selector="" format_explicit=false
  local arg cid customer services_body services selected_services resolved service
  local corp="" corp_source="" sites_result inspection_services rows_tmp rows row vcl_result payload rendered rows_returned
  local started_at elapsed command_started_at
  command_started_at="$(date +%s)"

  while (( $# > 0 )); do
    case "$1" in
      --format)
        (( $# >= 2 )) || legacy_map_usage
        format="$(tr '[:upper:]' '[:lower:]' <<<"$2")"
        format_explicit=true
        shift 2
        ;;
      --output)
        (( $# >= 2 )) || die '--output requires a file path'
        output="$2"
        shift 2
        ;;
      --sigsci-corp)
        (( $# >= 2 )) || die '--sigsci-corp requires a corp slug'
        corp="$2"
        corp_source="cli"
        shift 2
        ;;
      --json)
        format="json"
        format_explicit=true
        shift
        ;;
      --csv)
        format="csv"
        format_explicit=true
        shift
        ;;
      --*)
        die "unknown legacy-map option: $1"
        ;;
      *)
        [[ -z "$selector" ]] || legacy_map_usage
        selector="$1"
        shift
        ;;
    esac
  done

  case "$format" in
    human|json|csv)
      ;;
    *)
      die 'legacy-map format must be human, json, or csv'
      ;;
  esac
  if [[ -n "$output" && "$format_explicit" == "false" ]]; then
    case "$(tr '[:upper:]' '[:lower:]' <<<"${output##*.}")" in
      json) format="json" ;;
      csv) format="csv" ;;
    esac
  fi

  if [[ -z "$corp" ]]; then
    corp="${SIGSCI_CORP:-}"
    [[ -n "$corp" ]] && corp_source="env"
  fi
  [[ -n "$corp" ]] || die 'SIGSCI_CORP is required for internal NGWAF site inventory; use --sigsci-corp <corp> for this run'

  cid="$(current_cid)"
  legacy_map_trace "selected Fastly customer ID: $cid"
  started_at="$(date +%s)"
  customer="$(get "/customer/$cid")"
  elapsed=$(( $(date +%s) - started_at ))
  legacy_map_trace "customer lookup completed in ${elapsed}s"
  started_at="$(date +%s)"
  services_body="$(get_customer_services --details)" ||
    die 'service inventory unavailable; cannot build in-band NGWAF migration map safely'
  elapsed=$(( $(date +%s) - started_at ))
  legacy_map_trace "canonical customer service discovery completed in ${elapsed}s"
  legacy_map_trace "canonical customer services returned: $(jq '.data | length' <<<"$services_body")"
  services="$(normalize_services_for_vcl_size_json "$services_body")"

  if [[ -n "$selector" ]]; then
    resolved="$(resolve_vcl_size_service_json "$services_body" "$selector")"
    case "$(jq -r '.status' <<<"$resolved")" in
      COMPLETE)
        service="$(jq '.service' <<<"$resolved")"
        selected_services="$(jq -n --argjson service "$service" '[$service]')"
        ;;
      AMBIGUOUS)
        die "service selector is ambiguous: $selector"
        ;;
      *)
        die "service not found in selected customer token-visible service inventory: $selector"
        ;;
    esac
  else
    selected_services="$(jq 'map(select(.type == "vcl"))' <<<"$services")"
  fi
  legacy_map_trace "selected CDN/VCL services for generated VCL scan: $(jq 'length' <<<"$selected_services")"

  started_at="$(date +%s)"
  sites_result="$(legacy_map_fetch_sites_json "$corp")"
  elapsed=$(( $(date +%s) - started_at ))
  legacy_map_trace "internal NGWAF sites lookup completed for corp=$corp source=$corp_source in ${elapsed}s"
  sites_result="$(
    legacy_map_validate_sites_customer_json \
      "$sites_result" \
      "$cid" \
      "$(jq -r '.name // "unknown"' <<<"$customer")" \
      "$corp" \
      "$corp_source"
  )"
  legacy_map_trace "corp validation status: $(jq -r '.corp_validation_status // "UNKNOWN"' <<<"$sites_result")"
  if [[ "$(jq -r '.status // "UNKNOWN"' <<<"$sites_result")" == "COMPLETE" || "$(jq -r '.status // "UNKNOWN"' <<<"$sites_result")" == "PARTIAL" ]]; then
    started_at="$(date +%s)"
    inspection_services="$(legacy_map_resolve_inspection_services_json "$sites_result" "$services_body")"
    inspection_services="$(legacy_map_validate_inspection_services_json "$inspection_services" "$cid")" || return 1
    elapsed=$(( $(date +%s) - started_at ))
    legacy_map_trace "Inspection Service resolver completed in ${elapsed}s"
    legacy_map_trace "Inspection Service resolver is completed before generated VCL matching; no early stop after a later exact match occurs in current flow"
  else
    inspection_services='[]'
  fi

  rows_tmp="$(mktemp)"
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    if [[ "$(jq -r '.type // "unknown"' <<<"$service")" != "vcl" ]]; then
      legacy_map_row_for_non_vcl_json "$service" >>"$rows_tmp"
      continue
    fi

    vcl_result="$(legacy_map_extract_ess_host_json "$service")"
    row="$(legacy_map_rows_for_service_json "$service" "$vcl_result" "$sites_result" "$inspection_services")"
    if legacy_map_trace_enabled; then
      while IFS= read -r trace_line; do
        [[ -n "$trace_line" ]] && legacy_map_trace "$trace_line"
      done < <(
        jq -r '
          .[]
          | if .status == "CONFIRMED" then
              "exact Inspection Service name matched: " + (.inspection_service_name // "-") + " -> " + (.inspection_service_id // "-") + " -> " + (.workspace_name // "-")
            elif .status == "UNRESOLVED" then
              "no exact Inspection Service match for generated VCL host: " + (.inspection_service_host // "-")
            else empty
            end
        ' <<<"$row"
      )
    fi
    jq -c '.[]' <<<"$row" >>"$rows_tmp"
  done < <(jq -c '.[]' <<<"$selected_services")

  rows="$(jq -s '.' "$rows_tmp")"
  rm -f "$rows_tmp"

  payload="$(legacy_map_payload_json "$customer" "$services_body" "$sites_result" "$rows" "$selector")"
  rows_returned="$(jq -r '.mappings | length' <<<"$payload")"

  case "$format" in
    csv) rendered="$(legacy_map_payload_csv "$payload")" ;;
    human) rendered="$(legacy_map_payload_human "$payload")" ;;
    json) rendered="$(jq . <<<"$payload")" ;;
    *) die "internal error: unsupported legacy-map format: $format" ;;
  esac

  legacy_map_emit_output "$rendered" "$output" "$rows_returned"
  elapsed=$(( $(date +%s) - command_started_at ))
  legacy_map_trace "legacy-map command completed in ${elapsed}s"
}

# Shared collection and schema construction; renderers consume this JSON.
collect_security_summary_json() {
  local config_mode="${1:-summary}"
  local validate_scope="${2:-false}"
  local cid customer services_body products workspaces payload
  [[ "$config_mode" == summary || "$config_mode" == detailed ]] ||
    die 'security inventory config mode must be summary or detailed'

  cid="$(current_cid)" || return

  ui_phase 1 4 'Resolving the selected customer and token-visible services'
  customer="$(get "/customer/$cid")" || return
  if [[ "$validate_scope" == true ]]; then
    jq -e --arg cid "$cid" 'type == "object" and .id == $cid and
      (.name | type == "string" and length > 0)' >/dev/null <<<"$customer" ||
      die 'customer security: customer metadata does not match the selected customer'
  fi
  services_body="$(get_customer_services)" ||
    die 'service inventory unavailable; security summary cannot safely use audit-event-derived service counts as a substitute'
  progress_job_note "Services retrieved: $(jq '.data | length' <<<"$services_body")"

  ui_phase 2 4 'Checking security-product attachment inventory'
  products="$(collect_security_products_json "$services_body" "$config_mode")" || return

  ui_phase 3 4 'Retrieving the complete NGWAF workspace inventory'
  workspaces="$(
    get_all_pages "/ngwaf/v1/workspaces" \
      --data-urlencode "customer_id=$cid"
  )" || return
  progress_job_note "Workspaces discovered: $(jq '.data | length' <<<"$workspaces")"

  if [[ "$validate_scope" == true ]]; then
    jq -e --arg cid "$cid" '
      all(.data[]; type == "object" and (.id | type == "string" and length > 0)
        and (if has("customer_id") then .customer_id == $cid else true end)
        and (if (.customer | type) == "object" and (.customer | has("id"))
             then .customer.id == $cid else true end))
      and ([.data[].id] | length == (unique | length))
    ' >/dev/null <<<"$workspaces" ||
      die 'customer security: workspace metadata is malformed, duplicated, or conflicts with the selected customer'
  fi

  ui_phase 4 4 'Building the security summary'
  payload="$(
    printf '%s\n%s\n%s\n%s\n' "$customer" "$services_body" "$products" "$workspaces" |
      jq -s --arg config_mode "$config_mode" '
        def number_or_null:
          if type == "number" then .
          elif type == "string" and test("^[0-9]+(\\.[0-9]+)?$") then tonumber
          else null
          end;
        (now | todateiso8601) as $generated_at
        | .[0] as $customer
        | .[1] as $services_body
        | .[2] as $products
        | .[3] as $workspaces
        | ($services_body.data // []) as $services
        | (($services_body.meta.result.status // $services_body.meta.status // "UNKNOWN") == "COMPLETE") as $services_complete
        | ([$products[] | select((.result.status // .status // "UNKNOWN") != "COMPLETE")] | length == 0 and $services_complete) as $products_complete
        | ([$products[] | (.result.count // .result.count_lower_bound // .enabled_count // 0)] | add // 0) as $mapping_lower_bound
        | ([$products[] | select(((.result.count // .result.count_lower_bound // .enabled_count // 0) > 0))] | length) as $enabled_product_type_lower_bound
        | ([$products[] | select((.result.status // .status // "UNKNOWN") == "UNKNOWN")] | length == ($products | length) and ($products | length) > 0) as $all_products_unknown
        | (if $products_complete then "COMPLETE" elif $all_products_unknown then "UNKNOWN" else "PARTIAL" end) as $product_inventory_status
        | (([$products[] | select(.id == "ngwaf")] | .[0]) // {
            id: "ngwaf",
            label: "Edge WAF service attachments",
            result: {status: "UNKNOWN", count: null, count_lower_bound: null, duplicate_returned_count: 0, duplicate_returned_service_ids: []},
            services: []
          }) as $ngwaf_product
        | (($ngwaf_product.result.status // "UNKNOWN") == "COMPLETE") as $ngwaf_attachments_complete
        | ($workspaces.data // []) as $workspace_rows
        | ($workspace_rows
            | map({
                key: .id,
                value: {
                  id,
                  name,
                  mode: (.mode // null),
                  default_blocking_response_code: (.default_blocking_response_code // null)
                }
              })
            | from_entries) as $workspace_by_id
        | [
            $ngwaf_product.services[]?
            | . as $svc
            | (($svc.configuration // {}).workspace_id // null) as $workspace_id
            | (($svc.configuration // {}).traffic_ramp // null) as $traffic_ramp_raw
            | ($traffic_ramp_raw | number_or_null) as $traffic_ramp
            | (if ($workspace_id != null and $workspace_id != "") then ($workspace_by_id[$workspace_id] // null) else null end) as $workspace
            | {
                service_id: $svc.id,
                service_name: ($svc.name // ""),
                service_type: ($svc.type // "unknown"),
                platform: ($svc.platform // "unknown"),
                customer_id: ($svc.customer_id // null),
                workspace_id: $workspace_id,
                traffic_ramp: $traffic_ramp,
                traffic_ramp_raw: $traffic_ramp_raw,
                workspace: $workspace,
                configuration_http_status: ($svc.configuration_http_status // null),
                anomalies: [
                  (if ($workspace_id == null or $workspace_id == "") then "missing_workspace_id" else empty end),
                  (if ($workspace_id != null and $workspace_id != "" and $workspace == null) then "workspace_not_found" else empty end),
                  (if $traffic_ramp == null then "missing_or_invalid_traffic_ramp" else empty end),
                  (if ($traffic_ramp != null and $traffic_ramp < 100) then "traffic_ramp_below_100" else empty end)
                ]
              }
          ] as $ngwaf_attachments
        | ($ngwaf_attachments | map(.workspace_id) | map(select(. != null and . != "")) | unique) as $attached_workspace_ids
        | (if $ngwaf_attachments_complete then
            ($ngwaf_attachments
              | map(select(.workspace_id != null and .workspace_id != ""))
              | group_by(.workspace_id)
              | map(select(length > 1) | {
                  workspace_id: .[0].workspace_id,
                  workspace_name: (.[0].workspace.name // null),
                  services: map({service_id, service_name})
                }))
          else [] end) as $multiple_services_per_workspace
        | (if $ngwaf_attachments_complete then
            ($ngwaf_attachments
              | group_by(.service_id)
              | map(select(length > 1) | {
                  service_id: .[0].service_id,
                  service_name: .[0].service_name,
                  attachments: map({workspace_id, traffic_ramp})
                }))
          else [] end) as $multiple_attachments_per_service
        | [
            ($ngwaf_product.result.duplicate_returned_service_ids // [])[]
            | . as $sid
            | {
                service_id: $sid,
                service_name: (($ngwaf_attachments[]? | select(.service_id == $sid) | .service_name) // null),
                reason: "duplicate service ID returned by NGWAF enabled-service API"
              }
          ] as $duplicate_returned_services
        | ($multiple_attachments_per_service + $duplicate_returned_services) as $attachment_duplicates
        | (if $ngwaf_attachments_complete then
            ([
              $workspace_rows[]
              | select(.id as $id | ($attached_workspace_ids | index($id)) == null)
              | {
                  workspace_id: .id,
                  workspace_name: (.name // ""),
                  mode: (.mode // null),
                  default_blocking_response_code: (.default_blocking_response_code // null)
                }
            ])
          else [] end) as $workspaces_without_attachment
        | {
            status: $product_inventory_status,
            count: (if $products_complete then $mapping_lower_bound else null end),
            count_lower_bound: (if $product_inventory_status == "PARTIAL" then $mapping_lower_bound else null end),
            source: "GET /enabled-products/v1/{product_id}/services",
            evidence_type: "DERIVED",
            derived_from: [
              "products[].result"
            ],
            retrieved_at: $generated_at,
            reason: (
              if $products_complete then "all product attachment inventories complete"
              elif $all_products_unknown then "all product attachment inventories unknown"
              else "one or more product attachment inventories incomplete"
              end
            ),
            pagination: null,
            fallback_used: ([$products[] | select((.result.fallback_used // false) == true)] | length > 0),
            products: ($products | map({
              id,
              label,
              status: (.result.status // .status // "UNKNOWN"),
              count: (.result.count // null),
              count_lower_bound: (.result.count_lower_bound // null),
              source: (.result.api // .result.source // .discovery_method // null),
              evidence_type: (.result.evidence_type // (if (.result.status // .status // "UNKNOWN") == "UNKNOWN" then "UNKNOWN" else "DIRECT" end)),
              retrieved_at: (.result.retrieved_at // null),
              reason: (.result.reason // null),
              fallback_used: (.result.fallback_used // false)
            }))
          } as $product_inventory_result
        | {
            status: "COMPLETE",
            count: ($workspaces.data | length),
            count_lower_bound: null,
            source: "GET /ngwaf/v1/workspaces",
            evidence_type: "DIRECT",
            retrieved_at: $generated_at,
            reason: "complete workspace inventory response",
            pagination: {
              limit: ($workspaces.meta.limit // null),
              total: ($workspaces.meta.total // ($workspaces.data | length)),
              pages_fetched: ($workspaces.meta.pages_fetched // null)
            },
            fallback_used: false
          } as $workspace_inventory_result
        | ["api_discovery", "bot_management", "ddos_protection", "ngwaf"] as $expected_product_ids
        | ([$products[] | {key: .id, value: .}] | from_entries) as $product_by_id
        | ([$products[] | ([.services[]?.id] | unique | length)] | add // 0) as $normalized_mapping_count
        | ([$workspace_rows[] as $workspace_row | [$ngwaf_attachments[] | select(.workspace_id == $workspace_row.id)] | length] | add // 0) as $workspace_attachment_count
        | (
            [
              (
                if $services_complete then empty
                else {
                  type: "service_inventory_incomplete",
                  severity: "WARN",
                  detail: "Selected service inventory is not complete; reconciliation cannot be fully evaluated"
                }
                end
              ),
              (
                if ($workspace_inventory_result.status // "UNKNOWN") == "COMPLETE" then empty
                else {
                  type: "workspace_inventory_incomplete",
                  severity: "WARN",
                  detail: "NGWAF workspace inventory is not complete; reconciliation cannot be fully evaluated"
                }
                end
              ),
              (
                $expected_product_ids[] as $pid
                | select(($product_by_id | has($pid)) | not)
                | {
                    type: "missing_product_result",
                    severity: "WARN",
                    product_id: $pid,
                    detail: "Expected product result is missing; do not interpret as COMPLETE count=0"
                  }
              ),
              (
                $expected_product_ids[] as $pid
                | ($product_by_id[$pid] // empty) as $product
                | ($product.result.status // $product.status // "UNKNOWN") as $status
                | select($status != "COMPLETE")
                | {
                    type: "product_result_incomplete",
                    severity: "WARN",
                    product_id: $pid,
                    product_label: ($product.label // $pid),
                    detail: ("Product result status is " + $status + "; reconciliation cannot treat it as zero")
                  }
              ),
              (
                $products[] as $product
                | ($product.result.rejected_service_ids // [])[]
                | {
                    type: "rejected_service_id",
                    severity: "WARN",
                    product_id: $product.id,
                    product_label: ($product.label // $product.id),
                    service_id: .,
                    detail: "Product API returned a service ID that was not validated against selected-customer service inventory"
                  }
              ),
              (
                $products[] as $product
                | ($product.result.duplicate_returned_service_ids // [])[]
                | {
                    type: "duplicate_service_mapping",
                    severity: "WARN",
                    product_id: $product.id,
                    product_label: ($product.label // $product.id),
                    service_id: .,
                    detail: "Product API returned a duplicate service ID; normalized mapping was deduplicated"
                  }
              ),
              (
                $products[] as $product
                | ($product.result.status // $product.status // "UNKNOWN") as $status
                | select($status == "COMPLETE")
                | (($product.result.enabled_count // $product.result.count // $product.enabled_count // $product.count // 0) | tonumber) as $reported_count
                | ([ $product.services[]?.id ] | unique | length) as $normalized_count
                | select($reported_count != $normalized_count)
                | {
                    type: "product_count_mismatch",
                    severity: "FAIL",
                    product_id: $product.id,
                    product_label: ($product.label // $product.id),
                    detail: ("enabled_count=" + ($reported_count | tostring) + " normalized_mappings=" + ($normalized_count | tostring))
                  }
              ),
              (
                if $products_complete and ($mapping_lower_bound != $normalized_mapping_count) then {
                  type: "aggregate_mapping_count_mismatch",
                  severity: "FAIL",
                  detail: ("summary_mappings=" + ($mapping_lower_bound | tostring) + " normalized_mappings=" + ($normalized_mapping_count | tostring))
                } else empty end
              ),
              (
                if ($ngwaf_product.result.status // "UNKNOWN") == "COMPLETE" and (($ngwaf_product.result.count // 0) != ($ngwaf_attachments | length)) then {
                  type: "edge_waf_attachment_count_mismatch",
                  severity: "FAIL",
                  product_id: "ngwaf",
                  product_label: "Edge WAF service attachments",
                  detail: ("reported_count=" + (($ngwaf_product.result.count // 0) | tostring) + " normalized_attachments=" + (($ngwaf_attachments | length) | tostring))
                } else empty end
              ),
              (
                if ($ngwaf_product.result.status // "UNKNOWN") == "COMPLETE" and ($workspace_attachment_count != ($ngwaf_attachments | map(select(.workspace != null)) | length)) then {
                  type: "workspace_attachment_count_mismatch",
                  severity: "FAIL",
                  product_id: "ngwaf",
                  product_label: "Edge WAF service attachments",
                  detail: ("workspace_attachment_total=" + ($workspace_attachment_count | tostring) + " normalized_workspace_attachments=" + (($ngwaf_attachments | map(select(.workspace != null)) | length) | tostring))
                } else empty end
              ),
              (
                $ngwaf_attachments[]
                | . as $attachment
                | $attachment.anomalies[]?
                | {
                    type: .,
                    severity: (if . == "traffic_ramp_below_100" then "WARN" else "FAIL" end),
                    product_id: "ngwaf",
                    product_label: "Edge WAF service attachments",
                    service_id: $attachment.service_id,
                    service_name: $attachment.service_name,
                    workspace_id: $attachment.workspace_id,
                    detail: (
                      if . == "workspace_not_found" then "Edge WAF attachment references a workspace ID absent from workspace inventory"
                      elif . == "missing_workspace_id" then "Edge WAF attachment is missing workspace_id"
                      elif . == "missing_or_invalid_traffic_ramp" then "Edge WAF attachment has missing or invalid traffic_ramp"
                      elif . == "traffic_ramp_below_100" then "Edge WAF attachment traffic_ramp is below 100%"
                      else "Edge WAF attachment relationship anomaly"
                      end
                    )
                  }
              ),
              (
                $multiple_services_per_workspace[]
                | {
                    type: "multiple_services_per_workspace",
                    severity: "WARN",
                    product_id: "ngwaf",
                    product_label: "Edge WAF service attachments",
                    workspace_id: .workspace_id,
                    detail: ("workspace has " + ((.services // []) | length | tostring) + " attached services")
                  }
              ),
              (
                $attachment_duplicates[]
                | {
                    type: "multiple_attachments_per_service",
                    severity: "WARN",
                    product_id: "ngwaf",
                    product_label: "Edge WAF service attachments",
                    service_id: .service_id,
                    service_name: (.service_name // null),
                    detail: (.reason // ("service has " + ((.attachments // []) | length | tostring) + " attachment rows"))
                  }
              )
            ]
            | map(with_entries(select(.value != null)))
          ) as $reconciliation_findings
        | (["service_inventory_incomplete", "workspace_inventory_incomplete", "missing_product_result", "product_result_incomplete"]) as $unknown_finding_types
        | {
            status: (
              if ([$reconciliation_findings[] | select(.severity == "FAIL")] | length) > 0 then "FAIL"
              elif ([$reconciliation_findings[] | select(.type as $type | $unknown_finding_types | index($type) != null)] | length) > 0 then "UNKNOWN"
              elif ([$reconciliation_findings[] | select(.severity == "WARN")] | length) > 0 then "WARN"
              else "PASS"
              end
            ),
            evidence_type: "DERIVED",
            derived_from: [
              "inventory_sections.service_inventory",
              "inventory_sections.product_attachments",
              "inventory_sections.edge_waf_service_attachments",
              "inventory_sections.ngwaf_workspaces",
              "ngwaf.attachments"
            ],
            finding_count: ($reconciliation_findings | length),
            findings: $reconciliation_findings
          } as $reconciliation_result
        | ([$products[].services[]?] | length) as $configuration_mapping_count
        | ([$products[].services[]? | select((.configuration_requested // false) == true)] | length) as $configuration_requested_count
        | ([$products[].services[]? | select((.configuration_status // "") == "RETRIEVED")] | length) as $configuration_retrieved_count
        | ([$products[].services[]? | select((.configuration_status // "") == "UNAVAILABLE")] | length) as $configuration_unavailable_count
        | ([$products[].services[]? | select((.configuration_status // "") == "NOT_REQUESTED")] | length) as $configuration_not_requested_count
        | ([$products[].services[]? | select((.configuration_status // "") == "NOT_APPLICABLE")] | length) as $configuration_not_applicable_count
        | {
            evidence_type: "DERIVED",
            derived_from: [
              "products[].services[].configuration_status",
              "products[].services[].configuration_requested"
            ],
            status: (
              if $configuration_mapping_count == 0 then "NOT_APPLICABLE"
              elif $configuration_unavailable_count > 0 and $configuration_retrieved_count == 0 and $configuration_not_requested_count == 0 then "UNKNOWN"
              elif $configuration_unavailable_count > 0 then "PARTIAL"
              elif $configuration_not_requested_count > 0 and $configuration_requested_count == 0 then "NOT_REQUESTED"
              elif $configuration_not_requested_count > 0 then "PARTIAL"
              elif $configuration_not_applicable_count == $configuration_mapping_count then "NOT_APPLICABLE"
              elif $configuration_requested_count > 0 and $configuration_retrieved_count == $configuration_requested_count then "COMPLETE"
              else "PARTIAL"
              end
            ),
            mapping_count: $configuration_mapping_count,
            requested_count: $configuration_requested_count,
            retrieved_count: $configuration_retrieved_count,
            unavailable_count: $configuration_unavailable_count,
            not_requested_count: $configuration_not_requested_count,
            not_applicable_count: $configuration_not_applicable_count,
            known_unavailable_count: $configuration_unavailable_count,
            legacy_unavailable_configurations_semantics: "known UNAVAILABLE service mappings only; NOT_REQUESTED and NOT_APPLICABLE mappings are counted separately"
          } as $configuration_summary
        | {
            schema_version: 1,
            command: "security summary",
            mode: $config_mode,
            detailed: ($config_mode == "detailed"),
            generated_at: $generated_at,
            customer: {
              id: ($customer.id // null),
              name: ($customer.name // null)
            },
            summary: {
              token_visible_customer_services: (if $services_complete then ($services | length) else null end),
              evidence_type: "DERIVED",
              derived_from: [
                "inventory_sections.service_inventory",
                "inventory_sections.product_attachments",
                "inventory_sections.edge_waf_service_attachments",
                "inventory_sections.ngwaf_workspaces",
                "products",
                "ngwaf"
              ],
              token_visible_customer_services_lower_bound: ($services | length),
              service_inventory_status: ($services_body.meta.result.status // $services_body.meta.status // "UNKNOWN"),
              security_products_scanned: ($products | length),
              product_inventory_status: $product_inventory_status,
              enabled_product_types: (if $products_complete then $enabled_product_type_lower_bound else null end),
              enabled_product_types_lower_bound: (if $product_inventory_status == "UNKNOWN" then null else $enabled_product_type_lower_bound end),
              service_product_mappings: (if $products_complete then $mapping_lower_bound else null end),
              service_product_mappings_lower_bound: (if $product_inventory_status == "UNKNOWN" then null else $mapping_lower_bound end),
              cdn_mappings: (if $products_complete then ([$products[].services[]? | select(.platform == "CDN")] | length) else null end),
              cdn_mappings_lower_bound: (if $product_inventory_status == "UNKNOWN" then null else ([$products[].services[]? | select(.platform == "CDN")] | length) end),
              compute_mappings: (if $products_complete then ([$products[].services[]? | select(.platform == "Compute")] | length) else null end),
              compute_mappings_lower_bound: (if $product_inventory_status == "UNKNOWN" then null else ([$products[].services[]? | select(.platform == "Compute")] | length) end),
              paused_service_mappings: (if any($products[].services[]?; .paused == null) then null else ([$products[].services[]? | select(.paused == true)] | length) end),
              unknown_enablement_checks: ([$products[].result.unknown_count] | add // ([$products[].unknown_check_count] | add // 0)),
              configuration_summary: $configuration_summary,
              known_unavailable_configurations: $configuration_summary.known_unavailable_count,
              unavailable_configurations: $configuration_summary.known_unavailable_count,
              ngwaf_workspaces: ($workspaces.data | length),
              edge_waf_service_attachments: (
                if ($ngwaf_product.result.status // "UNKNOWN") == "COMPLETE" then ($ngwaf_product.result.count // ($ngwaf_attachments | length))
                else null
                end
              ),
              edge_waf_service_attachments_lower_bound: ($ngwaf_product.result.count_lower_bound // $ngwaf_product.result.count // ($ngwaf_attachments | length)),
              edge_waf_service_attachment_status: ($ngwaf_product.result.status // "UNKNOWN"),
              ngwaf_service_attachments: (
                if ($ngwaf_product.result.status // "UNKNOWN") == "COMPLETE" then ($ngwaf_product.result.count // ($ngwaf_attachments | length))
                else null
                end
              ),
              ngwaf_service_attachments_lower_bound: ($ngwaf_product.result.count_lower_bound // $ngwaf_product.result.count // ($ngwaf_attachments | length)),
              ngwaf_service_attachment_status: ($ngwaf_product.result.status // "UNKNOWN"),
              completeness: ($services_body.meta.completeness // "unknown"),
              token_visibility_complete_for_customer: ($services_body.meta.token_visibility_complete_for_customer // null)
            },
            products: $products,
            reconciliation: $reconciliation_result,
            inventory_sections: {
              service_inventory: ($services_body.meta.result // {
                status: ($services_body.meta.status // "UNKNOWN"),
                count: ($services_body.meta.count // null),
                count_lower_bound: ($services_body.meta.count_lower_bound // null),
                source: ($services_body.meta.source // null),
                retrieved_at: null,
                evidence_type: ($services_body.meta.evidence_type // "UNKNOWN"),
                reason: null,
                pagination: null,
                fallback_used: false
              }),
              product_attachments: $product_inventory_result,
              edge_waf_service_attachments: (
                ($ngwaf_product.result // {status: "UNKNOWN", count: null, count_lower_bound: null})
                + {
                  source: "GET /enabled-products/v1/ngwaf/services",
                  evidence_type: (($ngwaf_product.result // {}).evidence_type // (if (($ngwaf_product.result // {}).status // "UNKNOWN") == "UNKNOWN" then "UNKNOWN" else "DIRECT" end)),
                  retrieved_at: (($ngwaf_product.result // {}).retrieved_at // $generated_at),
                  pagination: (($ngwaf_product.result // {}).pagination // null),
                  fallback_used: (($ngwaf_product.result // {}).fallback_used // false)
                }
              ),
              ngwaf_service_attachments: (
                ($ngwaf_product.result // {status: "UNKNOWN", count: null, count_lower_bound: null})
                + {
                  source: "GET /enabled-products/v1/ngwaf/services",
                  evidence_type: (($ngwaf_product.result // {}).evidence_type // (if (($ngwaf_product.result // {}).status // "UNKNOWN") == "UNKNOWN" then "UNKNOWN" else "DIRECT" end)),
                  retrieved_at: (($ngwaf_product.result // {}).retrieved_at // $generated_at),
                  pagination: (($ngwaf_product.result // {}).pagination // null),
                  fallback_used: (($ngwaf_product.result // {}).fallback_used // false)
                }
              ),
              ngwaf_workspaces: $workspace_inventory_result
            },
            ngwaf: {
              edge_waf_service_attachment_result: ($ngwaf_product.result // {status: "UNKNOWN", count: null, count_lower_bound: null}),
              service_attachment_result: ($ngwaf_product.result // {status: "UNKNOWN", count: null, count_lower_bound: null}),
              reconciliation_status: (if $ngwaf_attachments_complete then "COMPLETE" else "UNAVAILABLE" end),
              reconciliation_reason: (if $ngwaf_attachments_complete then "Edge WAF service attachments and NGWAF workspaces available" else "Edge WAF service attachment inventory is not complete" end),
              edge_waf_service_attachment_count: (
                if ($ngwaf_product.result.status // "UNKNOWN") == "COMPLETE" then ($ngwaf_product.result.count // ($ngwaf_attachments | length))
                else null
                end
              ),
              edge_waf_service_attachment_count_lower_bound: ($ngwaf_product.result.count_lower_bound // $ngwaf_product.result.count // ($ngwaf_attachments | length)),
              service_attachment_count: (
                if ($ngwaf_product.result.status // "UNKNOWN") == "COMPLETE" then ($ngwaf_product.result.count // ($ngwaf_attachments | length))
                else null
                end
              ),
              service_attachment_count_lower_bound: ($ngwaf_product.result.count_lower_bound // $ngwaf_product.result.count // ($ngwaf_attachments | length)),
              attachments: $ngwaf_attachments,
              workspace_count: ($workspaces.data | length),
              workspace_inventory_result: $workspace_inventory_result,
              pages_fetched: ($workspaces.meta.pages_fetched // null),
              workspaces: [
                $workspaces.data[]
                | . as $workspace_row
                | {
                    id: $workspace_row.id,
                    name: ($workspace_row.name // ""),
                    workspace_uid: ($workspace_row.workspace_uid // null),
                    mode: (.mode // null),
                    default_blocking_response_code: (.default_blocking_response_code // null),
                    attachments: [
                      $ngwaf_attachments[]
                      | select(.workspace_id == $workspace_row.id)
                      | {service_id, service_name, traffic_ramp}
                    ],
                    attachment_count: ([$ngwaf_attachments[] | select(.workspace_id == $workspace_row.id)] | length)
                  }
              ],
              informational: {
                evidence_type: "INFORMATIONAL",
                derived_from: [
                  "ngwaf.workspaces",
                  "ngwaf.attachments"
                ],
                workspace_without_edge_waf_attachment: $workspaces_without_attachment
              },
              anomalies: {
                workspace_not_found: [
                  $ngwaf_attachments[]
                  | select(.anomalies | index("workspace_not_found") != null)
                  | {service_id, service_name, workspace_id}
                ],
                missing_workspace_id: [
                  $ngwaf_attachments[]
                  | select(.anomalies | index("missing_workspace_id") != null)
                  | {service_id, service_name}
                ],
                missing_or_invalid_traffic_ramp: [
                  $ngwaf_attachments[]
                  | select(.anomalies | index("missing_or_invalid_traffic_ramp") != null)
                  | {service_id, service_name, traffic_ramp_raw}
                ],
                traffic_ramp_below_100: [
                  $ngwaf_attachments[]
                  | select(.anomalies | index("traffic_ramp_below_100") != null)
                  | {service_id, service_name, workspace_id, traffic_ramp}
                ],
                multiple_services_per_workspace: $multiple_services_per_workspace,
                multiple_attachments_per_service: $attachment_duplicates
              },
              anomaly_count: (
                ([ $ngwaf_attachments[]? | select((.anomalies | length) > 0) ] | length)
                + ($multiple_services_per_workspace | length)
                + ($attachment_duplicates | length)
              )
            },
            provenance: {
              service_discovery: ($services_body.meta // {}),
              product_enablement: {
                data_class: "configuration_inventory",
                customer_scope: "customer_id query parameter plus response customer.id validation",
                products: ["api_discovery", "bot_management", "ddos_protection", "ngwaf"],
                endpoints: [
                  "GET /enabled-products/v1/{product_id}/services",
                  "GET /enabled-products/v1/{product_id}/services/{service_id}",
                  "GET /enabled-products/v1/{product_id}/services/{service_id}/configuration"
                ],
                missing_data_policy: "unknown_not_disabled",
                result: $product_inventory_result
              },
              ngwaf_workspaces: {
                endpoint: "GET /ngwaf/v1/workspaces",
                data_class: "configuration_snapshot",
                pagination: "complete_or_fail",
                result: $workspace_inventory_result
              }
            },
            limitations: [
              "The service set contains token-visible Fastly service inventory filtered to the selected customer ID; it does not prove that the token can see every service in the customer account.",
              "Product enablement is configuration inventory. It does not prove current traffic, effective enforcement, or security efficacy.",
              "Non-2xx enablement checks other than 404 are unknown, not disabled.",
              "Edge WAF service attachment means the NGWAF Edge WAF product is configured on a Fastly service; it does not prove traffic is flowing through that workspace.",
              "NGWAF workspaces can exist without Edge WAF service attachments; that is workspace inventory context, not an anomaly by itself.",
              "Only public service-level APIs for API Discovery, Bot Management, DDoS Protection, and Edge WAF service attachments are included.",
              "Configuration fields are reported as returned by Fastly and are not interpreted as proof of policy behavior."
            ]
          }
      '
  )" || return

  jq . <<<"$payload"
}

cmd_security_summary() {
  [[ $# -le 2 ]] || die 'usage: fastly-audit security summary [--json] [--detailed]'

  local mode='' detailed=false arg config_mode
  local payload
  for arg in "$@"; do
    case "$arg" in
      --json) mode='--json' ;;
      --detailed) detailed=true ;;
      *) die 'usage: fastly-audit security summary [--json] [--detailed]' ;;
    esac
  done
  if $detailed; then
    config_mode='detailed'
  else
    config_mode='summary'
  fi

  payload="$(collect_security_summary_json "$config_mode")"

  if [[ "$mode" == '--json' ]]; then
    jq . <<<"$payload"
    return
  fi

  ui_heading 'Security product summary'
  jq -r '
    def exact_or_lower($exact; $lower):
      if $exact != null then ($exact | tostring)
      elif $lower != null then ">=" + ($lower | tostring)
      else "UNKNOWN"
      end;
    "Customer: \(.customer.name) (\(.customer.id))",
    "Token-visible customer services: \(exact_or_lower(.summary.token_visible_customer_services; .summary.token_visible_customer_services_lower_bound))",
    "Service inventory source: \(.provenance.service_discovery.source // .provenance.service_discovery.discovery_method // "unknown")",
    "Security products: \(exact_or_lower(.summary.enabled_product_types; .summary.enabled_product_types_lower_bound)) enabled product type(s), \(exact_or_lower(.summary.service_product_mappings; .summary.service_product_mappings_lower_bound)) service mapping(s)",
    "Configuration detail: \(.summary.configuration_summary.retrieved_count) retrieved, \(.summary.configuration_summary.unavailable_count) unavailable, \(.summary.configuration_summary.not_requested_count) not requested",
    "Edge WAF service attachments: \(exact_or_lower(.summary.edge_waf_service_attachments; .summary.edge_waf_service_attachments_lower_bound))",
    "NGWAF workspaces: \(.summary.ngwaf_workspaces)",
    "Inventory completeness: \(.summary.completeness)",
    "Reconciliation: \(.reconciliation.status) (\(.reconciliation.finding_count) finding(s))"
  ' <<<"$payload"

  if jq -e '.reconciliation.finding_count > 0' >/dev/null <<<"$payload"; then
    printf '\n'
    ui_heading 'Reconciliation findings'
    jq -r '
      ["SEVERITY", "TYPE", "PRODUCT", "OBJECT", "DETAIL"],
      (
        .reconciliation.findings[]
        | [
            .severity,
            .type,
            (.product_label // .product_id // "-"),
            (.service_id // .workspace_id // "-"),
            (.detail // "-")
          ]
      )
      | @tsv
    ' <<<"$payload" | human_table
  fi

  printf '\n'
  ui_heading 'Inventory provenance'
  jq -r '
    def count_display:
      if .count != null then (.count | tostring)
      elif .count_lower_bound != null then ">=" + (.count_lower_bound | tostring)
      else "UNKNOWN"
      end;
    def source_display:
      .source // .api // "unknown";
    def detail_display:
      if (.status // "UNKNOWN") == "COMPLETE" and (.fallback_used // false) == true then "fallback used"
      elif (.status // "UNKNOWN") == "COMPLETE" then "-"
      else (.reason // "query incomplete")
      end;
    ["SECTION", "COUNT", "STATUS", "EVIDENCE", "SOURCE", "RETRIEVED", "DETAIL"],
    (
      [
        {name: "Service inventory", value: .inventory_sections.service_inventory},
        {name: "Product attachments", value: .inventory_sections.product_attachments},
        {name: "Edge WAF service attachments", value: .inventory_sections.edge_waf_service_attachments},
        {name: "NGWAF workspace inventory", value: .inventory_sections.ngwaf_workspaces}
      ][]
      | [
          .name,
          (.value | count_display),
          (.value.status // "UNKNOWN"),
          (.value.evidence_type // "UNKNOWN"),
          (.value | source_display),
          (.value.retrieved_at // "-"),
          (.value | detail_display)
        ]
    )
    | @tsv
  ' <<<"$payload" | human_table

  printf '\n'
  ui_heading 'Service security attachments'
  jq -r '
    def count_display:
      if (.result.status // .status) == "COMPLETE" then
        ((.result.count // .enabled_count // 0) | tostring) + "/" + ((.result.services_checked // 0) | tostring)
      elif (.result.status // .status) == "PARTIAL" then
        ">=" + ((.result.count_lower_bound // .enabled_count // 0) | tostring) + "/" + ((.result.services_checked // 0) | tostring)
      else "UNKNOWN"
      end;
    def detail:
      if (.result.status // .status) == "COMPLETE" then (.result.reason // "complete")
      else (.result.reason // "query incomplete")
      end;
    ["PRODUCT", "SERVICES", "STATUS", "CDN", "COMPUTE", "DETAIL"],
    (
      .products
      | sort_by(.label)
      | .[]
      | [
          .label,
          count_display,
          (.result.status // .status // "UNKNOWN"),
          ([.services[]? | select(.platform == "CDN")] | length | tostring),
          ([.services[]? | select(.platform == "Compute")] | length | tostring),
          detail
        ]
    )
    | @tsv
  ' <<<"$payload" | human_table

  printf '\n'
  ui_heading 'Enabled service mappings'
  jq -r '
    def cfg($pid; $c):
      if $c == null then "-"
      elif $pid == "bot_management" then
        "contentguard=" + (if $c.contentguard == null then "unknown" else ($c.contentguard | tostring) end)
      elif $pid == "ddos_protection" then
        "mode=" + (($c.mode // "unknown") | tostring)
      elif $pid == "ngwaf" then
        "workspace_id=" + (($c.workspace_id // "unknown") | tostring)
        + ", traffic_ramp=" + (($c.traffic_ramp // "unknown") | tostring)
      else ($c | tostring)
      end;
    def state:
      if (.configuration_status // "") == "NOT_REQUESTED" then "configuration not requested"
      elif (.configuration_status // "") == "NOT_APPLICABLE" then "enabled"
      elif (.configuration_status // "") == "RETRIEVED" then "configuration reported"
      elif (.configuration_status // "") == "UNAVAILABLE" then "configuration unknown (HTTP " + ((.configuration_http_status // "unknown") | tostring) + ")"
      elif .configuration_http_status == null then "enabled"
      elif .configuration_http_status == 200 then "configuration reported"
      else "configuration unknown (HTTP " + (.configuration_http_status | tostring) + ")"
      end;
    ["SERVICE", "TYPE", "PRODUCT", "CONFIGURATION", "STATE"],
    (
      .products[] as $product
      | $product.services[]?
      | [
          .name,
          .platform,
          $product.label,
          cfg($product.id; .configuration),
          state
        ]
    )
    | @tsv
  ' <<<"$payload" | human_table

  printf '\n'
  ui_heading 'Edge WAF service attachments'
  jq -r '
    def ramp:
      if .traffic_ramp == null then "-"
      else (.traffic_ramp | tostring) + "%"
      end;
    def workspace_display:
      if .workspace != null then (.workspace.name // .workspace_id // "-")
      elif .workspace_id != null and .workspace_id != "" then .workspace_id + " (not found)"
      else "-"
      end;
    def anomaly_display:
      if (.anomalies | length) == 0 then "-"
      else (.anomalies | join(", "))
      end;
    ["SERVICE", "WORKSPACE", "RAMP", "MODE", "DEFAULT BLOCK RESPONSE", "ANOMALIES"],
    (
      .ngwaf.attachments
      | sort_by(.service_name, .service_id)
      | .[]
      | [
          .service_name,
          workspace_display,
          ramp,
          (.workspace.mode // "-"),
          (.workspace.default_blocking_response_code // "-" | tostring),
          anomaly_display
        ]
    )
    | @tsv
  ' <<<"$payload" | human_table

  if jq -e '.ngwaf.anomaly_count > 0' >/dev/null <<<"$payload"; then
    printf '\n'
    ui_heading 'NGWAF attachment anomalies'
    jq -r '
      def rows($kind; $items):
        $items[]? | [
          $kind,
          (.service_name // .workspace_name // "-"),
          (.service_id // .workspace_id // "-"),
          (
            if .workspace_id != null and .service_id != null then "workspace_id=" + (.workspace_id | tostring)
            elif .traffic_ramp != null then "traffic_ramp=" + (.traffic_ramp | tostring)
            elif .traffic_ramp_raw != null then "traffic_ramp_raw=" + (.traffic_ramp_raw | tostring)
            elif .reason != null then .reason
            else "-"
            end
          )
        ];
      ["TYPE", "NAME", "ID", "DETAIL"],
      rows("workspace_not_found"; .ngwaf.anomalies.workspace_not_found),
      rows("missing_workspace_id"; .ngwaf.anomalies.missing_workspace_id),
      rows("missing_or_invalid_traffic_ramp"; .ngwaf.anomalies.missing_or_invalid_traffic_ramp),
      rows("traffic_ramp_below_100"; .ngwaf.anomalies.traffic_ramp_below_100),
      (.ngwaf.anomalies.multiple_services_per_workspace[]? | [
        "multiple_services_per_workspace",
        (.workspace_name // "-"),
        .workspace_id,
        ("services=" + ([.services[].service_name] | join(",")))
      ]),
      (.ngwaf.anomalies.multiple_attachments_per_service[]? | [
        "multiple_attachments_per_service",
        (.service_name // "-"),
        .service_id,
        (.reason // ("attachments=" + ((.attachments // []) | length | tostring)))
      ])
      | @tsv
    ' <<<"$payload" | human_table
  fi

  printf '\n'
  ui_heading 'NGWAF workspace inventory'
  jq -r '
    ["WORKSPACE", "ID", "MODE", "DEFAULT BLOCK RESPONSE", "ATTACHMENTS"],
    (
      .ngwaf.workspaces
      | sort_by(.name)
      | .[]
      | [
          .name,
          .id,
          (.mode // "-"),
          (.default_blocking_response_code // "-" | tostring),
          (.attachment_count | tostring)
        ]
    )
    | @tsv
  ' <<<"$payload" | human_table

  if jq -e '(.ngwaf.informational.workspace_without_edge_waf_attachment // []) | length > 0' >/dev/null <<<"$payload"; then
    printf '\nNOTE: Some NGWAF workspaces have no Edge WAF service attachment. That is reported as workspace inventory context, not an anomaly.\n'
  fi

  printf '\nNOTE: Enabled means the product is attached in Fastly configuration; it does not prove traffic, enforcement, or efficacy.\n'

  if jq -e '.summary.unknown_enablement_checks > 0 or .summary.unavailable_configurations > 0' >/dev/null <<<"$payload"; then
    printf '%s: WARNING: one or more security-product checks were inconclusive; inspect --json details. Unknown is not disabled.\n' "$PROGRAM_NAME" >&2
  fi
}

# Parse before preflight so help and usage errors never require API access.
customer_security_parse_args() {
  CUSTOMER_SECURITY_MODE=human
  (( $# <= 1 )) || die 'usage: ngwaf security [--json|help|-h|--help]'
  case "${1:-}" in
    '') ;;
    --json) CUSTOMER_SECURITY_MODE=json ;;
    help|-h|--help) CUSTOMER_SECURITY_MODE=help ;;
    *) die 'usage: ngwaf security [--json|help|-h|--help]' ;;
  esac
}

# Optional deployment sources are isolated from the required inventory. A failed
# probe yields a visibility result, never a negative deployment assertion.
customer_security_agent_error_reason() {
  local err="$1" status
  status="$(sed -nE 's/.*returned HTTP ([0-9]{3}).*/HTTP \1/p' "$err" | head -1)"
  if [[ "$status" == 'HTTP 400' ]] &&
    grep -Eq '^[[:space:]]*"detail":[[:space:]]*"Site not found"' "$err"; then
    printf '%s\n' 'HTTP 400 (Site not found)'
  else
    printf '%s\n' "${status:-request failed}"
  fi
}

# Public Fastly NGWAF Agents: workspace IDs and FASTLY_API_TOKEN via get().
# Internal SigSci/Salt site records use separate session credentials and IDs.
customer_security_agent_inventory_json() {
  [[ $# -eq 3 ]] || die 'customer_security_agent_inventory_json requires <workspace-id> <workspace-uid> <customer-id>'
  local workspace_id="$1" workspace_uid="$2" cid="$3" body err reason identifier_used=id
  err="$(mktemp)"
  if ! body="$(get "$(workspace_path "$workspace_id")/agents" \
    --data-urlencode "customer_id=$cid" 2>"$err")"; then
    reason="$(customer_security_agent_error_reason "$err")"
    if [[ "$reason" == HTTP\ 400* && -n "$workspace_uid" && "$workspace_uid" != "$workspace_id" ]]; then
      : >"$err"
      identifier_used=workspace_uid
      if ! body="$(get "$(workspace_path "$workspace_uid")/agents" \
        --data-urlencode "customer_id=$cid" 2>"$err")"; then
        reason="$(customer_security_agent_error_reason "$err")"
      else
        reason=''
      fi
    fi
  else
    reason=''
  fi
  if [[ -z "$reason" ]] &&
    jq -e --arg id "$workspace_id" --arg uid "$workspace_uid" '
      type == "object" and (.meta.total | type == "number" and . >= 0 and floor == .) and
      (.data | type == "array") and
      all(.data[]; type == "object" and has("module_detected") and
        (.module_detected | type == "boolean") and
        (if has("agent_active") then (.agent_active | type == "boolean") else true end) and
        (if has("workspace_id") then (.workspace_id == $id or ($uid != "" and .workspace_id == $uid)) else true end))
    ' >/dev/null <<<"$body"; then
    jq -c --arg identifier_used "$identifier_used" \
      '{status:"returned",source:"GET /ngwaf/v1/workspaces/{workspace_id}/agents",
        identifier_used:$identifier_used,reported_total:.meta.total,
        returned_agent_count:(.data | length),
        total_matches_returned_count:(.meta.total == (.data | length)),
        reported_total_status:(if .meta.total == (.data | length) then "matches_returned_count"
                               elif .meta.total > (.data | length) then "inflated_total_consistent_with_sds_5073"
                               else "reported_total_below_returned_count" end),agents:.data}' <<<"$body"
  else
    jq -nc --arg reason "${reason:-request failed or incomplete data}" \
      --arg identifier_used "$identifier_used" \
      '{status:"unavailable",source:"GET /ngwaf/v1/workspaces/{workspace_id}/agents",identifier_used:$identifier_used,reason:$reason,agents:[]}'
  fi
  rm -f "$err"
}

# The legacy Cloud WAF API is a separate, opt-in credential domain. Return only
# a response body and status; callers validate every relationship before use.
customer_security_cloud_get() {
  local path="$1" outfile="$2" code
  code="$(curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    --retry "$CURL_RETRIES" -o "$outfile" -w '%{http_code}' \
    -H 'Accept: application/json' -H "x-api-user: $SIGSCI_EMAIL" \
    -H "x-api-token: $SIGSCI_TOKEN" \
    "https://dashboard.signalsciences.net/api/v0$path" 2>/dev/null)" || code=000
  printf '%s\n' "$code"
}

customer_security_cloud_inventory_json() {
  local cid="$1" corp="${SIGSCI_CORP:-}" tmp code list instance id site site_code
  local records='[]' reason='' visible=false
  local -A validated_sites=()
  if [[ -z "$corp" || -z "${SIGSCI_EMAIL:-}" || -z "${SIGSCI_TOKEN:-}" ]]; then
    jq -nc '{status:"unavailable",source:"GET /corps/{corpName}/cloudwafInstances",reason:"SIGSCI_CORP, SIGSCI_EMAIL, and SIGSCI_TOKEN are required",associations:[]}'
    return
  fi
  tmp="$(mktemp)"
  code="$(customer_security_cloud_get "/corps/$(urlencode "$corp")/cloudwafInstances" "$tmp")"
  if [[ "$code" != 2* ]] || ! jq -e 'type == "object" and (.data | type == "array") and
    all(.data[]; type == "object" and (.id | type == "string" and length > 0)) and
    ([.data[].id] | length == (unique | length))' >/dev/null 2>&1 <"$tmp"; then
    rm -f "$tmp"
    jq -nc --arg reason "HTTP $code or incomplete list" '{status:"unavailable",source:"GET /corps/{corpName}/cloudwafInstances",reason:$reason,associations:[]}'
    return
  fi
  list="$(cat "$tmp")"
  visible=true
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    code="$(customer_security_cloud_get "/corps/$(urlencode "$corp")/cloudwafInstances/$(urlencode "$id")" "$tmp")"
    if [[ "$code" != 2* ]] || ! jq -e --arg id "$id" 'type == "object" and .id == $id and
      (.workspaceConfigs | type == "array") and
      all(.workspaceConfigs[]; type == "object" and (.siteName | type == "string" and length > 0))' >/dev/null 2>&1 <"$tmp"; then
      visible=false; reason="Cloud WAF instance detail HTTP $code or incomplete data"; break
    fi
    instance="$(cat "$tmp")"
    while IFS= read -r site; do
      [[ -n "$site" ]] || continue
      if [[ -z "${validated_sites[$site]+x}" ]]; then
        site_code="$(customer_security_cloud_get "/corps/$(urlencode "$corp")/sites/$(urlencode "$site")" "$tmp")"
        if [[ "$site_code" != 2* ]] || ! jq -e --arg cid "$cid" --arg site "$site" '
          type == "object" and .name == $site and .customer_id == $cid' >/dev/null 2>&1 <"$tmp"; then
          visible=false; reason="Cloud WAF site ownership unavailable or conflicting"; break
        fi
        validated_sites["$site"]=1
      fi
      records="$(jq -nc --argjson records "$records" --arg site "$site" --arg id "$id" \
        --arg name "$(jq -r '.name // .id' <<<"$instance")" \
        '$records + [{site_name:$site,instance_id:$id,instance_name:$name}]')"
    done < <(jq -r '.workspaceConfigs[].siteName' <<<"$instance")
    [[ "$visible" == true ]] || break
  done < <(jq -r '.data[].id' <<<"$list")
  rm -f "$tmp"
  if [[ "$visible" == true ]]; then
    jq -nc --argjson records "$records" '{status:"complete",source:"GET /corps/{corpName}/cloudwafInstances/{id}",associations:$records}'
  else
    jq -nc --arg reason "$reason" '{status:"unavailable",source:"GET /corps/{corpName}/cloudwafInstances/{id}",reason:$reason,associations:[]}'
  fi
}

customer_security_deployments_json() {
  local payload="$1" cid workspace_id workspace_uid agents_tmp agent_result cloud_result checked=0 total
  cid="$(jq -r '.customer.id' <<<"$payload")"
  total="$(jq '.ngwaf.workspaces | length' <<<"$payload")"
  agents_tmp="$(mktemp)"
  while IFS=$'\t' read -r workspace_id workspace_uid; do
    agent_result="$(customer_security_agent_inventory_json "$workspace_id" "$workspace_uid" "$cid")"
    jq -c --arg id "$workspace_id" '{workspace_id:$id,result:.}' <<<"$agent_result" >>"$agents_tmp"
    checked=$((checked + 1))
    progress_job_milestone 'Workspace checks' "$checked" "$total"
  done < <(jq -r '
    .ngwaf.workspaces as $all
    | $all[] as $workspace
    | [$workspace.id,
       (if ($workspace.workspace_uid | type) == "string" and $workspace.workspace_uid != "" and
          ([$all[] | select(.id == $workspace.workspace_uid or .workspace_uid == $workspace.workspace_uid)] | length) == 1
        then $workspace.workspace_uid else "" end)] | @tsv
  ' <<<"$payload")
  if (( total == 0 )); then progress_job_note 'Workspace checks: 0/0'; fi
  cloud_result="$(customer_security_cloud_inventory_json "$cid")"
  jq -s --argjson cloud "$cloud_result" \
    --slurpfile agents "$agents_tmp" '
      def record($type;$status;$evidence_type;$evidence;$source):
        {type:$type,status:$status,evidence_type:$evidence_type,evidence:$evidence,source:$source};
      .[0] as $payload | $payload
      | .ngwaf.deployment_sources = {cloud_waf:(($cloud | del(.associations)) +
          {unmatched_association_count: ([$cloud.associations[] | . as $association
            | select(([$payload.ngwaf.workspaces[] |
                select(.id == $association.site_name or .name == $association.site_name)] | length) != 1)] | length)}),
          agents:[$agents[] | {workspace_id,status:.result.status,source:.result.source,
            reason:.result.reason,reported_total:.result.reported_total,
            returned_agent_count:.result.returned_agent_count,
            total_matches_returned_count:.result.total_matches_returned_count,
            reported_total_status:.result.reported_total_status}]}
      | .ngwaf.workspaces |= map(
          . as $workspace
          | ([$payload.ngwaf.attachments[] | select(.workspace_id == $workspace.id and .configuration_status == "RETRIEVED" and .mapping_validation.status == "RESOLVED")]) as $attachments
          | ([$cloud.associations[] | . as $association
              | select(([$payload.ngwaf.workspaces[] |
                  select(.id == $association.site_name or .name == $association.site_name)] | length) == 1)
              | select(.site_name == $workspace.id or .site_name == $workspace.name)]) as $cloud_matches
          | ([$agents[] | select(.workspace_id == $workspace.id) | .result] | .[0]) as $agent_result
          | (if ($attachments | length) > 0 then
               [record("edge_waf";"confirmed";"service_attachment";
                 (if ($attachments | length) == 1 then "Fastly service attachment: " + ($attachments[0].service_name // $attachments[0].service_id)
                  else "\($attachments | length) Fastly service attachments" end);
                 "GET /enabled-products/v1/ngwaf/services/{service_id}/configuration")]
             else [] end) as $edge_records
          | ([$cloud_matches[] | record("cloud_waf";"confirmed";"cloud_waf_instance";
               "Cloud WAF instance: " + .instance_name;
               "GET /corps/{corpName}/cloudwafInstances/{id}")]) as $cloud_records
          | ([$agent_result.agents[] | select(.module_detected == true)]) as $modules
          | ([$agent_result.agents[] | select(.module_detected == false)]) as $other_agents
          | (if ($modules | length) > 0 then
               [record("agent_based_unknown";"unresolved";"agent_module";
                 ("NGWAF agent reports module_detected=true" +
                   ([$modules[0] | {module_type,module_server,module_version,host_os} | to_entries[] |
                     select(.value != null and .value != "") | "\(.key)=\(.value)"] |
                    if length > 0 then " (" + join(", ") + ")" else "" end));
                 "GET /ngwaf/v1/workspaces/{workspace_id}/agents")]
             else [] end) as $module_records
          | (if ($other_agents | length) > 0 then
               [record("agent_based_unknown";"unresolved";"agent_present";
                 (if any($other_agents[]; .agent_active == true) then "Active NGWAF agent; no module detected" else "NGWAF agent; no module detected" end);
                 "GET /ngwaf/v1/workspaces/{workspace_id}/agents")]
             else [] end) as $agent_records
          | .deployments = ($edge_records + $cloud_records + $module_records + $agent_records)
          | if (.deployments | length) == 0 then
              .deployments = [record("unknown";"unresolved";"none";
                "No recognized deployment evidence";"deployment inventory")]
            else . end
          | .deployment_visibility = {agents:($agent_result | del(.agents)),cloud_waf:($cloud | del(.associations))}
        )
      | .limitations += [
          "NGWAF deployment architecture is reported per workspace; a workspace may have multiple methods.",
          "Agent module observations do not establish whether the deployment is customer-managed On-Prem, Fastly-managed Edge, or Cloud WAF.",
          "Unresolved deployment architecture means available APIs do not safely identify the method."
        ]
    ' <<<"$payload"
  rm -f "$agents_tmp"
}

customer_security_payload_json() {
  # Retain the existing v1 product/result/provenance structures. Product-enable
  # attachment counts are separate from verified service-to-workspace joins.
  jq '
    def mapping_reasons($source; $service; $attachment):
      ($attachment.workspace_id) as $id
      | ([$source.ngwaf.workspaces[] | select(.id == $id)]) as $matches
      | ([$source.ngwaf.workspaces[] | select(.workspace_uid != null and .workspace_uid == $id and .id != $id)]) as $uid_id_conflicts
      | (if ($matches | length) == 1 and ($matches[0].workspace_uid | type) == "string" and $matches[0].workspace_uid != ""
         then [$source.ngwaf.workspaces[] | select(.id != $id and .workspace_uid == $matches[0].workspace_uid)]
         else [] end) as $uid_collisions
      | [
          (if $source.ngwaf.workspace_inventory_result.status != "COMPLETE" then "workspace_inventory_incomplete" else empty end),
          (if ($id | type) != "string" or $id == "" then "missing_workspace_id" else empty end),
          (if ($id | type) == "string" and $id != "" and ($matches | length) == 0 then "workspace_not_found" else empty end),
          (if ($matches | length) > 1 then "ambiguous_workspace_id" else empty end),
          (if ($uid_id_conflicts | length) > 0 or ($uid_collisions | length) > 0 or
              ($attachment.workspace != null and $attachment.workspace.id != $id) or
              ($service.configuration_status == "RETRIEVED" and $service.configuration.workspace_id != $id)
           then "conflicting_workspace_identifier" else empty end),
          (if ($service.customer_id != null and $service.customer_id != $source.customer.id) or
              ($attachment.customer_id != null and $attachment.customer_id != $source.customer.id)
           then "ownership_conflict" else empty end)
        ];
    . as $source
    | (.products[] | select(.id == "ngwaf")) as $edge
    | [.ngwaf.attachments[] as $attachment
        | ([$edge.services[] | select(.id == $attachment.service_id)]) as $services
        | ($services[0] // {}) as $service
        | (mapping_reasons($source; $service; $attachment) +
            (if ($services | length) != 1 then ["conflicting_service_identity"] else [] end)) as $reasons
        | $attachment
        | .configuration_status = ($service.configuration_status // null)
        | .configuration_evidence_type = ($service.configuration_evidence_type // null)
        | .traffic_ramp_raw = ($service.configuration.traffic_ramp // null)
        | .mapping_validation = {
            status: (if ($reasons | length) == 0 and $service.configuration_status == "RETRIEVED" then "RESOLVED" else "UNRESOLVED" end),
            reason_codes: ($reasons + (if $service.configuration_status != "RETRIEVED" then ["configuration_unavailable"] else [] end)),
            workspace_match_count: ([$source.ngwaf.workspaces[] | select(.id == $attachment.workspace_id)] | length),
            evidence_type: "DERIVED"
          }
      ] as $attachments
    | ($source.summary.service_inventory_status == "COMPLETE" and $edge.result.status == "COMPLETE"
        and $source.ngwaf.workspace_inventory_result.status == "COMPLETE"
        and ($attachments | length) == ($edge.services | length)
        and all($attachments[]; .mapping_validation.status == "RESOLVED")) as $links_complete
    | {
        schema_version,
        command: "customer security",
        generated_at,
        customer,
        summary,
        products,
        inventory_sections,
        provenance,
        ngwaf: (.ngwaf | {
          edge_waf_service_attachment_result,
          edge_waf_service_attachment_count,
          edge_waf_service_attachment_count_lower_bound,
          workspace_count,
          workspace_inventory_result,
          pages_fetched,
          attachment_mapping_result: {
            status: (if $links_complete then "COMPLETE" else "PARTIAL" end),
            evidence_type: "DERIVED",
            derived_from: ["products[].result", "products[].services[].configuration", "ngwaf.workspaces"],
            discovery_method: "ngwaf_product_enablement",
            completeness_scope: "product_enabled_service_attachments_only",
            other_deployment_methods_included: false,
            configured_attachment_count: ($attachments | length),
            resolved_mapping_count: ([$attachments[] | select(.mapping_validation.status == "RESOLVED")] | length),
            unresolved_attachments: [$attachments[] | select(.mapping_validation.status == "UNRESOLVED") |
              {service_id, workspace_id, reason_codes: .mapping_validation.reason_codes}],
            reason: (if $links_complete then "product-enabled service attachments and their workspace joins are complete within the selected inventory"
              else "product-enabled attachment inventory or workspace joins are inconclusive; verified workspace counts are lower bounds" end)
          },
          attachments: $attachments,
          workspaces: [.workspaces[]
            | . as $workspace
            | .attachments = [$attachments[] | select(.workspace_id == $workspace.id and .mapping_validation.status == "RESOLVED") |
                {service_id, service_name, traffic_ramp}]
            | .attachment_count_lower_bound = (if $links_complete then null else (.attachments | length) end)
            | .attachment_count = (if $links_complete then (.attachments | length) else null end)
            | .attachment_count_status = (if $links_complete then "COMPLETE" else "PARTIAL" end)]
        }),
        limitations: (.limitations + [
          "Edge WAF service attachments count NGWAF product enablement on token-visible Fastly services, not NGWAF workspaces or every NGWAF deployment method; zero attachments does not mean NGWAF is undeployed.",
          "Workspace existence does not establish attachment, traffic, production use, active use, per-hostname protection, or rule effectiveness.",
          "Workspace attachment counts are exact only when attachment inventory and workspace ID configuration are complete; otherwise observed mappings are lower bounds."
        ])
      }
    | .summary.token_visibility_complete_for_customer = (
        if ($source.provenance.service_discovery | has("token_visibility_complete_for_customer"))
        then $source.provenance.service_discovery.token_visibility_complete_for_customer
        else null end)
    | .summary.ngwaf_service_attachment_scope = "product_enabled_service_attachments_only"
    | .inventory_sections.edge_waf_service_attachments.completeness_scope = "product_enabled_service_attachments_only"
    | .inventory_sections.ngwaf_service_attachments.completeness_scope = "product_enabled_service_attachments_only"
    | .ngwaf.edge_waf_service_attachment_result.completeness_scope = "product_enabled_service_attachments_only"
    | .ngwaf.service_attachment_result.completeness_scope = "product_enabled_service_attachments_only"
  '
}

customer_security_render_human() {
  local payload="$1" product_id title status mapping_count
  ui_heading 'Customer security configuration'
  jq -r '
    def count($exact; $lower):
      if $exact != null then $exact | tostring
      elif $lower != null then ">=" + ($lower | tostring)
      else "UNKNOWN" end;
    "Customer: \(.customer.name) (\(.customer.id))",
    "Token-visible services: \(count(.summary.token_visible_customer_services; .summary.token_visible_customer_services_lower_bound))",
    "Service inventory: \(.summary.service_inventory_status) (\(.summary.completeness))"
  ' <<<"$payload"

  printf '\n'
  ui_heading 'SECURITY PRODUCTS'
  jq -r '
    ["PRODUCT", "SERVICES", "STATUS"],
    (.products[] | [ .label,
      (if .result.count != null then .result.count | tostring
       elif .result.count_lower_bound != null then ">=" + (.result.count_lower_bound | tostring)
       else "UNKNOWN" end), .result.status ]) | @tsv
  ' <<<"$payload" | human_table
  jq -r '
    "NGWAF workspaces inventoried: \(.ngwaf.workspace_count) (\(.ngwaf.workspace_inventory_result.status)).",
    "Edge WAF service attachments count NGWAF product enablement on token-visible Fastly services; they do not count NGWAF workspaces or every NGWAF deployment method.",
    (if .ngwaf.workspace_count > 0 and
        ([.products[] | select(.id == "ngwaf") | .result.count] | .[0]) == 0
     then "Zero Edge WAF service attachments does not mean NGWAF is undeployed."
     else empty end)
  ' <<<"$payload"

  while IFS=$'\t' read -r product_id title; do
    printf '\n'
    ui_heading "$title"
    status="$(jq -r --arg id "$product_id" '.products[] | select(.id == $id) | .result.status' <<<"$payload")"
    mapping_count="$(jq --arg id "$product_id" '.products[] | select(.id == $id) | .services | length' <<<"$payload")"
    if [[ "$status" != COMPLETE ]]; then
      printf 'Retrieval was inconclusive (%s); shown mappings are observed only.\n' "$status"
    elif [[ "$mapping_count" == 0 ]]; then
      if [[ "$product_id" == ngwaf ]]; then
        printf 'No NGWAF product-enabled service attachments found; other deployment methods may still be present.\n'
      else
        printf 'No configured service mappings found.\n'
      fi
    fi
    [[ "$mapping_count" != 0 ]] || continue
    jq -r --arg id "$product_id" '
      def display: if . == null then "not reported" else tostring end;
      . as $payload
      | (.products[] | select(.id == $id)) as $product
      | (if $id == "api_discovery" then ["SERVICE", "TYPE"]
         elif $id == "bot_management" then ["SERVICE", "TYPE", "CONTENTGUARD", "CONFIG STATUS"]
         elif $id == "ddos_protection" then ["SERVICE", "TYPE", "MODE", "CONFIG STATUS"]
         else ["SERVICE", "TYPE", "WORKSPACE", "RAMP", "MODE", "DEFAULT BLOCK RESPONSE", "CONFIG STATUS"] end),
        ($product.services | sort_by(.name, .id) | .[]
          | . as $service
          | [ (if .name == "" then .id else .name end), .platform ]
            + (if $id == "api_discovery" then []
               elif $id == "bot_management" then [($service.configuration.contentguard | display), $service.configuration_status]
               elif $id == "ddos_protection" then [($service.configuration.mode | display), $service.configuration_status]
               else
                 ([$payload.ngwaf.attachments[] | select(.service_id == $service.id)] | .[0]) as $attachment
                 | [($attachment.workspace.name // $attachment.workspace_id | display),
                    ($attachment.traffic_ramp_raw | display),
                    ($attachment.workspace.mode | display),
                    ($attachment.workspace.default_blocking_response_code | display),
                    $service.configuration_status]
               end)) | @tsv
    ' <<<"$payload" | human_table
  done <<'PRODUCTS'
api_discovery	API DISCOVERY
bot_management	BOT MANAGEMENT
ddos_protection	DDOS PROTECTION
ngwaf	EDGE WAF SERVICE ATTACHMENTS
PRODUCTS

  printf '\n'
  ui_heading 'NGWAF WORKSPACES'
  if [[ "$(jq '.ngwaf.workspace_count' <<<"$payload")" == 0 ]]; then
    printf 'No NGWAF workspaces found in the complete inventory.\n'
  else
    jq -r '
      def display: if . == null then "not reported" else tostring end;
      ["WORKSPACE", "ID", "MODE", "DEFAULT BLOCK RESPONSE", "ATTACHMENTS"],
      (.ngwaf.workspaces | sort_by(.name, .id) | .[] | [
        .name, .id, (.mode | display), (.default_blocking_response_code | display),
        (if .attachment_count != null then .attachment_count | tostring
         elif .attachment_count_lower_bound > 0 then ">=" + (.attachment_count_lower_bound | tostring)
         else "UNKNOWN" end)]) | @tsv
    ' <<<"$payload" | human_table
  fi
  if [[ "$(jq -r '.ngwaf.attachment_mapping_result.status' <<<"$payload")" != COMPLETE ]]; then
    printf '\nWorkspace attachment counts are inconclusive; observed counts are lower bounds.\n'
  fi
  printf '\n'
  ui_heading 'NGWAF DEPLOYMENTS'
  if [[ "$(jq '.ngwaf.workspace_count' <<<"$payload")" == 0 ]]; then
    printf 'No NGWAF workspaces found in the complete inventory.\n'
  else
    jq -r '
      def deployment_label:
        {edge_waf:"Edge WAF",cloud_waf:"Cloud WAF",
         agent_based_unknown:"Agent-based deployment",unknown:"Unknown"}[.] // .;
      ["WORKSPACE","DEPLOYMENT","EVIDENCE","STATUS"],
      (.ngwaf.workspaces | sort_by(.name,.id) | .[] as $workspace
       | $workspace.deployments[]
       | [$workspace.name, (.type | deployment_label), .evidence, (.status | ascii_upcase)])
      | @tsv
    ' <<<"$payload" | human_table
  fi
  jq -r '
    (if .ngwaf.deployment_sources.cloud_waf.status == "unavailable" then
       "Cloud WAF deployment visibility unavailable: " + .ngwaf.deployment_sources.cloud_waf.reason
     else empty end),
    (.ngwaf.deployment_sources.agents[] | select(.status == "unavailable") |
      "Agent inventory unavailable for workspace " + .workspace_id + ": " + .reason)
  ' <<<"$payload" >&2
  printf '\nScope: Token-visible services do not prove complete account-wide visibility.\n'
  printf 'Configuration and workspace presence do not prove traffic, per-hostname protection, enforcement, or efficacy.\n'
  printf 'Deployment architecture is per workspace; a customer and a workspace may use multiple methods.\n'
  printf 'Zero Edge WAF attachments do not prove a workspace is undeployed; unresolved means available APIs cannot safely identify the method.\n'
}

cmd_customer_security() {
  local payload
  payload="$(collect_security_summary_json detailed true | customer_security_payload_json)"
  ui_phase 5 5 'Inspecting deployment evidence'
  payload="$(customer_security_deployments_json "$payload")"
  if [[ "$CUSTOMER_SECURITY_MODE" == json ]]; then
    jq . <<<"$payload"
  else
    customer_security_render_human "$payload"
  fi
}
