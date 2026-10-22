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

# The jq program uses literal $-prefixed jq variables; shell expansion would corrupt it.
# shellcheck disable=SC2016
timeseries_instant_jq='
  def instant:
    if type != "string" then null else
      (try [capture("^(?<clock>[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9])(?<fraction>\\.[0-9]+)?(?<zone>Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$")] catch []) as $matches
      | if ($matches | length) != 1 then null else $matches[0] as $parts |
        if (($parts.fraction // ".0") | test("^\\.0+$") | not) then null else
          ($parts.clock + "Z") as $utc_clock
          | (try ($utc_clock | fromdateiso8601) catch null) as $base
          | if $base == null or ($base | todateiso8601) != $utc_clock then null
            elif $parts.zone == "Z" then $base
            else
              (($parts.zone[1:3] | tonumber) * 3600 + ($parts.zone[4:6] | tonumber)) as $offset
              | $base - (if $parts.zone[0:1] == "+" then $offset else -$offset end)
            end
        end
        end
    end;
'

# Validate only properties the response can establish. A missing bucket is
# visible, but the API does not say whether an idle day must have a zero row.
timeseries_integrity() {
  local body="$1" kind="$2" from="$3" to="$4" context="$5" diagnose="${6:-0}" result error
  result="$(jq -c --arg kind "$kind" --arg from "$from" --arg to "$to" "$timeseries_instant_jq"'
    def row_time: if $kind == "account" then .dimensions.time else .timestamp end;
    def row_workspace: if $kind == "account" then .dimensions.workspace else "__selected_workspace__" end;
    def valid_total: (.meta | type) == "object" and (.meta | has("total")) and
      (.meta.total | type) == "number" and .meta.total >= 0 and .meta.total == (.meta.total | floor);
    ($from | fromdateiso8601) as $start
    | ($to | fromdateiso8601) as $end
    | if ($start % 86400 != 0 or $end % 86400 != 0 or $end <= $start) then
        {error:"invalid requested UTC day window"}
      elif (.data | type) != "array" then {error:"malformed timeseries data"}
      elif ([.data[] | row_time | instant | select(. == null or . % 86400 != 0)] | length) > 0 then
        {error:"malformed or unaligned timeseries timestamp"}
      elif ([.data[] | row_time | instant |
        select(. < $start or . > $end or ($kind != "account" and . == $end))] | length) > 0 then
        {error:"timeseries interval outside requested window",
         offending:[.data[] | select((row_time | instant) as $t |
           $t < $start or $t > $end or ($kind != "account" and $t == $end)) |
           {timestamp: row_time, workspace: row_workspace}]}
      elif ((.meta | type) == "object" and (.meta | has("total")) and (valid_total | not)) then
        {error:"invalid timeseries meta.total"}
      elif (valid_total and .meta.total != (.data | length)) then
        {error:"timeseries meta.total differs from returned row count"}
      elif ((.meta.next_cursor? // .meta.next? // .next? // null) != null and
            (.meta.next_cursor? // .meta.next? // .next? // "") != "") then
        {error:"timeseries response indicates another page"}
      else
        ([.data[] | select($kind != "account" or (row_time | instant) < $end) |
          {workspace: row_workspace, timestamp: (row_time | instant | todateiso8601)}]) as $keys
        | (if $kind == "account" then
             [.data[] | select((row_time | instant) == $end)] | length
           else 0 end) as $excluded_end
        | ([$keys[] | [.workspace, .timestamp]] | group_by(.) | map(select(length > 1))) as $dupes
        | if ($dupes | length) > 0 then {error:"duplicate workspace/time interval"}
          else
            ([range($start; $end; 86400) | todateiso8601]) as $expected
            | ([$keys[].workspace] | unique) as $names
            | {requested_intervals: ($expected | length),
               observed_rows: ($keys | length),
               excluded_end_boundary_rows: $excluded_end,
               duplicate_intervals: 0,
               timestamp_interpretation: "daily_bucket_start_inferred_from_fixtures_not_documented",
               meta_total_checked: valid_total,
               workspace_intervals: [$names[] as $name |
                 [$keys[] | select(.workspace == $name) | .timestamp] as $observed |
                 {workspace: $name, observed_intervals: ($observed | length),
                  missing_intervals: [$expected[] | select(. as $t | $observed | index($t) | not)]}],
               completeness: "unknown",
               validation_status: "observed_rows_valid_completeness_unknown"}
          end
      end
  ' <<<"$body")" || die "$context returned malformed timeseries metadata"
  error="$(jq -r '.error // empty' <<<"$result")"
  if [[ -n "$error" ]]; then
    if [[ "$diagnose" == 1 && "$error" == 'timeseries interval outside requested window' ]]; then
      jq -c --arg from "$from" --arg to "$to" '
        .offending[] | {timestamp, workspace, requested_window:{from:$from,to:$to}}
      ' <<<"$result" | while IFS= read -r row; do
        printf '%s: interval diagnostic: %s\n' "${PROGRAM_NAME:-ngwaf}" "$row" >&2
      done
    fi
    die "$context: $error"
  fi
  printf '%s\n' "$result"
}

timeseries_warn_gaps() {
  local validation="$1" context="$2" missing unobserved
  missing="$(jq '[.workspace_intervals[].missing_intervals | length] | add // 0' <<<"$validation")"
  unobserved="$(jq '.unobserved_workspaces // [] | length' <<<"$validation")"
  if (( missing > 0 || unobserved > 0 )); then
    printf '%s: %s has %s unobserved workspace/day interval(s) and %s inventory workspace(s) with no rows; completeness is unknown\n' \
      "${PROGRAM_NAME:-ngwaf}" "$context" "$missing" "$unobserved" >&2
  fi
}

exclude_account_end_boundary_rows() {
  local body="$1" to="$2"
  jq --arg to "$to" "$timeseries_instant_jq"'
    ($to | fromdateiso8601) as $end |
    .data |= map(select((.dimensions.time | instant) != $end))
  ' <<<"$body"
}

timeseries_warn_excluded_end() {
  local validation="$1" context="$2" excluded
  excluded="$(jq -r '.excluded_end_boundary_rows // 0' <<<"$validation")"
  if (( excluded > 0 )); then
    printf '%s: %s: excluded %s row(s) timestamped at the requested end boundary from aggregation; bucket timestamp semantics remain unverified\n' \
      "${PROGRAM_NAME:-ngwaf}" "$context" "$excluded" >&2
  fi
}

account_timeseries_workspace_ids() {
  local body="$1" cid="$2" context="$3" inventory mapping
  inventory="$(get_all_pages /ngwaf/v1/workspaces --data-urlencode "customer_id=$cid")"
  mapping="$(json_stream "$inventory" "$body" | jq -sc '
    .[0] as $inventory | .[1] as $rows | $inventory |
    [.data[] | select((.id | type) != "string" or (.id | length) == 0 or
                      (.name | type) != "string" or (.name | length) == 0)] as $invalid
    | if ($invalid | length) > 0 then {error:"incomplete workspace inventory"}
      else
        ([.data | group_by(.name)[] | select(length > 1)] | length) as $collisions
        | if $collisions > 0 then {error:"workspace display-name collision in selected customer"}
          else
            [.data[] | {key:.name, value:.id}] | from_entries as $ids
            | ([$rows.data[].dimensions.workspace | select($ids[.] == null)] | unique) as $unknown
            | if ($unknown | length) > 0 then {error:"timeseries workspace name is absent from selected customer inventory"}
              else $ids end
          end
      end
  ')" || die "$context could not validate workspace inventory"
  [[ "$(jq -r '.error // empty' <<<"$mapping")" == "" ]] ||
    die "$context: $(jq -r '.error' <<<"$mapping")"
  printf '%s\n' "$mapping"
}

timeseries_attach_workspace_inventory() {
  json_stream "$1" "$2" | jq -s '
    .[0] as $validation | .[1] as $ids |
    ($validation.workspace_intervals | map(.workspace)) as $observed |
    $validation + {
      workspace_intervals: [$validation.workspace_intervals[] |
        . + {workspace_id: $ids[.workspace]}],
      unobserved_workspaces: [$ids | keys[] as $name |
        select($observed | index($name) | not) |
        {workspace: $name, workspace_id: $ids[$name]}]
    }
  '
}

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
  [[ $# -le 2 ]] || die 'usage: ngwaf overview [days] [--json]'
  local days="${1:-30}"
  local format="${2:-}"
  local cid customer body summary validation workspace_ids

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
  validation="$(timeseries_integrity "$body" account "$TS_FROM" "$TS_TO" "account overview")"
  workspace_ids="$(account_timeseries_workspace_ids "$body" "$cid" "account overview")"
  body="$(exclude_account_end_boundary_rows "$body" "$TS_TO")"
  timeseries_warn_excluded_end "$validation" "account overview"
  validation="$(timeseries_attach_workspace_inventory "$validation" "$workspace_ids")"
  timeseries_warn_gaps "$validation" "account overview"

  summary="$(
    json_stream "$body" "$workspace_ids" | jq -s '
      .[0] as $response | .[1] as $ids | $response |
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
          workspace_id: $ids[.[0].workspace],
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
    '
  )"

  if [[ "$format" == "--json" ]]; then
    json_stream "$summary" "$validation" |
      jq -s \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --argjson days "$days" '
      .[0] as $workspaces | .[1] as $validation
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
        validation: $validation,
        provenance: {
          endpoint: "GET /ngwaf/v1/timeseries",
          data_class: "ngwaf_timeseries",
          aggregation: "sum_of_daily_workspace_rows",
          requested_metrics: ["requests_total", "requests_attack", "requests_total_blocked"],
          missing_data_policy: "report_unobserved_intervals_without_zero_substitution",
          workspace_identity: "current_customer_inventory_name_match",
          completeness: "unknown"
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
  local cid customer input resolved w ws_id days format body validation
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
  validation=null
  if [[ -n "$TS_TO" && "$TS_FROM" == *T00:00:00Z && "$TS_TO" == *T00:00:00Z ]]; then
    validation="$(timeseries_integrity "$body" workspace "$TS_FROM" "$TS_TO" "timeseries for workspace $w")"
    timeseries_warn_gaps "$validation" "timeseries for workspace $w"
  fi

  if [[ "$format" == "--json" ]]; then
    json_stream "$body" "$validation" |
      jq -s \
      --arg workspace "$w" \
      --arg workspace_id "$ws_id" \
      --arg workspace_input "$input" \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --arg days "$days" '
      .[0] as $response | .[1] as $validation
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
        validation: $validation,
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
    die 'usage: ngwaf metrics <metric1,metric2,...> [days|--start UTC --end UTC] [--json] [--diagnose-intervals]'

  local cid customer metrics days format body summary validation workspace_ids start end start_epoch end_epoch diagnose_intervals
  cid="$(current_cid)"
  customer="$(current_customer_name)"
  metrics="$(tr -d '[:space:]' <<<"$1")"
  shift
  days=""
  format=""
  start=""
  end=""
  diagnose_intervals=0
  while (( $# > 0 )); do
    case "$1" in
      --json) [[ -z "$format" ]] || die 'duplicate --json'; format=--json; shift ;;
      --diagnose-intervals) (( diagnose_intervals == 0 )) || die 'duplicate --diagnose-intervals'; diagnose_intervals=1; shift ;;
      --start|--end)
        (( $# >= 2 )) || die "missing value for $1"
        if [[ "$1" == --start ]]; then
          [[ -z "$start" ]] || die 'duplicate --start'
          start="$2"
        else
          [[ -z "$end" ]] || die 'duplicate --end'
          end="$2"
        fi
        shift 2 ;;
      [0-9]*) [[ -z "$days" ]] || die 'duplicate days'; days="$1"; shift ;;
      *) die "invalid metrics argument: $1" ;;
    esac
  done

  [[ -n "$metrics" ]] || die 'at least one metric is required'
  if [[ -n "$start" || -n "$end" ]]; then
    [[ -n "$start" && -n "$end" && -z "$days" ]] || die 'metrics --start and --end are required together without days'
    start_epoch="$(timeseries_utc_epoch "$start")" || die 'invalid --start: expected UTC RFC3339 YYYY-MM-DDTHH:MM:SSZ'
    end_epoch="$(timeseries_utc_epoch "$end")" || die 'invalid --end: expected UTC RFC3339 YYYY-MM-DDTHH:MM:SSZ'
    [[ "$start" == *T00:00:00Z && "$end" == *T00:00:00Z ]] || die 'metrics explicit window must start and end at UTC midnight'
    (( end_epoch > start_epoch && (end_epoch - start_epoch) % 86400 == 0 &&
       end_epoch - start_epoch <= 30 * 86400 )) || die 'metrics explicit window must be 1-30 complete UTC days'
    days=$(( (end_epoch - start_epoch) / 86400 ))
    TS_FROM="$start"
    TS_TO="$end"
  else
    days="${days:-30}"
    validate_timeseries_days "$days"
    make_timeseries_window "$days"
  fi

  body="$(
    get "/ngwaf/v1/timeseries" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "from=$TS_FROM" \
      --data-urlencode "to=$TS_TO" \
      --data-urlencode "metrics=$metrics" \
      --data-urlencode "dimensions=workspaces,time" \
      --data-urlencode "granularity=86400"
  )"

  body="$(normalize_account_timeseries_response "$body" "$metrics" "account metric summary")"
  validation="$(timeseries_integrity "$body" account "$TS_FROM" "$TS_TO" "account metric summary" "$diagnose_intervals")"
  workspace_ids="$(account_timeseries_workspace_ids "$body" "$cid" "account metric summary")"
  body="$(exclude_account_end_boundary_rows "$body" "$TS_TO")"
  timeseries_warn_excluded_end "$validation" "account metric summary"
  validation="$(timeseries_attach_workspace_inventory "$validation" "$workspace_ids")"
  timeseries_warn_gaps "$validation" "account metric summary"

  summary="$(
    json_stream "$body" "$workspace_ids" | jq -s --arg metrics "$metrics" '
      .[0] as $response | .[1] as $ids | $response |
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
          | {workspace: $rows[0].workspace, workspace_id: $ids[$rows[0].workspace]}
            + reduce $metrics[] as $metric (
                {};
                .[$metric] = (
                  [$rows[] | (.values[$metric] | tonumber)] | add
                )
              )
        )
      | sort_by(.workspace)
    '
  )"

  if [[ "$format" == "--json" ]]; then
    json_stream "$summary" "$validation" |
      jq -s \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --arg metrics "$metrics" \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --argjson days "$days" '
      .[0] as $data | .[1] as $validation
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
        validation: $validation,
        provenance: {
          endpoint: "GET /ngwaf/v1/timeseries",
          data_class: "ngwaf_timeseries",
          aggregation: "sum_of_daily_workspace_rows",
          granularity_seconds: 86400,
          missing_data_policy: "report_unobserved_intervals_without_zero_substitution",
          workspace_identity: "current_customer_inventory_name_match",
          completeness: "unknown"
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
