# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

timeseries_debug_shape() {
  debug_enabled || return 0
  local body="$1" kind="$2" metrics="$3"
  jq -c --arg kind "$kind" --arg metrics "$metrics" '
    def field_type($row; $key):
      if ($row | type) != "object" then "no_object"
      elif ($row | has($key) | not) then "missing"
      else ($row[$key] | type) end;
    (.data // null) as $rows
    | ($rows | if type == "array" then . else [] end) as $safe_rows
    | ($safe_rows[0] // null) as $first
    | {
        endpoint: $kind,
        data_type: ($rows | type),
        row_count: ($safe_rows | length),
        first_row_type: ($first | type),
        timestamp_type: field_type($first; "timestamp"),
        dimensions_type: field_type($first; "dimensions"),
        values_type: field_type($first; "values"),
        values_count: (if ($first.values? | type) == "array" then ($first.values | length) else null end),
        requested_metric_types: [($metrics | split(","))[] as $m | {
          metric: $m,
          row: field_type($first; $m),
          first_value: field_type($first.values?[0]?; $m),
          any_value: (if ($first.values? | type) == "array" then
            [$first.values[] | select(type == "object" and has($m)) | .[$m] | type] | unique
          else [] end)
        }]
      }
  ' <<<"$body" | while IFS= read -r shape; do
    printf '%s: debug: timeseries response shape: %s\n' "${PROGRAM_NAME:-ngwaf}" "$shape" >&2
  done
}

timeseries_numeric_jq='def numeric: (type == "number") or (type == "string" and test("^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$") and (tonumber? != null));'

validate_workspace_timeseries_body() {
  local body="$1" metrics="$2" context="$3" bad
  jq -e '.data | type == "array" and length > 0' >/dev/null <<<"$body" ||
    die "$context returned no timeseries rows; refusing to treat missing data as zero"
  jq -e 'all(.data[]; (.timestamp | type) == "string" and (.timestamp | length) > 0)' >/dev/null <<<"$body" ||
    die "$context returned a timeseries row without a timestamp"
  bad="$(jq -r --arg metrics "$metrics" "$timeseries_numeric_jq
    (\$metrics | split(\",\")) as \$names
    | [.data[] as \$row | \$names[] as \$name
       | select((\$row | type) != \"object\" or ((\$row[\$name]? | numeric) | not))
       | \$name] | unique | join(\",\")" <<<"$body")"
  [[ -z "$bad" ]] || die "$context omitted or returned non-numeric requested metric(s): $bad; refusing to substitute zero"
}

validate_account_timeseries_body() {
  local body="$1" metrics="$2" context="$3" bad
  jq -e '.data | type == "array" and length > 0' >/dev/null <<<"$body" ||
    die "$context returned no timeseries rows; refusing to treat missing data as zero"
  jq -e 'all(.data[]; (.dimensions.workspace | type) == "string" and (.dimensions.time | type) == "string")' >/dev/null <<<"$body" ||
    die "$context returned a timeseries row without workspace/time dimensions"
  bad="$(jq -r --arg metrics "$metrics" "$timeseries_numeric_jq
    (\$metrics | split(\",\")) as \$names
    | [.data[] as \$row | \$names[] as \$name
       | select((\$row.values | type) != \"array\" or
                ([\$row.values[]? | select(type == \"object\" and has(\$name))] | length) != 1 or
                (([\$row.values[]? | select(type == \"object\" and has(\$name))][0][\$name] | numeric) | not))
       | \$name] | unique | join(\",\")" <<<"$body")"
  [[ -z "$bad" ]] || die "$context omitted or returned non-numeric requested metric(s): $bad; refusing to substitute zero"
  jq -e '[.data[].values[] | type == "object"] | all' >/dev/null <<<"$body" ||
    die "$context returned malformed metric values; expected an array of metric objects"
}

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
    NGWAF_TIMESERIES_DEBUG=account get "/ngwaf/v1/timeseries" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "from=$TS_FROM" \
      --data-urlencode "to=$TS_TO" \
      --data-urlencode "metrics=$CORE_METRICS" \
      --data-urlencode "dimensions=workspaces,time" \
      --data-urlencode "granularity=86400"
  )"

  timeseries_debug_shape "$body" account "$CORE_METRICS"
  validate_account_timeseries_body "$body" "$CORE_METRICS" "account overview"

  summary="$(
    jq '
      [
        .data[]
        | {
            workspace: .dimensions.workspace,
            timestamp: .dimensions.time,
            values: (reduce .values[] as $metric ({}; . + $metric))
          }
      ]
      | group_by(.workspace)
      | map({
          workspace: .[0].workspace,
          requests_total: (map(.values.requests_total | tonumber) | add),
          requests_attack: (map(.values.requests_attack | tonumber) | add),
          requests_total_blocked: (map(.values.requests_total_blocked | tonumber) | add),
          buckets: (map({
            timestamp,
            requests_total: (.values.requests_total | tonumber),
            requests_attack: (.values.requests_attack | tonumber),
            requests_total_blocked: (.values.requests_total_blocked | tonumber)
          }) | sort_by(.timestamp))
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

timeseries_arg_error() {
  die "$1; example: ${PROGRAM_NAME:-fastly-audit} ngwaf timeseries vi-agent-production 7 --json"
}

timeseries_utc_epoch() {
  local value="$1" rendered epoch
  [[ "$value" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$ ]] || return 1
  if rendered="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
    epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' 2>/dev/null)" || return 1
  else
    rendered="$(date -u -d "$value" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || return 1
    epoch="$(date -u -d "$value" '+%s' 2>/dev/null)" || return 1
  fi
  [[ "$rendered" == "$value" ]] || return 1
  printf '%s\n' "$epoch"
}

timeseries_parse_args() {
  TIMESERIES_HELP=0 TIMESERIES_WORKSPACE='' TIMESERIES_DAYS='' TIMESERIES_START='' TIMESERIES_END='' TIMESERIES_FORMAT=''
  local value
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        # Consumed by lib/dispatch.sh after preflight-free argument parsing.
        # shellcheck disable=SC2034
        TIMESERIES_HELP=1
        return 0
        ;;
      --json) [[ -z "$TIMESERIES_FORMAT" ]] || timeseries_arg_error 'duplicate --json'; TIMESERIES_FORMAT=--json ;;
      --start|--end)
        value="$1"
        (( $# >= 2 )) || timeseries_arg_error "missing value for $value (expected UTC RFC3339, e.g. 2026-09-01T00:00:00Z)"
        if [[ "$value" == --start ]]; then
          [[ -z "$TIMESERIES_START" ]] || timeseries_arg_error 'duplicate --start'
          TIMESERIES_START="$2"
        else
          [[ -z "$TIMESERIES_END" ]] || timeseries_arg_error 'duplicate --end'
          TIMESERIES_END="$2"
        fi
        shift
        ;;
      -*) timeseries_arg_error "unknown option: $1" ;;
      *)
        if [[ -z "$TIMESERIES_WORKSPACE" ]]; then
          TIMESERIES_WORKSPACE="$1"
        elif [[ -z "$TIMESERIES_DAYS" && "$1" =~ ^[0-9]+$ ]]; then
          TIMESERIES_DAYS="$1"
        else
          timeseries_arg_error "unexpected positional argument: $1"
        fi
        ;;
    esac
    shift
  done
  [[ -n "$TIMESERIES_WORKSPACE" ]] || timeseries_arg_error 'missing required workspace'
  if [[ -n "$TIMESERIES_START" || -n "$TIMESERIES_END" ]]; then
    [[ -n "$TIMESERIES_START" ]] || timeseries_arg_error 'missing required --start for explicit date range'
    [[ -z "$TIMESERIES_DAYS" ]] || timeseries_arg_error 'days cannot be combined with --start or --end'
    local start_epoch end_epoch
    start_epoch="$(timeseries_utc_epoch "$TIMESERIES_START")" || timeseries_arg_error 'invalid --start: expected UTC RFC3339 YYYY-MM-DDTHH:MM:SSZ'
    if [[ -n "$TIMESERIES_END" ]]; then
      end_epoch="$(timeseries_utc_epoch "$TIMESERIES_END")" || timeseries_arg_error 'invalid --end: expected UTC RFC3339 YYYY-MM-DDTHH:MM:SSZ'
      (( end_epoch > start_epoch )) || timeseries_arg_error '--end must be later than --start'
    fi
  else
    TIMESERIES_DAYS="${TIMESERIES_DAYS:-30}"
    validate_timeseries_days "$TIMESERIES_DAYS"
  fi
}

cmd_timeseries() {
  local cid customer input resolved w ws_id days format body
  cid="$(current_cid)"
  customer="$(current_customer_name)"
  input="$TIMESERIES_WORKSPACE"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
  days="$TIMESERIES_DAYS"
  format="$TIMESERIES_FORMAT"
  if [[ -n "$TIMESERIES_START" ]]; then
    TS_FROM="$TIMESERIES_START"
    TS_TO="$TIMESERIES_END"
  else
    make_timeseries_window "$days"
  fi

  local -a query_args=(
    --data-urlencode "customer_id=$cid"
    --data-urlencode "start=$TS_FROM"
    --data-urlencode "metrics=$CORE_METRICS"
    --data-urlencode "granularity=86400"
  )
  [[ -z "$TS_TO" ]] || query_args+=(--data-urlencode "end=$TS_TO")
  body="$(NGWAF_TIMESERIES_DEBUG=workspace NGWAF_HTTP_ERROR_CONTEXT=timeseries get "$(workspace_path "$ws_id")/timeseries" "${query_args[@]}")"

  timeseries_debug_shape "$body" workspace "$CORE_METRICS"
  validate_workspace_timeseries_body "$body" "$CORE_METRICS" "timeseries for workspace $w"

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
      --arg days "$days" '
      .[0] as $response
      | {
        customer: $customer,
        customer_id: $customer_id,
        workspace: $workspace,
        workspace_id: $workspace_id,
        workspace_input: $workspace_input,
        days: (if $days == "" then null else ($days | tonumber) end),
        window: {
          type: (if $days == "" then "explicit_utc_range" else "complete_utc_days" end),
          from: $from,
          to: (if $to == "" then null else $to end),
          to_is_exclusive: (if $days == "" then null else true end)
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

  if [[ -n "$days" ]]; then
    printf '%s — %s-day NGWAF timeseries\n' "$w" "$days"
    printf '%s → %s UTC (complete days)\n\n' "$TS_FROM" "$TS_TO"
  else
    printf '%s — NGWAF timeseries\n' "$w"
    printf '%s → %s UTC\n\n' "$TS_FROM" "${TS_TO:-latest available}"
  fi

  jq -r '
    ["TIMESTAMP", "REQUESTS", "ATTACK-TAGGED", "BLOCKED"],
    (
      .data
      | sort_by(.timestamp)
      | .[]
      | [
          .timestamp,
          ((.requests_total | tonumber) | tostring),
          ((.requests_attack | tonumber) | tostring),
          ((.requests_total_blocked | tonumber) | tostring)
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
