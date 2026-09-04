# shellcheck shell=bash
# Sourced by the fastly-audit entry point; do not execute directly.

collect_security_products_json() {
  [[ $# -eq 1 ]] || die 'collect_security_products_json requires <services-json>'

  local services_body="$1"
  local tmp product_id label config_kind category
  tmp="$(mktemp)"

  while IFS=$'\t' read -r product_id label config_kind category; do
    [[ -n "$product_id" && "$category" == 'security' ]] || continue
    discover_product_json "$product_id" "$label" "$config_kind" "$category" "$services_body" >>"$tmp"
  done < <(service_product_specs)

  jq -s '.' "$tmp"
  rm -f "$tmp"
}

cmd_security_summary() {
  [[ $# -le 1 ]] || die 'usage: fastly-audit security summary [--json]'

  local mode="${1:-}"
  local cid customer services_body products workspaces payload
  [[ -z "$mode" || "$mode" == '--json' ]] ||
    die 'usage: fastly-audit security summary [--json]'

  cid="$(current_cid)"

  ui_phase 1 4 'Resolving the selected customer and observed services'
  customer="$(get "/customer/$cid")"
  services_body="$(get_selected_services)"

  ui_phase 2 4 'Checking security-product enablement and configuration'
  products="$(collect_security_products_json "$services_body")"

  ui_phase 3 4 'Retrieving the complete NGWAF workspace inventory'
  workspaces="$(
    get_all_pages "/ngwaf/v1/workspaces" \
      --data-urlencode "customer_id=$cid"
  )"

  ui_phase 4 4 'Building the security summary'
  payload="$(
    printf '%s\n%s\n%s\n%s\n' "$customer" "$services_body" "$products" "$workspaces" |
      jq -s '
        .[0] as $customer
        | .[1] as $services_body
        | .[2] as $products
        | .[3] as $workspaces
        | ($services_body.data // []) as $services
        | {
            schema_version: 1,
            command: "security summary",
            generated_at: (now | todateiso8601),
            customer: {
              id: ($customer.id // null),
              name: ($customer.name // null)
            },
            summary: {
              observed_services: ($services | length),
              security_products_scanned: ($products | length),
              enabled_product_types: ([$products[] | select(.enabled_count > 0)] | length),
              service_product_mappings: ([$products[].enabled_count] | add // 0),
              cdn_mappings: ([$products[].services[]? | select(.platform == "CDN")] | length),
              compute_mappings: ([$products[].services[]? | select(.platform == "Compute")] | length),
              paused_service_mappings: ([$products[].services[]? | select(.paused == true)] | length),
              unknown_enablement_checks: ([$products[].unknown_check_count] | add // 0),
              unavailable_configurations: ([
                $products[].services[]?
                | select(.configuration_http_status != null and .configuration_http_status != 200)
              ] | length),
              ngwaf_workspaces: ($workspaces.data | length),
              completeness: ($services_body.meta.completeness // "unknown"),
              activation_scan_truncated: ($services_body.meta.activation_scan_truncated // false)
            },
            products: $products,
            ngwaf: {
              workspace_count: ($workspaces.data | length),
              pages_fetched: ($workspaces.meta.pages_fetched // null),
              workspaces: [
                $workspaces.data[]
                | {
                    id,
                    name,
                    mode: (.mode // null),
                    default_blocking_response_code: (.default_blocking_response_code // null)
                  }
              ]
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
                missing_data_policy: "unknown_not_disabled"
              },
              ngwaf_workspaces: {
                endpoint: "GET /ngwaf/v1/workspaces",
                data_class: "configuration_snapshot",
                pagination: "complete_or_fail"
              }
            },
            limitations: [
              "The service set contains services observed through selected-customer audit events and verified by direct lookup; it is not a guaranteed all-time account inventory.",
              "Product enablement is configuration inventory. It does not prove current traffic, effective enforcement, or security efficacy.",
              "Non-2xx enablement checks other than 404 are unknown, not disabled.",
              "Only public service-level APIs for API Discovery, Bot Management, DDoS Protection, and Next-Gen WAF are included.",
              "Configuration fields are reported as returned by Fastly and are not interpreted as proof of policy behavior."
            ]
          }
      '
  )"

  if [[ "$mode" == '--json' ]]; then
    jq . <<<"$payload"
    return
  fi

  ui_heading 'Security product summary'
  jq -r '
    "Customer: \(.customer.name) (\(.customer.id))",
    "Observed services: \(.summary.observed_services)",
    "Security products: \(.summary.enabled_product_types) enabled product type(s), \(.summary.service_product_mappings) service mapping(s)",
    "NGWAF workspaces: \(.summary.ngwaf_workspaces)",
    "Discovery completeness: \(.summary.completeness); truncated=\(.summary.activation_scan_truncated)"
  ' <<<"$payload"

  printf '\n'
  ui_heading 'Product coverage'
  jq -r '
    ["PRODUCT", "ENABLED", "CDN", "COMPUTE", "UNKNOWN"],
    (
      .products
      | sort_by(.label)
      | .[]
      | [
          .label,
          (.enabled_count | tostring),
          ([.services[]? | select(.platform == "CDN")] | length | tostring),
          ([.services[]? | select(.platform == "Compute")] | length | tostring),
          (.unknown_check_count | tostring)
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
        "contentguard=" + (($c.contentguard // "unknown") | tostring)
      elif $pid == "ddos_protection" then
        "mode=" + (($c.mode // "unknown") | tostring)
      elif $pid == "ngwaf" then
        "workspace_id=" + (($c.workspace_id // "unknown") | tostring)
        + ", traffic_ramp=" + (($c.traffic_ramp // "unknown") | tostring)
      else ($c | tostring)
      end;
    def state:
      if .configuration_http_status == null then "enabled"
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
  ui_heading 'NGWAF workspaces'
  jq -r '
    ["WORKSPACE", "ID", "MODE", "BLOCK RESPONSE"],
    (
      .ngwaf.workspaces
      | sort_by(.name)
      | .[]
      | [
          .name,
          .id,
          (.mode // "-"),
          (.default_blocking_response_code // "-" | tostring)
        ]
    )
    | @tsv
  ' <<<"$payload" | human_table

  printf '\nNOTE: Enabled means the product is attached in Fastly configuration; it does not prove traffic, enforcement, or efficacy.\n'

  if jq -e '.summary.activation_scan_truncated == true' >/dev/null <<<"$payload"; then
    printf '%s: WARNING: service discovery hit the configured audit-event page cap; counts may be incomplete.\n' "$PROGRAM_NAME" >&2
  fi
  if jq -e '.summary.unknown_enablement_checks > 0 or .summary.unavailable_configurations > 0' >/dev/null <<<"$payload"; then
    printf '%s: WARNING: one or more security-product checks were inconclusive; inspect --json details. Unknown is not disabled.\n' "$PROGRAM_NAME" >&2
  fi
}
