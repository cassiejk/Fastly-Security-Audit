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

  customer="$(current_customer_name)"

  body="$(
    get "/ngwaf/v1/timeseries" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "from=$TS_FROM" \
      --data-urlencode "to=$TS_TO" \
      --data-urlencode "metrics=$CORE_METRICS" \
      --data-urlencode "dimensions=workspaces,time" \
      --data-urlencode "granularity=86400"
  )"

  validate_timeseries_response "$body" "$CORE_METRICS" "account overview"

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
          requests_total: (map(.values.requests_total | tonumber) | add),
          requests_attack: (map(.values.requests_attack | tonumber) | add),
          requests_total_blocked: (map(.values.requests_total_blocked | tonumber) | add)
        })
      | sort_by(-.requests_total)
    ' <<<"$body"
  )"

  if [[ "$format" == "--json" ]]; then
    json_stream "$summary" |
      jq -s \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --argjson days "$days" '
      .[0] as $workspaces
      | {
        customer: $customer,
        customer_id: $customer_id,
        days: $days,
        from: $from,
        to: $to,
        window: {
          type: "complete_utc_days",
          from: $from,
          to: $to,
          to_is_exclusive: true
        },
        workspaces: $workspaces,
        provenance: {
          endpoint: "GET /ngwaf/v1/timeseries",
          data_class: "ngwaf_timeseries",
          aggregation: "sum_of_daily_workspace_rows",
          requested_metrics: ["requests_total", "requests_attack", "requests_total_blocked"],
          missing_data_policy: "fail_closed"
        }
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

  local cid customer input resolved w ws_id days format body
  cid="$(current_cid)"
  customer="$(current_customer_name)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
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
    get "$(workspace_path "$ws_id")/timeseries" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "from=$TS_FROM" \
      --data-urlencode "to=$TS_TO" \
      --data-urlencode "metrics=$CORE_METRICS" \
      --data-urlencode "granularity=86400"
  )"

  validate_timeseries_response "$body" "$CORE_METRICS" "timeseries for workspace $w"

  if [[ "$format" == "--json" ]]; then
    json_stream "$body" |
      jq -s \
      --arg workspace "$w" \
      --arg workspace_id "$ws_id" \
      --arg workspace_input "$input" \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --argjson days "$days" '
      .[0] as $response
      | {
        customer: $customer,
        customer_id: $customer_id,
        workspace: $workspace,
        workspace_id: $workspace_id,
        workspace_input: $workspace_input,
        days: $days,
        window: {
          type: "complete_utc_days",
          from: $from,
          to: $to,
          to_is_exclusive: true
        },
        data: $response.data,
        meta: ($response.meta // null),
        provenance: {
          endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/timeseries",
          data_class: "ngwaf_timeseries",
          granularity_seconds: 86400,
          requested_metrics: ["requests_total", "requests_attack", "requests_total_blocked"],
          missing_data_policy: "fail_closed"
        }
      }'
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
          ((.values[0].requests_total | tonumber) | tostring),
          ((.values[0].requests_attack | tonumber) | tostring),
          ((.values[0].requests_total_blocked | tonumber) | tostring)
        ]
    )
    | @tsv
  ' <<<"$body" | human_table
}

cmd_metrics() {
  [[ $# -ge 1 ]] ||
    die 'usage: ngwaf metrics <metric1,metric2,...> [days] [--json]'

  local cid customer metrics days format body summary
  cid="$(current_cid)"
  customer="$(current_customer_name)"
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

  validate_timeseries_response "$body" "$metrics" "account metric summary"

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
                  [$rows[] | (.values[$metric] | tonumber)] | add
                )
              )
        )
      | sort_by(.workspace)
    ' <<<"$body"
  )"

  if [[ "$format" == "--json" ]]; then
    json_stream "$summary" |
      jq -s \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --arg metrics "$metrics" \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --argjson days "$days" '
      .[0] as $data
      | {
        customer: $customer,
        customer_id: $customer_id,
        days: $days,
        window: {
          type: "complete_utc_days",
          from: $from,
          to: $to,
          to_is_exclusive: true
        },
        requested_metrics: ($metrics | split(",")),
        data: $data,
        provenance: {
          endpoint: "GET /ngwaf/v1/timeseries",
          data_class: "ngwaf_timeseries",
          aggregation: "sum_of_daily_workspace_rows",
          granularity_seconds: 86400,
          missing_data_policy: "fail_closed"
        }
      }'
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
          + [$metrics[] as $metric | (($row[$metric] | tonumber) | tostring)]
      )
    | @tsv
  ' <<<"$summary" | human_table
}
