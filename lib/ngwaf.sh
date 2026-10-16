# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

workspace_services_payload_json() {
  local in_band_evidence="$1" product="$2" workspaces="$3" selected_id="$4"
  printf '%s\n%s\n%s\n' "$in_band_evidence" "$product" "$workspaces" |
    jq -s --arg selected_id "$selected_id" '
    .[0] as $in_band_evidence | .[1] as $product | .[2] as $workspaces
    | if ($workspaces.data | type) != "array" or ($in_band_evidence.mappings | type) != "array" or ($product.services | type) != "array" then
      error("mapping source has a missing or malformed collection") else . end
    | ($in_band_evidence.mappings | map(select(.status == "CONFIRMED") | . as $row
      | ($workspaces.data | map(select(.id == $row.workspace_id))) as $by_id
      | (if ($by_id | length) == 1 then $by_id
         else ($workspaces.data | map(select(.name == $row.workspace_name))) end) as $matches
      | {
      workspace_id: (if ($matches | length) == 1 then $matches[0].id else $row.workspace_id end),
      workspace: .workspace_name, service_id: .source_service_id,
      name: .source_service_name, type: "CDN", active_version: .active_version,
      mapping_source: "in_band_vcl_evidence",
      mapping_evidence: {inspection_service_id, generated_vcl_version: .active_version,
        internal_site_id: .workspace_id,
        workspace_resolution: (if ($by_id | length) == 1 then "exact_id"
          elif ($matches | length) == 1 then "unique_exact_workspace_name" else "UNRESOLVED" end)}
    })) as $old
    | ($product.services | map(select(.type == "vcl" and
        .configuration_status == "RETRIEVED" and
        ((.configuration.workspace_id // "") | length > 0)) | {
      workspace_id: .configuration.workspace_id, service_id: .id,
      name, type: "CDN", active_version,
      mapping_source: "enabled_product_api",
      mapping_evidence: {configuration_endpoint: .configuration_source}
    })) as $new
    | ($in_band_evidence.mappings | map(select(.status == "UNKNOWN" or .status == "UNRESOLVED" or .status == "AMBIGUOUS"))) as $unresolved
    | ($product.services | map(select(.type == "vcl" and
        (.configuration_status != "RETRIEVED" or
         ((.configuration.workspace_id // "") | length == 0))))) as $unconfigured
    | ($workspaces.data | map(.id)) as $ids
    | ([$old[], $new[]] | map(select(.workspace_id as $id | $ids | index($id) != null))
       | sort_by(.workspace_id, .service_id) | group_by([.workspace_id, .service_id])
       | map(.[0] + {mapping_sources: (map(.mapping_source) | unique),
           mapping_evidence: (map({source: .mapping_source, evidence: .mapping_evidence}) | unique)})) as $relationships
    | (if (($in_band_evidence.summary.sites_inventory_status != "COMPLETE") and
          ($in_band_evidence.summary.sites_inventory_status != "NOT_REQUIRED")) or
          $product.status == "UNKNOWN" or $product.status == "FAILED" then "UNKNOWN"
       elif ($unresolved | length) > 0 or ($unconfigured | length) > 0 or $product.status != "COMPLETE" or
         (($product.result.rejected_service_ids // []) | length) > 0 or
         ([$old[], $new[]] | any(.workspace_id as $id | $ids | index($id) == null)) then "PARTIAL"
       else "COMPLETE" end) as $status
    | {
      command: "ngwaf workspace-services", customer: $in_band_evidence.customer.name,
      customer_id: $in_band_evidence.customer.id, status: $status,
      retrieved_at: (now | todateiso8601),
      coverage_scope: "observed deployed configuration of token-visible CDN services; not an authoritative linkage inventory",
      provenance: {in_band_vcl_evidence: $in_band_evidence.sources,
        enabled_product_api: $product.result,
        workspace_endpoint: "GET /ngwaf/v1/workspaces"},
      unresolved_services: $unresolved, unresolved_product_configurations: $unconfigured,
      unmatched_workspace_relationships: ([$old[], $new[]] | map(select(.workspace_id as $id | $ids | index($id) == null))),
      summary: {
        in_band_vcl_evidence_relationships: ($old | unique_by([.workspace_id, .service_id]) | length),
        enabled_product_relationships: ($new | unique_by([.workspace_id, .service_id]) | length),
        workspaces_with_no_observed_mapping: ([$workspaces.data[] | select(.id as $id | [$relationships[].workspace_id] | index($id) == null)] | length)
      },
      workspaces: [$workspaces.data[] | select($selected_id == "" or .id == $selected_id)
        | . as $w | {workspace: .name, workspace_id: .id,
          services: [$relationships[] | select(.workspace_id == $w.id) | del(.workspace_id, .workspace)],
          service_count: ([$relationships[] | select(.workspace_id == $w.id)] | length)}]
    }
    | if $selected_id != "" then
        if (.workspaces | length) == 1 then . + .workspaces[0]
        else error("resolved workspace is absent from workspace inventory") end
      else . end
  '
}

workspace_services_with_domains_json() {
  local payload="$1" pairs pair result tmp results
  pairs="$(jq -c '[.workspaces[].services[] | {service_id, version: (.active_version // "" | tostring)}] | unique_by([.service_id, .version]) | .[]' <<<"$payload")" || return 1
  tmp="$(mktemp)"
  while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    if ! result="$(service_domains_json "$(jq -r .service_id <<<"$pair")" "$(jq -r .version <<<"$pair")")"; then
      rm -f "$tmp"
      return 1
    fi
    printf '%s\n' "$result" >>"$tmp"
  done <<<"$pairs"
  results="$(jq -s . "$tmp")" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s\n%s\n' "$payload" "$results" | jq -s '
    .[1] as $results | .[0]
    | .mapping_status = .status
    | .domain_inventory_status = (
        if all($results[]; .status == "COMPLETE") then "COMPLETE"
        elif any($results[]; .status == "COMPLETE") then "PARTIAL"
        else "UNKNOWN" end)
    | .domain_queries = ([$results[] | select(.endpoint != null)] | length)
    | .workspaces |= map(.services |= map(. as $s
        | ($results | map(select(.service_id == $s.service_id and
            (.version | tostring) == ($s.active_version | tostring))) | .[0]
           // {status: "UNKNOWN", domains: null, domain_count: null, reason: "domain lookup result unavailable"}) as $d
        | . + {domains: (if $d.status == "COMPLETE" then [$d.domains[].name] else null end),
            domain_count: $d.domain_count, domain_inventory: $d}))
    | if .workspace_id != null then .services = .workspaces[0].services else . end
    | if .status == "COMPLETE" and .domain_inventory_status != "COMPLETE" then .status = "PARTIAL" else . end
  '
}

# The service-scoped path uses the existing per-service enablement API. It never
# lists product attachments for the customer or probes unrelated CDN services.
workspace_services_product_for_service_json() {
  local service="$1" cid="$2" sid path body code status=UNKNOWN reason=''
  local configuration='null' configuration_status=NOT_REQUESTED configuration_source=''
  local config_file config_code
  sid="$(jq -r .id <<<"$service")"
  path="/enabled-products/v1/ngwaf/services/$(urlencode "$sid")"
  body="$(mktemp)"
  code="$(http_get_to_file "$path" "$body")"
  case "$code" in
    2*)
      if [[ ! -s "$body" ]] || jq -e --arg sid "$sid" --arg cid "$cid" '
        type == "object" and
        (if (.service | type) == "object" and (.service | has("id")) then .service.id == $sid else true end) and
        (if has("service_id") then .service_id == $sid else true end) and
        (if has("customer_id") then .customer_id == $cid else true end) and
        (if (.customer | type) == "object" and (.customer | has("id")) then .customer.id == $cid else true end)
      ' "$body" >/dev/null 2>&1; then
        status=COMPLETE
        reason='per-service NGWAF enablement returned'
        configuration_source="$path/configuration"
        config_file="$(mktemp)"
        config_code="$(http_get_to_file "$configuration_source" "$config_file")"
        if [[ "$config_code" == 2* ]] && jq -e --arg sid "$sid" --arg cid "$cid" '
          type == "object" and (.configuration | type) == "object" and
          (if .configuration | has("workspace_id") then
            (.configuration.workspace_id == null or (.configuration.workspace_id | type) == "string")
           else true end) and
          (if has("service_id") then .service_id == $sid else true end) and
          (if has("customer_id") then .customer_id == $cid else true end) and
          (if (.service | type) == "object" and (.service | has("id")) then .service.id == $sid else true end) and
          (if (.customer | type) == "object" and (.customer | has("id")) then .customer.id == $cid else true end)
        ' "$config_file" >/dev/null 2>&1; then
          configuration="$(jq -c .configuration "$config_file")"
          configuration_status=RETRIEVED
        else
          configuration_status=UNAVAILABLE
          reason="NGWAF configuration unavailable or invalid (HTTP $config_code)"
        fi
        rm -f "$config_file"
      else
        reason='per-service NGWAF enablement response was malformed or conflicted with selected service/customer'
      fi
      ;;
    404) status=COMPLETE; reason='no enabled-product relationship reported for this service' ;;
    *) reason="per-service NGWAF enablement unavailable (HTTP $code)" ;;
  esac
  rm -f "$body"
  printf '%s\n%s\n' "$service" "$configuration" |
    jq -s --arg status "$status" --arg reason "$reason" --arg code "$code" \
    --arg source "GET /enabled-products/v1/ngwaf/services/{service_id}" \
    --arg configuration_source "$configuration_source" \
    --arg configuration_status "$configuration_status" '
      .[0] as $service | .[1] as $configuration
      | {status:$status,
       result:{status:$status,source:$source,reason:$reason,http_status:($code // null),
         fallback_used:false,configuration:{status:$configuration_status,
           source:(if $configuration_source == "" then null else "GET /enabled-products/v1/ngwaf/services/{service_id}/configuration" end)}},
       services:(if ($code | startswith("2")) and $status == "COMPLETE" then
         [$service + {configuration:$configuration,configuration_status:$configuration_status,
           configuration_source:(if $configuration_source == "" then null else "GET /enabled-products/v1/ngwaf/services/{service_id}/configuration" end)}]
         else [] end)}'
}

workspace_services_scoped_payload_json() {
  local payload="$1" service="$2" legacy="$3" workspaces_requested="$4"
  printf '%s\n%s\n%s\n' "$payload" "$service" "$legacy" |
    jq -s --argjson workspaces_requested "$workspaces_requested" '
      .[0] as $mapping | .[1] as $service | .[2] as $legacy
      | $mapping
      | ([.workspaces[] | select(any(.services[]; .mapping_sources | index("in_band_vcl_evidence") != null)) | .workspace_id] | unique) as $in_band_ids
      | ([.workspaces[] | select(any(.services[]; .mapping_sources | index("enabled_product_api") != null)) | .workspace_id] | unique) as $product_ids
      | .mapping_conflicts = (if ($in_band_ids | length) > 0 and ($product_ids | length) > 0 and
            (($product_ids - $in_band_ids) | length) > 0 then
          [{type:"source_workspace_disagreement",in_band_workspace_ids:$in_band_ids,
            enabled_product_workspace_ids:$product_ids}] else [] end)
      | if (.mapping_conflicts | length) > 0 and .status == "COMPLETE" then .status = "PARTIAL" else . end
      | .scope = "service_id"
      | .selected_service = {id:$service.id,name:$service.name,customer_id:$service.customer_id,
          active_version:$service.active_version}
      | .legacy_service_evidence = $legacy.mappings
      | .workspaces |= map(select(.service_count > 0))
      | .summary |= del(.workspaces_with_no_observed_mapping)
      | .summary.scanned_cdn_services = 1
      | .relationship_status = (if (.mapping_conflicts | length) > 0 then "CONFLICTING"
          elif (.workspaces | length) > 0 then "MAPPED"
          elif (.unresolved_services | length) > 0 or (.unmatched_workspace_relationships | length) > 0 or
               (.unresolved_product_configurations | length) > 0 or .status != "COMPLETE" then "UNRESOLVED"
          else "NO_OBSERVED_MAPPING" end)
      | .coverage_scope = "one verified CDN service; shared site and workspace inventories used only for exact reconciliation"
      | .provenance.service_detail = {source:"GET /service/{service_id}",ownership_validation:"exact service ID and customer ID"}
      | .provenance.workspace_inventory = {source:"GET /ngwaf/v1/workspaces",requested:$workspaces_requested}
      | .limitations = [
          "A missing observed mapping does not prove NGWAF is disabled or unattached.",
          "This maps CDN services to workspaces; it does not classify deployment architecture or establish WAFD migration eligibility.",
          "In-band evidence depends on generated VCL, internal NGWAF site inventory, and direct Inspection Service lookups."
        ]'
}

cmd_workspace_services_service_id() {
  local sid="$1" corp="$2" json="$3" with_domains="$4" cid customer corp_source=cli
  local service_file code service inventory normalized vcl sites inspection_services='[]'
  local rows legacy product workspaces payload workspaces_requested
  internal_ngwaf_require_credentials 'in-band workspace-service mapping' || return 1
  if [[ -z "$corp" ]]; then
    corp="${SIGSCI_CORP:-}"
    corp_source='env'
  fi
  [[ -n "$corp" ]] || die 'SIGSCI_CORP is required for internal NGWAF site inventory; use --sigsci-corp <corp> for this run'
  cid="$(current_cid)"
  load_customer_context || return 1
  customer="$(jq -c '{id,name}' <<<"$NGWAF_CUSTOMER_CONTEXT_JSON")"

  service_file="$(mktemp)"
  code="$(http_get_to_file "/service/$(urlencode "$sid")" "$service_file")"
  if [[ "$code" != 2* ]] || ! jq -e --arg sid "$sid" --arg cid "$cid" '
    type == "object" and .id == $sid and .customer_id == $cid and .type == "vcl" and
    (.name | type == "string" and length > 0)
  ' "$service_file" >/dev/null 2>&1; then
    rm -f "$service_file"
    die "workspace-services: service ownership, identity, or CDN type could not be verified (HTTP $code)"
  fi
  service="$(jq -c . "$service_file")"
  rm -f "$service_file"
  inventory="$(jq -nc --argjson service "$service" '{meta:{source:"GET /service/{service_id}",status:"COMPLETE",count:1},data:[$service]}')"
  normalized="$(normalize_services_for_vcl_size_json "$inventory" | jq -c '.[0]')" || return 1
  vcl="$(legacy_map_extract_ess_host_json "$normalized")" || return 1

  if [[ "$(jq -r .status <<<"$vcl")" == COMPLETE ]]; then
    sites="$(legacy_map_fetch_sites_json "$corp")" || return 1
    sites="$(legacy_map_validate_sites_customer_json "$sites" "$cid" "$(jq -r .name <<<"$customer")" "$corp" "$corp_source")" || return 1
    if [[ "$(jq -r .status <<<"$sites")" == COMPLETE ]]; then
      jq -e --arg cid "$cid" '
        all(.data[]; (.customer_id // .customerID // .customerId // .customer.id // null) == $cid)
      ' >/dev/null <<<"$sites" || die 'workspace-services: one or more internal NGWAF site customer IDs are missing or conflict with the selected customer'
      inspection_services="$(legacy_map_resolve_inspection_services_json "$sites" "$inventory")" || return 1
      inspection_services="$(jq --arg cid "$cid" '
        map(if .status == "COMPLETE" and .service.customer_id != $cid then
          .status = "UNKNOWN" | .reason = "Inspection Service customer ownership could not be verified" | .service = null
        else . end)
      ' <<<"$inspection_services")" || return 1
    fi
  else
    sites="$(jq -nc --arg corp "$corp" --arg cid "$cid" '
      {status:"NOT_REQUIRED",evidence_type:"INFORMATIONAL",
       source:"GET internal-ngwaf/v0/corps/{corp}/sites",reason:"no usable generated-VCL Inspection Service hostname to resolve",
       sigsci_corp:$corp,selected_customer_id:$cid,data:[]}')"
  fi
  rows="$(legacy_map_rows_for_service_json "$normalized" "$vcl" "$sites" "$inspection_services")" || return 1
  legacy="$(legacy_map_payload_json "$customer" "$inventory" "$sites" "$rows" "$sid")" || return 1
  product="$(workspace_services_product_for_service_json "$normalized" "$cid")" || return 1

  if jq -e --argjson product "$product" '
    any(.mappings[]; .status == "CONFIRMED") or
    any($product.services[]; (.configuration.workspace_id // "") != "")
  ' >/dev/null <<<"$legacy"; then
    workspaces="$(get_all_pages /ngwaf/v1/workspaces --data-urlencode "customer_id=$cid")" ||
      die 'workspace-services: workspace inventory unavailable; cannot verify the selected service mapping'
    jq -e --arg cid "$cid" '
      type == "object" and (.data | type) == "array" and
      all(.data[]; type == "object" and (.id | type == "string" and length > 0) and
        (.name | type == "string" and length > 0) and
        (if has("customer_id") then .customer_id == $cid else true end) and
        (if (.customer | type) == "object" and (.customer | has("id")) then .customer.id == $cid else true end)) and
      ([.data[].id] | length == (unique | length))
    ' >/dev/null <<<"$workspaces" || die 'workspace-services: workspace inventory identity or ownership is unverified'
    workspaces_requested=true
  else
    workspaces='{"meta":{"total":0,"pages_fetched":0},"data":[]}'
    workspaces_requested=false
  fi
  payload="$(workspace_services_payload_json "$legacy" "$product" "$workspaces" '')" || return 1
  payload="$(workspace_services_scoped_payload_json "$payload" "$normalized" "$legacy" "$workspaces_requested")" || return 1
  if [[ "$with_domains" == true ]]; then
    payload="$(workspace_services_with_domains_json "$payload")" || return 1
  fi
  if [[ "$json" == true ]]; then
    jq . <<<"$payload"
  else
    jq -r '
      "CDN service: \(.selected_service.name) (\(.selected_service.id))",
      "Active version: \(.selected_service.active_version // "UNKNOWN")",
      "Mapping status: \(.status); relationship: \(.relationship_status)",
      (.workspaces[] | "Workspace: \(.workspace) (\(.workspace_id)); sources: \([.services[].mapping_sources[]] | unique | join(", "))"),
      (if .provenance.in_band_vcl_evidence.internal_ngwaf_sites.status == "UNKNOWN" then
        "Internal NGWAF site inventory: \(.provenance.in_band_vcl_evidence.internal_ngwaf_sites.reason // "unavailable")" else empty end),
      (if .provenance.enabled_product_api.status != "COMPLETE" then
        "Enabled-product check: \(.provenance.enabled_product_api.reason // "unavailable")" else empty end),
      (.unresolved_services[] | "Unresolved in-band evidence: \(.status): \(.reason // "unknown")"),
      (.unresolved_product_configurations[] | "Enabled-product configuration unresolved for service \(.id): \(.configuration_status)"),
      (.unmatched_workspace_relationships[] | "Unmatched workspace relationship: \(.workspace_id)"),
      (.mapping_conflicts[] | "Conflicting mapping sources: in-band=\(.in_band_workspace_ids | join(",")); enabled-product=\(.enabled_product_workspace_ids | join(","))"),
      (if .relationship_status == "NO_OBSERVED_MAPPING" then "NO OBSERVED WORKSPACE MAPPING" else empty end)
    ' <<<"$payload"
  fi
  [[ "$(jq -r .status <<<"$payload")" == COMPLETE ]]
}

cmd_workspace_services() {
  local selector='' service_id='' all=false json=false corp='' cid resolved selected_id=''
  local workspaces in_band_evidence inventory product payload with_domains=false
  local -a in_band_args=(--json)
  while (( $# > 0 )); do
    case "$1" in
      --all) all=true; shift ;;
      --json) json=true; shift ;;
      --with-domains) with_domains=true; shift ;;
      --service-id)
        (( $# >= 2 )) || die '--service-id requires an exact CDN service ID'
        [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$ ]] || die '--service-id requires an exact CDN service ID'
        [[ -z "$service_id" ]] || die 'specify --service-id only once'
        service_id="$2"; shift 2 ;;
      --sigsci-corp)
        (( $# >= 2 )) || die '--sigsci-corp requires a corp slug'
        corp="$2"; in_band_args+=(--sigsci-corp "$corp"); shift 2 ;;
      --*) die "unknown workspace-services option: $1" ;;
      *) [[ -z "$selector" ]] || die 'specify one workspace or --all'; selector="$1"; shift ;;
    esac
  done
  if [[ -n "$service_id" ]]; then
    [[ "$all" == false && -z "$selector" ]] || die 'specify --service-id, one workspace, or --all'
    cmd_workspace_services_service_id "$service_id" "$corp" "$json" "$with_domains"
    return
  fi
  if [[ "$all" == true ]]; then
    [[ -z "$selector" ]] || die 'specify one workspace or --all'
  else
    [[ -n "$selector" ]] || die 'usage: fastly-audit ngwaf workspace-services <workspace>|--all [--json] [--sigsci-corp CORP] [--with-domains]'
  fi
  internal_ngwaf_require_credentials 'in-band workspace-service mapping' || return 1
  if [[ "$all" != true ]]; then
    resolved="$(resolve_workspace_json "$selector")" || return 1
    selected_id="$(jq -er '.id' <<<"$resolved")" || return 1
  fi
  cid="$(current_cid)"
  workspaces="$(get_all_pages /ngwaf/v1/workspaces --data-urlencode "customer_id=$cid")" || return 1
  in_band_evidence="$(cmd_security_legacy_map "${in_band_args[@]}")" || return 1
  inventory="$(get_customer_services --details)" || return 1
  product="$(discover_product_json ngwaf 'Edge WAF service attachments' ngwaf security "$inventory" true)" || return 1
  payload="$(workspace_services_payload_json "$in_band_evidence" "$product" "$workspaces" "$selected_id")" || return 1
  if [[ "$with_domains" == true ]]; then
    payload="$(workspace_services_with_domains_json "$payload")" || return 1
  fi
  if [[ "$json" == true ]]; then
    jq . <<<"$payload"
  else
    jq -r '"Mapping status: " + (.mapping_status // .status),
      (if .domain_inventory_status != null then "Domain inventory status: " + .domain_inventory_status,
        "Overall inventory status: " + .status else empty end),
      (.workspaces[] | "Workspace: " + .workspace,
        (if .service_count == 0 then "NO OBSERVED CDN SERVICE MAPPING" else empty end))' <<<"$payload"
    jq -r --arg with_domains "$with_domains" '
      (["WORKSPACE", "CDN SERVICE", "SERVICE ID", "VERSION", "SOURCE"] +
        (if $with_domains == "true" then ["CONFIGURED FASTLY DOMAINS"] else [] end)),
      (.workspaces[] as $w | $w.services[] | [$w.workspace, .name, .service_id,
        (.active_version // "UNKNOWN" | tostring), (.mapping_sources | map(if . == "in_band_vcl_evidence" then "in-band VCL evidence" elif . == "enabled_product_api" then "enabled-product API" else . end) | join(", "))] +
        (if $with_domains != "true" then []
         elif .domain_inventory.status != "COMPLETE" then ["UNKNOWN: " + .domain_inventory.reason]
         elif .domain_count == 0 then ["NO CONFIGURED FASTLY DOMAINS OBSERVED"]
         else [(.domains | join(", "))] end)) | @tsv' <<<"$payload" | human_table
    jq -r '"Total mapped services: " + ([.workspaces[].service_count] | add // 0 | tostring),
      "Mapping coverage (all token-visible CDN services):",
      "  in-band VCL evidence relationships: " + (.summary.in_band_vcl_evidence_relationships | tostring),
      "  enabled-product relationships: " + (.summary.enabled_product_relationships | tostring),
      "  workspaces with no observed mapping: " + (.summary.workspaces_with_no_observed_mapping | tostring),
      (.unresolved_services[] | "Unresolved service: " + .source_service_id + ": " + (.reason // .status)),
      (.unresolved_product_configurations[] | "Unresolved product configuration: " + .id),
      (.provenance.enabled_product_api.rejected_service_ids[]? | "Unvalidated product service ID: " + .),
      (if .provenance.enabled_product_api.status != "COMPLETE" then
        "Enabled-product inventory: " + (.provenance.enabled_product_api.reason // "unavailable") else empty end),
      (if .provenance.in_band_vcl_evidence.internal_ngwaf_sites.status != "COMPLETE" then
        "In-band evidence site inventory: " + (.provenance.in_band_vcl_evidence.internal_ngwaf_sites.reason // "unavailable") else empty end),
      "Coverage describes observed configuration evidence, not an authoritative linkage inventory."' <<<"$payload"
  fi
  if [[ "$with_domains" == true && "$json" != true ]]; then
    printf '\nConfigured Fastly domains do not prove identical NGWAF behavior for every hostname/path.\n'
  fi
  [[ "$(jq -r .status <<<"$payload")" == COMPLETE ]]
}

cmd_workspaces() {
  local cid body total returned
  cid="$(current_cid)"

  body="$(
    get_all_pages "/ngwaf/v1/workspaces" \
      --data-urlencode "customer_id=$cid"
  )"

  total="$(jq -r '.meta.total // (.data | length)' <<<"$body")"
  returned="$(jq -r '.data | length' <<<"$body")"

  printf 'Total NGWAF workspaces: %s\n\n' "$total"

  jq -r '
    ["NAME", "ID"],
    (.data | sort_by(.name) | .[] | [.name, .id])
    | @tsv
  ' <<<"$body" | human_table

  printf '\nSource: GET /ngwaf/v1/workspaces (selected customer; complete pagination or failure)\n'

  if (( total > returned )); then
    printf '\nWARNING: API returned %s of %s workspaces.\n' \
      "$returned" "$total" >&2
  fi
}

cmd_workspace() {
  [[ $# -eq 1 ]] || die 'usage: ngwaf workspace <workspace>'

  local cid input resolved w ws_id body
  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"

  body="$(get "$(workspace_path "$ws_id")" --data-urlencode "customer_id=$cid")"
  jq --arg input "$input" --arg workspace "$w" --arg workspace_id "$ws_id" '{
      workspace: $workspace,
      workspace_id: $workspace_id,
      workspace_input: $input,
      mode,
      immediate_blocking: (.attack_signal_thresholds.immediate // null),
      default_blocking_response_code,
      provenance: {
        endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}",
        data_class: "configuration_snapshot",
        customer_scoped: true
      }
    }' <<<"$body"
}

get_workspace_rule_json() {
  [[ $# -eq 4 ]] ||
    die 'get_workspace_rule_json requires <customer-id> <workspace-id> <workspace-name> <rule-id>'

  local cid="$1"
  local ws_id="$2"
  local workspace="$3"
  local rule_id="$4"
  local encoded_rule_id body actual_rule_id
  local NGWAF_PROGRESS_LABEL

  [[ -n "$rule_id" ]] || die 'rule ID must not be empty'

  encoded_rule_id="$(urlencode "$rule_id")"
  # Dynamically scoped and consumed by get() in lib/core.sh.
  # shellcheck disable=SC2034
  NGWAF_PROGRESS_LABEL="retrieving rule $rule_id from $workspace"

  body="$(
    get "$(workspace_path "$ws_id")/rules/$encoded_rule_id" \
      --data-urlencode "customer_id=$cid"
  )"

  actual_rule_id="$(jq -r '.id // empty' <<<"$body")"
  [[ -n "$actual_rule_id" ]] ||
    die "rule response did not contain an ID: $rule_id"
  [[ "$actual_rule_id" == "$rule_id" ]] ||
    die "rule response ID did not match requested rule: expected $rule_id, received $actual_rule_id"

  printf '%s\n' "$body"
}

cmd_rule() {
  [[ $# -eq 2 ]] || die 'usage: ngwaf rule <workspace> <rule_id>'

  local cid input rule_id resolved w ws_id body
  cid="$(current_cid)"
  input="$1"
  rule_id="$2"

  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
  body="$(get_workspace_rule_json "$cid" "$ws_id" "$w" "$rule_id")"

  jq \
    --arg workspace "$w" \
    --arg workspace_id "$ws_id" \
    --arg workspace_input "$input" \
    --arg rule_id "$rule_id" \
    '. + {
      context: {
        workspace: $workspace,
        workspace_id: $workspace_id,
        workspace_input: $workspace_input,
        rule_id: $rule_id
      },
      provenance: {
        endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/rules/{rule_id}",
        data_class: "configuration_snapshot",
        customer_scoped: true,
        pagination: "not_applicable"
      }
    }' <<<"$body"
}

cmd_rules() {
  [[ $# -ge 1 ]] || die 'usage: ngwaf rules <workspace> [--list|--json]'

  local cid input resolved w ws_id mode body summary
  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
  mode="${2:-}"

  body="$(
    get_all_pages "$(workspace_path "$ws_id")/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  if [[ "$mode" == "--json" ]]; then
    jq \
      --arg workspace "$w" \
      --arg workspace_id "$ws_id" \
      --arg workspace_input "$input" \
      '. + {
        context: {
          workspace: $workspace,
          workspace_id: $workspace_id,
          workspace_input: $workspace_input
        },
        provenance: {
          endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/rules",
          data_class: "configuration_snapshot",
          pagination: "complete_or_fail"
        }
      }' <<<"$body"
    return
  fi

  summary="$(summarize_rules_json <<<"$body")"

  jq --arg w "$w" --arg wsid "$ws_id" --arg input "$input" \
    '. + {workspace: $w, workspace_id: $wsid, workspace_input: $input}' <<<"$summary" |
    jq '{
      workspace,
      workspace_id,
      workspace_input,
      total_rules: .total,
      enabled_rules: .enabled,
      disabled_rules: .disabled,
      enabled_allow_rules,
      enabled_block_rules,
      enabled_browser_challenge_rules,
      enabled_rate_limit_rules,
      enabled_signal_exclusion_rules,
      rule_types,
      enabled_actions,
      pages_fetched
    }'

  if [[ "$mode" == "--list" ]]; then
    printf '\n'
    jq -r '
      ["TYPE", "ENABLED", "ACTIONS", "DESCRIPTION"],
      (
        .data[]
        | [
            (.type // "unknown"),
            (.enabled | tostring),
            ([.actions[]?.type] | join(",")),
            (.description // "")
          ]
      )
      | @tsv
    ' <<<"$body" | human_table
  fi
}

cmd_account_rules() {
  [[ $# -le 1 ]] || die 'usage: ngwaf account-rules [--list|--json]'

  local cid mode body summary
  cid="$(current_cid)"
  mode="${1:-}"

  [[ -z "$mode" || "$mode" == "--list" || "$mode" == "--json" ]] ||
    die 'usage: ngwaf account-rules [--list|--json]'

  body="$(
    get_all_pages "/ngwaf/v1/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  if [[ "$mode" == "--json" ]]; then
    jq --arg customer_id "$cid" '. + {
      context: {customer_id: $customer_id},
      provenance: {
        endpoint: "GET /ngwaf/v1/rules",
        data_class: "configuration_snapshot",
        pagination: "complete_or_fail"
      }
    }' <<<"$body"
    return
  fi

  summary="$(summarize_rules_json <<<"$body")"

  jq --arg cid "$cid" '
    . + {
      customer_id: $cid,
      global_rules: 0,
      workspace_scoped_rules: 0,
      provenance: {
        endpoint: "GET /ngwaf/v1/rules",
        data_class: "configuration_snapshot",
        pagination: "complete_or_fail"
      }
    }
  ' <<<"$summary" |
  jq --argjson globals "$(jq '[.data[] | select(((.scope.applies_to // []) | index("*")) != null)] | length' <<<"$body")" \
     --argjson scoped "$(jq '[.data[] | select(((.scope.applies_to // []) | index("*")) == null)] | length' <<<"$body")" \
    '.global_rules = $globals | .workspace_scoped_rules = $scoped'

  if [[ "$mode" == "--list" ]]; then
    printf '\n'
    jq -r '
      ["TYPE", "ENABLED", "APPLIES TO", "ACTIONS", "DESCRIPTION"],
      (
        .data[]
        | [
            (.type // "unknown"),
            (.enabled | tostring),
            ((.scope.applies_to // []) | join(",")),
            ([.actions[]?.type] | join(",")),
            (.description // "")
          ]
      )
      | @tsv
    ' <<<"$body" | human_table
  fi
}

cmd_thresholds() {
  [[ $# -ge 1 ]] || die 'usage: ngwaf thresholds <workspace> [--json]'

  local cid input resolved w ws_id mode body
  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
  mode="${2:-}"

  body="$(
    get "$(workspace_path "$ws_id")/thresholds" \
      --data-urlencode "customer_id=$cid"
  )"

  if [[ "$mode" == "--json" ]]; then
    jq --arg workspace "$w" --arg workspace_id "$ws_id" --arg workspace_input "$input" '
      . + {
        context: {
          workspace: $workspace,
          workspace_id: $workspace_id,
          workspace_input: $workspace_input
        },
        provenance: {
          endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/thresholds",
          data_class: "configuration_snapshot"
        }
      }
    ' <<<"$body"
    return
  fi

  jq --arg w "$w" --arg wsid "$ws_id" --arg input "$input" '{
    workspace: $w,
    workspace_id: $wsid,
    workspace_input: $input,
    total_thresholds: (.data | length),
    enabled_thresholds: ([.data[] | select(.enabled == true)] | length),
    disabled_thresholds: ([.data[] | select(.enabled == false)] | length)
  }' <<<"$body"
}

cmd_posture() {
  [[ $# -eq 1 ]] || die 'usage: ngwaf posture <workspace>'

  local cid input resolved w ws ws_id rules account_rules account_applying thresholds
  local workspace_lists account_lists
  local rules_summary account_summary workspace_lists_summary account_lists_summary
  local threshold_summary

  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"

  ws="$(
    get "$(workspace_path "$ws_id")" \
      --data-urlencode "customer_id=$cid"
  )"

  [[ "$(jq -r '.id // empty' <<<"$ws")" == "$ws_id" ]] ||
    die "workspace response ID did not match resolved workspace $ws_id"

  rules="$(
    get_all_pages "$(workspace_path "$ws_id")/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  # Account-level rules are a separate control layer. Filter their scope to
  # rules that are global (*) or explicitly include this workspace ID.
  account_rules="$(
    get_all_pages "/ngwaf/v1/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  account_applying="$(
    jq --arg wsid "$ws_id" '
      .data = [
        .data[]
        | select(
            ((.scope.applies_to // []) | index("*")) != null
            or ((.scope.applies_to // []) | index($wsid)) != null
          )
      ]
      | .meta.total = (.data | length)
    ' <<<"$account_rules"
  )"

  thresholds="$(
    get "$(workspace_path "$ws_id")/thresholds" \
      --data-urlencode "customer_id=$cid"
  )"

  # Lists are inventory context: rules may reference account- or workspace-level
  # lists. Presence of a list does not prove that any specific rule uses it.
  workspace_lists="$(
    get_all_pages "$(workspace_path "$ws_id")/lists" \
      --data-urlencode "customer_id=$cid"
  )"

  account_lists="$(
    get_all_pages "/ngwaf/v1/lists" \
      --data-urlencode "customer_id=$cid"
  )"

  rules_summary="$(summarize_rules_json <<<"$rules")"
  account_summary="$(summarize_rules_json <<<"$account_applying")"
  workspace_lists_summary="$(summarize_lists_json <<<"$workspace_lists")"
  account_lists_summary="$(summarize_lists_json <<<"$account_lists")"

  threshold_summary="$(
    jq '
      def counts($items):
        ($items | sort | group_by(.) | map({key: .[0], value: length}) | from_entries);
      {
        total: (.data | length),
        enabled: ([.data[] | select(.enabled == true)] | length),
        disabled: ([.data[] | select(.enabled == false)] | length),
        enabled_by_action: counts([.data[] | select(.enabled == true) | (.action // "unknown")]),
        enabled_block_immediately: ([.data[] | select(.enabled == true and .action == "block_immediately")] | length)
      }
    ' <<<"$thresholds"
  )"

  json_stream \
    "$ws" \
    "$rules_summary" \
    "$account_summary" \
    "$threshold_summary" \
    "$workspace_lists_summary" \
    "$account_lists_summary" |
    jq -s \
    --arg workspace "$w" \
    --arg workspace_id "$ws_id" \
    --arg workspace_input "$input" \
    --arg customer_id "$cid" \
    --argjson account_global "$(jq '[.data[] | select(((.scope.applies_to // []) | index("*")) != null)] | length' <<<"$account_applying")" \
    --argjson account_specific "$(jq --arg wsid "$ws_id" '[.data[] | select(((.scope.applies_to // []) | index("*")) == null and ((.scope.applies_to // []) | index($wsid)) != null)] | length' <<<"$account_applying")" \
    '.[0] as $ws
    | .[1] as $rules
    | .[2] as $account_rules
    | .[3] as $thresholds
    | .[4] as $workspace_lists
    | .[5] as $account_lists
    | {
      workspace: $workspace,
      workspace_id: $workspace_id,
      workspace_input: $workspace_input,
      customer_id: $customer_id,
      enforcement: {
        mode: ($ws.mode // "unknown"),
        immediate_blocking: ($ws.attack_signal_thresholds.immediate // null),
        default_blocking_response_code: ($ws.default_blocking_response_code // null)
      },
      attack_thresholds: ($ws.attack_signal_thresholds // {}),
      rules: $rules,
      account_rules_applying: (
        $account_rules
        + {
            global: $account_global,
            workspace_specific: $account_specific,
            note: "Filtered to account rules whose scope.applies_to is * or this workspace ID."
          }
      ),
      signal_thresholds: $thresholds,
      lists: {
        workspace: $workspace_lists,
        account: $account_lists,
        note: "List inventory only. Presence of a list does not establish that a rule references it."
      },
      provenance: {
        data_class: "configuration_snapshot",
        workspace_resolution: "exact ID first; otherwise case-insensitive exact name",
        pagination: "complete_or_fail"
      }
    }'
}

cmd_lists() {
  [[ $# -ge 1 && $# -le 2 ]] || die 'usage: ngwaf lists <workspace> [--json]'

  local cid input resolved w mode ws_id workspace_lists account_lists
  local workspace_summary account_summary
  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
  mode="${2:-}"

  [[ -z "$mode" || "$mode" == "--json" ]] ||
    die 'usage: ngwaf lists <workspace> [--json]'

  workspace_lists="$(
    get_all_pages "$(workspace_path "$ws_id")/lists" \
      --data-urlencode "customer_id=$cid"
  )"
  account_lists="$(
    get_all_pages "/ngwaf/v1/lists" \
      --data-urlencode "customer_id=$cid"
  )"

  if [[ "$mode" == "--json" ]]; then
    json_stream "$workspace_lists" "$account_lists" |
      jq -s \
      --arg workspace "$w" \
      --arg workspace_id "$ws_id" \
      --arg workspace_input "$input" '
      .[0] as $workspace_lists
      | .[1] as $account_lists
      | {
        workspace: $workspace,
        workspace_id: $workspace_id,
        workspace_input: $workspace_input,
        workspace_lists: $workspace_lists,
        account_lists: $account_lists,
        provenance: {
          data_class: "configuration_snapshot",
          workspace_endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/lists",
          account_endpoint: "GET /ngwaf/v1/lists",
          pagination: "complete_or_fail"
        }
      }'
    return
  fi

  workspace_summary="$(summarize_lists_json <<<"$workspace_lists")"
  account_summary="$(summarize_lists_json <<<"$account_lists")"

  json_stream "$workspace_summary" "$account_summary" |
    jq -s \
    --arg workspace "$w" \
    --arg workspace_id "$ws_id" \
    --arg workspace_input "$input" '
    .[0] as $workspace_lists
    | .[1] as $account_lists
    | {
      workspace: $workspace,
      workspace_id: $workspace_id,
      workspace_input: $workspace_input,
      workspace_lists: $workspace_lists,
      account_lists: $account_lists,
      note: "List inventory only; this does not prove which lists are referenced by effective rules."
    }'
}
