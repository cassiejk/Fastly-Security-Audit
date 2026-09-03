# shellcheck shell=bash
# Backticks in user-facing single-quoted messages are intentional Markdown-like
# command delimiters, not shell substitutions.
# shellcheck disable=SC2016
# Sourced by the ngwaf entry point; do not execute directly.

get_selected_services() {
  local cid from_ts page page_size max_pages
  local body count activation_pages activation_events truncated
  local ids_tmp recent_tmp services_tmp unknown_tmp
  local sid detail_tmp code observed_ids selected unknown_checks

  cid="$(current_cid)"
  page_size="$SERVICE_AUDIT_PAGE_SIZE"
  max_pages="$SERVICE_AUDIT_MAX_PAGES"

  [[ "$SERVICE_AUDIT_DAYS" =~ ^[0-9]+$ ]] || die 'NGWAF_SERVICE_AUDIT_DAYS must be an integer'
  [[ "$page_size" =~ ^[0-9]+$ ]] || die 'NGWAF_SERVICE_AUDIT_PAGE_SIZE must be an integer'
  [[ "$max_pages" =~ ^[0-9]+$ ]] || die 'NGWAF_SERVICE_AUDIT_MAX_PAGES must be an integer'
  (( SERVICE_AUDIT_DAYS >= 1 && SERVICE_AUDIT_DAYS <= 365 )) || die 'NGWAF_SERVICE_AUDIT_DAYS must be between 1 and 365'
  (( page_size >= 1 && page_size <= 100 )) || die 'NGWAF_SERVICE_AUDIT_PAGE_SIZE must be between 1 and 100'
  (( max_pages >= 1 && max_pages <= 500 )) || die 'NGWAF_SERVICE_AUDIT_MAX_PAGES must be between 1 and 500'

  if date -u -v-"${SERVICE_AUDIT_DAYS}"d '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    from_ts="$(date -u -v-"${SERVICE_AUDIT_DAYS}"d '+%Y-%m-%dT%H:%M:%SZ')"
  else
    from_ts="$(date -u -d "$SERVICE_AUDIT_DAYS days ago" '+%Y-%m-%dT%H:%M:%SZ')"
  fi

  ids_tmp="$(mktemp)"
  recent_tmp="$(mktemp)"
  services_tmp="$(mktemp)"
  unknown_tmp="$(mktemp)"
  activation_pages=0
  activation_events=0
  truncated=false

  printf 'Discovering selected-customer services from Fastly audit events...\n' >&2

  # Scan deployment activations within the audit window. The customer_id
  # filter was explicitly validated with the root:read token before this path
  # was adopted.
  page=1
  while :; do
    body="$(
      get "/events" \
        -H "Accept: application/vnd.api+json" \
        --data-urlencode "filter[customer_id]=$cid" \
        --data-urlencode "filter[event_type]=version.activate" \
        --data-urlencode "filter[created_at][gte]=$from_ts" \
        --data-urlencode "sort=-created_at" \
        --data-urlencode "page[number]=$page" \
        --data-urlencode "page[size]=$page_size"
    )"

    jq -e '.data | type == "array"' >/dev/null <<<"$body" || {
      rm -f "$ids_tmp" "$recent_tmp" "$services_tmp" "$unknown_tmp"
      die '/events did not return a JSON:API data array'
    }

    # Fail closed if customer scoping is ever ignored or changes semantics.
    if ! jq -e --arg cid "$cid" '[.data[].attributes.customer_id // empty] | all(. == $cid)' >/dev/null <<<"$body"; then
      rm -f "$ids_tmp" "$recent_tmp" "$services_tmp" "$unknown_tmp"
      die '/events customer_id filter returned events for another customer; refusing service discovery'
    fi

    count="$(jq '.data | length' <<<"$body")"
    activation_events=$(( activation_events + count ))
    activation_pages=$(( activation_pages + 1 ))
    jq -r '.data[].attributes.service_id // empty' <<<"$body" >>"$ids_tmp"

    if (( activation_pages % 5 == 0 )); then
      printf '  scanned %s activation event page(s) / %s event(s)...\n' \
        "$activation_pages" "$activation_events" >&2
    fi

    (( count < page_size )) && break

    if (( page >= max_pages )); then
      truncated=true
      break
    fi
    page=$(( page + 1 ))
  done

  # Add the most recent general customer events. This is intentionally only one
  # page: it catches very new service configuration activity without crawling
  # the account's full high-volume audit stream.
  body="$(
    get "/events" \
      -H "Accept: application/vnd.api+json" \
      --data-urlencode "filter[customer_id]=$cid" \
      --data-urlencode "sort=-created_at" \
      --data-urlencode "page[number]=1" \
      --data-urlencode "page[size]=$page_size"
  )"
  jq -e '.data | type == "array"' >/dev/null <<<"$body" || {
    rm -f "$ids_tmp" "$recent_tmp" "$services_tmp" "$unknown_tmp"
    die '/events recent activity query did not return a JSON:API data array'
  }
  if ! jq -e --arg cid "$cid" '[.data[].attributes.customer_id // empty] | all(. == $cid)' >/dev/null <<<"$body"; then
    rm -f "$ids_tmp" "$recent_tmp" "$services_tmp" "$unknown_tmp"
    die '/events recent activity query returned another customer; refusing service discovery'
  fi
  jq -r '.data[].attributes.service_id // empty' <<<"$body" >"$recent_tmp"
  cat "$recent_tmp" >>"$ids_tmp"

  observed_ids="$(sort -u "$ids_tmp" | jq -Rn '[inputs | select(length > 0)]')"
  printf 'Observed %s unique service ID(s); fetching service metadata...\n' "$(jq 'length' <<<"$observed_ids")" >&2

  # Resolve each observed service directly. Do not use /service pagination.
  while IFS= read -r sid; do
    [[ -n "$sid" ]] || continue
    detail_tmp="$(mktemp)"
    code="$(http_get_to_file "/service/$sid" "$detail_tmp")"
    case "$code" in
      2*)
        if jq -e --arg cid "$cid" '(.customer_id // "") == $cid' >/dev/null 2>&1 <"$detail_tmp"; then
          jq . "$detail_tmp" >>"$services_tmp"
        else
          jq -n --arg service_id "$sid" --arg status "$code" \
            '{service_id: $service_id, http_status: $status, reason: "customer_id_mismatch"}' >>"$unknown_tmp"
        fi
        ;;
      404)
        # Audit logs can retain references to deleted services. A 404 is not an
        # inventory error; simply omit that historical/deleted service.
        ;;
      *)
        jq -n --arg service_id "$sid" --arg status "$code" \
          '{service_id: $service_id, http_status: $status, reason: "service_lookup_failed"}' >>"$unknown_tmp"
        ;;
    esac
    rm -f "$detail_tmp"
  done < <(jq -r '.[]' <<<"$observed_ids")

  selected="$(jq -s 'unique_by(.id)' "$services_tmp")"
  unknown_checks="$(jq -s '.' "$unknown_tmp")"
  rm -f "$ids_tmp" "$recent_tmp" "$services_tmp" "$unknown_tmp"

  # Structured payloads can exceed macOS ARG_MAX when passed through
  # `jq --argjson`. Stream them as JSON documents instead.
  printf '%s\n%s\n%s\n' "$observed_ids" "$unknown_checks" "$selected" |
    jq -s \
    --arg method "customer-audit-events" \
    --arg from "$from_ts" \
    --argjson audit_days "$SERVICE_AUDIT_DAYS" \
    --argjson activation_pages "$activation_pages" \
    --argjson activation_events "$activation_events" \
    --argjson recent_events "$(jq '.data | length' <<<"$body")" \
    --argjson truncated "$truncated" \
    '.[0] as $observed_ids
    | .[1] as $unknown_checks
    | .[2] as $data
    | {
      meta: {
        discovery_method: $method,
        audit_window_days: $audit_days,
        audit_from: $from,
        activation_event_pages_fetched: $activation_pages,
        activation_events_scanned: $activation_events,
        recent_events_scanned: $recent_events,
        observed_service_ids: ($observed_ids | length),
        selected_total: ($data | length),
        activation_scan_truncated: $truncated,
        unknown_service_lookup_count: ($unknown_checks | length),
        unknown_service_lookups: $unknown_checks,
        completeness: "observed-within-audit-window"
      },
      data: $data
    }'
}

# Service-level products that currently expose a public "services with product
# enabled" endpoint. Account-level products (for example KV Store or Domain
# Research) are intentionally excluded from this service matrix.

service_product_specs() {
  cat <<'EOF'
api_discovery	API Discovery	none	security
bot_management	Bot Management	bot_management	security
brotli_compression	Brotli Compression	none	delivery
ddos_protection	DDoS Protection	ddos_protection	security
domain_inspector	Domain Inspector	none	observability
fanout	Fanout	none	delivery
image_optimizer	Image Optimizer	none	delivery
log_explorer_insights	Log Explorer & Insights	none	observability
ngwaf	Next-Gen WAF	ngwaf	security
origin_inspector	Origin Inspector	none	observability
websockets	WebSockets	none	delivery
EOF
}

# Return one normalized JSON object for a service-level product. Prefer the
# efficient customer-level enabled-services endpoint when it is demonstrably
# scoped to the selected customer. If that endpoint is unavailable or reports a
# different customer, fall back to read-only per-service enablement probes.

discover_product_json() {
  [[ $# -eq 5 ]] || die 'discover_product_json requires <id> <label> <config-kind> <category> <services-json>'

  local product_id="$1"
  local label="$2"
  local config_kind="$3"
  local category="$4"
  local services_body="$5"
  local cid list_tmp list_code returned_cid method enabled_ids unknown_checks
  local probe_tmp probe_code sid configs_tmp configs

  cid="$(current_cid)"
  list_tmp="$(mktemp)"
  list_code="$(http_get_to_file "/enabled-products/v1/$product_id/services" "$list_tmp")"
  enabled_ids='[]'
  unknown_checks='[]'
  returned_cid=''
  method='customer-list'

  if [[ "$list_code" == 2* ]] && jq -e 'type == "object" and ((.services // []) | type == "array")' >/dev/null 2>&1 <"$list_tmp"; then
    returned_cid="$(jq -r '.customer.id // empty' "$list_tmp")"
    if [[ -n "$returned_cid" && "$returned_cid" == "$cid" ]]; then
      enabled_ids="$(
        {
          jq '.data' <<<"$services_body"
          cat "$list_tmp"
        } | jq -s '
          .[0] as $services
          | (.[1].services // []) as $enabled
          | [$services[] | select(.id as $id | $enabled | index($id) != null) | .id]
        '
      )"
    else
      method='per-service-probe'
    fi
  else
    method='per-service-probe'
  fi
  rm -f "$list_tmp"

  if [[ "$method" == 'per-service-probe' ]]; then
    local enabled_tmp unknown_tmp
    enabled_tmp="$(mktemp)"
    unknown_tmp="$(mktemp)"

    while IFS= read -r sid; do
      [[ -n "$sid" ]] || continue
      probe_tmp="$(mktemp)"
      probe_code="$(http_get_to_file "/enabled-products/v1/$product_id/services/$sid" "$probe_tmp")"
      case "$probe_code" in
        2*) printf '%s\n' "$sid" >>"$enabled_tmp" ;;
        404) : ;;
        *)
          jq -n --arg service_id "$sid" --arg status "$probe_code" \
            '{service_id: $service_id, http_status: $status}' >>"$unknown_tmp"
          ;;
      esac
      rm -f "$probe_tmp"
    done < <(jq -r '.data[].id' <<<"$services_body")

    enabled_ids="$(jq -Rn '[inputs | select(length > 0)]' <"$enabled_tmp")"
    unknown_checks="$(jq -s '.' "$unknown_tmp")"
    rm -f "$enabled_tmp" "$unknown_tmp"
  fi

  # Fetch configuration only for products whose public API exposes a useful
  # configuration resource today: NGWAF, Bot Management, and DDoS Protection.
  configs_tmp="$(mktemp)"
  if [[ "$config_kind" != 'none' ]]; then
    while IFS= read -r sid; do
      [[ -n "$sid" ]] || continue
      probe_tmp="$(mktemp)"
      probe_code="$(http_get_to_file "/enabled-products/v1/$product_id/services/$sid/configuration" "$probe_tmp")"
      if [[ "$probe_code" == 2* ]] && jq -e 'type == "object"' >/dev/null 2>&1 <"$probe_tmp"; then
        jq '.configuration // {}' "$probe_tmp" |
          jq -s \
            --arg service_id "$sid" \
            '.[0] as $configuration
             | {service_id: $service_id, configuration: $configuration, configuration_http_status: 200}' >>"$configs_tmp"
      else
        jq -n \
          --arg service_id "$sid" \
          --arg status "$probe_code" \
          '{service_id: $service_id, configuration: null, configuration_http_status: $status}' >>"$configs_tmp"
      fi
      rm -f "$probe_tmp"
    done < <(jq -r '.[]' <<<"$enabled_ids")
  fi
  configs="$(jq -s '.' "$configs_tmp")"
  rm -f "$configs_tmp"

  {
    jq '.data' <<<"$services_body"
    printf '%s\n%s\n%s\n' "$enabled_ids" "$configs" "$unknown_checks"
  } | jq -s \
    --arg id "$product_id" \
    --arg label "$label" \
    --arg category "$category" \
    --arg discovery_method "$method" \
    --arg list_customer_id "$returned_cid" '
      def platform:
        if (.type // "") == "vcl" then "CDN"
        elif (.type // "") == "wasm" then "Compute"
        else (.type // "unknown")
        end;
      def active_version:
        if (.active_version | type) == "object" then
          (.active_version.number // .active_version.version // .active_version.id // null)
        elif .active_version != null then .active_version
        elif ((.environments // []) | type) == "array" then
          (([.environments[] | select((.name // "") == "production") | .active_version] | .[0]) // .version // null)
        else (.version // null)
        end;
      .[0] as $all_services
      | .[1] as $enabled_ids
      | .[2] as $configs
      | .[3] as $unknown_checks
      | {
        id: $id,
        label: $label,
        category: $category,
        discovery_method: $discovery_method,
        product_list_customer_id: (if $list_customer_id == "" then null else $list_customer_id end),
        enabled_count: ($enabled_ids | length),
        unknown_check_count: ($unknown_checks | length),
        unknown_checks: $unknown_checks,
        services: [
          $all_services[]
          | select(.id as $sid | $enabled_ids | index($sid) != null)
          | . as $svc
          | ($configs | map(select(.service_id == $svc.id)) | .[0] // {}) as $cfg
          | {
              id: $svc.id,
              name: ($svc.name // ""),
              customer_id: ($svc.customer_id // null),
              type: ($svc.type // "unknown"),
              platform: ($svc | platform),
              active_version: ($svc | active_version),
              paused: ($svc.paused // false),
              configuration: ($cfg.configuration // null),
              configuration_http_status: ($cfg.configuration_http_status // null)
            }
        ]
      }
    '
}

collect_products_json() {
  [[ $# -eq 1 ]] || die 'collect_products_json requires <services-json>'

  local services_body="$1"
  local tmp product_id label config_kind category
  tmp="$(mktemp)"

  while IFS=$'\t' read -r product_id label config_kind category; do
    [[ -n "$product_id" ]] || continue
    discover_product_json "$product_id" "$label" "$config_kind" "$category" "$services_body" >>"$tmp"
  done < <(service_product_specs)

  jq -s '.' "$tmp"
  rm -f "$tmp"
}

cmd_services() {
  [[ $# -le 1 ]] || die 'usage: ngwaf services [--json]'

  local mode="${1:-}"
  local cid customer services_body normalized
  [[ -z "$mode" || "$mode" == '--json' ]] || die 'usage: ngwaf services [--json]'

  cid="$(current_cid)"
  customer="$(get "/customer/$cid")"
  services_body="$(get_selected_services)"

  normalized="$(
    printf '%s\n%s\n' "$customer" "$services_body" |
      jq -s '
        def platform:
          if (.type // "") == "vcl" then "CDN"
          elif (.type // "") == "wasm" then "Compute"
          else (.type // "unknown")
          end;
        def active_version:
          if (.active_version | type) == "object" then
            (.active_version.number // .active_version.version // .active_version.id // null)
          elif .active_version != null then .active_version
          elif ((.environments // []) | type) == "array" then
            (([.environments[] | select((.name // "") == "production") | .active_version] | .[0]) // .version // null)
          else (.version // null)
          end;
        .[0] as $customer
        | .[1] as $body
        | ($body.data // []) as $services
        | {
            customer: {id: ($customer.id // null), name: ($customer.name // null)},
            summary: {
              total: ($services | length),
              cdn: ([$services[] | select((.type // "") == "vcl")] | length),
              compute: ([$services[] | select((.type // "") == "wasm")] | length),
              other: ([$services[] | select(((.type // "") != "vcl") and ((.type // "") != "wasm"))] | length),
              paused: ([$services[] | select(.paused == true)] | length),
              discovery_method: ($body.meta.discovery_method // null),
              audit_window_days: ($body.meta.audit_window_days // null),
              activation_event_pages_fetched: ($body.meta.activation_event_pages_fetched // null),
              activation_events_scanned: ($body.meta.activation_events_scanned // null),
              recent_events_scanned: ($body.meta.recent_events_scanned // null),
              activation_scan_truncated: ($body.meta.activation_scan_truncated // false),
              unknown_service_lookup_count: ($body.meta.unknown_service_lookup_count // 0),
              completeness: ($body.meta.completeness // "unknown")
            },
            services: [
              $services[]
              | {
                  id,
                  name,
                  customer_id,
                  type: (.type // "unknown"),
                  platform: platform,
                  active_version: active_version,
                  paused: (.paused // false),
                  created_at: (.created_at // null),
                  updated_at: (.updated_at // null)
                }
            ]
          }
      '
  )"

  if [[ "$mode" == '--json' ]]; then
    jq . <<<"$normalized"
    return
  fi

  jq -r '
    "Customer: \(.customer.name) (\(.customer.id))",
    "Observed services: \(.summary.total) total — \(.summary.cdn) CDN, \(.summary.compute) Compute, \(.summary.other) other; \(.summary.paused) paused",
    "Discovery: audit events over \(.summary.audit_window_days)d; activation pages=\(.summary.activation_event_pages_fetched), activation events=\(.summary.activation_events_scanned), recent events=\(.summary.recent_events_scanned)"
  ' <<<"$normalized"
  if jq -e '.summary.activation_scan_truncated == true' >/dev/null <<<"$normalized"; then
    printf 'WARNING: activation-event discovery hit the configured page cap; this observed service set may be incomplete. Increase NGWAF_SERVICE_AUDIT_MAX_PAGES if needed.\n' >&2
  fi
  if jq -e '.summary.unknown_service_lookup_count > 0' >/dev/null <<<"$normalized"; then
    printf 'WARNING: one or more observed service IDs could not be resolved. Use `ngwaf services --json` for discovery metadata.\n' >&2
  fi
  printf '\n'

  jq -r '
    ["TYPE", "ACTIVE", "PAUSED", "NAME", "SERVICE ID"],
    (
      .services
      | sort_by(.platform, .name)
      | .[]
      | [
          .platform,
          (.active_version // "-" | tostring),
          (.paused | tostring),
          .name,
          .id
        ]
    )
    | @tsv
  ' <<<"$normalized" | human_table
}

cmd_products() {
  [[ $# -le 1 ]] || die 'usage: ngwaf products [--json]'

  local mode="${1:-}"
  local cid customer services_body products payload
  [[ -z "$mode" || "$mode" == '--json' ]] || die 'usage: ngwaf products [--json]'

  cid="$(current_cid)"
  customer="$(get "/customer/$cid")"
  services_body="$(get_selected_services)"
  products="$(collect_products_json "$services_body")"

  payload="$(
    printf '%s\n%s\n%s\n' "$customer" "$services_body" "$products" |
      jq -s '
        .[0] as $customer
        | .[1] as $services_body
        | .[2] as $products
        | {
          customer: {id: ($customer.id // null), name: ($customer.name // null)},
          services_scanned: ($services_body.data | length),
          service_discovery: ($services_body.meta // {}),
          product_definitions_scanned: ($products | length),
          products: $products,
          note: "Service-level product inventory is evaluated against the audit-observed selected-customer service set. Account-level products without a service mapping are not included. Non-2xx checks other than 404 are reported as unknown rather than treated as disabled."
        }
      '
  )"

  if [[ "$mode" == '--json' ]]; then
    jq . <<<"$payload"
    return
  fi

  jq -r '
    "Customer: \(.customer.name) (\(.customer.id))",
    "Observed services scanned: \(.services_scanned)",
    "Service discovery: audit events over \(.service_discovery.audit_window_days // "?")d; truncated=\(.service_discovery.activation_scan_truncated // false)",
    "Service-level products checked: \(.product_definitions_scanned)"
  ' <<<"$payload"

  printf '\nPRODUCT SUMMARY\n'
  jq -r '
    ["CATEGORY", "PRODUCT", "ENABLED SERVICES", "UNKNOWN CHECKS", "DISCOVERY"],
    (
      .products
      | sort_by(.category, .label)
      | .[]
      | [
          (.category | ascii_upcase),
          .label,
          (.enabled_count | tostring),
          (.unknown_check_count | tostring),
          .discovery_method
        ]
    )
    | @tsv
  ' <<<"$payload" | human_table

  printf '\nENABLED SERVICE / PRODUCT MAPPING\n'
  jq -r '
    def cfg($pid; $c):
      if $c == null then "-"
      elif $pid == "bot_management" then "contentguard=" + (($c.contentguard // "unknown") | tostring)
      elif $pid == "ddos_protection" then "mode=" + (($c.mode // "unknown") | tostring)
      elif $pid == "ngwaf" then
        "workspace_id=" + (($c.workspace_id // "unknown") | tostring)
        + ", traffic_ramp=" + (($c.traffic_ramp // "unknown") | tostring)
      else ($c | tostring)
      end;
    ["SERVICE", "TYPE", "PRODUCT", "CONFIGURATION"],
    (
      .products[] as $p
      | $p.services[]?
      | [
          .name,
          .platform,
          $p.label,
          cfg($p.id; .configuration)
        ]
    )
    | @tsv
  ' <<<"$payload" | human_table

  if jq -e '[.products[].unknown_check_count] | add > 0' >/dev/null <<<"$payload"; then
    printf '\nWARNING: One or more product checks were inconclusive (for example permission/API errors). Use --json to inspect unknown_checks; they are not counted as disabled.\n' >&2
  fi
}

cmd_inventory() {
  [[ $# -le 1 ]] || die 'usage: ngwaf inventory [--json]'

  local mode="${1:-}"
  local cid customer services_body products workspaces payload
  [[ -z "$mode" || "$mode" == '--json' ]] || die 'usage: ngwaf inventory [--json]'

  cid="$(current_cid)"
  customer="$(get "/customer/$cid")"
  services_body="$(get_selected_services)"
  products="$(collect_products_json "$services_body")"
  workspaces="$(
    get_all_pages "/ngwaf/v1/workspaces" \
      --data-urlencode "customer_id=$cid"
  )"

  payload="$(
    printf '%s\n%s\n%s\n%s\n' "$customer" "$services_body" "$products" "$workspaces" |
      jq -s '
        .[0] as $customer
        | .[1] as $services_body
        | .[2] as $products
        | .[3] as $workspaces
        | ($services_body.data // []) as $services
        | {
            customer: {id: ($customer.id // null), name: ($customer.name // null)},
            edge_services: {
              total: ($services | length),
              cdn: ([$services[] | select((.type // "") == "vcl")] | length),
              compute: ([$services[] | select((.type // "") == "wasm")] | length),
              other: ([$services[] | select(((.type // "") != "vcl") and ((.type // "") != "wasm"))] | length),
              paused: ([$services[] | select(.paused == true)] | length),
              discovery: ($services_body.meta // {}),
              services: [
                $services[]
                | {
                    id,
                    name,
                    type: (.type // "unknown"),
                    platform: (if (.type // "") == "vcl" then "CDN" elif (.type // "") == "wasm" then "Compute" else (.type // "unknown") end),
                    active_version: (
                      if (.active_version | type) == "object" then (.active_version.number // .active_version.version // .active_version.id // null)
                      elif .active_version != null then .active_version
                      elif ((.environments // []) | type) == "array" then (([.environments[] | select((.name // "") == "production") | .active_version] | .[0]) // .version // null)
                      else (.version // null)
                      end
                    ),
                    paused: (.paused // false)
                  }
              ]
            },
            service_products: {
              definitions_scanned: ($products | length),
              products: $products
            },
            ngwaf: {
              workspace_count: ($workspaces.data | length),
              workspaces: [$workspaces.data[] | {id, name, mode, default_blocking_response_code}],
              pages_fetched: ($workspaces.meta.pages_fetched // null)
            },
            notes: [
              "Service inventory contains services observed through selected-customer audit events and then verified by direct service lookup; it is not guaranteed to be a complete all-time account inventory.",
              "The audit-based service discovery window is finite and may be truncated by NGWAF_SERVICE_AUDIT_MAX_PAGES on very active accounts.",
              "Product inventory covers known public service-level product enablement APIs; account-level products are not included.",
              "A product check that returns a non-2xx status other than 404 is reported as unknown, not disabled.",
              "Product enablement is configuration inventory and does not prove that a service currently carries meaningful production traffic."
            ]
          }
      '
  )"

  if [[ "$mode" == '--json' ]]; then
    jq . <<<"$payload"
    return
  fi

  jq -r '
    "Customer: \(.customer.name) (\(.customer.id))",
    "",
    "EDGE SERVICES (AUDIT-OBSERVED)",
    "  Total:   \(.edge_services.total)",
    "  CDN:     \(.edge_services.cdn)",
    "  Compute: \(.edge_services.compute)",
    "  Other:   \(.edge_services.other)",
    "  Paused:  \(.edge_services.paused)",
    "  Audit window: \(.edge_services.discovery.audit_window_days // "?")d; activation scan truncated=\(.edge_services.discovery.activation_scan_truncated // false)",
    "",
    "NGWAF",
    "  Workspaces: \(.ngwaf.workspace_count)"
  ' <<<"$payload"

  printf '\nSERVICE-LEVEL PRODUCTS\n'
  jq -r '
    ["CATEGORY", "PRODUCT", "ENABLED SERVICES", "UNKNOWN"],
    (
      .service_products.products
      | sort_by(.category, .label)
      | .[]
      | [
          (.category | ascii_upcase),
          .label,
          (.enabled_count | tostring),
          (.unknown_check_count | tostring)
        ]
    )
    | @tsv
  ' <<<"$payload" | human_table

  printf '\nSECURITY PRODUCT MAPPING\n'
  jq -r '
    def cfg($pid; $c):
      if $c == null then "-"
      elif $pid == "bot_management" then "contentguard=" + (($c.contentguard // "unknown") | tostring)
      elif $pid == "ddos_protection" then "mode=" + (($c.mode // "unknown") | tostring)
      elif $pid == "ngwaf" then
        "workspace_id=" + (($c.workspace_id // "unknown") | tostring)
        + ", traffic_ramp=" + (($c.traffic_ramp // "unknown") | tostring)
      else "-"
      end;
    ["SERVICE", "TYPE", "PRODUCT", "CONFIGURATION"],
    (
      .service_products.products[] as $p
      | select($p.category == "security")
      | $p.services[]?
      | [.name, .platform, $p.label, cfg($p.id; .configuration)]
    )
    | @tsv
  ' <<<"$payload" | human_table

  if jq -e '.edge_services.discovery.activation_scan_truncated == true' >/dev/null <<<"$payload"; then
    printf '\nWARNING: service discovery hit the audit-event page cap; service and product counts are based on an incomplete observed-service set.\n' >&2
  fi

  if jq -e '[.service_products.products[].unknown_check_count] | add > 0' >/dev/null <<<"$payload"; then
    printf '\nWARNING: Some product checks were inconclusive. Run `ngwaf inventory --json` for exact HTTP statuses.\n' >&2
  fi
}
