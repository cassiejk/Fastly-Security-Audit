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
            enabled: ($rule.enabled // false),
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
    jq -n \
      --arg workspace "$w" \
      --arg workspace_id "$ws_id" \
      --arg workspace_input "$input" \
      --argjson total_rules "$(jq '.data | length' <<<"$body")" \
      --argjson pages_fetched "$(jq '.meta.pages_fetched // 1' <<<"$body")" \
      --argjson matched_rules "$matches" \
      '{
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
          (.enabled | tostring),
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

  jq -n \
    --arg service_id "$service_id" \
    --arg service_name "$service_name" \
    --arg customer_id "$cid" \
    --arg customer "$customer" \
    --arg from "$HIST_FROM" \
    --arg to "$HIST_TO" \
    --argjson rows "$(jq '.data // []' <<<"$body")" \
    '
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

  jq -n \
    --arg service_id "$service_id" \
    --arg service_name "$service_name" \
    --arg customer_id "$cid" \
    --arg customer "$customer" \
    --arg from "$HIST_FROM" \
    --arg to "$HIST_TO" \
    --argjson rows "$(jq '.data // []' <<<"$body")" \
    '
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
