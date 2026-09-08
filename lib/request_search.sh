# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

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

  [[ "$limit" =~ ^-?[0-9]+$ ]] || die 'request limit must be a positive integer'
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

request_search_payload_human() {
  [[ $# -eq 1 ]] || die 'request_search_payload_human requires <payload-json>'

  local payload="$1"

  ui_heading 'NGWAF request search'
  jq -r '
    "Customer: \(.customer) (\(.customer_id))",
    "Workspace: \(.workspace) (\(.workspace_id); input=\(.workspace_input))",
    "Query: \(.query)",
    "Window: \(.window.from) to \(.window.until) UTC (rolling \(.days)d; 5-minute ingestion buffer)",
    "Matches: \(.total_matches // "unknown") total; showing \(.rows_returned) row(s), limit \(.limit)",
    "Data: retained searchable NGWAF records, not raw traffic or scaled estimates.",
    ""
  ' <<<"$payload"

  jq -r '
    def cell:
      if . == null then "-"
      elif type == "array" then (if length == 0 then "-" else join(";") end)
      else tostring
      end;

    ["TIMESTAMP", "REQUEST ID", "STATUS", "METHOD", "HOST", "PATH", "SOURCE IP", "SIGNALS"],
    (
      .requests[]?
      | [
          .timestamp,
          .request_id,
          .response_code,
          .method,
          .host,
          (.path // .uri),
          .source_ip,
          .signal_names
        ]
    )
    | map(cell)
    | @tsv
  ' <<<"$payload" | human_table

  printf '\nCaveat: rows are bounded by --limit and signal/request-search data may be sampled or mixed-storage.\n'
}

requests_resolve_format() {
  [[ $# -eq 3 ]] || die 'requests_resolve_format requires <format> <explicit> <output>'

  local format="$1"
  local explicit="$2"
  local output="$3"
  local inferred=""
  local ext=""

  if [[ -n "$output" ]]; then
    ext="$(tr '[:upper:]' '[:lower:]' <<<"${output##*.}")"
    case "$ext" in
      json) inferred="json" ;;
      csv) inferred="csv" ;;
    esac
  fi

  if [[ "$format" == "auto" && -n "$inferred" ]]; then
    printf '%s\n' "$inferred"
    return
  fi

  if [[ "$explicit" == "true" && -n "$inferred" && "$format" != "$inferred" ]]; then
    printf '%s: warning: --format %s overrides .%s output extension\n' \
      "${PROGRAM_NAME:-ngwaf}" "$format" "${output##*.}" >&2
  fi

  if [[ "$format" == "auto" ]]; then
    if [[ -t 1 ]]; then
      printf 'human\n'
    else
      printf 'json\n'
    fi
  else
    printf '%s\n' "$format"
  fi
}

request_search_emit_output() {
  [[ $# -eq 3 ]] || die 'request_search_emit_output requires <content> <output-file> <rows-returned>'

  local content="$1"
  local output="$2"
  local rows_returned="$3"
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

  if [[ "$rows_returned" == "1" ]]; then
    printf '%s: wrote 1 request record to %s\n' "${PROGRAM_NAME:-ngwaf}" "$output" >&2
  else
    printf '%s: wrote %s request records to %s\n' "${PROGRAM_NAME:-ngwaf}" "$rows_returned" "$output" >&2
  fi
}

cmd_requests() {
  [[ $# -ge 2 ]] ||
    die "usage: ngwaf requests <workspace> '<search query>' [days] [--limit N] [--format auto|json|csv] [--output FILE]"

  local input="$1"
  local requested_query="$2"
  shift 2

  local days=7
  local days_set=false
  local limit="$REQUEST_SEARCH_DEFAULT_LIMIT"
  local format="auto"
  local format_explicit=false
  local output=""
  local body body_tmp payload rendered resolved_format rows_returned

  while (( $# > 0 )); do
    case "$1" in
      --limit)
        (( $# >= 2 )) || die '--limit requires a positive integer'
        limit="$2"
        shift 2
        ;;
      --format)
        (( $# >= 2 )) || die '--format requires auto, json, or csv'
        format="$(tr '[:upper:]' '[:lower:]' <<<"$2")"
        format_explicit=true
        shift 2
        ;;
      --output)
        (( $# >= 2 )) || die '--output requires a file path'
        output="$2"
        shift 2
        ;;
      --json)
        format="json"
        format_explicit=true
        shift
        ;;
      --csv)
        format="csv"
        format_explicit=true
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
          die "usage: ngwaf requests <workspace> '<search query>' [days] [--limit N] [--format auto|json|csv] [--output FILE]"
        fi
        ;;
    esac
  done

  case "$format" in
    auto|json|csv)
      ;;
    *)
      die 'requests format must be auto, json, or csv'
      ;;
  esac
  resolved_format="$(requests_resolve_format "$format" "$format_explicit" "$output")"

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
  rows_returned="$(jq -r '.rows_returned' <<<"$payload")"

  if [[ -n "$output" ]]; then
    case "$resolved_format" in
      csv) rendered="$(request_search_payload_csv "$payload")" ;;
      human) rendered="$(request_search_payload_human "$payload")" ;;
      json) rendered="$(jq . <<<"$payload")" ;;
      *) die "internal error: unsupported requests format: $resolved_format" ;;
    esac

    request_search_emit_output "$rendered" "$output" "$rows_returned"
  else
    case "$resolved_format" in
      csv) request_search_payload_csv "$payload" ;;
      human) request_search_payload_human "$payload" ;;
      json) jq . <<<"$payload" ;;
      *) die "internal error: unsupported requests format: $resolved_format" ;;
    esac
  fi
}
cmd_signal_count() {
  [[ $# -ge 2 && $# -le 3 ]] ||
    die 'usage: ngwaf signal-count <workspace> <signal> [days]'

  cmd_count "$1" "tag:$2" "${3:-7}"
}
