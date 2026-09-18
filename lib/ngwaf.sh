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
    | (if $in_band_evidence.summary.sites_inventory_status != "COMPLETE" or $product.status == "UNKNOWN" or $product.status == "FAILED" then "UNKNOWN"
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

cmd_workspace_services() {
  local selector='' all=false json=false corp='' cid resolved selected_id=''
  local workspaces in_band_evidence inventory product payload with_domains=false
  local -a in_band_args=(--json)
  while (( $# > 0 )); do
    case "$1" in
      --all) all=true; shift ;;
      --json) json=true; shift ;;
      --with-domains) with_domains=true; shift ;;
      --sigsci-corp)
        (( $# >= 2 )) || die '--sigsci-corp requires a corp slug'
        corp="$2"; in_band_args+=(--sigsci-corp "$corp"); shift 2 ;;
      --*) die "unknown workspace-services option: $1" ;;
      *) [[ -z "$selector" ]] || die 'specify one workspace or --all'; selector="$1"; shift ;;
    esac
  done
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
  inventory="$(get_token_visible_customer_services)" || return 1
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
