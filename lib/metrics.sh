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

REQUEST_SEARCH_DEFAULT_LIMIT="${NGWAF_REQUEST_SEARCH_DEFAULT_LIMIT:-25}"
REQUEST_SEARCH_PAGE_SIZE="${NGWAF_REQUEST_SEARCH_PAGE_SIZE:-100}"
REQUEST_SEARCH_MAX_LIMIT="${NGWAF_REQUEST_SEARCH_MAX_LIMIT:-1000}"
REQUEST_SEARCH_CUSTOMER=""
REQUEST_SEARCH_CUSTOMER_ID=""
REQUEST_SEARCH_WORKSPACE=""
REQUEST_SEARCH_WORKSPACE_ID=""
REQUEST_SEARCH_WORKSPACE_INPUT=""
REQUEST_SEARCH_REQUESTED_QUERY=""
REQUEST_SEARCH_QUERY=""
REQUEST_SEARCH_DAYS=""
REQUEST_SEARCH_FROM_UTC=""
REQUEST_SEARCH_UNTIL_UTC=""
REQUEST_SEARCH_FROM_EPOCH=""
REQUEST_SEARCH_UNTIL_EPOCH=""
RULE_AUDIT_DEFAULT_SIGNALS="${NGWAF_RULE_AUDIT_SIGNALS:-SQLI,XSS,CMDEXE,TRAVERSAL,SCANNER,SUSPECTED-BAD-BOT,DATACENTER}"
RULE_AUDIT_HIGH_VOLUME="${NGWAF_RULE_AUDIT_HIGH_VOLUME:-1000000}"
RULE_AUDIT_STALE_DAYS="${NGWAF_RULE_AUDIT_STALE_DAYS:-365}"

request_search_validate_limit() {
  local limit="$1"

  [[ "$REQUEST_SEARCH_DEFAULT_LIMIT" =~ ^[0-9]+$ ]] ||
    die 'NGWAF_REQUEST_SEARCH_DEFAULT_LIMIT must be a positive integer'
  [[ "$REQUEST_SEARCH_PAGE_SIZE" =~ ^[0-9]+$ ]] ||
    die 'NGWAF_REQUEST_SEARCH_PAGE_SIZE must be a positive integer'
  [[ "$REQUEST_SEARCH_MAX_LIMIT" =~ ^[0-9]+$ ]] ||
    die 'NGWAF_REQUEST_SEARCH_MAX_LIMIT must be a positive integer'

  (( REQUEST_SEARCH_DEFAULT_LIMIT >= 1 )) ||
    die 'NGWAF_REQUEST_SEARCH_DEFAULT_LIMIT must be at least 1'
  (( REQUEST_SEARCH_PAGE_SIZE >= 1 && REQUEST_SEARCH_PAGE_SIZE <= 100 )) ||
    die 'NGWAF_REQUEST_SEARCH_PAGE_SIZE must be between 1 and 100'
  (( REQUEST_SEARCH_MAX_LIMIT >= 1 )) ||
    die 'NGWAF_REQUEST_SEARCH_MAX_LIMIT must be at least 1'

  [[ "$limit" =~ ^[0-9]+$ ]] || die 'request limit must be an integer'
  (( limit >= 1 )) || die 'request limit must be at least 1'
  (( limit <= REQUEST_SEARCH_MAX_LIMIT )) ||
    die "request limit exceeds NGWAF_REQUEST_SEARCH_MAX_LIMIT ($REQUEST_SEARCH_MAX_LIMIT)"
}

request_search_normalize_query() {
  local query="$1"

  # Fastly's request-search key for a matching rule ID is `ruleid`. Earlier
  # helper guidance used `rule`, which the API silently ignored and therefore
  # returned the unfiltered workspace total. Preserve that convenient spelling
  # as an explicit, visible alias rather than returning misleading results.
  if [[ "$query" =~ (^|[[:space:]])rule: ]]; then
    query="$(sed -E 's/(^|[[:space:]])rule:/\1ruleid:/g' <<<"$query")"
    printf '%s: note: normalized search key rule: to ruleid:\n' \
      "${PROGRAM_NAME:-ngwaf}" >&2
  fi

  printf '%s\n' "$query"
}

request_search_make_window() {
  local days="$1"
  local end start

  validate_request_days "$days"

  # Five-minute buffer for the request-search ingestion pipeline.
  if date -u -v-5M +%s >/dev/null 2>&1; then
    end="$(date -u -v-5M +%s)"
  else
    end="$(date -u -d '5 minutes ago' +%s)"
  fi

  start=$((end - (days * 86400)))

  REQUEST_SEARCH_DAYS="$days"
  REQUEST_SEARCH_FROM_EPOCH="$start"
  REQUEST_SEARCH_UNTIL_EPOCH="$end"
  REQUEST_SEARCH_FROM_UTC="$(epoch_to_utc "$start")"
  REQUEST_SEARCH_UNTIL_UTC="$(epoch_to_utc "$end")"
}

request_search_validate_response() {
  [[ $# -eq 2 ]] || die 'request_search_validate_response requires <body> <context>'

  local body="$1"
  local context="$2"

  jq -e '
    (.data | type) == "array"
    and ((has("meta") | not) or (.meta | type == "object"))
    and (
      (.meta.total? == null)
      or (
        (.meta.total | type) == "number"
        and .meta.total >= 0
        and ((.meta.total | floor) == .meta.total)
      )
    )
  ' >/dev/null <<<"$body" ||
    die "$context returned an unexpected response; refusing to report request-search results"
}

request_search_get_page() {
  [[ $# -eq 5 ]] ||
    die 'request_search_get_page requires <workspace-id> <query> <limit> <page> <progress-label>'

  local ws_id="$1"
  local query="$2"
  local limit="$3"
  local page="$4"
  local progress_label="$5"

  if [[ -n "$page" ]]; then
    NGWAF_PROGRESS_LABEL="$progress_label" \
      get "$(workspace_path "$ws_id")/requests" \
        --data-urlencode "customer_id=$REQUEST_SEARCH_CUSTOMER_ID" \
        --data-urlencode "limit=$limit" \
        --data-urlencode "page=$page" \
        --data-urlencode "q=from:$REQUEST_SEARCH_FROM_EPOCH until:$REQUEST_SEARCH_UNTIL_EPOCH $query"
  else
    NGWAF_PROGRESS_LABEL="$progress_label" \
      get "$(workspace_path "$ws_id")/requests" \
        --data-urlencode "customer_id=$REQUEST_SEARCH_CUSTOMER_ID" \
        --data-urlencode "limit=$limit" \
        --data-urlencode "q=from:$REQUEST_SEARCH_FROM_EPOCH until:$REQUEST_SEARCH_UNTIL_EPOCH $query"
  fi
}

request_search_fetch() {
  [[ $# -eq 4 ]] ||
    die 'request_search_fetch requires <workspace-id> <query> <limit> <progress-label>'

  local ws_id="$1"
  local query="$2"
  local requested_limit="$3"
  local progress_label="$4"
  local page_size="$REQUEST_SEARCH_PAGE_SIZE"
  local body

  request_search_validate_limit "$requested_limit"

  if (( requested_limit <= page_size )); then
    if body="$(request_search_get_page "$ws_id" "$query" "$requested_limit" "" "$progress_label")"; then
      :
    else
      return 1
    fi
    request_search_validate_response "$body" "request search"
    json_stream "$body" |
      jq -s --argjson limit "$requested_limit" '
        .[0] as $response
        | $response + {
            meta: (($response.meta // {}) + {
              limit_requested: $limit,
              pages_fetched: 1,
              rows_returned: ($response.data | length)
            })
          }
      '
    return
  fi

  local pages_tmp page fetched total pages_fetched remaining per_page count page_total
  local target total_json duplicate_ids
  pages_tmp="$(mktemp)"
  page=1
  fetched=0
  total=-1
  pages_fetched=0

  while (( fetched < requested_limit )); do
    remaining=$(( requested_limit - fetched ))
    per_page="$page_size"
    (( remaining < per_page )) && per_page="$remaining"

    if body="$(
      request_search_get_page \
        "$ws_id" \
        "$query" \
        "$per_page" \
        "$page" \
        "$progress_label (page $page)"
    )"; then
      :
    else
      rm -f "$pages_tmp"
      return 1
    fi
    request_search_validate_response "$body" "request search page $page"

    count="$(jq '.data | length' <<<"$body")"
    (( count <= per_page )) || {
      rm -f "$pages_tmp"
      die "request-search page $page returned more rows than requested"
    }

    page_total="$(
      jq -r '
        if (.meta.total? | type) == "number"
        then (.meta.total | tostring)
        else empty
        end
      ' <<<"$body"
    )"
    if [[ -n "$page_total" ]]; then
      if (( total < 0 )); then
        total="$page_total"
      elif (( page_total != total )); then
        printf 'WARNING: request-search total changed from %s to %s while paging; using latest total.\n' \
          "$total" "$page_total" >&2
        total="$page_total"
      fi
    fi

    jq '.data' <<<"$body" >>"$pages_tmp"
    fetched=$(( fetched + count ))
    pages_fetched=$(( pages_fetched + 1 ))

    target="$requested_limit"
    if (( total >= 0 && total < target )); then
      target="$total"
    fi

    if (( count == 0 )); then
      if (( fetched < target )); then
        rm -f "$pages_tmp"
        die "request-search pagination stopped early: retrieved $fetched of $target requested rows"
      fi
      break
    fi

    if (( count < per_page )); then
      if (( total >= 0 && fetched < target )); then
        rm -f "$pages_tmp"
        die "request-search pagination returned a short page before completion: retrieved $fetched of $target requested rows"
      fi
      break
    fi

    (( total >= 0 && fetched >= total )) && break
    page=$(( page + 1 ))
    (( page <= 1000 )) || {
      rm -f "$pages_tmp"
      die 'request-search pagination safety limit exceeded'
    }
  done

  duplicate_ids="$(
    jq -s '
      (add // [])
      | [.[].id // empty | select(length > 0)] as $ids
      | ($ids | length) != ($ids | unique | length)
    ' "$pages_tmp"
  )"
  if [[ "$duplicate_ids" == "true" ]]; then
    rm -f "$pages_tmp"
    die 'request-search pagination returned duplicate request IDs; refusing to report ambiguous rows'
  fi

  total_json="null"
  (( total >= 0 )) && total_json="$total"

  jq -s \
    --argjson limit "$requested_limit" \
    --argjson total "$total_json" \
    --argjson pages_fetched "$pages_fetched" \
    --argjson rows_returned "$fetched" \
    '{
      meta: {
        total: $total,
        limit_requested: $limit,
        pages_fetched: $pages_fetched,
        rows_returned: $rows_returned
      },
      data: (add // [])
    }' "$pages_tmp"

  rm -f "$pages_tmp"
}

request_search_prepare_scope() {
  [[ $# -eq 2 ]] ||
    die 'request_search_prepare_scope requires <workspace> <days>'

  local input="$1"
  local days="$2"
  local resolved

  request_search_make_window "$days"

  REQUEST_SEARCH_CUSTOMER_ID="$(current_cid)"
  REQUEST_SEARCH_CUSTOMER="$(current_customer_name)"
  REQUEST_SEARCH_WORKSPACE_INPUT="$input"

  resolved="$(resolve_workspace_json "$input")"
  REQUEST_SEARCH_WORKSPACE="$(jq -r '.name' <<<"$resolved")"
  REQUEST_SEARCH_WORKSPACE_ID="$(jq -r '.id' <<<"$resolved")"
}

request_search_execute() {
  [[ $# -eq 3 ]] ||
    die 'request_search_execute requires <query> <limit> <mode>'

  local requested_query="$1"
  local limit="$2"
  local mode="$3"
  local progress_label

  request_search_validate_limit "$limit"
  [[ -n "$REQUEST_SEARCH_CUSTOMER_ID" ]] ||
    die 'request-search customer scope has not been prepared'
  [[ -n "$REQUEST_SEARCH_WORKSPACE_ID" ]] ||
    die 'request-search workspace scope has not been prepared'

  REQUEST_SEARCH_REQUESTED_QUERY="$requested_query"
  REQUEST_SEARCH_QUERY="$(request_search_normalize_query "$requested_query")"

  case "$mode" in
    count)
      progress_label="counting matching requests in $REQUEST_SEARCH_WORKSPACE"
      ;;
    requests)
      progress_label="retrieving matching requests in $REQUEST_SEARCH_WORKSPACE"
      ;;
    *)
      die "unknown request-search mode: $mode"
      ;;
  esac

  request_search_fetch \
    "$REQUEST_SEARCH_WORKSPACE_ID" \
    "$REQUEST_SEARCH_QUERY" \
    "$limit" \
    "$progress_label"
}

request_search_run() {
  [[ $# -eq 5 ]] ||
    die 'request_search_run requires <workspace> <query> <days> <limit> <mode>'

  local input="$1"
  local requested_query="$2"
  local days="$3"
  local limit="$4"
  local mode="$5"

  request_search_prepare_scope "$input" "$days"
  request_search_execute "$requested_query" "$limit" "$mode"
}

cmd_count() {
  [[ $# -ge 2 && $# -le 3 ]] ||
    die "usage: ngwaf count <workspace> '<search query>' [days]"

  local body body_tmp
  body_tmp="$(mktemp)"
  if request_search_run "$1" "$2" "${3:-7}" 1 count >"$body_tmp"; then
    :
  else
    local rc=$?
    rm -f "$body_tmp"
    return "$rc"
  fi
  body="$(<"$body_tmp")"
  rm -f "$body_tmp"

  jq -e '
    (.data | type) == "array"
    and (.meta | type) == "object"
    and ((.meta.total | type) == "number")
    and (.meta.total >= 0)
  ' >/dev/null <<<"$body" ||
    die 'request search returned an unexpected response; refusing to report a count'

  jq -n \
    --arg workspace "$REQUEST_SEARCH_WORKSPACE" \
    --arg workspace_id "$REQUEST_SEARCH_WORKSPACE_ID" \
    --arg workspace_input "$REQUEST_SEARCH_WORKSPACE_INPUT" \
    --arg customer "$REQUEST_SEARCH_CUSTOMER" \
    --arg customer_id "$REQUEST_SEARCH_CUSTOMER_ID" \
    --arg query "$REQUEST_SEARCH_QUERY" \
    --arg requested_query "$REQUEST_SEARCH_REQUESTED_QUERY" \
    --arg from "$REQUEST_SEARCH_FROM_UTC" \
    --arg until "$REQUEST_SEARCH_UNTIL_UTC" \
    --argjson from_epoch "$REQUEST_SEARCH_FROM_EPOCH" \
    --argjson until_epoch "$REQUEST_SEARCH_UNTIL_EPOCH" \
    --argjson days "$REQUEST_SEARCH_DAYS" \
    --argjson count "$(jq '.meta.total' <<<"$body")" \
    '{
      customer: $customer,
      customer_id: $customer_id,
      workspace: $workspace,
      workspace_id: $workspace_id,
      workspace_input: $workspace_input,
      days: $days,
      query: $query,
      count: $count,
      count_scope: "retained_searchable_request_records",
      sampling_caveat: "This count may reflect sampled or mixed-storage request data. It is not raw traffic or a scaled estimate.",
      window: {
        type: "rolling",
        from: $from,
        until: $until,
        from_epoch: $from_epoch,
        until_epoch: $until_epoch,
        boundary_semantics: "from/until passed verbatim to request search; endpoint-defined",
        ingestion_buffer_seconds: 300
      },
      provenance: {
        endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/requests",
        data_class: "retained_request_search",
        aggregation: "response.meta.total",
        rows_requested: 1,
        missing_data_policy: "fail_closed",
        limitations: [
          "May contain sampled or mixed-storage request records.",
          "Not raw traffic and not a scaled estimate."
        ]
      }
    }
    + (if $query != $requested_query
       then {requested_query: $requested_query, query_normalized: true}
       else {query_normalized: false}
       end)'
}

request_search_payload_json() {
  [[ $# -eq 2 ]] || die 'request_search_payload_json requires <body> <limit>'

  local body="$1"
  local limit="$2"

  json_stream "$body" |
    jq -s \
      --arg workspace "$REQUEST_SEARCH_WORKSPACE" \
      --arg workspace_id "$REQUEST_SEARCH_WORKSPACE_ID" \
      --arg workspace_input "$REQUEST_SEARCH_WORKSPACE_INPUT" \
      --arg customer "$REQUEST_SEARCH_CUSTOMER" \
      --arg customer_id "$REQUEST_SEARCH_CUSTOMER_ID" \
      --arg query "$REQUEST_SEARCH_QUERY" \
      --arg requested_query "$REQUEST_SEARCH_REQUESTED_QUERY" \
      --arg from "$REQUEST_SEARCH_FROM_UTC" \
      --arg until "$REQUEST_SEARCH_UNTIL_UTC" \
      --argjson from_epoch "$REQUEST_SEARCH_FROM_EPOCH" \
      --argjson until_epoch "$REQUEST_SEARCH_UNTIL_EPOCH" \
      --argjson days "$REQUEST_SEARCH_DAYS" \
      --argjson limit "$limit" '
      def header_value($headers; $name):
        [$headers[]? | select(((.name // "") | ascii_downcase) == ($name | ascii_downcase)) | .value]
        | .[0] // null;

      def signal_name:
        if type == "object" then
          (.type // .name // .signal // .tag // .detector // empty | tostring)
        else
          tostring
        end;

      .[0] as $response
      | ($response.data // []) as $records
      | {
        customer: $customer,
        customer_id: $customer_id,
        workspace: $workspace,
        workspace_id: $workspace_id,
        workspace_input: $workspace_input,
        days: $days,
        query: $query,
        limit: $limit,
        total_matches: (
          if ($response.meta.total? | type) == "number"
          then $response.meta.total
          else null
          end
        ),
        rows_returned: ($records | length),
        count_scope: "retained_searchable_request_records",
        sampling_caveat: "This count may reflect sampled or mixed-storage request data. It is not raw traffic or a scaled estimate.",
        window: {
          type: "rolling",
          from: $from,
          until: $until,
          from_epoch: $from_epoch,
          until_epoch: $until_epoch,
          boundary_semantics: "from/until passed verbatim to request search; endpoint-defined",
          ingestion_buffer_seconds: 300
        },
        provenance: {
          endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/requests",
          data_class: "retained_request_search",
          aggregation: "response.data",
          rows_requested: $limit,
          rows_returned: ($records | length),
          pagination: (
            if (($response.meta.pages_fetched // 1) | tonumber) > 1
            then "bounded_page_loop"
            else "single_request"
            end
          ),
          pages_fetched: ($response.meta.pages_fetched // 1),
          missing_data_policy: "fail_closed",
          limitations: [
            "May contain sampled or mixed-storage request records.",
            "Not raw traffic and not a scaled estimate.",
            "Rows are bounded by --limit and may be fewer than total_matches."
          ]
        },
        meta: ($response.meta // {}),
        requests: [
          $records[]
          | . as $request
          | {
              timestamp: ($request.timestamp // null),
              request_id: ($request.id // null),
              host: (
                $request.server_hostname
                // header_value(($request.request_headers // []); "host")
                // null
              ),
              server_hostname: ($request.server_hostname // null),
              remote_hostname: ($request.remote_hostname // null),
              method: ($request.method // null),
              path: ($request.path // null),
              uri: ($request.uri // null),
              source_ip: ($request.remote_ip // null),
              user_agent: (
                $request.user_agent
                // header_value(($request.request_headers // []); "user-agent")
                // null
              ),
              response_code: ($request.response_code // null),
              agent_response_code: ($request.agent_response_code // null),
              signals: ($request.signals // []),
              signal_names: [($request.signals // [])[]? | signal_name | select(length > 0)],
              raw: $request
            }
        ]
      }
      + (if $query != $requested_query
         then {requested_query: $requested_query, query_normalized: true}
         else {query_normalized: false}
         end)'
}

request_search_payload_csv() {
  [[ $# -eq 1 ]] || die 'request_search_payload_csv requires <payload-json>'

  local payload="$1"

  jq -r '
    def cell:
      if . == null then ""
      elif type == "array" then join(";")
      else tostring
      end;

    [
      "customer",
      "customer_id",
      "workspace",
      "workspace_id",
      "days",
      "query",
      "total_matches",
      "rows_returned",
      "timestamp",
      "request_id",
      "host",
      "method",
      "path",
      "uri",
      "source_ip",
      "user_agent",
      "response_code",
      "agent_response_code",
      "signal_names"
    ],
    (
      . as $payload
      | .requests[]?
      | [
          $payload.customer,
          $payload.customer_id,
          $payload.workspace,
          $payload.workspace_id,
          $payload.days,
          $payload.query,
          $payload.total_matches,
          $payload.rows_returned,
          .timestamp,
          .request_id,
          .host,
          .method,
          .path,
          .uri,
          .source_ip,
          .user_agent,
          .response_code,
          .agent_response_code,
          .signal_names
        ]
    )
    | map(cell)
    | @csv
  ' <<<"$payload"
}

request_search_emit_output() {
  [[ $# -eq 2 ]] || die 'request_search_emit_output requires <content> <output-file>'

  local content="$1"
  local output="$2"
  local parent temp_file old_umask

  if [[ -z "$output" ]]; then
    printf '%s\n' "$content"
    return
  fi

  parent="$(dirname "$output")"
  [[ -d "$parent" ]] || die "requests output directory does not exist: $parent"
  [[ ! -e "$output" ]] || die "refusing to overwrite existing requests output: $output"

  old_umask="$(umask)"
  umask 077
  temp_file="$(mktemp "$parent/.ngwaf-requests.XXXXXX")"
  umask "$old_umask"

  if ! printf '%s\n' "$content" >"$temp_file"; then
    rm -f "$temp_file"
    die "failed to write requests output: $output"
  fi

  chmod 600 "$temp_file"
  if ! ln "$temp_file" "$output"; then
    rm -f "$temp_file"
    die "refusing to overwrite existing requests output: $output"
  fi
  rm -f "$temp_file"

  printf '%s: wrote requests output: %s\n' "${PROGRAM_NAME:-ngwaf}" "$output" >&2
}

cmd_requests() {
  [[ $# -ge 2 ]] ||
    die "usage: ngwaf requests <workspace> '<search query>' [days] [--limit N] [--format json|csv] [--output FILE]"

  local input="$1"
  local requested_query="$2"
  shift 2

  local days=7
  local days_set=false
  local limit="$REQUEST_SEARCH_DEFAULT_LIMIT"
  local format="json"
  local output=""
  local body body_tmp payload rendered

  while (( $# > 0 )); do
    case "$1" in
      --limit)
        (( $# >= 2 )) || die '--limit requires a positive integer'
        limit="$2"
        shift 2
        ;;
      --format)
        (( $# >= 2 )) || die '--format requires json or csv'
        format="$(tr '[:upper:]' '[:lower:]' <<<"$2")"
        shift 2
        ;;
      --output)
        (( $# >= 2 )) || die '--output requires a file path'
        output="$2"
        shift 2
        ;;
      --json)
        format="json"
        shift
        ;;
      --csv)
        format="csv"
        shift
        ;;
      --*)
        die "unknown requests option: $1"
        ;;
      *)
        if [[ "$days_set" == "false" ]]; then
          days="$1"
          days_set=true
          shift
        else
          die "usage: ngwaf requests <workspace> '<search query>' [days] [--limit N] [--format json|csv] [--output FILE]"
        fi
        ;;
    esac
  done

  case "$format" in
    json|csv)
      ;;
    *)
      die 'requests format must be json or csv'
      ;;
  esac

  body_tmp="$(mktemp)"
  if request_search_run "$input" "$requested_query" "$days" "$limit" requests >"$body_tmp"; then
    :
  else
    local rc=$?
    rm -f "$body_tmp"
    return "$rc"
  fi
  body="$(<"$body_tmp")"
  rm -f "$body_tmp"
  payload="$(request_search_payload_json "$body" "$limit")"

  if [[ "$format" == "csv" ]]; then
    rendered="$(request_search_payload_csv "$payload")"
  else
    rendered="$(jq . <<<"$payload")"
  fi

  request_search_emit_output "$rendered" "$output"
}

rule_audit_validate_settings() {
  [[ "$RULE_AUDIT_HIGH_VOLUME" =~ ^[0-9]+$ ]] ||
    die 'NGWAF_RULE_AUDIT_HIGH_VOLUME must be a positive integer'
  [[ "$RULE_AUDIT_STALE_DAYS" =~ ^[0-9]+$ ]] ||
    die 'NGWAF_RULE_AUDIT_STALE_DAYS must be a positive integer'

  (( RULE_AUDIT_HIGH_VOLUME >= 1 )) ||
    die 'NGWAF_RULE_AUDIT_HIGH_VOLUME must be at least 1'
  (( RULE_AUDIT_STALE_DAYS >= 1 )) ||
    die 'NGWAF_RULE_AUDIT_STALE_DAYS must be at least 1'
}

rule_audit_signals_json() {
  [[ $# -eq 1 ]] || die 'rule_audit_signals_json requires <signals-csv>'

  local signals_csv
  signals_csv="$(tr -d '[:space:]' <<<"$1")"
  [[ -n "$signals_csv" ]] || die 'rule-audit signals list must not be empty'

  jq -Rn --arg csv "$signals_csv" '
    reduce ($csv | split(","))[] as $signal (
      [];
      if ($signal | length) == 0 then .
      elif index($signal) != null then .
      else . + [$signal]
      end
    )
    | if length > 0 then . else error("empty signal list") end
  ' || die 'rule-audit signals list must contain at least one signal'
}

rule_audit_count_query() {
  [[ $# -eq 1 ]] || die 'rule_audit_count_query requires <query>'

  local query="$1"
  local body_tmp body count
  body_tmp="$(mktemp)"
  if request_search_execute "$query" 1 count >"$body_tmp"; then
    :
  else
    local rc=$?
    rm -f "$body_tmp"
    return "$rc"
  fi
  body="$(<"$body_tmp")"
  rm -f "$body_tmp"

  count="$(
    jq -r '
      if (.meta.total | type) == "number"
      then (.meta.total | tostring)
      else empty
      end
    ' <<<"$body"
  )"
  [[ -n "$count" ]] ||
    die "request search omitted meta.total for query: $query"

  printf '%s\n' "$count"
}

rule_audit_intersections_json() {
  [[ $# -eq 3 ]] ||
    die 'rule_audit_intersections_json requires <rule-id> <signals-json> <total>'

  local rule_id="$1"
  local signals="$2"
  local total="$3"
  local tmp signal query count
  tmp="$(mktemp)"

  while IFS= read -r signal; do
    [[ -n "$signal" ]] || continue
    query="ruleid:$rule_id tag:$signal"
    count="$(rule_audit_count_query "$query")"
    jq -n \
      --arg signal "$signal" \
      --arg query "$query" \
      --argjson count "$count" \
      '{signal: $signal, query: $query, count: $count}' >>"$tmp"
  done < <(jq -r '.[]' <<<"$signals")

  jq -s --argjson total "$total" '
    map(
      . + {
        percent_of_rule_matches: (
          if $total > 0
          then ((.count / $total) * 100)
          else null
          end
        )
      }
    )
  ' "$tmp"
  rm -f "$tmp"
}

rule_audit_indicators_json() {
  [[ $# -eq 3 ]] ||
    die 'rule_audit_indicators_json requires <rule-json> <total> <intersections-json>'

  local rule="$1"
  local total="$2"
  local intersections="$3"

  json_stream "$rule" "$intersections" |
    jq -s \
      --argjson total "$total" \
      --argjson high_volume "$RULE_AUDIT_HIGH_VOLUME" \
      --argjson stale_days "$RULE_AUDIT_STALE_DAYS" '
      def norm_action:
        tostring | gsub("[^A-Za-z0-9]"; "") | ascii_downcase;
      def parse_time:
        if type != "string" then null
        else (try fromdateiso8601 catch (try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch null))
        end;

      .[0] as $rule
      | .[1] as $intersections
      | [($rule.actions // [])[]? | if type == "object" then (.type // .action // .name // empty) else . end | tostring] as $action_types
      | ($action_types | map(norm_action)) as $action_norms
      | (($action_norms | index("allow")) != null) as $has_allow
      | (($action_norms | index("block")) != null) as $has_block
      | (($action_norms | index("addsignal")) != null) as $has_add_signal
      | [
          ($rule.conditions // []),
          ($rule.condition_groups // []),
          ($rule.groups // [])
        ] as $condition_roots
      | [$condition_roots | .. | strings] as $condition_strings
      | (
          any(
            $condition_strings[];
            test("path|uri|url|^/"; "i")
          )
        ) as $has_path_condition
      | (
          any(
            $condition_strings[];
            test("host|method|header|country|remote|ip|client|signal|tag|user.?agent|cookie"; "i")
          )
        ) as $has_non_path_condition
      | (
          any(
            $condition_strings[];
            test("\\\\?\\.\\(?(css|js|mjs|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|eot|map|pdf)([^A-Za-z0-9]|$)"; "i")
          )
        ) as $has_static_extension
      | (
          any(
            $condition_strings[];
            test("regex|regexp|matches"; "i") or test("[\\[\\]()+?{}|]")
          )
        ) as $has_regex_like_condition
      | ($rule.updated_at // $rule.created_at // null) as $last_changed
      | ($last_changed | parse_time) as $last_changed_epoch
      | (
          $last_changed_epoch != null
          and ((now - $last_changed_epoch) > ($stale_days * 86400))
        ) as $is_stale
      | [$intersections[]? | select((.count // 0) > 0) | .signal] as $signal_hits
      | [
          (if $has_allow then {
            category: "observation",
            indicator: "allow_action",
            detail: "Rule contains an allow action."
          } else empty end),
          (if $has_block then {
            category: "observation",
            indicator: "block_action",
            detail: "Rule contains a block action."
          } else empty end),
          (if $has_allow and $has_add_signal then {
            category: "review_indicator",
            indicator: "add_signal_plus_allow",
            detail: "Rule combines add_signal with allow; confirm the signal is intended as audit evidence rather than enforcement."
          } else empty end),
          (if $has_allow and $has_path_condition and ($has_non_path_condition | not) then {
            category: "review_indicator",
            indicator: "path_only_allow",
            detail: "Allow rule appears to rely on path or URI conditions without an obvious host, method, header, IP, or signal condition."
          } else empty end),
          (if $has_allow and $has_static_extension then {
            category: "optimization_indicator",
            indicator: "static_extension_allow",
            detail: "Allow rule references common static-file extensions; confirm the exemption is still needed and narrow enough."
          } else empty end),
          (if $has_regex_like_condition then {
            category: "review_indicator",
            indicator: "regex_condition",
            detail: "Rule conditions include regex-like patterns or operators that may deserve human review."
          } else empty end),
          (if $is_stale then {
            category: "review_indicator",
            indicator: "stale_rule",
            detail: ("Rule has not changed in at least " + ($stale_days | tostring) + " days based on updated_at/created_at."),
            last_changed_at: $last_changed
          } else empty end),
          (if $total >= $high_volume then {
            category: "optimization_indicator",
            indicator: "high_match_volume",
            detail: (($total | tostring) + " retained searchable records matched this rule in the selected window."),
            threshold: $high_volume
          } else empty end),
          (if $has_allow and (($signal_hits | length) > 0) then {
            category: "review_indicator",
            indicator: "allow_signal_intersections",
            detail: ("Selected signals occur within the allow-rule cohort: " + ($signal_hits | join(", ")) + "."),
            signals: $signal_hits
          } else empty end)
        ]
    '
}

rule_audit_one_rule_json() {
  [[ $# -eq 2 ]] || die 'rule_audit_one_rule_json requires <rule-id> <signals-json>'

  local rule_id="$1"
  local signals="$2"
  local rule total intersections indicators

  rule="$(
    get_workspace_rule_json \
      "$REQUEST_SEARCH_CUSTOMER_ID" \
      "$REQUEST_SEARCH_WORKSPACE_ID" \
      "$REQUEST_SEARCH_WORKSPACE" \
      "$rule_id"
  )"
  total="$(rule_audit_count_query "ruleid:$rule_id")"
  intersections="$(rule_audit_intersections_json "$rule_id" "$signals" "$total")"
  indicators="$(rule_audit_indicators_json "$rule" "$total" "$intersections")"

  json_stream "$rule" "$intersections" "$indicators" |
    jq -s \
      --arg rule_id "$rule_id" \
      --arg total_query "ruleid:$rule_id" \
      --argjson total "$total" '
      def action_type:
        if type == "object" then (.type // .action // .name // empty)
        else .
        end | tostring;

      .[0] as $rule
      | .[1] as $intersections
      | .[2] as $indicators
      | {
        rule_id: ($rule.id // $rule_id),
        description: ($rule.description // ""),
        enabled: ($rule.enabled // null),
        type: ($rule.type // null),
        action_types: [($rule.actions // [])[]? | action_type],
        total_retained_matches: $total,
        total_match_query: $total_query,
        signal_intersections: $intersections,
        review_indicators: $indicators,
        configuration: {
          rule_id: ($rule.id // $rule_id),
          description: ($rule.description // ""),
          enabled: ($rule.enabled // null),
          type: ($rule.type // null),
          scope: ($rule.scope // null),
          request_logging: (
            $rule.request_logging
            // $rule.request_logging_mode
            // $rule.logging
            // $rule.log
            // null
          ),
          condition_operator: (
            $rule.condition_operator
            // $rule.conditions_operator
            // $rule.operator
            // null
          ),
          group_operator: (
            $rule.group_operator
            // $rule.condition_group_operator
            // null
          ),
          conditions: ($rule.conditions // []),
          condition_groups: ($rule.condition_groups // $rule.groups // null),
          actions: ($rule.actions // []),
          action_types: [($rule.actions // [])[]? | action_type],
          created_at: ($rule.created_at // null),
          updated_at: ($rule.updated_at // null),
          raw: $rule
        }
      }
    '
}

rule_audit_render_human() {
  [[ $# -eq 1 ]] || die 'rule_audit_render_human requires <report-json>'

  local report="$1"
  local rule rule_id description enabled type actions updated total indicators

  ui_heading 'NGWAF rule audit'
  jq -r '
    "Customer: \(.customer) (\(.customer_id))",
    "Workspace: \(.workspace) (\(.workspace_id); input=\(.workspace_input))",
    "Window: \(.window.from) → \(.window.until) UTC (rolling \(.days)d; 5-minute ingestion buffer)",
    "Signals: \(.signals | join(", "))",
    "Rules audited: \(.rules | length)"
  ' <<<"$report"

  while IFS= read -r rule; do
    rule_id="$(jq -r '.rule_id' <<<"$rule")"
    description="$(jq -r '.description // ""' <<<"$rule")"
    enabled="$(jq -r '.enabled // "unknown"' <<<"$rule")"
    type="$(jq -r '.type // "unknown"' <<<"$rule")"
    actions="$(jq -r 'if (.action_types | length) > 0 then (.action_types | join(", ")) else "-" end' <<<"$rule")"
    updated="$(jq -r '.configuration.updated_at // .configuration.created_at // "-"' <<<"$rule")"
    total="$(jq -r '.total_retained_matches' <<<"$rule")"
    indicators="$(jq '.review_indicators | length' <<<"$rule")"

    printf '\n'
    ui_heading "Rule $rule_id"
    printf 'Description: %s\n' "${description:-"-"}"
    printf 'Enabled: %s · Type: %s · Actions: %s\n' "$enabled" "$type" "$actions"
    printf 'Last changed: %s\n' "$updated"
    printf 'Retained matches: %s\n' "$total"

    printf '\nSignal intersections\n'
    jq -r '
      def pct:
        if . == null then "n/a"
        elif . > 0 and . < 0.001 then "<0.001%"
        else (((. * 1000) | round) / 1000 | tostring) + "%"
        end;
      ["SIGNAL", "MATCHES", "% OF RULE MATCHES"],
      (
        .signal_intersections[]
        | [
            .signal,
            (.count | tostring),
            (.percent_of_rule_matches | pct)
          ]
      )
      | @tsv
    ' <<<"$rule" | human_table

    printf '\nReview indicators\n'
    if (( indicators == 0 )); then
      printf '  - none\n'
    else
      jq -r '.review_indicators[] | "  - " + .detail' <<<"$rule"
    fi
  done < <(jq -c '.rules[]' <<<"$report")

  printf '\nCaveat:\n'
  printf '  Counts represent retained searchable NGWAF records, not raw traffic or scaled traffic estimates.\n'
  printf '  Signal cohorts can overlap; do not sum them as unique requests.\n'
}

cmd_rule_audit() {
  local usage
  usage="usage: ngwaf rule-audit <workspace> <rule_id> [<rule_id> ...] [--days N] [--signals CSV] [--json]"
  [[ $# -ge 2 ]] || die "$usage"

  local input="$1"
  shift
  local days=7
  local signals_csv="$RULE_AUDIT_DEFAULT_SIGNALS"
  local format="human"
  local signals tmp rule_id report
  local -a rule_ids=()

  while (( $# > 0 )); do
    case "$1" in
      --days)
        (( $# >= 2 )) || die '--days requires an integer from 1 to 7'
        days="$2"
        shift 2
        ;;
      --signals)
        (( $# >= 2 )) || die '--signals requires a comma-separated signal list'
        signals_csv="$2"
        shift 2
        ;;
      --json)
        format="json"
        shift
        ;;
      --format)
        (( $# >= 2 )) || die '--format requires human or json'
        format="$(tr '[:upper:]' '[:lower:]' <<<"$2")"
        shift 2
        ;;
      --*)
        die "unknown rule-audit option: $1"
        ;;
      *)
        rule_ids+=("$1")
        shift
        ;;
    esac
  done

  (( ${#rule_ids[@]} > 0 )) || die "$usage"
  case "$format" in
    human|json)
      ;;
    *)
      die 'rule-audit format must be human or json'
      ;;
  esac

  rule_audit_validate_settings
  signals="$(rule_audit_signals_json "$signals_csv")"
  request_search_prepare_scope "$input" "$days"

  tmp="$(mktemp)"
  for rule_id in "${rule_ids[@]}"; do
    rule_audit_one_rule_json "$rule_id" "$signals" >>"$tmp"
  done

  json_stream "$signals" "$(jq -s '.' "$tmp")" |
    jq -s \
      --arg customer "$REQUEST_SEARCH_CUSTOMER" \
      --arg customer_id "$REQUEST_SEARCH_CUSTOMER_ID" \
      --arg workspace "$REQUEST_SEARCH_WORKSPACE" \
      --arg workspace_id "$REQUEST_SEARCH_WORKSPACE_ID" \
      --arg workspace_input "$REQUEST_SEARCH_WORKSPACE_INPUT" \
      --arg from "$REQUEST_SEARCH_FROM_UTC" \
      --arg until "$REQUEST_SEARCH_UNTIL_UTC" \
      --argjson from_epoch "$REQUEST_SEARCH_FROM_EPOCH" \
      --argjson until_epoch "$REQUEST_SEARCH_UNTIL_EPOCH" \
      --argjson days "$REQUEST_SEARCH_DAYS" \
      --argjson high_volume "$RULE_AUDIT_HIGH_VOLUME" \
      --argjson stale_days "$RULE_AUDIT_STALE_DAYS" '
      def norm_action:
        tostring | gsub("[^A-Za-z0-9]"; "") | ascii_downcase;

      .[0] as $signals
      | .[1] as $audited_rules
      | {
        command: "rule-audit",
        customer: $customer,
        customer_id: $customer_id,
        workspace: $workspace,
        workspace_id: $workspace_id,
        workspace_input: $workspace_input,
        days: $days,
        signals: $signals,
        count_scope: "retained_searchable_request_records",
        sampling_caveat: "Counts may reflect sampled or mixed-storage request data. They are not raw traffic or scaled estimates.",
        window: {
          type: "rolling",
          from: $from,
          until: $until,
          from_epoch: $from_epoch,
          until_epoch: $until_epoch,
          boundary_semantics: "from/until passed verbatim to request search; endpoint-defined",
          ingestion_buffer_seconds: 300
        },
        summary: {
          rules_audited: ($audited_rules | length),
          rules_with_allow: ([
            $audited_rules[]
            | select([(.action_types // [])[]? | norm_action] | index("allow") != null)
          ] | length),
          rules_with_signal_intersections: ([
            $audited_rules[]
            | select(any(.signal_intersections[]?; (.count // 0) > 0))
          ] | length),
          rules_over_high_volume_threshold: ([
            $audited_rules[]
            | select((.total_retained_matches // 0) >= $high_volume)
          ] | length)
        },
        rule_audit_settings: {
          high_volume_retained_matches: $high_volume,
          stale_rule_days: $stale_days
        },
        rules: $audited_rules,
        notes: [
          "Signal cohorts can overlap; never sum signal counts as unique requests.",
          "Review indicators are deterministic observations for human analysis, not automatic remediation advice.",
          "A signal intersection does not by itself prove malicious traffic.",
          "Counts are retained searchable NGWAF records, not raw CDN traffic or scaled estimates."
        ],
        provenance: {
          data_class: "ngwaf_rule_configuration_plus_retained_request_search",
          endpoints: [
            "GET /ngwaf/v1/workspaces/{workspace_id}/rules/{rule_id}",
            "GET /ngwaf/v1/workspaces/{workspace_id}/requests"
          ],
          request_search: {
            endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/requests",
            aggregation: "response.meta.total",
            rows_requested_per_count: 1,
            missing_data_policy: "fail_closed"
          },
          rule_configuration: {
            endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/rules/{rule_id}",
            data_class: "configuration_snapshot",
            identity_validation: "response id must match requested rule id"
          },
          workspace_resolution: "exact ID first; otherwise case-insensitive exact name",
          customer_scoped: true
        }
      }
    ' >"${tmp}.report"
  report="$(<"${tmp}.report")"
  rm -f "$tmp" "${tmp}.report"

  if [[ "$format" == "json" ]]; then
    jq . <<<"$report"
  else
    rule_audit_render_human "$report"
  fi
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
  customer="$(current_customer_name)"

  body="$(
    get "/ngwaf/v1/timeseries" \
      --data-urlencode "customer_id=$cid" \
      --data-urlencode "from=$TS_FROM" \
      --data-urlencode "to=$TS_TO" \
      --data-urlencode "metrics=$metrics" \
      --data-urlencode "dimensions=workspaces,time" \
      --data-urlencode "granularity=86400"
  )"

  validate_timeseries_response "$body" "$metrics" "attack profile"

  # First rank production workspaces by requests_attack for the selected window.
  workspace_summary="$(
    jq --arg prod_regex "$prod_regex" '
      [
        .data[]
        | {
            workspace: .dimensions.workspace,
            attack: (.values[0].requests_attack | tonumber)
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
      def n: tonumber;

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
    json_stream "$workspace_summary" "$top_workspace_names" "$signal_summary" |
      jq -s \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --argjson span_days "$span_days" \
      --argjson top_n "$top_n" \
      --arg production_workspace_filter "$prod_regex" '
      .[0] as $production_workspaces
      | .[1] as $selected_workspaces
      | .[2] as $attack_signals
      | {
        customer: $customer,
        customer_id: $customer_id,
        from: $from,
        to: $to,
        to_is_exclusive: true,
        span_days: $span_days,
        window: {
          type: "complete_utc_days",
          from: $from,
          to: $to,
          to_is_exclusive: true
        },
        scopes: {
          workspace_ranking: "production workspaces only, identified by workspace name",
          signal_totals: "same top production workspaces shown in the ranking"
        },
        top_n: $top_n,
        production_workspace_filter: $production_workspace_filter,
        selected_workspaces: $selected_workspaces,
        production_workspaces: $production_workspaces[:$top_n],
        attack_signals: $attack_signals,
        provenance: {
          endpoint: "GET /ngwaf/v1/timeseries",
          data_class: "ngwaf_timeseries_with_name_based_workspace_filter",
          aggregation: "sum_of_daily_rows_for_selected_workspaces",
          missing_data_policy: "fail_closed"
        }
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
  customer="$(current_customer_name)"

  # Resolve the selected customer's workspace set FIRST. Every top-attacks
  # request below is made directly against one of these workspace IDs, which
  # avoids relying on the ambiguous account-level reports/attacks response.
  workspaces_body="$(
    get_all_pages "/ngwaf/v1/workspaces" \
      --data-urlencode "customer_id=$cid"
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

  validate_timeseries_response "$attack_ts" "requests_attack" "attack-origins denominator"

  attack_total="$(
    jq --argjson production_names "$production_workspace_names" '
      [
        .data[]?
        | select(.dimensions.workspace as $w | $production_names | index($w))
        | (.values[0].requests_attack | tonumber)
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

      jq -e '
        all(.data[]?;
          (.count | type) == "number"
          or ((.count | type) == "string" and (.count | tonumber? != null))
        )
      ' <<<"$body" >/dev/null || {
        rm -f "$tmp"
        die "top-attacks returned a missing or non-numeric count for workspace $workspace_name ($workspace_id), chunk $chunk_from -> $chunk_to"
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
            requests: (.count | tonumber)
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
    json_stream "$production_workspace_names" "$source_summary" |
      jq -s \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$TS_FROM" \
      --arg to "$TS_TO" \
      --argjson span_days "$span_days" \
      --arg production_workspace_filter "$prod_regex" \
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
      --argjson other_share "$other_share" '
      .[0] as $production_workspaces
      | .[1] as $countries
      | {
        customer: $customer,
        customer_id: $customer_id,
        from: $from,
        to: $to,
        to_is_exclusive: true,
        span_days: $span_days,
        window: {
          type: "complete_utc_days",
          from: $from,
          to: $to,
          to_is_exclusive: true
        },
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
        methodology: "Resolve workspaces from the selected customer ID, retain production workspaces whose names contain a prd/prod/production token, split the requested reporting period into contiguous intervals of 7 days or less, query each selected workspace top-attacks endpoint with customer_id and field=remote_country_code for every interval, aggregate country counts across intervals and workspaces, and reconcile the returned country counts against requests_attack timeseries for that exact same production workspace set.",
        provenance: {
          data_class: "ngwaf_top_attacks_reconciled_to_timeseries",
          endpoints: [
            "GET /ngwaf/v1/workspaces/{workspace_id}/top-attacks",
            "GET /ngwaf/v1/timeseries"
          ],
          workspace_selection: "name_regex",
          pagination: "workspace_inventory_complete_or_fail",
          missing_data_policy: "fail_closed"
        }
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
