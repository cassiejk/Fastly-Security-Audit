# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

cmd_overview() {
  local days="${1:-30}"
  local format="${2:-}"
  local cid customer body summary

  [[ "$days" != "--json" ]] || {
    format="--json"
    days=30
  }

  validate_timeseries_days "$days"
  [[ -z "$format" || "$format" == "--json" ]] ||
    die 'usage: ngwaf overview [days] [--json]'

  cid="$(current_cid)"
  make_timeseries_window "$days"

  customer="$(get "/customer/$cid" | jq -r '.name')"

  body="$(
    get "/ngwaf/v1/timeseries" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "from=$TS_FROM" \
      --data-urlencode "to=$TS_TO" \
      --data-urlencode "metrics=$CORE_METRICS" \
      --data-urlencode "dimensions=workspaces,time" \
      --data-urlencode "granularity=86400"
  )"

  summary="$(
    jq '
      [
        .data[]
        | {
            workspace: .dimensions.workspace,
            values: (.values[0] // {})
          }
      ]
      | group_by(.workspace)
      | map({
          workspace: .[0].workspace,
          requests_total: (map(.values.requests_total // 0) | add),
          requests_attack: (map(.values.requests_attack // 0) | add),
          requests_total_blocked: (map(.values.requests_total_blocked // 0) | add)
        })
      | sort_by(-.requests_total)
    ' <<<"$body"
  )"

  if [[ "$format" == "--json" ]]; then
    jq -n \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --argjson days "$days" \
      --argjson workspaces "$summary" \
      '{
        customer: $customer,
        customer_id: $customer_id,
        days: $days,
        from: $from,
        to: $to,
        workspaces: $workspaces
      }'
    return
  fi

  printf '%s — NGWAF %s-day overview\n' "$customer" "$days"
  printf '%s → %s UTC (complete days)\n\n' "$TS_FROM" "$TS_TO"

  jq -r '
    def human:
      if . >= 1000000000 then (((. / 1000000000) * 100 | round) / 100 | tostring) + "B"
      elif . >= 1000000 then (((. / 1000000) * 100 | round) / 100 | tostring) + "M"
      elif . >= 1000 then (((. / 1000) * 10 | round) / 10 | tostring) + "K"
      else tostring
      end;

    ["WORKSPACE", "REQUESTS", "ATTACK-TAGGED", "BLOCKED"],
    (
      .[]
      | [
          .workspace,
          (.requests_total | human),
          (.requests_attack | human),
          (.requests_total_blocked | human)
        ]
    )
    | @tsv
  ' <<<"$summary" | human_table

  printf '\nNote: attack-tagged and blocked are independent metrics; do not divide one by the other as a block-rate calculation.\n'
}

cmd_timeseries() {
  [[ $# -ge 1 ]] || die 'usage: ngwaf timeseries <workspace> [days] [--json]'

  local cid w days format body
  cid="$(current_cid)"
  w="$1"
  days="${2:-30}"
  format="${3:-}"

  if [[ "$days" == "--json" ]]; then
    format="--json"
    days=30
  fi

  validate_timeseries_days "$days"
  [[ -z "$format" || "$format" == "--json" ]] ||
    die 'usage: ngwaf timeseries <workspace> [days] [--json]'

  make_timeseries_window "$days"

  body="$(
    get "$(workspace_path "$w")/timeseries" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "from=$TS_FROM" \
      --data-urlencode "to=$TS_TO" \
      --data-urlencode "metrics=$CORE_METRICS" \
      --data-urlencode "granularity=86400"
  )"

  if [[ "$format" == "--json" ]]; then
    jq . <<<"$body"
    return
  fi

  printf '%s — %s-day NGWAF timeseries\n' "$w" "$days"
  printf '%s → %s UTC (complete days)\n\n' "$TS_FROM" "$TS_TO"

  jq -r '
    ["DATE", "REQUESTS", "ATTACK-TAGGED", "BLOCKED"],
    (
      .data
      | sort_by(.dimensions.time // .timestamp)
      | .[]
      | [
          ((.dimensions.time // .timestamp) | split("T")[0]),
          ((.values[0].requests_total // 0) | tostring),
          ((.values[0].requests_attack // 0) | tostring),
          ((.values[0].requests_total_blocked // 0) | tostring)
        ]
    )
    | @tsv
  ' <<<"$body" | human_table
}

cmd_metrics() {
  [[ $# -ge 1 ]] ||
    die 'usage: ngwaf metrics <metric1,metric2,...> [days] [--json]'

  local cid metrics days format body summary
  cid="$(current_cid)"
  metrics="$(tr -d '[:space:]' <<<"$1")"
  days="${2:-30}"
  format="${3:-}"

  if [[ "$days" == "--json" ]]; then
    format="--json"
    days=30
  fi

  [[ -n "$metrics" ]] || die 'at least one metric is required'
  validate_timeseries_days "$days"
  [[ -z "$format" || "$format" == "--json" ]] ||
    die 'usage: ngwaf metrics <metric1,metric2,...> [days] [--json]'

  make_timeseries_window "$days"

  body="$(
    get "/ngwaf/v1/timeseries" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "from=$TS_FROM" \
      --data-urlencode "to=$TS_TO" \
      --data-urlencode "metrics=$metrics" \
      --data-urlencode "dimensions=workspaces,time" \
      --data-urlencode "granularity=86400"
  )"

  summary="$(
    jq --arg metrics "$metrics" '
      ($metrics | split(",")) as $metrics
      | [
          .data[]
          | {
              workspace: .dimensions.workspace,
              values: (.values[0] // {})
            }
        ]
      | group_by(.workspace)
      | map(
          . as $rows
          | {workspace: $rows[0].workspace}
            + reduce $metrics[] as $metric (
                {};
                .[$metric] = (
                  [$rows[] | (.values[$metric] // 0)] | add
                )
              )
        )
      | sort_by(.workspace)
    ' <<<"$body"
  )"

  if [[ "$format" == "--json" ]]; then
    jq . <<<"$summary"
    return
  fi

  printf 'Account-level NGWAF metric summary — %s days\n' "$days"
  printf '%s → %s UTC (complete days)\n\n' "$TS_FROM" "$TS_TO"

  jq -r --arg metrics "$metrics" '
    ($metrics | split(",")) as $metrics
    | (["WORKSPACE"] + $metrics),
      (
        .[] as $row
        | [$row.workspace]
          + [$metrics[] as $metric | (($row[$metric] // 0) | tostring)]
      )
    | @tsv
  ' <<<"$summary" | human_table
}

cmd_count() {
  [[ $# -ge 2 && $# -le 3 ]] ||
    die "usage: ngwaf count <workspace> '<search query>' [days]"

  local cid w requested_query query days end start body
  cid="$(current_cid)"
  w="$1"
  requested_query="$2"
  query="$requested_query"
  days="${3:-7}"

  validate_request_days "$days"

  # Fastly's request-search key for a matching rule ID is `ruleid`. Earlier
  # helper guidance used `rule`, which the API silently ignored and therefore
  # returned the unfiltered workspace total. Preserve that convenient spelling
  # as an explicit, visible alias rather than returning a misleading count.
  if [[ "$query" =~ (^|[[:space:]])rule: ]]; then
    query="$(sed -E 's/(^|[[:space:]])rule:/\1ruleid:/g' <<<"$query")"
    printf 'ngwaf: note: normalized search key rule: to ruleid:\n' >&2
  fi

  # Five-minute buffer for the request-search ingestion pipeline.
  if date -u -v-5M +%s >/dev/null 2>&1; then
    end="$(date -u -v-5M +%s)"
  else
    end="$(date -u -d '5 minutes ago' +%s)"
  fi

  start=$((end - (days * 86400)))

  body="$(
    NGWAF_PROGRESS_LABEL="counting matching requests in $w" \
    get "$(workspace_path "$w")/requests" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "limit=1" \
      --data-urlencode "q=from:$start until:$end $query"
  )"

  jq -e '
    (.data | type) == "array"
    and (.meta | type) == "object"
    and ((.meta.total | type) == "number")
    and (.meta.total >= 0)
  ' >/dev/null <<<"$body" ||
    die 'request search returned an unexpected response; refusing to report a count'

  jq -n \
    --arg workspace "$w" \
    --arg query "$query" \
    --arg requested_query "$requested_query" \
    --argjson days "$days" \
    --argjson count "$(jq '.meta.total' <<<"$body")" \
    '{
      workspace: $workspace,
      days: $days,
      query: $query,
      count: $count
    }
    + (if $query != $requested_query
       then {requested_query: $requested_query, query_normalized: true}
       else {query_normalized: false}
       end)'
}

cmd_attack_profile() {
  local format=""
  local cid customer body workspace_summary top_workspace_names signal_summary
  local metrics="requests_attack,SQLI,TRAVERSAL,XSS,CMDEXE,AWS-SSRF"
  local prod_regex='(^|[-_])(prd|prod|production)([-_]|$)'
  local span_days=""
  local top_n=5

  if [[ "${!#:-}" == "--json" ]]; then
    format="--json"
    set -- "${@:1:$(($#-1))}"
  fi

  case "$#" in
    0)
      make_timeseries_window 30
      span_days=30
      ;;
    1)
      validate_timeseries_days "$1"
      make_timeseries_window "$1"
      span_days="$1"
      ;;
    2)
      local from_date="$1"
      local to_date="$2"
      local from_epoch to_epoch

      [[ "$from_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
        die 'FROM date must be YYYY-MM-DD'
      [[ "$to_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
        die 'TO date must be YYYY-MM-DD'

      if date -u -j -f "%Y-%m-%d" "$from_date" "+%s" >/dev/null 2>&1; then
        from_epoch="$(date -u -j -f "%Y-%m-%d" "$from_date" "+%s")"
        to_epoch="$(date -u -j -f "%Y-%m-%d" "$to_date" "+%s")"
      else
        from_epoch="$(date -u -d "$from_date" "+%s")"
        to_epoch="$(date -u -d "$to_date" "+%s")"
      fi

      (( to_epoch > from_epoch )) || die 'TO date must be after FROM date'
      span_days=$(( (to_epoch - from_epoch) / 86400 ))
      (( span_days <= 31 )) ||
        die 'exact attack-profile date range must be 31 days or less'

      TS_FROM="${from_date}T00:00:00Z"
      TS_TO="${to_date}T00:00:00Z"
      ;;
    *)
      die 'usage: ngwaf attack-profile [days|FROM TO] [--json]'
      ;;
  esac

  cid="$(current_cid)"
  customer="$(get "/customer/$cid" | jq -r '.name')"

  body="$(
    get "/ngwaf/v1/timeseries" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "from=$TS_FROM" \
      --data-urlencode "to=$TS_TO" \
      --data-urlencode "metrics=$metrics" \
      --data-urlencode "dimensions=workspaces,time" \
      --data-urlencode "granularity=86400"
  )"

  # First rank production workspaces by requests_attack for the selected window.
  workspace_summary="$(
    jq --arg prod_regex "$prod_regex" '
      [
        .data[]
        | {
            workspace: .dimensions.workspace,
            attack: ((.values[0].requests_attack // 0) | tonumber? // 0)
          }
      ]
      | group_by(.workspace)
      | map({
          workspace: .[0].workspace,
          requests_attack: (map(.attack) | add // 0)
        })
      | map(select(.workspace | test($prod_regex; "i")))
      | sort_by(-.requests_attack)
    ' <<<"$body"
  )"

  # The QBR attack-signal chart is intentionally scoped to the SAME top five
  # production workspaces shown in the workspace-ranking chart.
  top_workspace_names="$(
    jq --argjson n "$top_n" '[.[:$n][].workspace]' <<<"$workspace_summary"
  )"

  signal_summary="$(
    jq --argjson top_workspaces "$top_workspace_names" '
      def n:
        if . == null then 0
        elif type == "number" then .
        else (tonumber? // 0)
        end;

      [
        .data[]
        | select(.dimensions.workspace as $w | $top_workspaces | index($w))
        | (.values[0] // {})
      ] as $rows
      | [
          {metric: "SQLI", label: "SQL Injection", requests: ($rows | map(.SQLI | n) | add // 0)},
          {metric: "TRAVERSAL", label: "Directory Traversal", requests: ($rows | map(.TRAVERSAL | n) | add // 0)},
          {metric: "XSS", label: "Cross-Site Scripting", requests: ($rows | map(.XSS | n) | add // 0)},
          {metric: "CMDEXE", label: "Command Execution", requests: ($rows | map(.CMDEXE | n) | add // 0)},
          {metric: "AWS-SSRF", label: "AWS Server-Side Request Forgery", requests: ($rows | map(."AWS-SSRF" | n) | add // 0)}
        ]
      | sort_by(-.requests)
    ' <<<"$body"
  )"

  if [[ "$format" == "--json" ]]; then
    jq -n \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --argjson span_days "$span_days" \
      --argjson top_n "$top_n" \
      --arg production_workspace_filter "$prod_regex" \
      --argjson production_workspaces "$workspace_summary" \
      --argjson selected_workspaces "$top_workspace_names" \
      --argjson attack_signals "$signal_summary" \
      '{
        customer: $customer,
        customer_id: $customer_id,
        from: $from,
        to: $to,
        to_is_exclusive: true,
        span_days: $span_days,
        scopes: {
          workspace_ranking: "production workspaces only, identified by workspace name",
          signal_totals: "same top production workspaces shown in the ranking"
        },
        top_n: $top_n,
        production_workspace_filter: $production_workspace_filter,
        selected_workspaces: $selected_workspaces,
        production_workspaces: $production_workspaces[:$top_n],
        attack_signals: $attack_signals
      }'
    return
  fi

  printf '%s — NGWAF attack profile\n' "$customer"
  printf '%s → %s UTC (TO is exclusive; %s days)\n\n' "$TS_FROM" "$TS_TO" "$span_days"

  printf 'Top %s production workspaces by attack-signaled requests\n' "$top_n"
  jq -r --argjson n "$top_n" '
    def human:
      if . >= 1000000000 then (((. / 1000000000) * 100 | round) / 100 | tostring) + "B"
      elif . >= 1000000 then (((. / 1000000) * 100 | round) / 100 | tostring) + "M"
      elif . >= 1000 then (((. / 1000) * 10 | round) / 10 | tostring) + "K"
      else tostring
      end;

    ["WORKSPACE", "ATTACK-SIGNALED"],
    (
      .[:$n][]
      | [.workspace, (.requests_attack | human)]
    )
    | @tsv
  ' <<<"$workspace_summary" | human_table

  printf '\nTop attack signals — same top %s production workspaces\n' "$top_n"
  jq -r '
    def human:
      if . >= 1000000000 then (((. / 1000000000) * 100 | round) / 100 | tostring) + "B"
      elif . >= 1000000 then (((. / 1000000) * 100 | round) / 100 | tostring) + "M"
      elif . >= 1000 then (((. / 1000) * 10 | round) / 10 | tostring) + "K"
      else tostring
      end;

    ["SIGNAL", "METRIC", "REQUESTS"],
    (
      .[]
      | [.label, .metric, (.requests | human)]
    )
    | @tsv
  ' <<<"$signal_summary" | human_table

  printf '\nScope / validation notes:\n'
  printf '  - Workspace ranking: top %s production workspaces matched by name using %s.\n' "$top_n" "$prod_regex"
  printf '  - Attack-signal totals: summed across exactly those same top %s workspaces.\n' "$top_n"
  printf '  - Selected workspaces: %s\n' "$(jq -r 'join(", ")' <<<"$top_workspace_names")"
  printf '  - Signals can overlap; signal counts are not mutually exclusive and should not be summed as unique attacked requests.\n'
  if (( span_days == 31 )); then
    printf '  - NOTE: this exact range spans 31 days. Prefer a calendar-month label such as "August 2026" over "Last 30 Days."\n'
  fi
  printf 'WARNING: NGWAF metrics retention depends on entitlement and current query date; validate the returned range before using it in customer-facing material.\n'
}

cmd_attack_origins() {
  local format=""
  local cid customer workspaces_body production_workspaces workspace_total workspace_returned
  local span_days="" workspace_count attack_ts attack_total
  local prod_regex='(^|[-_])(prd|prod|production)([-_]|$)'
  local production_workspace_names
  local tmp rows source_summary returned_source_total source_coverage
  local top_five_total top_five_share returned_top_five_share other_total other_share
  local workspace_id workspace_name body
  local workspace_index=0
  local top_limit=100
  local chunk_days=7
  local chunk_count=0
  local range_start_epoch range_end_epoch chunk_start_epoch chunk_end_epoch
  local chunk_from chunk_to

  if [[ "${!#:-}" == "--json" ]]; then
    format="--json"
    set -- "${@:1:$(($#-1))}"
  fi

  case "$#" in
    0)
      make_timeseries_window 30
      span_days=30
      ;;
    1)
      validate_timeseries_days "$1"
      make_timeseries_window "$1"
      span_days="$1"
      ;;
    2)
      local from_date="$1"
      local to_date="$2"
      local from_epoch to_epoch

      [[ "$from_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
        die 'FROM date must be YYYY-MM-DD'
      [[ "$to_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
        die 'TO date must be YYYY-MM-DD'

      if date -u -j -f "%Y-%m-%d" "$from_date" "+%s" >/dev/null 2>&1; then
        from_epoch="$(date -u -j -f "%Y-%m-%d" "$from_date" "+%s")"
        to_epoch="$(date -u -j -f "%Y-%m-%d" "$to_date" "+%s")"
      else
        from_epoch="$(date -u -d "$from_date" "+%s")"
        to_epoch="$(date -u -d "$to_date" "+%s")"
      fi

      (( to_epoch > from_epoch )) || die 'TO date must be after FROM date'
      span_days=$(( (to_epoch - from_epoch) / 86400 ))
      (( span_days <= 30 )) ||
        die 'attack-origins date range must be 30 days or less'

      TS_FROM="${from_date}T00:00:00Z"
      TS_TO="${to_date}T00:00:00Z"
      ;;
    *)
      die 'usage: ngwaf attack-origins [days|FROM TO] [--json]'
      ;;
  esac

  cid="$(current_cid)"
  customer="$(get "/customer/$cid" | jq -r '.name')"

  # Resolve the selected customer's workspace set FIRST. Every top-attacks
  # request below is made directly against one of these workspace IDs, which
  # avoids relying on the ambiguous account-level reports/attacks response.
  workspaces_body="$(
    get "/ngwaf/v1/workspaces" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "limit=100"
  )"

  workspace_total="$(jq -r '.meta.total // (.data | length)' <<<"$workspaces_body")"
  workspace_returned="$(jq -r '.data | length' <<<"$workspaces_body")"
  if (( workspace_total > workspace_returned )); then
    die "selected customer has $workspace_total workspaces but only $workspace_returned were returned; pagination is required before attack-origins can be trusted"
  fi

  # QBR scope: production workspaces only. Use the same token-aware production
  # naming rule as attack-profile so dev/staging/perf/etc. are not queried.
  production_workspaces="$(
    jq --arg prod_regex "$prod_regex" '[.data[] | select(.name | test($prod_regex; "i"))]' <<<"$workspaces_body"
  )"
  workspace_count="$(jq 'length' <<<"$production_workspaces")"
  (( workspace_count > 0 )) || die "no production workspaces matched $prod_regex for selected customer"
  production_workspace_names="$(jq '[.[].name]' <<<"$production_workspaces")"

  # requests_attack is the independent denominator/reconciliation check and MUST
  # use the same production workspace set as the country numerator.
  attack_ts="$(
    get "/ngwaf/v1/timeseries" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "from=$TS_FROM" \
      --data-urlencode "to=$TS_TO" \
      --data-urlencode "metrics=requests_attack" \
      --data-urlencode "dimensions=workspaces,time" \
      --data-urlencode "granularity=86400"
  )"

  attack_total="$(
    jq --argjson production_names "$production_workspace_names" '
      [
        .data[]?
        | select(.dimensions.workspace as $w | $production_names | index($w))
        | ((.values[0].requests_attack // 0) | tonumber? // 0)
      ]
      | add // 0
    ' <<<"$attack_ts"
  )"

  # top-attacks enforces a maximum 7-day interval. Split the requested
  # reporting window into contiguous <=7-day chunks and aggregate the country
  # counts across chunks. This lets attack-origins support the same <=30-day
  # reporting window as NGWAF timeseries while honoring the endpoint limit.
  if date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$TS_FROM" "+%s" >/dev/null 2>&1; then
    range_start_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$TS_FROM" "+%s")"
    range_end_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$TS_TO" "+%s")"
  else
    range_start_epoch="$(date -u -d "$TS_FROM" "+%s")"
    range_end_epoch="$(date -u -d "$TS_TO" "+%s")"
  fi

  (( range_end_epoch > range_start_epoch )) ||
    die 'attack-origins resolved an invalid time range'

  chunk_count=$(( (span_days + chunk_days - 1) / chunk_days ))

  tmp="$(mktemp)"
  : > "$tmp"

  if [[ "$format" != "--json" ]]; then
    printf '%s — NGWAF attack request origins\n' "$customer"
    printf '%s → %s UTC (TO is exclusive; %s days)\n' "$TS_FROM" "$TS_TO" "$span_days"
    printf 'Scope: selected customer (%s), %s production NGWAF workspaces (prd/prod/production)\n' "$cid" "$workspace_count"
    printf 'Querying per-workspace top-attacks by remote country code...\n\n'
  fi

  while IFS=$'\t' read -r workspace_id workspace_name; do
    [[ -n "$workspace_id" ]] || continue
    workspace_index=$((workspace_index + 1))
    if [[ "$format" != "--json" ]]; then
      printf '\r  [%s/%s] %s' "$workspace_index" "$workspace_count" "$workspace_name" >&2
    fi

    chunk_start_epoch="$range_start_epoch"
    while (( chunk_start_epoch < range_end_epoch )); do
      chunk_end_epoch=$(( chunk_start_epoch + (chunk_days * 86400) ))
      (( chunk_end_epoch > range_end_epoch )) && chunk_end_epoch="$range_end_epoch"

      if date -u -r "$chunk_start_epoch" "+%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
        chunk_from="$(date -u -r "$chunk_start_epoch" "+%Y-%m-%dT%H:%M:%SZ")"
        chunk_to="$(date -u -r "$chunk_end_epoch" "+%Y-%m-%dT%H:%M:%SZ")"
      else
        chunk_from="$(date -u -d "@$chunk_start_epoch" "+%Y-%m-%dT%H:%M:%SZ")"
        chunk_to="$(date -u -d "@$chunk_end_epoch" "+%Y-%m-%dT%H:%M:%SZ")"
      fi

      body="$(
        get "/ngwaf/v1/workspaces/$workspace_id/top-attacks" \
          --data-urlencode "customer_id=$cid" \
          --data-urlencode "field=remote_country_code" \
          --data-urlencode "from=$chunk_from" \
          --data-urlencode "to=$chunk_to" \
          --data-urlencode "limit=$top_limit"
      )"

      # Fail closed if Fastly changes the response shape.
      jq -e '.data | type == "array"' <<<"$body" >/dev/null || {
        rm -f "$tmp"
        die "unexpected top-attacks response for workspace $workspace_name ($workspace_id), chunk $chunk_from -> $chunk_to"
      }

      jq -c \
        --arg workspace_id "$workspace_id" \
        --arg workspace_name "$workspace_name" \
        --arg chunk_from "$chunk_from" \
        --arg chunk_to "$chunk_to" '
        .data[]?
        | {
            workspace_id: $workspace_id,
            workspace: $workspace_name,
            chunk_from: $chunk_from,
            chunk_to: $chunk_to,
            country_code: (.value // ""),
            country: (
              if ((.display_name // "") | length) > 0 then .display_name
              elif (.value // "") == "private" then "Private Network"
              elif (.value // "") == "" then "Unknown"
              else .value
              end
            ),
            requests: ((.count // 0) | tonumber? // 0)
          }
      ' <<<"$body" >> "$tmp"

      chunk_start_epoch="$chunk_end_epoch"
    done
  done < <(jq -r '.[] | [.id, .name] | @tsv' <<<"$production_workspaces")
  if [[ "$format" != "--json" ]]; then
    printf '\r%*s\r' 100 '' >&2
  fi

  rows="$(jq -s '.' "$tmp")"
  rm -f "$tmp"

  source_summary="$(
    jq --argjson attack_total "$attack_total" '
      sort_by(.country_code, .country)
      | group_by([.country_code, .country])
      | map({
          country_code: .[0].country_code,
          country: .[0].country,
          requests: (map(.requests) | add // 0),
          workspace_count: (map(.workspace_id) | unique | length)
        })
      | map(. + {
          share_of_attack_requests:
            (if $attack_total > 0 then (.requests / $attack_total) else 0 end)
        })
      | sort_by(-.requests)
    ' <<<"$rows"
  )"

  returned_source_total="$(jq '[.[].requests] | add // 0' <<<"$source_summary")"
  if (( attack_total > 0 )); then
    source_coverage="$(jq -n --argjson n "$returned_source_total" --argjson d "$attack_total" '$n / $d')"
  else
    source_coverage="0"
  fi

  top_five_total="$(jq '[.[:5][].requests] | add // 0' <<<"$source_summary")"
  if (( attack_total > 0 )); then
    top_five_share="$(jq -n --argjson n "$top_five_total" --argjson d "$attack_total" '$n / $d')"
  else
    top_five_share="0"
  fi
  if (( returned_source_total > 0 )); then
    returned_top_five_share="$(jq -n --argjson n "$top_five_total" --argjson d "$returned_source_total" '$n / $d')"
  else
    returned_top_five_share="0"
  fi

  other_total=$(( attack_total - top_five_total ))
  (( other_total >= 0 )) || other_total=0
  if (( attack_total > 0 )); then
    other_share="$(jq -n --argjson n "$other_total" --argjson d "$attack_total" '$n / $d')"
  else
    other_share="0"
  fi

  if [[ "$format" == "--json" ]]; then
    jq -n \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --argjson span_days "$span_days" \
      --arg production_workspace_filter "$prod_regex" \
      --argjson production_workspaces "$production_workspace_names" \
      --argjson workspace_count "$workspace_count" \
      --argjson per_workspace_limit "$top_limit" \
      --argjson chunk_days "$chunk_days" \
      --argjson chunks_per_workspace "$chunk_count" \
      --argjson attack_requests "$attack_total" \
      --argjson returned_source_requests "$returned_source_total" \
      --argjson returned_source_coverage "$source_coverage" \
      --argjson top_five_requests "$top_five_total" \
      --argjson top_five_share "$top_five_share" \
      --argjson top_five_share_of_returned_sources "$returned_top_five_share" \
      --argjson other_requests "$other_total" \
      --argjson other_share "$other_share" \
      --argjson countries "$source_summary" \
      '{
        customer: $customer,
        customer_id: $customer_id,
        from: $from,
        to: $to,
        to_is_exclusive: true,
        span_days: $span_days,
        scope: "production workspaces only",
        production_workspace_filter: $production_workspace_filter,
        production_workspaces: $production_workspaces,
        workspace_count: $workspace_count,
        source: "GET /ngwaf/v1/workspaces/{workspace_id}/top-attacks?customer_id={customer_id}&field=remote_country_code",
        per_workspace_limit_per_chunk: $per_workspace_limit,
        max_days_per_top_attacks_query: $chunk_days,
        chunks_per_workspace: $chunks_per_workspace,
        attack_requests_timeseries: $attack_requests,
        returned_country_requests: $returned_source_requests,
        returned_country_coverage_vs_requests_attack: $returned_source_coverage,
        top_five: {
          requests: $top_five_requests,
          share_of_attack_requests: $top_five_share,
          share_of_returned_country_rows: $top_five_share_of_returned_sources
        },
        other_or_unreturned: {
          requests: $other_requests,
          share_of_attack_requests: $other_share
        },
        countries: $countries,
        methodology: "Resolve workspaces from the selected customer ID, retain production workspaces whose names contain a prd/prod/production token, split the requested reporting period into contiguous intervals of 7 days or less, query each selected workspace top-attacks endpoint with customer_id and field=remote_country_code for every interval, aggregate country counts across intervals and workspaces, and reconcile the returned country counts against requests_attack timeseries for that exact same production workspace set."
      }'
    return
  fi

  jq -r '
    def human:
      if . >= 1000000000 then (((. / 1000000000) * 100 | round) / 100 | tostring) + "B"
      elif . >= 1000000 then (((. / 1000000) * 100 | round) / 100 | tostring) + "M"
      elif . >= 1000 then (((. / 1000) * 10 | round) / 10 | tostring) + "K"
      else tostring
      end;
    def pct:
      (((. * 10000) | round) / 100 | tostring) + "%";

    ["COUNTRY", "REQUESTS", "SHARE OF ATTACK REQUESTS", "WORKSPACES"],
    (
      .[:10][]
      | [.country, (.requests | human), (.share_of_attack_requests | pct), (.workspace_count | tostring)]
    )
    | @tsv
  ' <<<"$source_summary" | human_table

  printf '\nTop five combined: %s (%s of requests_attack; %s of returned country counts)\n' \
    "$(jq -n --argjson n "$top_five_total" '
      if $n >= 1000000000 then ((($n / 1000000000) * 100 | round) / 100 | tostring) + "B"
      elif $n >= 1000000 then ((($n / 1000000) * 100 | round) / 100 | tostring) + "M"
      elif $n >= 1000 then ((($n / 1000) * 10 | round) / 10 | tostring) + "K"
      else ($n | tostring) end
    ' -r)" \
    "$(jq -n --argjson p "$top_five_share" '((($p * 10000) | round) / 100 | tostring) + "%"' -r)" \
    "$(jq -n --argjson p "$returned_top_five_share" '((($p * 10000) | round) / 100 | tostring) + "%"' -r)"

  printf '\nValidation:\n'
  printf '  - Customer: %s (%s).\n' "$customer" "$cid"
  printf '  - Production workspaces queried directly: %s (filter: %s).\n' "$workspace_count" "$prod_regex"
  printf '  - top-attacks chunking: %s chunk(s) per workspace, each <= %s days (%s API calls total).\n' \
    "$chunk_count" "$chunk_days" "$((workspace_count * chunk_count))"
  printf '  - Production-workspace requests_attack timeseries: %s.\n' "$attack_total"
  printf '  - Country rows returned by top-attacks: %s (%s of requests_attack).\n' \
    "$returned_source_total" \
    "$(jq -n --argjson p "$source_coverage" '((($p * 10000) | round) / 100 | tostring) + "%"' -r)"
  printf '  - Country identifies request origin only; it does not establish attacker identity or intent.\n'
  printf '  - Each workspace/chunk query is capped at the top %s country rows; use the coverage figure to detect an incomplete tail.\n' "$top_limit"
  printf 'WARNING: Do not use exact country shares customer-facing unless returned country coverage reconciles closely with requests_attack. A materially low or >100%% coverage indicates truncation or a metric-semantics mismatch that must be investigated first.\n'
}

cmd_signal_count() {
  [[ $# -ge 2 && $# -le 3 ]] ||
    die 'usage: ngwaf signal-count <workspace> <signal> [days]'

  cmd_count "$1" "tag:$2" "${3:-7}"
}
