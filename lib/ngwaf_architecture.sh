# shellcheck shell=bash
# Read-only, single-service Edge WAF architecture inspection.

# GET /service/{id} can omit active_version. Only the documented Version
# number and active flag are authoritative; .version may be a draft.
architecture_active_from_detail_json() {
  jq -c '
    .active_version as $v
    | (if ($v | type) == "object" then $v.number else $v end) as $n
    | if ($v | type) == "object" and $v.active == false and $n != null then
      {status:"CONFLICT",version:null,source:"GET /service/{service_id}",reason:"active_version_marked_inactive"}
      elif ($n | type) == "number" and $n > 0 and $n == ($n | floor) and
         (($v | type) != "object" or $v.active != false)
      then {status:"RESOLVED",version:$n,source:"GET /service/{service_id}",reason:"active_version"}
      elif ($n | type) == "string" and ($n | test("^[1-9][0-9]*$")) and
           (($v | type) != "object" or $v.active != false)
      then {status:"RESOLVED",version:($n|tonumber),source:"GET /service/{service_id}",reason:"active_version"}
      else {status:"UNRESOLVED",version:null,source:"GET /service/{service_id}",reason:"active_version_missing_or_invalid"}
      end
  ' "$1"
}

architecture_active_from_versions_json() {
  local sid="$1" body="$2"
  jq -c --arg sid "$sid" '
    if type != "array" then
      {status:"UNRESOLVED",version:null,reason:"unexpected_version_list_schema"}
    elif any(.[]; type != "object" or .service_id != $sid or
          (.number | type) != "number" or .number <= 0 or .number != (.number | floor) or
          (.active | type) != "boolean") then
      {status:"UNRESOLVED",version:null,reason:"version_identity_or_schema_conflict"}
    elif ([.[].number] | unique | length) != length then
      {status:"UNRESOLVED",version:null,reason:"duplicate_version_number"}
    else ([.[] | select(.active == true)] | if length == 1 then
      {status:"RESOLVED",version:.[0].number,reason:"one_active_version"}
      elif length == 0 then
      {status:"UNRESOLVED",version:null,reason:"no_active_version"}
      else {status:"UNRESOLVED",version:null,reason:"multiple_active_versions"} end)
    end
  ' "$body"
}

cmd_service_ngwaf_architecture() {
  local selector='' version='' version_source=active json=false
  local cid detail body code service inventory resolved sid active selected endpoint version_resolution version_body version_code
  local product_code product_status=UNVERIFIED product_reason product_body
  local vcl_status=UNKNOWN vcl_reason='' vcl_http=null parsed='{"status":"UNKNOWN","matches":[],"line_count":null}'
  local content retrieved_at='' report context_lines=1 architecture=unknown deployment=UNVERIFIED

  while (( $# > 0 )); do
    case "$1" in
      --json) json=true; shift ;;
      --show-vcl) context_lines=3; shift ;;
      --version)
        (( $# >= 2 )) || die '--version requires a positive version number'
        [[ "$2" =~ ^[1-9][0-9]*$ ]] || die '--version requires a positive version number'
        version="$2"; version_source=explicit; shift 2 ;;
      --*) die "unknown service ngwaf-architecture option: $1" ;;
      *) [[ -z "$selector" ]] || die 'specify one service'; selector="$1"; shift ;;
    esac
  done
  [[ -n "$selector" ]] || die 'usage: fastly-audit service ngwaf-architecture <service-id-or-name> [--version N] [--show-vcl] [--json]'
  require perl
  cid="$(current_cid)"

  # Try exact service identity first. A 404 permits the existing exact-name
  # resolver; other failures never broaden into customer inventory.
  sid="$selector"
  detail="$(mktemp)"
  ui_phase 1 3 'Verifying service identity and customer ownership'
  code="$(NGWAF_HTTP_REDACT_CURL_STDERR=1 http_get_to_file "/service/$(urlencode "$sid")" "$detail")"
  if [[ "$code" == 404 ]]; then
    rm -f "$detail"
    ui_phase 1 3 'Resolving selected service name'
    inventory="$(get_token_visible_customer_services)" || die 'token-visible service inventory unavailable; cannot resolve service name'
    resolved="$(resolve_vcl_size_service_json "$inventory" "$selector")" || return 1
    [[ "$(jq -r .status <<<"$resolved")" == COMPLETE ]] || die "service name is absent or ambiguous in selected-customer inventory: $selector"
    sid="$(jq -r '.service.id' <<<"$resolved")"
    detail="$(mktemp)"
    code="$(NGWAF_HTTP_REDACT_CURL_STDERR=1 http_get_to_file "/service/$(urlencode "$sid")" "$detail")"
  fi
  if [[ "$code" != 2* ]] || ! jq -e --arg sid "$sid" --arg cid "$cid" '
    type == "object" and .id == $sid and .customer_id == $cid and
    (.name | type) == "string" and (.name | length) > 0 and
    (.type == "vcl" or .type == "wasm")
  ' "$detail" >/dev/null 2>&1; then
    rm -f "$detail"
    die "service identity, type, or selected-customer ownership could not be verified (HTTP $code)"
  fi
  version_resolution="$(architecture_active_from_detail_json "$detail" | jq -c '. + {http_status:200}')" || return 1
  if [[ "$(jq -r .status <<<"$version_resolution")" == UNRESOLVED ]]; then
    ui_phase 1 3 'Service detail has no verified active version; checking this service version list'
    version_body="$(mktemp)"
    version_code="$(NGWAF_HTTP_REDACT_CURL_STDERR=1 http_get_to_file "/service/$(urlencode "$sid")/version" "$version_body")"
    if [[ "$version_code" == 2* ]] && jq -e -s 'length == 1' "$version_body" >/dev/null 2>&1; then
      version_resolution="$(architecture_active_from_versions_json "$sid" "$version_body" | jq -c --argjson code "$version_code" '. + {source:"GET /service/{service_id}/version",http_status:$code}')" || return 1
    else
      version_resolution="$(jq -nc --arg code "$version_code" '{status:"UNRESOLVED",version:null,source:"GET /service/{service_id}/version",reason:"version_list_request_or_json_failed",http_status:(if $code == "000" then null else ($code|tonumber) end)}')"
    fi
    rm -f "$version_body"
  fi
  active="$(jq -r '.version // empty' <<<"$version_resolution")"
  service="$(normalize_services_for_vcl_size_json "$(jq -c '{data:[.]}' "$detail")" |
    jq -c --arg active "$active" '.[0] | .active_version = (if ($active | test("^[1-9][0-9]*$")) then ($active|tonumber) else null end)')" || return 1
  rm -f "$detail"
  selected="$active"
  [[ "$version_source" == active ]] || selected="$version"

  endpoint=''
  if [[ "$(jq -r .type <<<"$service")" == vcl ]]; then
    if [[ -z "$selected" || ! "$selected" =~ ^[1-9][0-9]*$ ]]; then
      vcl_status=UNAVAILABLE
      vcl_reason='active service version could not be established'
      ui_phase 2 3 'Skipping generated VCL: active service version is unresolved'
    else
      endpoint="/service/$sid/version/$selected/generated_vcl"
      ui_phase 2 3 'Retrieving the selected generated VCL'
      body="$(mktemp)"; content="$(mktemp)"
      chmod 600 "$body" "$content" 2>/dev/null || true
      code="$(NGWAF_HTTP_REDACT_CURL_STDERR=1 http_get_to_file "$endpoint" "$body")"
      retrieved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if [[ "$code" == 2* ]] && jq -e --arg sid "$sid" --argjson version "$selected" '
        type == "object" and (.content | type) == "string" and (.content | length) > 0 and
        (if has("service_id") then .service_id == $sid else true end) and
        (if has("version") then .version == $version else true end)
      ' "$body" >/dev/null 2>&1 &&
         jq -j '.content' "$body" >"$content"; then
        if parsed="$(perl "$NGWAF_ROOT/lib/ngwaf_architecture_vcl.pl" "$content" "$context_lines")"; then
          vcl_status=COMPLETE
          vcl_reason='generated VCL content retrieved and inspected'
        else
          vcl_status=FAILED
          vcl_reason='generated VCL could not be parsed'
        fi
      elif [[ "$code" == 2* ]]; then
        vcl_status=FAILED
        vcl_reason='generated VCL response lacked a valid content string'
      else
        vcl_status=FAILED
        vcl_reason="generated VCL request failed (HTTP $code)"
      fi
      if [[ "$code" == 000 ]]; then vcl_http=null; else vcl_http="$code"; fi
      rm -f "$body" "$content"
    fi
  else
    vcl_status=NOT_APPLICABLE
    vcl_reason='Compute services do not have CDN generated VCL'
    ui_phase 2 3 'Skipping generated VCL: service is Compute'
  fi

  ui_phase 3 3 'Checking per-service Edge WAF enablement'
  product_body="$(mktemp)"
  product_code="$(NGWAF_HTTP_REDACT_CURL_STDERR=1 http_get_to_file "/enabled-products/v1/ngwaf/services/$(urlencode "$sid")" "$product_body")"
  if [[ "$product_code" == 2* ]] && jq -e --arg sid "$sid" --arg cid "$cid" '
    type == "object" and
    (if has("service_id") then .service_id == $sid else true end) and
    (if (.service | type) == "object" and (.service | has("id")) then .service.id == $sid else true end) and
    (if has("customer_id") then .customer_id == $cid else true end) and
    (if (.customer | type) == "object" and (.customer | has("id")) then .customer.id == $cid else true end) and
    (if has("enabled") then .enabled == true else true end)
  ' "$product_body" >/dev/null 2>&1; then
    product_status=CONFIRMED
    product_reason='per-service NGWAF enablement returned HTTP 200 with no conflicting identity'
  else
    product_reason='per-service NGWAF enablement was absent, unavailable, malformed, or conflicted with selected identity'
  fi
  rm -f "$product_body"

  [[ -n "$retrieved_at" ]] || retrieved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$product_status" == CONFIRMED && -n "$active" && "$selected" == "$active" ]]; then
    deployment=CONFIRMED
    if [[ "$(jq -r .type <<<"$service")" == wasm ]]; then
      architecture=out_of_band
    elif [[ "$vcl_status" == COMPLETE ]]; then
      case "$(jq -r '.status' <<<"$parsed")" in
        ABSENT) architecture=in_band ;;
        PRESENT)
          if [[ "$(jq -r '.matches[0].value' <<<"$parsed")" == true ]]; then
            architecture=out_of_band
          else
            architecture=in_band
          fi ;;
      esac
    fi
  fi
  report="$(printf '%s\n%s\n%s\n' "$service" "$parsed" "$version_resolution" | jq -s \
    --arg command 'service ngwaf-architecture' --arg selected "$selected" --arg active "$active" \
    --arg version_source "$version_source" --arg endpoint "$endpoint" --arg retrieved_at "$retrieved_at" \
    --arg product_status "$product_status" --arg product_reason "$product_reason" --arg product_code "$product_code" \
    --arg vcl_status "$vcl_status" --arg vcl_reason "$vcl_reason" --arg vcl_http "$vcl_http" \
    --arg deployment "$deployment" --arg architecture "$architecture" '
      .[0] as $service | .[1] as $parsed | .[2] as $version_resolution
      | {command:$command,service:{id:$service.id,name:$service.name,type:$service.type,
           inspected_version:(if $selected == "" then null else ($selected|tonumber) end),
           active_version:(if $active == "" then null else ($active|tonumber) end),
           inspected_version_is_active:($active != "" and $selected == $active),version_source:$version_source,
           active_version_resolution:$version_resolution},
         ngwaf_architecture:{deployment_type:(if $deployment == "CONFIRMED" then "edge" else null end),deployment_status:$deployment,
           inspection_architecture:$architecture,
           parameter:{name:"ngwaf_oob_enabled",status:(if $vcl_status == "COMPLETE" then $parsed.status else "UNKNOWN" end),
             value:(if $vcl_status == "COMPLETE" and $parsed.status == "PRESENT" then $parsed.matches[0].value else null end),
             declarations:(if $vcl_status == "COMPLETE" then $parsed.matches else [] end)},
           evidence:{source:"generated_vcl",endpoint:(if $endpoint == "" then null else $endpoint end),
             retrieval_status:$vcl_status,reason:$vcl_reason,http_status:(if $vcl_http == "null" then null else ($vcl_http|tonumber) end),
             line_count:(if $vcl_status == "COMPLETE" then $parsed.line_count else null end),retrieved_at:$retrieved_at},
           deployment_evidence:{source:"GET /enabled-products/v1/ngwaf/services/{service_id}",
             status:$product_status,reason:$product_reason,
             http_status:(if $product_code == "000" then null else ($product_code|tonumber) end)}},
         limitations:["Per-service enablement verifies product attachment, not traffic or enforcement.",
           "Historical version architecture is not proof of historical Edge WAF deployment.",
           "Legacy Signal Sciences-managed attachments may not be visible through per-service product enablement."]}'
  )" || return 1
  if [[ "$json" == true ]]; then
    jq . <<<"$report"
  else
    jq -r '
      "Edge WAF Architecture Inspection", "Service: \(.service.name)", "Service ID: \(.service.id)",
      "Service Type: \(.service.type)", "Inspected Version: \(.service.inspected_version // "UNKNOWN")",
      "Active Version: \(.service.active_version // "UNKNOWN")", "Version Source: \(.service.version_source)",
      "Edge WAF Deployment: \(.ngwaf_architecture.deployment_status)",
      "Inspection Architecture: \(.ngwaf_architecture.inspection_architecture | ascii_upcase)",
      "Parameter Status: \(.ngwaf_architecture.parameter.status)",
      "Parameter Value: \(if .ngwaf_architecture.parameter.value == null then "UNKNOWN" else (.ngwaf_architecture.parameter.value | tostring) end)",
      "VCL Retrieval: \(.ngwaf_architecture.evidence.retrieval_status)",
      "Evidence Source: \(.ngwaf_architecture.evidence.endpoint // "not available")",
      (.ngwaf_architecture.parameter.declarations[]? | . as $declaration
        | "Actual Generated VCL (lines \(.line_start)-\(.line_end)): \(.raw_text)",
          (.context[] | select(.line_number < $declaration.line_start or .line_number > $declaration.line_end)
            | "  Line \(.line_number): \(.text)")),
      (if .ngwaf_architecture.parameter.status == "ABSENT" then
        "Complete VCL inspected: \(.ngwaf_architecture.evidence.line_count) lines; no matching declaration."
       else empty end),
      "Retrieved At: \(.ngwaf_architecture.evidence.retrieved_at)"' <<<"$report"
  fi
  if [[ -z "$active" ]] ||
     { [[ "$(jq -r '.type' <<<"$service")" == vcl ]] && [[ "$vcl_status" != COMPLETE ]]; }; then
    return 1
  fi
}
