# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

RULE_AUDIT_DEFAULT_SIGNALS="${NGWAF_RULE_AUDIT_SIGNALS:-SQLI,XSS,CMDEXE,TRAVERSAL,SCANNER,SUSPECTED-BAD-BOT,DATACENTER}"
RULE_AUDIT_HIGH_VOLUME="${NGWAF_RULE_AUDIT_HIGH_VOLUME:-1000000}"
RULE_AUDIT_STALE_DAYS="${NGWAF_RULE_AUDIT_STALE_DAYS:-365}"
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
