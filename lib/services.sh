# shellcheck shell=bash
# Backticks in user-facing single-quoted messages are intentional Markdown-like
# command delimiters, not shell substitutions.
# shellcheck disable=SC2016
# Sourced by the ngwaf entry point; do not execute directly.

get_selected_services() {
  local cid from_ts page page_size max_pages recent_code
  local body count activation_pages activation_events recent_events truncated
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
  recent_events=0
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
  recent_code="$(
    http_get_to_file "/events" "$recent_tmp" \
      -H "Accept: application/vnd.api+json" \
      --data-urlencode "filter[customer_id]=$cid" \
      --data-urlencode "sort=-created_at" \
      --data-urlencode "page[number]=1" \
      --data-urlencode "page[size]=$page_size"
  )"
  if [[ "$recent_code" == 2* ]] && jq -e '.data | type == "array"' >/dev/null 2>&1 <"$recent_tmp"; then
    body="$(cat "$recent_tmp")"
    if jq -e --arg cid "$cid" '[.data[].attributes.customer_id // empty] | all(. == $cid)' >/dev/null <<<"$body"; then
      recent_events="$(jq '.data | length' <<<"$body")"
      jq -r '.data[].attributes.service_id // empty' <<<"$body" >>"$ids_tmp"
    else
      rm -f "$ids_tmp" "$recent_tmp" "$services_tmp" "$unknown_tmp"
      die '/events recent activity query returned another customer; refusing service discovery'
    fi
  else
    printf '%s: WARNING: /events recent activity query returned HTTP %s or invalid JSON; continuing with activation-event service discovery only.\n' \
      "${PROGRAM_NAME:-ngwaf}" "$recent_code" >&2
  fi

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
    --argjson recent_events "$recent_events" \
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

# Customer-scoped search is a UI-backed fast path, not a public-API contract.
# Only a fully validated traversal is published. Return 1 for an inconclusive
# search (safe legacy fallback), 2 for auth/scope failure (no fallback). Failure
# reasons are fixed text/status codes; cursors and response bodies stay private.
search_customer_services_json() {
  local cid="$1" output="$2" tmp code reason='' failure=1
  local total='' page_total count fetched=0 pages=0 cursor='' next_cursor
  local -a args
  local -A seen_cursors=()
  tmp="$(mktemp -d)" || return 1
  : >"$tmp/pages"

  while :; do
    if (( pages >= 1000 )); then reason='cursor pagination safety limit exceeded'; break; fi
    args=(--data-urlencode "customer_id=$cid" --data-urlencode 'limit=100' --data-urlencode 'sort=name')
    [[ -z "$cursor" ]] || args+=(--data-urlencode "cursor=$cursor")
    code="$(http_get_to_file /search/services "$tmp/page" "${args[@]}")" || code=000
    case "$code" in
      401|403)
        reason="search authorization failed: HTTP $code"; failure=2; break ;;
      2*) ;;
      *) reason="search unavailable: HTTP $code"; break ;;
    esac
    # Bound numeric totals for safe shell arithmetic; larger inventories cannot
    # complete within the traversal safety bound and use the legacy fallback.
    if ! jq -e '
      type == "object" and (.data | type == "array") and (.meta | type == "object")
      and (.meta.total | type == "number" and . >= 0 and . <= 2147483647 and . == floor)
      and (if .meta | has("next_cursor") then
             (.meta.next_cursor == null or (.meta.next_cursor | type == "string"))
           else true end)
      and all(.data[]; type == "object" and (.id | type == "string" and length > 0)
        and (if has("name") then .name | type == "string" else true end)
        and (if has("type") then .type | type == "string" else true end)
        and (if has("paused") then .paused == null or (.paused | type == "boolean") else true end))
    ' "$tmp/page" >/dev/null 2>&1; then
      reason='unexpected search JSON or missing/invalid metadata'; break
    fi
    # The authenticated, case-sensitive customer ID scopes the search request.
    # If the response supplies ownership metadata, it must agree as well.
    if ! jq -e --arg cid "$cid" '
      (if has("customer_id") then .customer_id == $cid else true end)
      and (if (.customer | type) == "object" and (.customer | has("id")) then .customer.id == $cid else true end)
      and (if .meta | has("customer_id") then .meta.customer_id == $cid else true end)
      and all(.data[];
        (if has("customer_id") then .customer_id == $cid else true end)
        and (if (.customer | type) == "object" and (.customer | has("id")) then .customer.id == $cid else true end))
    ' "$tmp/page" >/dev/null 2>&1; then
      reason='search response conflicts with authenticated customer scope'; failure=2; break
    fi
    page_total="$(jq -r '.meta.total' "$tmp/page")"
    count="$(jq '.data | length' "$tmp/page")"
    if [[ -n "$total" && "$total" != "$page_total" ]]; then
      reason='search total changed during cursor traversal'; break
    fi
    total="$page_total"
    jq '.data' "$tmp/page" >>"$tmp/pages" || { reason='search page could not be collected'; break; }
    pages=$(( pages + 1 ))
    fetched=$(( fetched + count ))
    if (( fetched > total )); then reason='search collected more services than meta.total'; break; fi
    next_cursor="$(jq -r '.meta.next_cursor // ""' "$tmp/page")"
    # Reject control characters before shell extraction could alter an opaque
    # cursor (command substitution strips trailing newlines).
    if ! jq -e '(.meta.next_cursor // "") | test("[[:cntrl:]]") | not' "$tmp/page" >/dev/null; then
      reason='search returned an invalid cursor'; break
    fi
    if [[ -z "$next_cursor" ]]; then
      if (( fetched != total )); then reason='search collected count differs from meta.total'; fi
      break
    fi
    if (( count == 0 || fetched >= total )); then
      reason='search cursor contradicts collected count'; break
    fi
    if [[ -n "${seen_cursors["$next_cursor"]:-}" ]]; then
      reason='search cursor repeated during traversal'; break
    fi
    seen_cursors["$next_cursor"]=1
    cursor="$next_cursor"
  done

  if [[ -z "$reason" ]]; then
    if ! jq -s -e 'add | length == (unique_by(.id) | length)' "$tmp/pages" >/dev/null; then
      reason='search returned duplicate service IDs'
    fi
  fi
  if [[ -n "$reason" ]]; then
    rm -rf "$tmp"
    printf '%s\n' "$reason"
    return "$failure"
  fi

  jq -s --arg cid "$cid" --arg retrieved_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson count "$fetched" --argjson pages "$pages" '
    {
      meta: {
        discovery_method: "fastly-customer-service-search", source: "GET /search/services",
        scope: "customer", customer_filter: "exact_customer_id",
        filtered_locally_by_customer_id: false, selected_customer_id: $cid,
        selected_total: $count, selected_total_lower_bound: $count,
        completeness: "token-visible", status: "COMPLETE", evidence_type: "DIRECT",
        count: $count, count_lower_bound: null, fallback_used: false,
        token_visibility_complete_for_customer: null,
        result: {
          status: "COMPLETE", count: $count, count_lower_bound: null,
          source: "GET /search/services", scope: "customer", evidence_type: "DIRECT",
          filtered_locally_by_customer_id: false, retrieved_at: $retrieved_at,
          customer_scope: {customer_id: $cid, filter: "server_side_exact_customer_id",
            validation: "authenticated customer identity and returned ownership metadata when present",
            token_visibility_complete_for_customer: null},
          reason: "complete customer-scoped service search with count and cursor validation",
          pagination: {type: "cursor", limit: 100, sort: "name", pages_fetched: $pages,
            returned_total: $count, reported_total: $count, truncated: false, terminated: true},
          fallback_used: false, returned_total: $count, reported_total: $count
        },
        note: "Customer-scoped Fastly service search is token-visible; complete pagination does not prove visibility of every customer service."
      },
      data: (add | map({
        id, name: (.name // ""), customer_id: $cid, type: (.type // "unknown"),
        active_version: (if has("active_version") then .active_version else null end),
        paused: (if has("paused") then .paused else null end),
        state: (if has("state") then .state else null end),
        production_version_number: (if has("production_version_number") then .production_version_number else null end),
        staging_version_number: (if has("staging_version_number") then .staging_version_number else null end),
        latest_locked_version_number: (if has("latest_locked_version_number") then .latest_locked_version_number else null end),
        latest_draft_version_number: (if has("latest_draft_version_number") then .latest_draft_version_number else null end),
        updated_at: (.updated_at // null), created_at: (.created_at // null)
      }))
    }
  ' "$tmp/pages" >"$output"
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# Callers that need legacy active-version/paused metadata opt in to details.
# Search state/version fields are retained, never guessed into those fields.
# Details are fetched only for rows lacking required legacy fields; ownership
# must be proven by the service response itself before merging it.
enrich_customer_services_json() {
  local inventory="$1" cid="$2" tmp service sid code queried=0
  tmp="$(mktemp -d)" || return 1
  : >"$tmp/services"
  while IFS= read -r service; do
    if jq -e '.active_version != null and .paused != null' >/dev/null <<<"$service"; then
      printf '%s\n' "$service" >>"$tmp/services"
      continue
    fi
    sid="$(jq -r .id <<<"$service")"
    code="$(http_get_to_file "/service/$(urlencode "$sid")" "$tmp/detail")" || code=000
    if [[ "$code" != 2* ]] || ! jq -e --arg sid "$sid" --arg cid "$cid" \
      'type == "object" and .id == $sid and .customer_id == $cid
       and (if has("paused") then .paused == null or (.paused | type == "boolean") else true end)' "$tmp/detail" >/dev/null 2>&1; then
      printf '%s: Service detail enrichment failed or scope was unverified (HTTP %s); inventory unavailable.\n' \
        "${PROGRAM_NAME:-ngwaf}" "$code" >&2
      rm -rf "$tmp"
      return 1
    fi
    printf '%s\n' "$service" >"$tmp/search-row"
    jq -s '.[0] * .[1]' "$tmp/search-row" "$tmp/detail" >>"$tmp/services" || { rm -rf "$tmp"; return 1; }
    queried=$(( queried + 1 ))
  done < <(jq -c '.data[]' <<<"$inventory")
  printf '%s\n' "$inventory" >"$tmp/inventory"
  jq -s '.' "$tmp/services" >"$tmp/rows" || { rm -rf "$tmp"; return 1; }
  jq -s --argjson queried "$queried" '
    .[0] as $inventory | .[1] as $rows
    | $inventory | .data = $rows
    | .meta.enrichment = {source: "GET /service/{service_id}", services_queried: $queried,
        fields: ["active_version", "paused"], ownership_validation: "exact service and customer IDs"}
  ' "$tmp/inventory" "$tmp/rows"
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

get_customer_services() {
  [[ $# == 0 || ( $# == 1 && "$1" == --details ) ]] || die 'get_customer_services accepts only --details'
  local cid selected tmp reason rc inventory
  # Use the authenticated canonical ID, never a normalized spelling of user input.
  load_customer_context || return 1
  selected="$(current_cid)" || return 1
  cid="$(jq -r .id <<<"$NGWAF_CUSTOMER_CONTEXT_JSON")"
  if [[ -z "$cid" || "$cid" != "$selected" ]]; then
    printf '%s: Customer service discovery requires matching authenticated customer scope.\n' "${PROGRAM_NAME:-ngwaf}" >&2
    return 1
  fi
  tmp="$(mktemp)" || return 1
  printf 'Listing customer-scoped services from Fastly service search...\n' >&2
  if reason="$(search_customer_services_json "$cid" "$tmp")"; then
    inventory="$(cat "$tmp")"
    rm -f "$tmp"
    if [[ "${1:-}" == --details ]]; then
      enrich_customer_services_json "$inventory" "$cid"
    else
      printf '%s\n' "$inventory"
    fi
    return
  else
    rc=$?
    rm -f "$tmp"
    if [[ "$rc" == 2 ]]; then
      printf '%s: Customer service discovery failed: %s; not using legacy fallback.\n' "${PROGRAM_NAME:-ngwaf}" "$reason" >&2
      return 1
    fi
  fi
  printf '%s: Service search was unavailable/inconclusive (%s); using legacy token-visible service discovery.\n' \
    "${PROGRAM_NAME:-ngwaf}" "$reason" >&2
  inventory="$(get_token_visible_customer_services)" || return 1
  jq --arg reason "$reason" '
    .meta.scope = "token-visible" | .meta.filtered_locally_by_customer_id = true
    | .meta.fallback_used = true
    | .meta.result.scope = "token-visible" | .meta.result.filtered_locally_by_customer_id = true
    | .meta.result.fallback_used = true | .meta.result.fallback_from = "GET /search/services"
    | .meta.result.fallback_reason = $reason
  ' <<<"$inventory"
}

get_token_visible_customer_services() {
  local cid tmp code services retrieved_at

  cid="$(current_cid)"
  tmp="$(mktemp)"
  retrieved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf 'Listing token-visible services from Fastly service inventory...\n' >&2

  code="$(http_get_to_file "/service" "$tmp")"
  if [[ "$code" != 2* ]]; then
    printf '%s: Service inventory unavailable: GET /service returned HTTP %s; not falling back to audit-event inventory.\n' \
      "${PROGRAM_NAME:-ngwaf}" "$code" >&2
    printf '%s: Token-visible customer services: UNKNOWN\n' "${PROGRAM_NAME:-ngwaf}" >&2
    rm -f "$tmp"
    return 1
  fi

  if ! jq -e 'type == "array" or ((.data // null) | type == "array")' >/dev/null 2>&1 <"$tmp"; then
    printf '%s: Service inventory unavailable: GET /service returned invalid JSON shape; expected an array or an object with a data array.\n' \
      "${PROGRAM_NAME:-ngwaf}" >&2
    printf '%s: Token-visible customer services: UNKNOWN\n' "${PROGRAM_NAME:-ngwaf}" >&2
    rm -f "$tmp"
    return 1
  fi

  services="$(
    jq --arg cid "$cid" '
      def service_array:
        if type == "array" then .
        else (.data // [])
        end;
      service_array
      | map(select((.id // "") != "" and (.customer_id // "") == $cid))
      | unique_by(.id)
    ' "$tmp"
  )"
  {
    cat "$tmp"
    printf '%s\n' "$services"
  } | jq -s \
    --arg method "fastly-service-inventory" \
    --arg endpoint "GET /service" \
    --arg cid "$cid" \
    --arg retrieved_at "$retrieved_at" '
      .[0] as $raw
      | .[1] as $services
      | (
          if ($raw | type) == "array" then null
          else ($raw.meta.total // null)
          end
        ) as $reported_total
      | (
          if ($raw | type) == "array" then ($raw | length)
          else (($raw.data // []) | length)
          end
        ) as $returned_total
      | ($reported_total != null and $returned_total < $reported_total) as $truncated
      | (if $truncated then "PARTIAL" else "COMPLETE" end) as $status
      |
      {
        meta: {
          discovery_method: $method,
          source: $endpoint,
          customer_filter: "exact_customer_id",
          selected_customer_id: $cid,
          selected_total: (if $status == "COMPLETE" then ($services | length) else null end),
          selected_total_lower_bound: ($services | length),
          completeness: (if $status == "COMPLETE" then "token-visible" else "partial-token-visible" end),
          status: $status,
          evidence_type: "DIRECT",
          count: (if $status == "COMPLETE" then ($services | length) else null end),
          count_lower_bound: (if $status == "COMPLETE" then null else ($services | length) end),
          result: {
            status: $status,
            count: (if $status == "COMPLETE" then ($services | length) else null end),
            count_lower_bound: (if $status == "COMPLETE" then null else ($services | length) end),
            source: $endpoint,
            evidence_type: "DIRECT",
            retrieved_at: $retrieved_at,
            customer_scope: {
              customer_id: $cid,
              filter: "exact_customer_id",
              token_visibility_complete_for_customer: null
            },
            reason: (if $status == "COMPLETE" then "complete service inventory response" else "PARTIAL: service inventory response reported more rows than were returned" end),
            pagination: {
              returned_total: $returned_total,
              reported_total: $reported_total,
              truncated: $truncated
            },
            fallback_used: false,
            returned_total: $returned_total,
            reported_total: $reported_total
          },
          token_visibility_complete_for_customer: null,
          note: "Services are listed from Fastly service inventory, filtered to the selected customer ID, and deduplicated by service ID. This is token-visible inventory and does not prove that the token can see every service in the customer account."
        },
        data: $services
      }
    '
  rm -f "$tmp"
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
ngwaf	Edge WAF service attachments	ngwaf	security
origin_inspector	Origin Inspector	none	observability
websockets	WebSockets	none	delivery
EOF
}

normalize_services_for_vcl_size_json() {
  [[ $# -eq 1 ]] || die 'normalize_services_for_vcl_size_json requires <services-json>'

  local services_body="$1"
  jq '
    def platform:
      if (.type // "") == "vcl" then "CDN"
      elif (.type // "") == "wasm" then "Compute"
      else (.type // "unknown")
      end;
    def active_version:
      if (.active_version | type) == "object" then
        (.active_version.number // .active_version.version // .active_version.id // null)
      elif .active_version != null then .active_version
      else ((.environments // []) as $environments
        | if ($environments | type) == "array" then
            (([$environments[] | select((.name // "") == "production") | .active_version] | .[0]) // .version // null)
          else (.version // null)
          end)
      end;
    (.data // []) | map({
      id,
      name: (.name // ""),
      customer_id: (.customer_id // null),
      type: (.type // "unknown"),
      platform: platform,
      active_version: active_version,
      paused: (if has("paused") then .paused else false end)
    })
  ' <<<"$services_body"
}

resolve_vcl_size_service_json() {
  [[ $# -eq 2 ]] || die 'resolve_vcl_size_service_json requires <services-json> <service>'

  local services_body="$1"
  local selector="$2"
  local services
  services="$(normalize_services_for_vcl_size_json "$services_body")"

  printf '%s\n' "$services" |
    jq --arg selector "$selector" '
      (map(select(.id == $selector))) as $id_matches
      | if ($id_matches | length) == 1 then
          {status: "COMPLETE", service: $id_matches[0]}
        elif ($id_matches | length) > 1 then
          {status: "AMBIGUOUS", reason: "multiple services matched service ID", matches: $id_matches}
        else
          (map(select((.name | ascii_downcase) == ($selector | ascii_downcase)))) as $name_matches
          | if ($name_matches | length) == 1 then
              {status: "COMPLETE", service: $name_matches[0]}
            elif ($name_matches | length) > 1 then
              {status: "AMBIGUOUS", reason: "multiple services matched service name", matches: $name_matches}
            else
              {status: "NOT_FOUND", reason: "service not found in selected customer token-visible service inventory", matches: []}
            end
        end
    '
}

generated_vcl_line_count() {
  [[ $# -eq 1 ]] || die 'generated_vcl_line_count requires <content-file>'

  local path="$1"
  local bytes newline_count last_byte_hex
  bytes="$(wc -c <"$path" | tr -d '[:space:]')"
  if [[ "$bytes" == "0" ]]; then
    printf '0\n'
    return
  fi

  newline_count="$(LC_ALL=C tr -cd '\n' <"$path" | wc -c | tr -d '[:space:]')"
  last_byte_hex="$(tail -c 1 "$path" | od -An -tx1 | tr -d '[:space:]')"
  if [[ "$last_byte_hex" == "0a" ]]; then
    printf '%s\n' "$newline_count"
  else
    printf '%s\n' "$(( newline_count + 1 ))"
  fi
}

measure_generated_vcl_for_service_json() {
  [[ $# -eq 1 ]] || die 'measure_generated_vcl_for_service_json requires <service-json>'

  local service_json="$1"
  local sid name service_type platform active_version endpoint retrieved_at
  local body_tmp content_tmp code bytes lines kib status reason

  sid="$(jq -r '.id // empty' <<<"$service_json")"
  name="$(jq -r '.name // ""' <<<"$service_json")"
  service_type="$(jq -r '.type // "unknown"' <<<"$service_json")"
  platform="$(jq -r '.platform // "unknown"' <<<"$service_json")"
  active_version="$(jq -r '.active_version // empty' <<<"$service_json")"
  retrieved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$service_type" != "vcl" ]]; then
    jq -n \
      --arg id "$sid" \
      --arg name "$name" \
      --arg type "$service_type" \
      --arg platform "$platform" \
      --arg active_version "$active_version" \
      '{
        id: $id,
        name: $name,
        type: $type,
        platform: $platform,
        active_version: (if $active_version == "" then null else $active_version end),
        generated_vcl: {
          status: "NOT_APPLICABLE",
          evidence_type: "INFORMATIONAL",
          source: null,
          retrieved_at: null,
          reason: "Generated VCL is not applicable to non-VCL/Compute services",
          measurements: {
            evidence_type: "DERIVED",
            bytes: null,
            lines: null,
            kib: null
          }
        }
      }'
    return
  fi

  if [[ -z "$active_version" || "$active_version" == "null" ]]; then
    jq -n \
      --arg id "$sid" \
      --arg name "$name" \
      --arg type "$service_type" \
      --arg platform "$platform" \
      '{
        id: $id,
        name: $name,
        type: $type,
        platform: $platform,
        active_version: null,
        generated_vcl: {
          status: "UNKNOWN",
          evidence_type: "UNKNOWN",
          source: "GET /service/{service_id}/version/{version}/generated_vcl",
          retrieved_at: null,
          reason: "active version could not be established",
          measurements: {
            evidence_type: "DERIVED",
            bytes: null,
            lines: null,
            kib: null
          }
        }
      }'
    return
  fi

  endpoint="/service/$sid/version/$active_version/generated_vcl"
  body_tmp="$(mktemp)"
  content_tmp="$(mktemp)"
  chmod 600 "$body_tmp" "$content_tmp" 2>/dev/null || true

  code="$(http_get_to_file "$endpoint" "$body_tmp")"
  if [[ "$code" == 2* ]] && jq -e '((type == "object" and (.content | type) == "string") or type == "string")' >/dev/null 2>&1 <"$body_tmp"; then
    if jq -j 'if type == "object" then .content else . end' "$body_tmp" >"$content_tmp" 2>/dev/null; then
      bytes="$(wc -c <"$content_tmp" | tr -d '[:space:]')"
      lines="$(generated_vcl_line_count "$content_tmp")"
      kib="$(jq -n --argjson bytes "$bytes" '($bytes / 1024 * 100 | round) / 100')"
      status='COMPLETE'
      reason='generated VCL retrieved and measured'
    else
      status='UNKNOWN'
      reason='generated VCL response content could not be decoded'
      bytes='null'
      lines='null'
      kib='null'
    fi
  elif [[ "$code" == 2* ]]; then
    status='UNKNOWN'
    reason='generated VCL response did not contain a supported content string'
    bytes='null'
    lines='null'
    kib='null'
  else
    status='UNKNOWN'
    reason="generated VCL query failed: HTTP $code"
    bytes='null'
    lines='null'
    kib='null'
  fi

  rm -f "$body_tmp" "$content_tmp"

  jq -n \
    --arg id "$sid" \
    --arg name "$name" \
    --arg type "$service_type" \
    --arg platform "$platform" \
    --arg active_version "$active_version" \
    --arg status "$status" \
    --arg source "GET /service/{service_id}/version/{version}/generated_vcl" \
    --arg endpoint "$endpoint" \
    --arg retrieved_at "$retrieved_at" \
    --arg reason "$reason" \
    --argjson bytes "$bytes" \
    --argjson lines "$lines" \
    --argjson kib "$kib" '
      {
        id: $id,
        name: $name,
        type: $type,
        platform: $platform,
        active_version: $active_version,
        generated_vcl: {
          status: $status,
          evidence_type: (if $status == "COMPLETE" then "DIRECT" else "UNKNOWN" end),
          source: $source,
          endpoint: $endpoint,
          retrieved_at: (if $status == "COMPLETE" then $retrieved_at else null end),
          reason: $reason,
          measurements: {
            evidence_type: "DERIVED",
            bytes: $bytes,
            lines: $lines,
            kib: $kib
          }
        }
      }
    '
}

# Return one normalized JSON object for a service-level product. Prefer the
# efficient customer-level enabled-services endpoint when it is demonstrably
# scoped to the selected customer. If that endpoint is unavailable or reports a
# different customer, fall back to read-only per-service enablement probes.

discover_product_json() {
  [[ $# -ge 5 && $# -le 6 ]] || die 'discover_product_json requires <id> <label> <config-kind> <category> <services-json> [request-config]'

  local product_id="$1"
  local label="$2"
  local config_kind="$3"
  local category="$4"
  local services_body="$5"
  local request_config="${6:-true}"
  local cid list_tmp parse_tmp list_code returned_cid method enabled_ids raw_enabled_ids unknown_checks
  local fallback_reason disabled_count forced_status forced_reason
  local probe_tmp probe_code sid configs_tmp configs retrieved_at selected_services
  [[ "$request_config" == 'true' || "$request_config" == 'false' ]] ||
    die 'discover_product_json request-config must be true or false'

  cid="$(current_cid)"
  retrieved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  list_tmp=''
  parse_tmp=''
  list_code=''
  enabled_ids='[]'
  raw_enabled_ids='[]'
  unknown_checks='[]'
  returned_cid=''
  method='customer-list'
  fallback_reason=''
  disabled_count=0
  forced_status=''
  forced_reason=''
  selected_services='[]'

  if ! selected_services="$(
    jq -c '
      def selected_array:
        if type == "object" and (.data | type) == "array" then .data
        elif type == "array" then .
        else error("selected service inventory is missing a data array")
        end;
      selected_array as $services
      | if all($services[]; type == "object" and ((.id // "") | type == "string" and length > 0)) then
          $services
        else
          error("selected service inventory contains service objects without string id")
        end
    ' <<<"$services_body" 2>/dev/null
  )"; then
    selected_services='[]'
    method='selected-service-inventory-parse-error'
    forced_status='UNKNOWN'
    forced_reason='selected service inventory could not be normalized'
    unknown_checks='[]'
  else
    list_tmp="$(mktemp)"
    parse_tmp="$(mktemp)"
    list_code="$(
      http_get_to_file "/enabled-products/v1/$product_id/services" "$list_tmp" \
        --data-urlencode "customer_id=$cid"
    )"
  fi

  if [[ -z "$forced_status" && "$list_code" == 2* ]]; then
    if jq --arg cid "$cid" '
      def service_id:
        if type == "string" then .
        elif type == "object" then
          (
            .id
            // .service_id
            // .service.id
            // .attributes.service_id
            // .attributes.id
            // empty
          )
        else empty
        end;
      def ids_from($items):
        [$items[] | service_id | select(type == "string" and length > 0)];
      def customer:
        (.customer.id // .customer_id // .meta.customer_id // .data.customer_id // null);
      if type == "object" then
        if has("services") then
          if (.services | type) == "array" then
            {ok: true, collection: "services", customer_id: customer, ids: ids_from(.services)}
          else
            {ok: false, reason: "services field is present but is not an array"}
          end
        elif has("data") then
          if (.data | type) == "array" then
            {ok: true, collection: "data", customer_id: customer, ids: ids_from(.data)}
          else
            {ok: false, reason: "data field is present but is not an array"}
          end
        else
          {ok: false, reason: "missing services or data collection"}
        end
      elif type == "array" then
        {ok: true, collection: "root", customer_id: null, ids: ids_from(.)}
      else
        {ok: false, reason: "response root is not an object or array"}
      end
    ' "$list_tmp" >"$parse_tmp" 2>/dev/null; then
      if [[ "$(jq -r '.ok' "$parse_tmp")" == 'true' ]]; then
        returned_cid="$(jq -r '.customer_id // empty' "$parse_tmp")"
        if [[ -n "$returned_cid" && "$returned_cid" != "$cid" ]]; then
          method='per-service-probe'
          fallback_reason="customer-list returned customer.id=$returned_cid"
        else
          raw_enabled_ids="$(jq '.ids' "$parse_tmp")"
        fi
      else
        method='customer-list-parse-error'
        forced_status='UNKNOWN'
        forced_reason="$(jq -r '.reason // "enabled-product response did not contain a recognized service collection"' "$parse_tmp")"
      fi
    else
      method='customer-list-parse-error'
      forced_status='UNKNOWN'
      forced_reason='enabled-product response was not valid JSON'
    fi

    if [[ "$method" == 'customer-list' ]]; then
      enabled_ids="$(
        printf '%s\n%s\n' "$selected_services" "$raw_enabled_ids" |
          jq -s '
            .[0] as $services
            | (.[1] | unique) as $enabled
            | [$services[] | select(.id as $id | $enabled | index($id) != null) | .id]
          '
      )"
    fi
  elif [[ -z "$forced_status" ]]; then
    method='per-service-probe'
    fallback_reason="customer-list returned HTTP $list_code"
  fi

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
        404) disabled_count=$(( disabled_count + 1 )) ;;
        *)
          jq -n --arg service_id "$sid" --arg status "$probe_code" \
            '{service_id: $service_id, http_status: $status}' >>"$unknown_tmp"
          ;;
      esac
      rm -f "$probe_tmp"
    done < <(jq -r '.[].id' <<<"$selected_services")

    enabled_ids="$(jq -Rn '[inputs | select(length > 0)]' <"$enabled_tmp")"
    raw_enabled_ids="$enabled_ids"
    unknown_checks="$(jq -s '.' "$unknown_tmp")"
    rm -f "$enabled_tmp" "$unknown_tmp"
  elif [[ -n "$forced_status" ]]; then
    unknown_checks="$(
      jq -r '.[].id' <<<"$selected_services" |
        jq -Rn --arg status 'parse_error' '[inputs | select(length > 0) | {service_id: ., http_status: $status}]'
    )"
  fi
  [[ -z "$list_tmp" ]] || rm -f "$list_tmp"
  [[ -z "$parse_tmp" ]] || rm -f "$parse_tmp"

  # Fetch configuration only when explicitly requested for products whose
  # public API exposes a useful configuration resource today: NGWAF, Bot
  # Management, and DDoS Protection.
  configs_tmp="$(mktemp)"
  if [[ "$config_kind" != 'none' && "$request_config" == 'true' ]]; then
    while IFS= read -r sid; do
      [[ -n "$sid" ]] || continue
      probe_tmp="$(mktemp)"
      probe_code="$(http_get_to_file "/enabled-products/v1/$product_id/services/$sid/configuration" "$probe_tmp")"
      if [[ "$probe_code" == 2* ]] && jq -e 'type == "object"' >/dev/null 2>&1 <"$probe_tmp"; then
        jq '.configuration // {}' "$probe_tmp" |
          jq -s \
            --arg service_id "$sid" \
            '.[0] as $configuration
             | {
                 service_id: $service_id,
                 configuration: $configuration,
                 configuration_http_status: 200,
                 configuration_status: "RETRIEVED",
                 configuration_requested: true
               }' >>"$configs_tmp"
      else
        jq -n \
          --arg service_id "$sid" \
          --arg status "$probe_code" \
          '{
             service_id: $service_id,
             configuration: null,
             configuration_http_status: $status,
             configuration_status: "UNAVAILABLE",
             configuration_requested: true
           }' >>"$configs_tmp"
      fi
      rm -f "$probe_tmp"
    done < <(jq -r '.[]' <<<"$enabled_ids")
  elif [[ "$config_kind" != 'none' ]]; then
    while IFS= read -r sid; do
      [[ -n "$sid" ]] || continue
      jq -n \
        --arg service_id "$sid" \
        '{
           service_id: $service_id,
           configuration: null,
           configuration_http_status: null,
           configuration_status: "NOT_REQUESTED",
           configuration_requested: false
         }' >>"$configs_tmp"
    done < <(jq -r '.[]' <<<"$enabled_ids")
  fi
  configs="$(jq -s '.' "$configs_tmp")"
  rm -f "$configs_tmp"

  {
    printf '%s\n' "$selected_services"
    printf '%s\n%s\n%s\n%s\n' "$enabled_ids" "$configs" "$unknown_checks" "$raw_enabled_ids"
  } | jq -s \
    --arg id "$product_id" \
    --arg label "$label" \
    --arg category "$category" \
    --arg cid "$cid" \
    --arg discovery_method "$method" \
    --arg fallback_reason "$fallback_reason" \
    --arg list_customer_id "$returned_cid" \
    --arg retrieved_at "$retrieved_at" \
    --arg forced_status "$forced_status" \
    --arg forced_reason "$forced_reason" \
    --arg config_kind "$config_kind" \
    --arg request_config "$request_config" \
    --argjson disabled_count "$disabled_count" '
      def platform:
        if (.type // "") == "vcl" then "CDN"
        elif (.type // "") == "wasm" then "Compute"
        else (.type // "unknown")
        end;
      def active_version:
        if (.active_version | type) == "object" then
          (.active_version.number // .active_version.version // .active_version.id // null)
        elif .active_version != null then .active_version
        else ((.environments // []) as $environments
          | if ($environments | type) == "array" then
              (([$environments[] | select((.name // "") == "production") | .active_version] | .[0]) // .version // null)
            else (.version // null)
            end)
        end;
      .[0] as $all_services
      | .[1] as $enabled_ids
      | .[2] as $configs
      | .[3] as $unknown_checks
      | .[4] as $raw_enabled_ids
      | ($raw_enabled_ids | unique) as $raw_unique_enabled_ids
      | ([$all_services[].id] | unique) as $selected_service_ids
      | ($raw_unique_enabled_ids - $selected_service_ids) as $rejected_service_ids
      | (($raw_enabled_ids | length) - ($raw_unique_enabled_ids | length)) as $duplicate_returned_count
      | ($raw_enabled_ids | group_by(.) | map(select(length > 1) | .[0])) as $duplicate_returned_service_ids
      | ($all_services | length) as $service_total
      | ($enabled_ids | length) as $enabled_count
      | ($unknown_checks | length) as $unknown_count
      | ([$configs[]? | select(.configuration_status == "RETRIEVED")] | length) as $configuration_retrieved_count
      | ([$configs[]? | select(.configuration_status == "UNAVAILABLE")] | length) as $configuration_unavailable_count
      | ([$configs[]? | select(.configuration_status == "NOT_REQUESTED")] | length) as $configuration_not_requested_count
      | (
          if $config_kind == "none" then "NOT_APPLICABLE"
          elif $enabled_count == 0 then "NOT_APPLICABLE"
          elif $request_config != "true" then "NOT_REQUESTED"
          elif $configuration_unavailable_count == 0 then "COMPLETE"
          elif $configuration_retrieved_count == 0 then "UNAVAILABLE"
          else "PARTIAL"
          end
        ) as $configuration_status
      | (
          if $discovery_method == "customer-list" then ($service_total - $enabled_count)
          else $disabled_count
          end
        ) as $effective_disabled_count
      | (
          if $forced_status != "" then $forced_status
              elif $unknown_count == 0 then "COMPLETE"
              elif $unknown_count == $service_total then "UNKNOWN"
              else "PARTIAL"
              end
        ) as $status
      | (if $status == "UNKNOWN" then "UNKNOWN" else "DIRECT" end) as $evidence_type
      | (
          if $status == "COMPLETE" then $enabled_count
          else null
          end
        ) as $count
      | (
          if $status == "PARTIAL" then $enabled_count
          else null
          end
        ) as $count_lower_bound
      | {
        id: $id,
        label: $label,
        category: $category,
        discovery_method: $discovery_method,
        product_list_customer_id: (if $list_customer_id == "" then null else $list_customer_id end),
        status: $status,
        count: $count,
        count_lower_bound: $count_lower_bound,
        evidence_type: $evidence_type,
        result: {
          status: $status,
          count: $count,
          count_lower_bound: $count_lower_bound,
          source: $discovery_method,
          api: "GET /enabled-products/v1/" + $id + "/services",
          evidence_type: $evidence_type,
          retrieved_at: $retrieved_at,
          customer_scope: {
            customer_id: $cid,
            selected_customer_id: $cid,
            validation: "selected customer service inventory validation"
          },
          reason: (
            if $forced_reason != "" then "query failed: " + $forced_reason
            elif $status == "UNKNOWN" and $unknown_count == $service_total and $service_total == 0 then "query failed: product inventory unavailable"
            elif $status == "COMPLETE" and $fallback_reason == "" and ($rejected_service_ids | length) == 0 and $duplicate_returned_count == 0 then "complete product service list"
            elif $status == "COMPLETE" and $fallback_reason == "" then "complete product service list; rejected " + (($rejected_service_ids | length) | tostring) + " unvalidated service ID(s); ignored " + ($duplicate_returned_count | tostring) + " duplicate returned service ID(s)"
            elif $status == "COMPLETE" then "complete per-service fallback after " + $fallback_reason
            elif $status == "PARTIAL" then "query partially failed: " + ($unknown_count | tostring) + " of " + ($service_total | tostring) + " service check(s) unknown" + (if $fallback_reason == "" then "" else "; fallback reason: " + $fallback_reason end)
            else "query failed: all " + ($service_total | tostring) + " service check(s) unknown" + (if $fallback_reason == "" then "" else "; fallback reason: " + $fallback_reason end)
            end
          ),
          http_statuses: ([$unknown_checks[].http_status] | unique),
          pagination: null,
          fallback_used: ($discovery_method != "customer-list"),
          fallback_reason: (if $fallback_reason == "" then null else $fallback_reason end),
          services_checked: $service_total,
          enabled_count: $enabled_count,
          disabled_count: $effective_disabled_count,
          unknown_count: $unknown_count,
          rejected_count: ($rejected_service_ids | length),
          rejected_service_ids: $rejected_service_ids,
          duplicate_returned_count: $duplicate_returned_count,
          duplicate_returned_service_ids: $duplicate_returned_service_ids,
          configuration: {
            status: $configuration_status,
            requested: ($request_config == "true" and $config_kind != "none" and $enabled_count > 0),
            kind: $config_kind,
            source: (
              if $config_kind == "none" or $request_config != "true" or $enabled_count == 0 then null
              else "GET /enabled-products/v1/" + $id + "/services/{service_id}/configuration"
              end
            ),
            evidence_type: (
              if $configuration_status == "COMPLETE" then "DIRECT"
              elif $configuration_status == "NOT_APPLICABLE" then "INFORMATIONAL"
              else "UNKNOWN"
              end
            ),
            retrieved_count: $configuration_retrieved_count,
            unavailable_count: $configuration_unavailable_count,
            not_requested_count: $configuration_not_requested_count
          }
        },
        enabled_count: $enabled_count,
        unknown_check_count: $unknown_count,
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
              paused: (if $svc | has("paused") then $svc.paused else false end),
              configuration: ($cfg.configuration // null),
              configuration_http_status: ($cfg.configuration_http_status // null),
              configuration_status: (
                $cfg.configuration_status //
                (if $config_kind == "none" then "NOT_APPLICABLE"
                 elif $request_config != "true" then "NOT_REQUESTED"
                 else "UNAVAILABLE"
                 end)
              ),
              configuration_evidence_type: (
                ($cfg.configuration_status //
                  (if $config_kind == "none" then "NOT_APPLICABLE"
                   elif $request_config != "true" then "NOT_REQUESTED"
                   else "UNAVAILABLE"
                   end)) as $cfg_status
                | if $cfg_status == "RETRIEVED" then "DIRECT"
                  elif $cfg_status == "NOT_APPLICABLE" then "INFORMATIONAL"
                  else "UNKNOWN"
                  end
              ),
              configuration_source: (
                if $config_kind == "none" or $request_config != "true" then null
                else "GET /enabled-products/v1/" + $id + "/services/" + $svc.id + "/configuration"
                end
              ),
              configuration_requested: ($cfg.configuration_requested // ($request_config == "true" and $config_kind != "none"))
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
  services_body="$(get_customer_services --details)" ||
    die 'service inventory unavailable; cannot safely use audit-event-derived service counts as a substitute'

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
          else ((.environments // []) as $environments
            | if ($environments | type) == "array" then
                (([$environments[] | select((.name // "") == "production") | .active_version] | .[0]) // .version // null)
              else (.version // null)
              end)
          end;
        .[0] as $customer
        | .[1] as $body
        | ($body.data // []) as $services
        | {
            customer: {id: ($customer.id // null), name: ($customer.name // null)},
            service_discovery: ($body.meta // {}),
            summary: {
              total: ($services | length),
              cdn: ([$services[] | select((.type // "") == "vcl")] | length),
              compute: ([$services[] | select((.type // "") == "wasm")] | length),
              other: ([$services[] | select(((.type // "") != "vcl") and ((.type // "") != "wasm"))] | length),
              paused: (if any($services[]; .paused == null) then null else ([$services[] | select(.paused == true)] | length) end),
              discovery_method: ($body.meta.discovery_method // null),
              source: ($body.meta.source // $body.meta.result.source // null),
              status: ($body.meta.status // $body.meta.result.status // "UNKNOWN"),
              evidence_type: ($body.meta.evidence_type // $body.meta.result.evidence_type // "UNKNOWN"),
              count: ($body.meta.count // $body.meta.result.count // null),
              count_lower_bound: ($body.meta.count_lower_bound // $body.meta.result.count_lower_bound // null),
              token_visibility_complete_for_customer: ($body.meta.token_visibility_complete_for_customer // null),
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
                  paused: (if has("paused") then .paused else false end),
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
    "Token-visible customer services: \(.summary.total) total — \(.summary.cdn) CDN, \(.summary.compute) Compute, \(.summary.other) other; \(.summary.paused // "UNKNOWN") paused",
    "Service inventory source: \(.summary.source // .summary.discovery_method // "unknown")",
    "Inventory completeness: \(.summary.completeness)"
  ' <<<"$normalized"
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

service_domains_json() {
  [[ $# -eq 2 ]] || die 'service_domains_json requires <service-id> <version>'
  local sid="$1" version="$2" endpoint='' tmp code='' domains='null'
  local status=UNKNOWN reason='no active version found for CDN service' retrieved_at
  retrieved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$version" =~ ^[1-9][0-9]*$ ]]; then
    endpoint="/service/$(urlencode "$sid")/version/$version/domain"
    tmp="$(mktemp)"
    if code="$(http_get_to_file "$endpoint" "$tmp")"; then
      if [[ "$code" == 000 ]]; then
        reason='Fastly domain inventory request failed: network or transport error'
      elif [[ "$code" == 2* ]]; then
        if domains="$(jq --arg sid "$sid" --arg version "$version" '
          if type != "array" then error("expected domain array")
          elif all(.[]; type == "object" and
            (.name | type == "string" and length > 0) and
            (.service_id == null or .service_id == $sid) and
            (.version == null or (.version | tostring) == $version)) then
              sort_by(.name) | unique_by(.name) | map({name})
          else error("invalid domain object or mismatched service/version") end
        ' "$tmp" 2>/dev/null)"; then
          status=COMPLETE
          reason='configured Fastly domain objects retrieved'
        else
          domains='null'
          reason='Fastly domain inventory response was malformed or did not contain a valid domain array for this service/version'
        fi
      else
        reason="Fastly domain inventory request failed: HTTP $code"
      fi
    else
      reason='Fastly domain inventory request failed: network or transport error'
    fi
    rm -f "$tmp"
  fi
  printf '%s\n' "$domains" | jq --arg sid "$sid" --arg version "$version" \
    --arg status "$status" --arg reason "$reason" --arg endpoint "$endpoint" \
    --arg code "$code" --arg retrieved_at "$retrieved_at" '{
      service_id: $sid, version: (try ($version | tonumber) catch null),
      status: $status, domains: ., domain_count: (if . == null then null else length end),
      reason: $reason, retrieved_at: $retrieved_at,
      source: "GET /service/{service_id}/version/{version}/domain",
      endpoint: (if $endpoint == "" then null else $endpoint end),
      http_status: (if $code == "000" or $code == "" then null else try ($code | tonumber) catch null end)
    }'
}

cmd_service_domains() {
  local selector='' version='' version_source=active json=false inventory resolved service result payload enriched
  while (( $# > 0 )); do
    case "$1" in
      --json) json=true; shift ;;
      --version)
        (( $# >= 2 )) || die '--version requires a positive version number'
        [[ "$2" =~ ^[1-9][0-9]*$ ]] || die '--version requires a positive version number'
        version="$2"; version_source=explicit; shift 2 ;;
      --*) die "unknown service domains option: $1" ;;
      *) [[ -z "$selector" ]] || die 'specify one CDN service'; selector="$1"; shift ;;
    esac
  done
  [[ -n "$selector" ]] || die 'usage: fastly-audit service domains <service> [--version N] [--json]'
  inventory="$(get_customer_services)" || die 'service inventory unavailable; cannot resolve CDN service safely'
  resolved="$(resolve_vcl_size_service_json "$inventory" "$selector")" || return 1
  case "$(jq -r .status <<<"$resolved")" in
    COMPLETE) service="$(jq .service <<<"$resolved")" ;;
    AMBIGUOUS) die "CDN service selector is ambiguous: $selector" ;;
    *) die "could not resolve CDN service '$selector' in selected customer inventory" ;;
  esac
  [[ "$(jq -r .type <<<"$service")" == vcl ]] || die "service '$selector' is not a CDN/VCL service"
  if [[ "$version_source" == active && "$(jq -r .meta.source <<<"$inventory")" == 'GET /search/services' ]]; then
    enriched="$(enrich_customer_services_json "$(jq '{data: [.], meta: {}}' <<<"$service")" "$(current_cid)")" || return 1
    service="$(normalize_services_for_vcl_size_json "$enriched" | jq '.[0]')" || return 1
  fi
  if [[ "$version_source" == active ]]; then
    version="$(jq -r '.active_version // ""' <<<"$service")"
  fi
  result="$(service_domains_json "$(jq -r .id <<<"$service")" "$version")" || return 1
  payload="$(printf '%s\n%s\n' "$service" "$result" | jq -s --arg version_source "$version_source" '
    .[0] as $s | .[1] + {command: "service domains", service: $s.name,
      customer_id: $s.customer_id, version_source: $version_source,
      limitations: ["Configured Fastly domains do not prove identical NGWAF behavior for every hostname/path."]}')" || return 1
  if [[ "$json" == true ]]; then
    jq . <<<"$payload"
  else
    jq -r '"CDN service: " + .service, "Service ID: " + .service_id,
      "Version: " + (.version // "UNKNOWN" | tostring), "Domain inventory status: " + .status,
      (if .status == "COMPLETE" then
        "Configured Fastly domains:", (.domains[].name),
        (if .domain_count == 0 then "NO CONFIGURED FASTLY DOMAINS OBSERVED" else empty end),
        "Total configured domains: " + (.domain_count | tostring)
       else "ERROR: " + .reason end)' <<<"$payload"
  fi
  [[ "$(jq -r .status <<<"$payload")" == COMPLETE ]]
}

cmd_service_vcl_size() {
  [[ $# -ge 1 && $# -le 2 ]] || die 'usage: fastly-audit service vcl-size <service> [--json]'

  local mode='' selector='' arg cid customer services_body resolved service result payload
  for arg in "$@"; do
    case "$arg" in
      --json) mode='--json' ;;
      *)
        [[ -z "$selector" ]] || die 'usage: fastly-audit service vcl-size <service> [--json]'
        selector="$arg"
        ;;
    esac
  done
  [[ -n "$selector" ]] || die 'usage: fastly-audit service vcl-size <service> [--json]'

  cid="$(current_cid)"
  customer="$(get "/customer/$cid")"
  services_body="$(get_customer_services)" ||
    die 'service inventory unavailable; cannot resolve service safely'
  resolved="$(resolve_vcl_size_service_json "$services_body" "$selector")"

  case "$(jq -r '.status' <<<"$resolved")" in
    COMPLETE)
      service="$(jq '.service' <<<"$resolved")"
      if [[ "$(jq -r .meta.source <<<"$services_body")" == 'GET /search/services' && "$(jq -r .type <<<"$service")" == vcl ]]; then
        local enriched
        enriched="$(enrich_customer_services_json "$(jq '{data: [.], meta: {}}' <<<"$service")" "$cid")" || return 1
        service="$(normalize_services_for_vcl_size_json "$enriched" | jq '.[0]')" || return 1
      fi
      ;;
    AMBIGUOUS)
      die "service selector is ambiguous: $selector"
      ;;
    *)
      die "service not found in selected customer token-visible service inventory: $selector"
      ;;
  esac

  result="$(measure_generated_vcl_for_service_json "$service")"
  payload="$(
    printf '%s\n%s\n' "$customer" "$result" |
      jq -s '
        .[0] as $customer
        | .[1] as $service
        | {
            schema_version: 1,
            command: "service vcl-size",
            customer: {id: ($customer.id // null), name: ($customer.name // null)},
            service: $service,
            limitations: [
              "Generated VCL size is measured from Fastly active generated VCL for the active service version.",
              "Measurements are byte and line counts of generated VCL content only; response JSON, headers, and transport overhead are not counted.",
              "Generated VCL content is not included in normal output."
            ]
          }
      '
  )"

  if [[ "$mode" == '--json' ]]; then
    jq . <<<"$payload"
    return
  fi

  jq -r '
    def comma:
      tostring | split("") | reverse | to_entries
      | map(if .key > 0 and (.key % 3) == 0 then .value + "," else .value end)
      | reverse | join("");
    def size:
      if . == null then "UNKNOWN" else ((. | tostring) + " KiB") end;
    "Service: \(.service.name)",
    "Service ID: \(.service.id)",
    "Type: \(.service.platform)",
    "Active version: \(.service.active_version // "UNKNOWN")",
    "",
    "Generated VCL",
    "Lines: \(.service.generated_vcl.measurements.lines | if . == null then "UNKNOWN" else comma end)",
    "Bytes: \(.service.generated_vcl.measurements.bytes | if . == null then "UNKNOWN" else comma end)",
    "Size: \(.service.generated_vcl.measurements.kib | size)",
    "Status: \(.service.generated_vcl.status)",
    "Reason: \(.service.generated_vcl.reason)"
  ' <<<"$payload"
}

cmd_customer_vcl_size() {
  [[ $# -le 1 ]] || die 'usage: fastly-audit customer vcl-size [--json]'

  local mode="${1:-}"
  local cid customer services_body services results_tmp result payload
  [[ -z "$mode" || "$mode" == '--json' ]] || die 'usage: fastly-audit customer vcl-size [--json]'

  cid="$(current_cid)"
  customer="$(get "/customer/$cid")"
  services_body="$(get_customer_services --details)" ||
    die 'service inventory unavailable; cannot build customer VCL size report safely'
  services="$(normalize_services_for_vcl_size_json "$services_body")"
  results_tmp="$(mktemp)"

  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    result="$(measure_generated_vcl_for_service_json "$service")"
    printf '%s\n' "$result" >>"$results_tmp"
  done < <(jq -c '.[]' <<<"$services")

  payload="$(
    printf '%s\n%s\n%s\n' "$customer" "$services_body" "$(jq -s '.' "$results_tmp")" |
      jq -s '
        .[0] as $customer
        | .[1] as $services_body
        | .[2] as $services
        | ($services | map(select(.type == "vcl"))) as $vcl_services
        | {
            schema_version: 1,
            command: "customer vcl-size",
            customer: {id: ($customer.id // null), name: ($customer.name // null)},
            summary: {
              total_token_visible_services: ($services | length),
              vcl_services: ($vcl_services | length),
              measured: ([$services[] | select(.generated_vcl.status == "COMPLETE")] | length),
              unknown: ([$services[] | select(.generated_vcl.status == "UNKNOWN")] | length),
              not_applicable: ([$services[] | select(.generated_vcl.status == "NOT_APPLICABLE")] | length),
              compute_skipped: ([$services[] | select(.type == "wasm")] | length),
              source: "GET /service/{service_id}/version/{version}/generated_vcl",
              service_inventory: ($services_body.meta.result // $services_body.meta // {})
            },
            services: (
              $services
              | sort_by(-(.generated_vcl.measurements.bytes // -1), .name)
            ),
            limitations: [
              "Generated VCL content is not included in normal output.",
              "Only VCL/CDN services are queried for generated VCL; Compute services are not applicable.",
              "Customer scope is the selected customer token-visible service inventory filtered and deduplicated by service ID."
            ]
          }
      '
  )"
  rm -f "$results_tmp"

  if [[ "$mode" == '--json' ]]; then
    jq . <<<"$payload"
    return
  fi

  jq -r '
    "Customer: \(.customer.name) (\(.customer.id))",
    "VCL services measured: \(.summary.measured)",
    "Unknown: \(.summary.unknown)",
    "Compute skipped: \(.summary.compute_skipped)"
  ' <<<"$payload"

  printf '\n'
  jq -r '
    def size:
      if . == null then "UNKNOWN" else ((. | tostring) + " KiB") end;
    ["SERVICE", "VERSION", "LINES", "BYTES", "SIZE"],
    (
      .services[]
      | select(.generated_vcl.status == "COMPLETE")
      | [
          .name,
          (.active_version | tostring),
          (.generated_vcl.measurements.lines | tostring),
          (.generated_vcl.measurements.bytes | tostring),
          (.generated_vcl.measurements.kib | size)
        ]
    )
    | @tsv
  ' <<<"$payload" | human_table

  if jq -e '.summary.unknown > 0' >/dev/null <<<"$payload"; then
    printf '\nUNKNOWN\n'
    jq -r '
      ["SERVICE", "VERSION", "REASON"],
      (
        .services[]
        | select(.generated_vcl.status == "UNKNOWN")
        | [
            .name,
            (.active_version // "-" | tostring),
            (.generated_vcl.reason // "unknown")
          ]
      )
      | @tsv
    ' <<<"$payload" | human_table
  fi
}

cmd_products() {
  [[ $# -le 1 ]] || die 'usage: ngwaf products [--json]'

  local mode="${1:-}"
  local cid customer services_body products payload
  [[ -z "$mode" || "$mode" == '--json' ]] || die 'usage: ngwaf products [--json]'

  cid="$(current_cid)"
  customer="$(get "/customer/$cid")"
  services_body="$(get_customer_services)" ||
    die 'service inventory unavailable; cannot safely use audit-event-derived service counts as a substitute'
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
          note: "Service-level product inventory is evaluated against the selected-customer token-visible service inventory; the discovery provenance identifies service search or legacy GET /service. Account-level products without a service mapping are not included. Non-2xx checks other than 404 are reported as unknown rather than treated as disabled."
        }
      '
  )"

  if [[ "$mode" == '--json' ]]; then
    jq . <<<"$payload"
    return
  fi

  jq -r '
    "Customer: \(.customer.name) (\(.customer.id))",
    "Token-visible customer services scanned: \(.services_scanned)",
    "Service inventory source: \(.service_discovery.source // .service_discovery.discovery_method // "unknown")",
    "Service-level products checked: \(.product_definitions_scanned)"
  ' <<<"$payload"

  printf '\nPRODUCT SUMMARY\n'
  jq -r '
    def count_display:
      if (.result.status // .status) == "COMPLETE" then
        ((.result.count // .enabled_count // 0) | tostring) + "/" + ((.result.services_checked // 0) | tostring)
      elif (.result.status // .status) == "PARTIAL" then
        ">=" + ((.result.count_lower_bound // .enabled_count // 0) | tostring) + "/" + ((.result.services_checked // 0) | tostring)
      else "UNKNOWN"
      end;
    ["CATEGORY", "PRODUCT", "SERVICES", "STATUS", "DISCOVERY"],
    (
      .products
      | sort_by(.category, .label)
      | .[]
      | [
          (.category | ascii_upcase),
          .label,
          count_display,
          (.result.status // .status // "UNKNOWN"),
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
  services_body="$(get_customer_services --details)" ||
    die 'service inventory unavailable; cannot safely use audit-event-derived service counts as a substitute'
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
              paused: (if any($services[]; .paused == null) then null else ([$services[] | select(.paused == true)] | length) end),
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
                      else ((.environments // []) as $environments
                        | if ($environments | type) == "array" then (([$environments[] | select((.name // "") == "production") | .active_version] | .[0]) // .version // null)
                          else (.version // null)
                          end)
                      end
                    ),
                    paused: (if has("paused") then .paused else false end)
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
              "Service inventory contains token-visible services from Fastly service inventory filtered to the selected customer ID; it does not prove that the token can see every service in the customer account.",
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
    "EDGE SERVICES (TOKEN-VISIBLE)",
    "  Total:   \(.edge_services.total)",
    "  CDN:     \(.edge_services.cdn)",
    "  Compute: \(.edge_services.compute)",
    "  Other:   \(.edge_services.other)",
    "  Paused:  \(.edge_services.paused // "UNKNOWN")",
    "  Source:  \(.edge_services.discovery.source // .edge_services.discovery.discovery_method // "unknown")",
    "  Completeness: \(.edge_services.discovery.completeness // "unknown")",
    "",
    "NGWAF",
    "  Workspaces: \(.ngwaf.workspace_count)"
  ' <<<"$payload"

  printf '\nSERVICE-LEVEL PRODUCTS\n'
  jq -r '
    def count_display:
      if (.result.status // .status) == "COMPLETE" then
        ((.result.count // .enabled_count // 0) | tostring) + "/" + ((.result.services_checked // 0) | tostring)
      elif (.result.status // .status) == "PARTIAL" then
        ">=" + ((.result.count_lower_bound // .enabled_count // 0) | tostring) + "/" + ((.result.services_checked // 0) | tostring)
      else "UNKNOWN"
      end;
    ["CATEGORY", "PRODUCT", "SERVICES", "STATUS"],
    (
      .service_products.products
      | sort_by(.category, .label)
      | .[]
      | [
          (.category | ascii_upcase),
          .label,
          count_display,
          (.result.status // .status // "UNKNOWN")
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

  if jq -e '[.service_products.products[].unknown_check_count] | add > 0' >/dev/null <<<"$payload"; then
    printf '\nWARNING: Some product checks were inconclusive. Run `ngwaf inventory --json` for exact HTTP statuses.\n' >&2
  fi
}
