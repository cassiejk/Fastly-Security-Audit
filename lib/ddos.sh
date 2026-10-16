# shellcheck shell=bash
# Sourced by the fastly-audit entry point; do not execute directly.

DDOS_EVIDENCE_SCHEMA="fastly-ddos-evidence"
DDOS_EVIDENCE_SCHEMA_VERSION=1
DDOS_EVENT_RULE_PAGE_LIMIT="${NGWAF_DDOS_EVENT_RULE_PAGE_LIMIT:-100}"

[[ "$DDOS_EVENT_RULE_PAGE_LIMIT" =~ ^[0-9]+$ ]] ||
  die 'NGWAF_DDOS_EVENT_RULE_PAGE_LIMIT must be a positive integer'
(( DDOS_EVENT_RULE_PAGE_LIMIT > 0 )) ||
  die 'NGWAF_DDOS_EVENT_RULE_PAGE_LIMIT must be a positive integer'

ddos_validate_resource_id() {
  [[ $# -eq 2 ]] || die 'ddos_validate_resource_id requires <label> <value>'

  local label="$1"
  local value="$2"

  [[ -n "$value" ]] || die "$label must not be empty"
  [[ ! "$value" =~ [[:cntrl:]/] ]] || die "$label contains invalid characters"
  [[ "$value" != '.' && "$value" != '..' ]] || die "$label contains a traversal-like value"
}

ddos_event_endpoint() {
  printf '/ddos-protection/v1/events/%s' "$(urlencode "$1")"
}

ddos_event_rules_endpoint() {
  printf '/ddos-protection/v1/events/%s/rules' "$(urlencode "$1")"
}

ddos_rule_endpoint() {
  printf '/ddos-protection/v1/rules/%s' "$(urlencode "$1")"
}

ddos_traffic_stats_endpoint() {
  printf '/ddos-protection/v1/events/%s/rules/%s/traffic-stats' \
    "$(urlencode "$1")" "$(urlencode "$2")"
}

ddos_extract_event_json() {
  [[ $# -eq 2 ]] || die 'ddos_extract_event_json requires <body> <event-id>'

  local body="$1"
  local event_id="$2"

  jq -ec --arg event_id "$event_id" '
    def payload:
      if type == "object" and (.data | type) == "object" then
        (.data | if (.attributes | type) == "object" then . + .attributes else . end)
      elif type == "object" then
        .
      else
        error("DDoS event response is not an object")
      end;

    payload
    | select((.id // "") == $event_id)
    | if ((.customer_id? != null) and ((.customer_id | type) != "string" or (.customer_id | length) == 0)) then
        error("DDoS event customer_id is malformed")
      elif ((.service_id? != null) and ((.service_id | type) != "string" or (.service_id | length) == 0)) then
        error("DDoS event service_id is malformed")
      else
        .
      end
  ' <<<"$body"
}

ddos_extract_rule_json() {
  [[ $# -eq 2 ]] || die 'ddos_extract_rule_json requires <body> <rule-id>'

  local body="$1"
  local rule_id="$2"

  jq -ec --arg rule_id "$rule_id" '
    def payload:
      if type == "object" and (.data | type) == "object" then
        (.data | if (.attributes | type) == "object" then . + .attributes else . end)
      elif type == "object" then
        .
      else
        error("DDoS rule response is not an object")
      end;

    payload
    | select((.id // .rule_id // "") == $rule_id)
  ' <<<"$body"
}

ddos_event_rule_records_filter() {
  cat <<'JQ'
    def records:
      if type == "array" then
        .
      elif type == "object" and (.data | type) == "array" then
        .data
      elif type == "object" and (.rules | type) == "array" then
        .rules
      else
        error("DDoS event rules response did not contain an array")
      end;
    records
JQ
}

ddos_page_next_cursor_filter() {
  cat <<'JQ'
    if type == "array" then
      null
    elif type == "object" then
      (.meta.next_cursor? // .next_cursor? // .pagination.next_cursor? // null) as $cursor
      | if ($cursor == null or ($cursor | type) == "string") then
          $cursor
        else
          error("DDoS pagination cursor was not a string or null")
        end
    else
      error("DDoS paginated response was not an object or array")
    end
JQ
}

ddos_get_event_rule_pages() {
  [[ $# -eq 4 ]] || die 'ddos_get_event_rule_pages requires <event-id> <pages-file> <records-file> <meta-file>'

  local event_id="$1"
  local pages_file="$2"
  local records_file="$3"
  local meta_file="$4"
  local endpoint cursor="" body next_cursor count pages_fetched=0 total_records=0
  local seen_cursors

  endpoint="$(ddos_event_rules_endpoint "$event_id")"
  seen_cursors="$(mktemp)"
  : >"$pages_file"
  : >"$records_file"

  while :; do
    local -a query_args=(--data-urlencode "limit=$DDOS_EVENT_RULE_PAGE_LIMIT")
    if [[ -n "$cursor" ]]; then
      query_args+=(--data-urlencode "cursor=$cursor")
    fi

    body="$(NGWAF_PROGRESS_LABEL="reading DDoS event rules" get "$endpoint" "${query_args[@]}")"
    printf '%s\n' "$body" >>"$pages_file"

    count="$(
      jq -r "$(ddos_event_rule_records_filter) | length" <<<"$body"
    )" || {
      rm -f "$seen_cursors"
      die "DDoS event rules response was malformed for event $event_id"
    }
    jq -c "$(ddos_event_rule_records_filter)[]" <<<"$body" >>"$records_file" || {
      rm -f "$seen_cursors"
      die "DDoS event rules response was malformed for event $event_id"
    }
    total_records=$(( total_records + count ))
    pages_fetched=$(( pages_fetched + 1 ))

    next_cursor="$(jq -r "$(ddos_page_next_cursor_filter)" <<<"$body")" || {
      rm -f "$seen_cursors"
      die "DDoS event rules pagination metadata was invalid for event $event_id"
    }
    [[ "$next_cursor" != "null" ]] || break
    [[ -n "$next_cursor" ]] || break

    if grep -F -x -- "$next_cursor" "$seen_cursors" >/dev/null; then
      rm -f "$seen_cursors"
      die "DDoS event rules pagination repeated cursor: $next_cursor"
    fi
    printf '%s\n' "$next_cursor" >>"$seen_cursors"
    cursor="$next_cursor"

    (( pages_fetched <= 1000 )) || {
      rm -f "$seen_cursors"
      die "DDoS event rules pagination safety limit exceeded for event $event_id"
    }
  done

  rm -f "$seen_cursors"
  jq -n \
    --arg endpoint "$endpoint" \
    --argjson limit "$DDOS_EVENT_RULE_PAGE_LIMIT" \
    --argjson pages_fetched "$pages_fetched" \
    --argjson total_records "$total_records" \
    '{
      endpoint: $endpoint,
      method: "GET",
      limit: $limit,
      pages_fetched: $pages_fetched,
      total_records: $total_records
    }' >"$meta_file"
}

ddos_event_rule_ids_json() {
  [[ $# -eq 1 ]] || die 'ddos_event_rule_ids_json requires <records-file>'

  local records_file="$1"

  jq -s '
    def rule_id:
      (.rule_id // .id // null);
    [.[]
      | rule_id as $id
      | if (($id | type) == "string" and ($id | length) > 0) then
          $id
        else
          error("DDoS event rule record is missing id/rule_id")
        end
    ] as $ids
    | ($ids | group_by(.) | map(select(length > 1) | .[0])) as $duplicates
    | if ($duplicates | length) > 0 then
        error("DDoS event rules contained duplicate rule IDs: " + ($duplicates | join(", ")))
      else
        $ids
      end
  ' "$records_file"
}

ddos_append_event_rule_evidence() {
  [[ $# -eq 4 ]] || die 'ddos_append_event_rule_evidence requires <records-file> <output-file> <event-id> <retrieved-at>'

  local records_file="$1"
  local output_file="$2"
  local event_id="$3"
  local retrieved_at="$4"
  local endpoint

  endpoint="$(ddos_event_rules_endpoint "$event_id")"
  jq -s -c \
    --arg event_id "$event_id" \
    --arg endpoint "$endpoint" \
    --arg retrieved_at "$retrieved_at" '
    def rule_id:
      (.rule_id // .id);
    .[]
    | {
        event_id: $event_id,
        rule_id: rule_id,
        retrieved_at: $retrieved_at,
        source: {
          method: "GET",
          endpoint: $endpoint,
          data_class: "ddos_event_rule"
        },
        response: .
      }
  ' "$records_file" >"$output_file"
}

ddos_append_rule_detail() {
  [[ $# -eq 3 ]] || die 'ddos_append_rule_detail requires <rule-id> <retrieved-at> <output-file>'

  local rule_id="$1"
  local retrieved_at="$2"
  local output_file="$3"
  local endpoint body rule

  endpoint="$(ddos_rule_endpoint "$rule_id")"
  body="$(NGWAF_PROGRESS_LABEL="reading DDoS rule $rule_id" get "$endpoint")"
  if ! rule="$(ddos_extract_rule_json "$body" "$rule_id")"; then
    die "DDoS rule detail response ID did not match requested rule $rule_id"
  fi

  json_stream "$rule" |
    jq -s -c \
      --arg rule_id "$rule_id" \
      --arg endpoint "$endpoint" \
      --arg retrieved_at "$retrieved_at" '
      .[0] as $rule
      | {
          rule_id: $rule_id,
          retrieved_at: $retrieved_at,
          source: {
            method: "GET",
            endpoint: $endpoint,
            data_class: "ddos_rule_detail"
          },
          response: $rule
        }
    ' >>"$output_file"
}

ddos_append_traffic_stats() {
  [[ $# -eq 4 ]] || die 'ddos_append_traffic_stats requires <event-id> <rule-id> <retrieved-at> <output-file>'

  local event_id="$1"
  local rule_id="$2"
  local retrieved_at="$3"
  local output_file="$4"
  local endpoint body

  endpoint="$(ddos_traffic_stats_endpoint "$event_id" "$rule_id")"
  body="$(NGWAF_PROGRESS_LABEL="reading DDoS traffic stats for $rule_id" get "$endpoint")"
  jq -e 'type == "object" or type == "array"' >/dev/null <<<"$body" ||
    die "DDoS traffic-statistics response was not JSON object/array for rule $rule_id"

  json_stream "$body" |
    jq -s -c \
      --arg event_id "$event_id" \
      --arg rule_id "$rule_id" \
      --arg endpoint "$endpoint" \
      --arg retrieved_at "$retrieved_at" '
      .[0] as $stats
      | {
          event_id: $event_id,
          rule_id: $rule_id,
          retrieved_at: $retrieved_at,
          source: {
            method: "GET",
            endpoint: $endpoint,
            data_class: "ddos_event_rule_traffic_stats"
          },
          response: $stats
        }
    ' >>"$output_file"
}

ddos_emit_evidence_output() {
  [[ $# -eq 3 ]] || die 'ddos_emit_evidence_output requires <content> <output-file> <rule-count>'

  local content="$1"
  local output="$2"
  local rule_count="$3"
  local parent temp_file old_umask

  if [[ "$output" == "-" ]]; then
    printf '%s\n' "$content"
    return
  fi

  parent="$(dirname "$output")"
  [[ -d "$parent" ]] || die "DDoS evidence output directory does not exist: $parent"
  [[ ! -e "$output" ]] || die "refusing to overwrite existing DDoS evidence output: $output"

  old_umask="$(umask)"
  umask 077
  temp_file="$(mktemp "$parent/.fastly-ddos-evidence.XXXXXX")"
  umask "$old_umask"

  if ! printf '%s\n' "$content" >"$temp_file"; then
    rm -f "$temp_file"
    die "failed to write DDoS evidence output: $output"
  fi

  chmod 600 "$temp_file"
  if ! ln "$temp_file" "$output"; then
    rm -f "$temp_file"
    die "refusing to overwrite existing DDoS evidence output: $output"
  fi
  rm -f "$temp_file"

  if [[ "$rule_count" == "1" ]]; then
    printf '%s: wrote DDoS evidence for %s event rule to %s\n' \
      "${PROGRAM_NAME:-ngwaf}" "$rule_count" "$output" >&2
  else
    printf '%s: wrote DDoS evidence for %s event rules to %s\n' \
      "${PROGRAM_NAME:-ngwaf}" "$rule_count" "$output" >&2
  fi
}

ddos_build_evidence_bundle() {
  [[ $# -eq 13 ]] || die 'ddos_build_evidence_bundle requires internal evidence files and scope'

  local event_file="$1"
  local event_rules_file="$2"
  local event_rule_pages_file="$3"
  local event_rule_pagination_file="$4"
  local rule_details_file="$5"
  local traffic_stats_file="$6"
  local event_id="$7"
  local requested_customer_id="$8"
  local event_customer_id="$9"
  local service_id="${10}"
  local requested_service_id="${11}"
  local collected_at="${12}"
  local event_retrieved_at="${13}"
  local event_endpoint

  event_endpoint="$(ddos_event_endpoint "$event_id")"
  jq -n \
    --arg schema "$DDOS_EVIDENCE_SCHEMA" \
    --argjson schema_version "$DDOS_EVIDENCE_SCHEMA_VERSION" \
    --arg collected_at "$collected_at" \
    --arg collector_name "${PROGRAM_NAME:-ngwaf}" \
    --arg collector_version "$VERSION" \
    --arg event_id "$event_id" \
    --arg requested_customer_id "$requested_customer_id" \
    --arg event_customer_id "$event_customer_id" \
    --arg service_id "$service_id" \
    --arg requested_service_id "$requested_service_id" \
    --arg event_endpoint "$event_endpoint" \
    --arg event_retrieved_at "$event_retrieved_at" \
    --slurpfile event "$event_file" \
    --slurpfile event_rules "$event_rules_file" \
    --slurpfile event_rule_pages "$event_rule_pages_file" \
    --slurpfile event_rule_pagination "$event_rule_pagination_file" \
    --slurpfile rule_details "$rule_details_file" \
    --slurpfile traffic_stats "$traffic_stats_file" '
    ($event_rule_pagination[0] // {}) as $pagination
    | {
        schema: $schema,
        schema_version: $schema_version,
        collected_at: $collected_at,
        collector: {
          name: $collector_name,
          version: $collector_version
        },
        scope: {
          event_id: $event_id,
          requested_customer_id: $requested_customer_id,
          customer_id: (if $event_customer_id == "" then null else $event_customer_id end),
          service_id: (if $service_id == "" then null else $service_id end),
          requested_service_id: (if $requested_service_id == "" then null else $requested_service_id end)
        },
        collection: {
          status: "complete",
          completeness: "complete",
          missing_data_policy: "fail_closed",
          partial_evidence_supported: true,
          errors: [],
          api_access: "read_only_GET_requests",
          endpoints: [
            "GET /ddos-protection/v1/events/{event_id}",
            "GET /ddos-protection/v1/events/{event_id}/rules",
            "GET /ddos-protection/v1/rules/{rule_id}",
            "GET /ddos-protection/v1/events/{event_id}/rules/{rule_id}/traffic-stats"
          ],
          pagination: {
            event_rules: {
              method: "cursor",
              status: "complete",
              pages_fetched: ($pagination.pages_fetched // 0),
              total_records: ($pagination.total_records // ($event_rules | length))
            }
          },
          limitations: [
            "No DDoS investigation heuristics, false-positive classification, mitigation recommendations, or aggregate traffic totals are calculated.",
            "Current rule details are preserved separately from event-specific rule evidence."
          ]
        },
        data: {
          event: {
            event_id: $event_id,
            retrieved_at: $event_retrieved_at,
            source: {
              method: "GET",
              endpoint: $event_endpoint,
              data_class: "ddos_event"
            },
            response: $event[0]
          },
          event_rules: {
            retrieved_at: ($event_rules[0].retrieved_at // null),
            source: {
              method: "GET",
              endpoint: $pagination.endpoint,
              data_class: "ddos_event_rules",
              pagination: "cursor"
            },
            records: $event_rules,
            raw_pages: $event_rule_pages
          },
          rule_details: $rule_details,
          traffic_stats: $traffic_stats
        }
      }
  '
}

cmd_ddos_export_event() {
  [[ $# -ge 1 ]] ||
    die 'usage: fastly-audit ddos export-event EVENT_ID --output FILE|- [--customer CUSTOMER_ID] [--service SERVICE_ID]'

  local event_id="$1"
  shift
  local output="" requested_customer_id="" requested_service_id=""
  local cid customer_name endpoint event_body event event_customer_id event_service_id
  local verified_customer_id rule_ids rule_count collected_at event_retrieved_at rules_retrieved_at
  local work_dir event_file event_rule_records_raw event_rules_file event_rule_pages_file event_rule_pagination_file
  local rule_details_file traffic_stats_file bundle

  ddos_validate_resource_id 'DDoS event ID' "$event_id"

  while (( $# > 0 )); do
    case "$1" in
      --output)
        (( $# >= 2 )) || die '--output requires a file path or -'
        output="$2"
        shift 2
        ;;
      --customer)
        (( $# >= 2 )) || die '--customer requires a customer ID'
        requested_customer_id="$2"
        shift 2
        ;;
      --service)
        (( $# >= 2 )) || die '--service requires a service ID'
        requested_service_id="$2"
        shift 2
        ;;
      --*)
        die "unknown DDoS export-event option: $1"
        ;;
      *)
        die 'usage: fastly-audit ddos export-event EVENT_ID --output FILE|- [--customer CUSTOMER_ID] [--service SERVICE_ID]'
        ;;
    esac
  done

  [[ -n "$output" ]] || die 'DDoS export-event requires --output FILE or --output -'
  [[ "$output" == "-" || ! -e "$output" ]] ||
    die "refusing to overwrite existing DDoS evidence output: $output"

  cid="$(current_cid)"
  customer_name="$(current_customer_name)"
  if [[ -n "$requested_customer_id" && "$requested_customer_id" != "$cid" ]]; then
    die "requested customer $requested_customer_id does not match selected customer $customer_name ($cid)"
  fi
  requested_customer_id="$cid"
  if [[ -n "$requested_service_id" ]]; then
    ddos_validate_resource_id 'DDoS service ID' "$requested_service_id"
  fi

  endpoint="$(ddos_event_endpoint "$event_id")"
  event_retrieved_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  event_body="$(NGWAF_PROGRESS_LABEL="reading DDoS event" get "$endpoint")"
  if ! event="$(ddos_extract_event_json "$event_body" "$event_id")"; then
    die "DDoS event lookup returned an unrecognized object or mismatched event ID: $event_id"
  fi

  event_customer_id="$(jq -r '.customer_id // empty' <<<"$event")"
  event_service_id="$(jq -r '.service_id // empty' <<<"$event")"
  if [[ -n "$requested_service_id" && "$event_service_id" != "$requested_service_id" ]]; then
    die "DDoS event service_id ${event_service_id:-missing} does not match requested service $requested_service_id"
  fi

  verified_customer_id="$event_customer_id"
  if [[ -z "$verified_customer_id" && -n "$event_service_id" ]]; then
    verified_customer_id="$(ddos_event_service_customer_id "$event_service_id")"
  fi
  [[ -n "$verified_customer_id" ]] ||
    die "DDoS event ownership could not be established: event $event_id has no customer_id or verifiable service_id"
  [[ "$verified_customer_id" == "$cid" ]] ||
    die "DDoS event does not belong to selected customer $customer_name ($cid)"

  work_dir="$(mktemp -d)"
  event_file="$work_dir/event.json"
  event_rule_records_raw="$work_dir/event-rule-records.jsonl"
  event_rules_file="$work_dir/event-rules.jsonl"
  event_rule_pages_file="$work_dir/event-rule-pages.jsonl"
  event_rule_pagination_file="$work_dir/event-rule-pagination.json"
  rule_details_file="$work_dir/rule-details.jsonl"
  traffic_stats_file="$work_dir/traffic-stats.jsonl"
  : >"$rule_details_file"
  : >"$traffic_stats_file"
  printf '%s\n' "$event" >"$event_file"

  ddos_get_event_rule_pages "$event_id" "$event_rule_pages_file" "$event_rule_records_raw" "$event_rule_pagination_file"
  rule_ids="$(ddos_event_rule_ids_json "$event_rule_records_raw")" ||
    die "DDoS event rules contained missing or duplicate rule IDs for event $event_id"
  rule_count="$(jq 'length' <<<"$rule_ids")"
  rules_retrieved_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  ddos_append_event_rule_evidence "$event_rule_records_raw" "$event_rules_file" "$event_id" "$rules_retrieved_at"

  while IFS= read -r rule_id; do
    [[ -n "$rule_id" ]] || continue
    ddos_append_rule_detail "$rule_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$rule_details_file"
    ddos_append_traffic_stats "$event_id" "$rule_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$traffic_stats_file"
  done < <(jq -r '.[]' <<<"$rule_ids")

  collected_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  bundle="$(
    ddos_build_evidence_bundle \
      "$event_file" \
      "$event_rules_file" \
      "$event_rule_pages_file" \
      "$event_rule_pagination_file" \
      "$rule_details_file" \
      "$traffic_stats_file" \
      "$event_id" \
      "$requested_customer_id" \
      "$verified_customer_id" \
      "$event_service_id" \
      "$requested_service_id" \
      "$collected_at" \
      "$event_retrieved_at"
  )"
  rm -rf "$work_dir"

  ddos_emit_evidence_output "$(jq . <<<"$bundle")" "$output" "$rule_count"
}
