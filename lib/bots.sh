# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

cmd_bot_rules() {
  [[ $# -ge 1 && $# -le 2 ]] || die 'usage: ngwaf bot-rules <workspace> [--json]'

  local cid input resolved w ws_id format body matches
  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
  format="${2:-}"

  [[ -z "$format" || "$format" == "--json" ]] ||
    die 'usage: ngwaf bot-rules <workspace> [--json]'

  body="$(
    get_all_pages "$(workspace_path "$ws_id")/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  # A bot-related rule can be identified in two independent ways:
  #   1. It references a Bot Management / client-challenge signal.
  #   2. It uses a Bot Management-specific action such as browserChallenge
  #      or verifyToken, even if no bot signal appears in the rule conditions.
  #
  # DATACENTER is intentionally included as bot-adjacent evidence, not a bot
  # verdict. It describes hosting/cloud source infrastructure and can be useful
  # in bot controls, but must not be interpreted as proof that a request is a bot.
  matches="$(
    jq '
      def bot_signal:
        test(
          "^(VERIFIED-BOT(?:\\.[A-Z0-9_-]+)*|SUSPECTED-BOT(?:\\.[A-Z0-9_-]+)*|SUSPECTED-BAD-BOT(?:\\.[A-Z0-9_-]+)*|CHALLENGE-TOKEN-(?:VALID|INVALID)|CLIENTSIDE-COOKIE-VALID)$";
          "i"
        );

      def bot_adjacent_signal:
        test("^DATACENTER$"; "i");

      def normalized_action:
        tostring | gsub("[^A-Za-z]"; "") | ascii_downcase;

      def bot_action:
        normalized_action == "browserchallenge" or normalized_action == "verifytoken";

      def scalar_strings:
        [.. | strings];

      [
        .data[]
        | . as $rule
        | ([
            ($rule.conditions // []),
            ($rule.rate_limit // {}),
            ($rule.actions // [])
          ] | scalar_strings | unique) as $strings
        | ($strings | map(select(bot_signal))) as $bot_signals
        | ($strings | map(select(bot_adjacent_signal))) as $adjacent_signals
        | ([($rule.actions // [])[]?.type // empty] | map(select(bot_action))) as $bot_actions
        | select(
            ($bot_signals | length) > 0
            or ($adjacent_signals | length) > 0
            or ($bot_actions | length) > 0
          )
        | {
            id: ($rule.id // ""),
            enabled: (if $rule | has("enabled") then $rule.enabled else null end),
            actions: [($rule.actions // [])[]?.type // empty],
            bot_signals: $bot_signals,
            bot_adjacent_signals: $adjacent_signals,
            bot_actions: $bot_actions,
            description: ($rule.description // ""),
            match_basis: (
              [
                (if ($bot_signals | length) > 0 then "bot-signal" else empty end),
                (if ($bot_actions | length) > 0 then "bot-action" else empty end),
                (if ($adjacent_signals | length) > 0 then "bot-adjacent" else empty end)
              ]
            )
          }
      ]
    ' <<<"$body"
  )"

  if [[ "$format" == "--json" ]]; then
    json_stream "$matches" |
      jq -s \
      --arg workspace "$w" \
      --arg workspace_id "$ws_id" \
      --arg workspace_input "$input" \
      --argjson total_rules "$(jq '.data | length' <<<"$body")" \
      --argjson pages_fetched "$(jq '.meta.pages_fetched // 1' <<<"$body")" '
      .[0] as $matched_rules
      | {
        workspace: $workspace,
        workspace_id: $workspace_id,
        workspace_input: $workspace_input,
        total_rules_scanned: $total_rules,
        pages_fetched: $pages_fetched,
        matched_rules: ($matched_rules | length),
        rules: $matched_rules,
        notes: [
          "Bot signals include VERIFIED-BOT.*, SUSPECTED-BOT.*, SUSPECTED-BAD-BOT.*, CHALLENGE-TOKEN-VALID/INVALID, and CLIENTSIDE-COOKIE-VALID.",
          "Rules using browserChallenge or verifyToken are included even when no bot signal appears in the rule conditions.",
          "DATACENTER is included as bot-adjacent evidence only; it is not a bot verdict."
        ],
        provenance: {
          endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/rules",
          data_class: "configuration_snapshot_with_heuristic_classification",
          pagination: "complete_or_fail"
        }
      }'
    return
  fi

  printf '%s — bot-related workspace rules\n' "$w"
  printf 'Scanned %s rules across %s page(s); matched %s.\n\n' \
    "$(jq '.data | length' <<<"$body")" \
    "$(jq '.meta.pages_fetched // 1' <<<"$body")" \
    "$(jq 'length' <<<"$matches")"

  jq -r '
    ["ENABLED", "ACTIONS", "BOT / CHALLENGE SIGNALS", "BASIS", "DESCRIPTION"],
    (
      .[]
      | [
          (if .enabled == null then "unknown" else (.enabled | tostring) end),
          (.actions | join(",")),
          ((.bot_signals + .bot_adjacent_signals) | unique | join(",")),
          (.match_basis | join(",")),
          .description
        ]
    )
    | @tsv
  ' <<<"$matches" | human_table

  printf '\nNotes:\n'
  printf '  - Bot-signal families include VERIFIED-BOT.*, SUSPECTED-BOT.*, and SUSPECTED-BAD-BOT.*.\n'
  printf '  - Client-challenge signals/actions include CHALLENGE-TOKEN-VALID/INVALID, CLIENTSIDE-COOKIE-VALID, browserChallenge, and verifyToken.\n'
  printf '  - DATACENTER is bot-adjacent only; it identifies hosting/cloud infrastructure and is not itself a bot verdict.\n'
}

historical_bot_summary_json() {
  local service_id="$1"
  local cid customer service service_cid service_name body

  cid="$(current_cid)"
  customer="$(current_customer_name)"

  service="$(get "/service/$service_id")"
  service_cid="$(jq -r '.customer_id // ""' <<<"$service")"
  service_name="$(jq -r '.name // ""' <<<"$service")"

  [[ "$service_cid" == "$cid" ]] ||
    die "service $service_id belongs to customer $service_cid, not selected customer $cid"

  body="$(
    get "/stats/service/$service_id" \
      --data-urlencode "from=$HIST_FROM" \
      --data-urlencode "to=$HIST_TO" \
      --data-urlencode "by=day"
  )"

  validate_historical_response \
    "$body" \
    "edge_requests,bot_edge_requests_analyzed_count,bot_edge_requests_detected_count,bot_edge_requests_verified_count,bot_edge_requests_headless_count,bot_edge_requests_ai_crawler_count,bot_edge_requests_search_engine_crawler_count" \
    "Historical Stats for service $service_id"

  jq '.data // []' <<<"$body" |
    jq -s \
    --arg service_id "$service_id" \
    --arg service_name "$service_name" \
    --arg customer_id "$cid" \
    --arg customer "$customer" \
    --arg from "$HIST_FROM" \
    --arg to "$HIST_TO" '
    .[0] as $rows
    |
    def n:
      if . == null then 0
      elif type == "number" then .
      else (tonumber? // 0)
      end;

    ($rows | map(.edge_requests | n) | add // 0) as $edge_requests
    | ($rows | map(.bot_edge_requests_analyzed_count | n) | add // 0) as $analyzed
    | ($rows | map(.bot_edge_requests_detected_count | n) | add // 0) as $detected
    | ($rows | map(.bot_edge_requests_verified_count | n) | add // 0) as $verified
    | ($rows | map(.bot_edge_requests_headless_count | n) | add // 0) as $headless
    | ($rows | map(.bot_edge_requests_ai_crawler_count | n) | add // 0) as $ai
    | ($rows | map(.bot_edge_requests_search_engine_crawler_count | n) | add // 0) as $search
    | {
        customer: $customer,
        customer_id: $customer_id,
        service_id: $service_id,
        service_name: $service_name,
        from: $from,
        to: $to,
        window: {
          type: "complete_utc_days",
          from: $from,
          to: $to,
          to_is_exclusive: true
        },
        daily_rows: ($rows | length),
        edge_requests: $edge_requests,
        analyzed: $analyzed,
        detected: $detected,
        bot_percentage: (
          if $analyzed > 0
          then (($detected / $analyzed) * 100)
          else null
          end
        ),
        verified: $verified,
        headless: $headless,
        ai_crawler: $ai,
        search_engine_crawler: $search,
        provenance: {
          endpoint: "GET /stats/service/{service_id}",
          data_class: "historical_stats",
          aggregation: "sum_of_daily_rows",
          missing_data_policy: "fail_closed",
          bot_metric_semantics: "sampled_and_scaled_estimates"
        }
      }
    '
}

cmd_bot_stats() {
  [[ $# -ge 1 ]] ||
    die 'usage: ngwaf bot-stats <service_id> [days|FROM TO] [--json]'

  local service_id="$1"
  shift

  local format=""
  local summary

  if [[ "${!#:-}" == "--json" ]]; then
    format="--json"
    set -- "${@:1:$(($#-1))}"
  fi

  case "$#" in
    0)
      make_historical_window_days 30
      ;;
    1)
      validate_historical_days "$1"
      make_historical_window_days "$1"
      ;;
    2)
      set_historical_window_dates "$1" "$2"
      validate_monthly_historical_window "$1" "$2"
      ;;
    *)
      die 'usage: ngwaf bot-stats <service_id> [days|FROM TO] [--json]'
      ;;
  esac

  summary="$(historical_bot_summary_json "$service_id")"

  if [[ "$format" == "--json" ]]; then
    jq . <<<"$summary"
    return
  fi

  printf '%s — Historical Bot Management\n' "$(jq -r '.service_name' <<<"$summary")"
  printf '%s → %s UTC (TO is exclusive)\n\n' "$HIST_FROM" "$HIST_TO"

  jq -r '
    def human:
      if . >= 1000000000 then (((. / 1000000000) * 100 | round) / 100 | tostring) + "B"
      elif . >= 1000000 then (((. / 1000000) * 100 | round) / 100 | tostring) + "M"
      elif . >= 1000 then (((. / 1000) * 10 | round) / 10 | tostring) + "K"
      else tostring
      end;

    ["SERVICE", "EDGE REQUESTS", "BOT ANALYZED*", "BOTS DETECTED*", "BOT % OF ANALYZED*", "VERIFIED*", "HEADLESS*", "AI CRAWLER*", "SEARCH CRAWLER*"],
    [
      .service_name,
      (.edge_requests | human),
      (.analyzed | human),
      (.detected | human),
      (if .bot_percentage == null then "n/a" else (((.bot_percentage * 100) | round) / 100 | tostring) + "%" end),
      (.verified | human),
      (.headless | human),
      (.ai_crawler | human),
      (.search_engine_crawler | human)
    ]
    | @tsv
  ' <<<"$summary" | human_table

  printf '\nDefinitions:\n'
  printf '  Bot %% of analyzed* = bot-detected / bot-analyzed using Bot Management metrics.\n'
  printf '  * Bot Management metrics are sampled and scaled estimates; do not divide them by edge_requests to calculate coverage.\n'
  printf 'WARNING: Sanity-check service scope and outliers before using API-derived values in customer-facing material.\n'
}

historical_bot_summary_known_service_json() {
  local service_id="$1"
  local service_name="$2"
  local cid customer body

  cid="$(current_cid)"
  customer="$(current_customer_name)"

  body="$(
    get "/stats/service/$service_id" \
      --data-urlencode "from=$HIST_FROM" \
      --data-urlencode "to=$HIST_TO" \
      --data-urlencode "by=day"
  )"

  validate_historical_response \
    "$body" \
    "$BOT_HIST_FIELDS" \
    "Historical Stats for service $service_id"

  jq '.data // []' <<<"$body" |
    jq -s \
    --arg service_id "$service_id" \
    --arg service_name "$service_name" \
    --arg customer_id "$cid" \
    --arg customer "$customer" \
    --arg from "$HIST_FROM" \
    --arg to "$HIST_TO" '
    .[0] as $rows
    |
    def n:
      if . == null then 0
      elif type == "number" then .
      else (tonumber? // 0)
      end;

    ($rows | map(.edge_requests | n) | add // 0) as $edge_requests
    | ($rows | map(.bot_edge_requests_analyzed_count | n) | add // 0) as $analyzed
    | ($rows | map(.bot_edge_requests_detected_count | n) | add // 0) as $detected
    | ($rows | map(.bot_edge_requests_verified_count | n) | add // 0) as $verified
    | ($rows | map(.bot_edge_requests_headless_count | n) | add // 0) as $headless
    | ($rows | map(.bot_edge_requests_ai_crawler_count | n) | add // 0) as $ai_crawler
    | ($rows | map(.bot_edge_requests_ai_fetcher_count | n) | add // 0) as $ai_fetcher
    | ($rows | map(.bot_edge_requests_search_engine_crawler_count | n) | add // 0) as $search_engine_crawler
    | ($rows | map(.bot_edge_requests_accessibility_count | n) | add // 0) as $accessibility
    | ($rows | map(.bot_edge_requests_content_fetcher_count | n) | add // 0) as $content_fetcher
    | ($rows | map(.bot_edge_requests_monitoring_count | n) | add // 0) as $monitoring
    | ($rows | map(.bot_edge_requests_online_marketing_count | n) | add // 0) as $online_marketing
    | ($rows | map(.bot_edge_requests_page_preview_count | n) | add // 0) as $page_preview
    | ($rows | map(.bot_edge_requests_platform_integrations_count | n) | add // 0) as $platform_integrations
    | ($rows | map(.bot_edge_requests_research_count | n) | add // 0) as $research
    | ($rows | map(.bot_edge_requests_search_engine_optimization_count | n) | add // 0) as $search_engine_optimization
    | ($rows | map(.bot_edge_requests_security_tools_count | n) | add // 0) as $security_tools
    | {
        customer: $customer,
        customer_id: $customer_id,
        service_id: $service_id,
        service_name: $service_name,
        from: $from,
        to: $to,
        window: {
          type: "complete_utc_days",
          from: $from,
          to: $to,
          to_is_exclusive: true
        },
        daily_rows: ($rows | length),
        edge_requests: $edge_requests,
        analyzed: $analyzed,
        detected: $detected,
        bot_percentage: (
          if $analyzed > 0
          then (($detected / $analyzed) * 100)
          else null
          end
        ),
        verified: $verified,
        headless: $headless,
        ai_crawler: $ai_crawler,
        ai_fetcher: $ai_fetcher,
        search_engine_crawler: $search_engine_crawler,
        accessibility: $accessibility,
        content_fetcher: $content_fetcher,
        monitoring: $monitoring,
        online_marketing: $online_marketing,
        page_preview: $page_preview,
        platform_integrations: $platform_integrations,
        research: $research,
        search_engine_optimization: $search_engine_optimization,
        security_tools: $security_tools,
        provenance: {
          endpoint: "GET /stats/service/{service_id}",
          data_class: "historical_stats",
          aggregation: "sum_of_daily_rows",
          missing_data_policy: "fail_closed",
          bot_metric_semantics: "sampled_and_scaled_estimates"
        }
      }
    '
}

# ContentGuard workspaces use cursor pagination, unlike NGWAF workspaces.
# Buffer the complete validated collection so failures never emit partial JSON.
bot_workspaces_collect_json() {
  local cid="$1" sid="$2" tmp code reason='' cursor='' next_cursor
  local total='' page_total count fetched=0 pages=0
  local -a args
  local -A seen_cursors=()
  tmp="$(mktemp -d)" || return 1
  : >"$tmp/pages"
  while :; do
    if (( pages >= 1000 )); then reason='cursor pagination safety limit exceeded'; break; fi
    args=(--data-urlencode "customer_id=$cid" --data-urlencode 'limit=100')
    [[ -z "$sid" ]] || args+=(--data-urlencode "service_id=$sid")
    [[ -z "$cursor" ]] || args+=(--data-urlencode "cursor=$cursor")
    code="$(http_get_to_file /bot-management/v1/workspaces "$tmp/page" "${args[@]}")" || code=000
    case "$code" in
      2*) ;;
      401|403) reason="workspace authorization failed (HTTP $code)"; break ;;
      *) reason="workspace request failed (HTTP $code)"; break ;;
    esac
    if ! jq -e --arg cid "$cid" --arg sid "$sid" '
      def text: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
      def owner:
        (if has("customer_id") then .customer_id == $cid else true end)
        and (if has("customer") then
          (.customer | type == "object" and has("id")) and .customer.id == $cid
          else true end);
      type == "object" and owner
      and (.meta | type == "object" and owner
        and (.total | type == "number" and . >= 0 and . <= 2147483647 and . == floor)
        and has("next_cursor")
        and (.next_cursor == null or (.next_cursor | text)))
      and (.data | type == "array" and length <= 100)
      and all(.data[]; type == "object" and owner
        and (.id | text) and (.name | text)
        and (.protection_mode == "off" or .protection_mode == "log" or .protection_mode == "block")
        and (.services | type == "array" and all(.[]; text) and length == (unique | length))
        and (if $sid != "" then (.services | index($sid)) != null else true end))
    ' "$tmp/page" >/dev/null 2>&1; then
      reason='workspace schema, ownership, service association, or pagination metadata is invalid'; break
    fi
    page_total="$(jq -r '.meta.total' "$tmp/page")"
    if [[ -n "$total" && "$page_total" != "$total" ]]; then reason='workspace total changed during pagination'; break; fi
    total="$page_total"
    count="$(jq '.data | length' "$tmp/page")"
    jq '.data' "$tmp/page" >>"$tmp/pages" || { reason='could not collect workspace page'; break; }
    pages=$(( pages + 1 ))
    fetched=$(( fetched + count ))
    next_cursor="$(jq -r '.meta.next_cursor // ""' "$tmp/page")"
    if (( fetched > total )); then reason='workspace count exceeds total'; break; fi
    if [[ -z "$next_cursor" ]]; then
      if (( fetched != total )); then reason='workspace pagination incomplete: count differs from total'; fi
      break
    fi
    if (( count == 0 || fetched >= total )); then reason='workspace cursor contradicts count'; break; fi
    if [[ -n "${seen_cursors["$next_cursor"]:-}" ]]; then reason='workspace cursor repeated'; break; fi
    seen_cursors["$next_cursor"]=1
    cursor="$next_cursor"
  done
  if [[ -z "$reason" ]] && ! jq -s -e 'add | length == (unique_by(.id) | length)' "$tmp/pages" >/dev/null; then
    reason='duplicate workspace IDs'
  fi
  if [[ -n "$reason" ]]; then
    rm -rf "$tmp"
    printf '%s: bot workspaces: %s\n' "${PROGRAM_NAME:-fastly-audit}" "$reason" >&2
    return 1
  fi
  jq -s --argjson pages "$pages" --argjson total "$total" \
    '{pagination:{complete:true,pages_fetched:$pages,total:$total},data:(add // [])}' "$tmp/pages"
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

cmd_bot_workspaces() {
  local sid='' json=false cid service collection payload
  while (( $# > 0 )); do
    case "$1" in
      --json) [[ "$json" == false ]] || die 'duplicate --json'; json=true; shift ;;
      --service-id)
        [[ $# -ge 2 && -n "$2" && "$2" != -* && -z "$sid" ]] || die '--service-id requires one exact service ID, specified once'
        sid="$2"; shift 2 ;;
      help|-h|--help)
        [[ $# == 1 && -z "$sid" && "$json" == false ]] || die 'help cannot be combined with workspace options'
        bot_workspaces_usage; return ;;
      *) die "unknown bot workspaces argument: $1" ;;
    esac
  done
  dispatch_preflight bot-workspaces
  cid="$(current_cid)" || return 1
  if [[ -n "$sid" ]]; then
    service="$(get "/service/$(urlencode "$sid")")" || return 1
    jq -e --arg sid "$sid" --arg cid "$cid" '
      type == "object" and .id == $sid and .customer_id == $cid and .type == "vcl"
      and (if has("customer") then (.customer | type == "object") and .customer.id == $cid else true end)
    ' >/dev/null <<<"$service" || die 'bot workspaces: service identity, customer ownership, or CDN type could not be verified'
  fi
  collection="$(bot_workspaces_collect_json "$cid" "$sid")" || return 1
  payload="$(jq --argjson customer "$(jq '{id,name}' <<<"$NGWAF_CUSTOMER_CONTEXT_JSON")" --arg sid "$sid" '
    {
      schema_version:1, customer:$customer,
      scope:{service_id:(if $sid == "" then null else $sid end)},
      result:{status:"COMPLETE",count:(.data|length),reason:"complete customer-scoped workspace collection"},
      pagination,
      workspaces:[.data[] | {workspace_id:.id,name,protection_mode,services,
        ownership_validation:{customer:"authenticated customer-scoped request; explicit metadata checked",
          requested_service:(if $sid == "" then "not requested" else "direct service ownership and returned association verified" end),
          other_services:"API-reported; not independently ownership-verified"}}],
      provenance:{endpoint:"GET /bot-management/v1/workspaces",data_class:"configuration_snapshot",pagination:"cursor"},
      limitations:["Bot Management workspaces configure ContentGuard; they are distinct from NGWAF workspaces.",
        "Association and protection mode do not prove active traffic inspection, per-hostname coverage, or effective enforcement.",
        "Results reflect credential-visible data within the selected customer scope."]
    }' <<<"$collection")" || return 1
  if [[ "$json" == true ]]; then jq . <<<"$payload"; return; fi
  printf 'Bot Management workspaces — %s (%s)\n' \
    "$(jq -r '.customer.name' <<<"$payload")" "$cid"
  if [[ -n "$sid" ]]; then printf 'Service: %s\n' "$sid"; fi
  printf 'Complete: %s workspace(s), %s page(s)\n' \
    "$(jq '.result.count' <<<"$payload")" "$(jq '.pagination.pages_fetched' <<<"$payload")"
  if [[ "$(jq '.result.count' <<<"$payload")" == 0 ]]; then
    printf 'No matching Bot Management workspaces returned for this customer/service scope.\n'
  else
    jq -r '(["WORKSPACE ID","NAME","PROTECTION MODE","SERVICE IDS"],
      (.workspaces[] | [.workspace_id,.name,.protection_mode,(.services|join(","))])) | @tsv' <<<"$payload" | human_table
  fi
  printf '\nContentGuard configuration associations; distinct from NGWAF workspaces.\n'
  printf 'Association does not prove active inspection, hostname coverage, or enforcement effectiveness.\n'
}
