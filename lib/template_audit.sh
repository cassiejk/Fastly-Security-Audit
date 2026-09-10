# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

template_audit_shell_arg() {
  printf '%q' "$1"
}

template_audit_requests_command_prefix() {
  if [[ "${PROGRAM_NAME:-ngwaf}" == "ngwaf" ]]; then
    printf 'ngwaf requests'
  else
    printf '%s ngwaf requests' "${PROGRAM_NAME:-fastly-audit}"
  fi
}

template_audit_tag_value() {
  local value="$1"
  local escaped

  if [[ "$value" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    printf '%s\n' "$value"
    return
  fi

  escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '"%s"\n' "$escaped"
}

template_audit_count_query() {
  [[ $# -eq 1 ]] || die 'template_audit_count_query requires <query>'

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

template_audit_candidates_json() {
  [[ $# -eq 1 ]] || die 'template_audit_candidates_json requires <rules-json>'

  local rules_payload="$1"

  json_stream "$rules_payload" |
    jq -s '
      def nonempty_scalar:
        select(. != null)
        | if type == "string" or type == "number" or type == "boolean" then tostring else empty end
        | select(length > 0);
      def first_nonempty($items): [$items[]? | nonempty_scalar][0] // null;
      def unique_nonempty($items): [$items[]? | nonempty_scalar] | unique;
      def norm_token: tostring | gsub("[^A-Za-z0-9]"; "") | ascii_downcase;
      def action_type:
        if type == "object" then (.type? // .action? // .name? // empty)
        else .
        end
        | nonempty_scalar;
      def action_types: [(.actions // [])[]? | action_type];
      def rule_type: (.type // .rule_type // "");
      def is_templated_signal:
        ((rule_type | norm_token) | contains("templatedsignal"))
        or any(action_types[]?; ((. | norm_token) | contains("templatedsignal")));
      def condition_objects:
        [
          (.conditions // [])[]?,
          (.condition_groups // [])[]?.conditions[]?,
          (.groups // [])[]?.conditions[]?
          | select(type == "object")
        ];
      def value_candidates:
        [
          .value?,
          .match?,
          .pattern?,
          .content?,
          .argument?,
          .path?,
          .uri?,
          .method?,
          .hostname?,
          .host?
        ]
        + (if (.values? | type) == "array" then .values else [] end);
      def condition_values_for($regex):
        [
          condition_objects[]
          | select(((.field // .type // .name // .target // .variable // "") | tostring | test($regex; "i")))
          | value_candidates[]
          | nonempty_scalar
        ]
        | unique;
      def template_id:
        first_nonempty([
          .template_id?,
          .template.id?,
          .templated_signal.template_id?,
          .signal.template_id?,
          .actions[]?.template_id?,
          .actions[]?.template.id?,
          .actions[]?.parameters.template_id?
        ]);
      def template_name:
        first_nonempty([
          .template_name?,
          .template.name?,
          .template.display_name?,
          .templated_signal.template_name?,
          .templated_signal.name?,
          .templated_signal.display_name?,
          .actions[]?.template_name?,
          .actions[]?.template.name?,
          .actions[]?.parameters.template_name?
        ]);
      def signal_id:
        first_nonempty([
          .signal_id?,
          .signal.id?,
          .signal.reference_id?,
          .templated_signal.signal_id?,
          .templated_signal.id?,
          .template.signal_id?,
          .actions[]?.signal_id?,
          .actions[]?.signal.id?,
          .actions[]?.signal.reference_id?,
          .actions[]?.parameters.signal_id?
        ]);
      def signal_name:
        first_nonempty([
          .signal_name?,
          .signal.name?,
          .signal.display_name?,
          .signal?,
          .tag?,
          .templated_signal.signal_name?,
          .templated_signal.name?,
          .template.signal_name?,
          .actions[]?.signal_name?,
          .actions[]?.signal.name?,
          .actions[]?.signal?,
          .actions[]?.parameters.signal_name?,
          .actions[]?.parameters.signal?
        ]);
      def display_name:
        first_nonempty([
          template_name,
          signal_name,
          .name?,
          .display_name?,
          .description?
        ]);
      def rule_id:
        first_nonempty([.id?, .rule_id?, .reference_id?]);
      def rule_method:
        first_nonempty([
          .method?,
          .request_method?,
          (condition_values_for("method")[]?)
        ]);
      def rule_path:
        first_nonempty([
          .path?,
          .uri?,
          .url?,
          (condition_values_for("path|uri|url")[]?)
        ]);
      def rule_host:
        first_nonempty([
          .host?,
          .hostname?,
          .domain?,
          (condition_values_for("host|hostname|domain")[]?)
        ]);

      (.[0].data // []) as $rules
      | [
          $rules[]
          | select(is_templated_signal)
          | . as $raw
          | {
              rule_id: rule_id,
              enabled: (if $raw | has("enabled") then $raw.enabled else null end),
              type: ($raw.type // $raw.rule_type // null),
              name: display_name,
              template_id: template_id,
              template_name: template_name,
              signal_id: signal_id,
              signal_name: signal_name,
              description: ($raw.description // $raw.name // ""),
              method: rule_method,
              path: rule_path,
              host: rule_host,
              conditions: ($raw.conditions // []),
              condition_groups: ($raw.condition_groups // $raw.groups // []),
              actions: ($raw.actions // []),
              created_at: ($raw.created_at // null),
              updated_at: ($raw.updated_at // null),
              raw: $raw
            } as $rule
          | $rule
          | . + {
              correlation_key: (
                if .signal_id != null then "signal_id:" + .signal_id
                elif .template_id != null then "template_id:" + .template_id
                elif .name != null then "name:" + (.name | ascii_downcase)
                else "rule_id:" + (.rule_id // "unknown")
                end
              ),
              condition_signature: ([
                .method // "",
                .host // "",
                .path // "",
                (.conditions | tojson),
                (.condition_groups | tojson)
              ] | @json),
              selectors: unique_nonempty([
                .rule_id,
                .template_id,
                .template_name,
                .signal_id,
                .signal_name,
                .name
              ])
            }
        ]
    '
}

template_audit_select_template_json() {
  [[ $# -eq 2 ]] || die 'template_audit_select_template_json requires <candidates-json> <template>'

  local candidates_payload="$1"
  local template_input="$2"

  json_stream "$candidates_payload" |
    jq -s --arg requested "$template_input" '
      def norm_name: tostring | ascii_downcase;
      .[0] as $candidates
      | ($requested | norm_name) as $requested_name
      | [
          $candidates[]
          | select(
              (.template_id // "") == $requested
              or (.signal_id // "") == $requested
              or (.rule_id // "") == $requested
              or ((.template_name // "" | norm_name) == $requested_name)
              or ((.signal_name // "" | norm_name) == $requested_name)
              or ((.name // "" | norm_name) == $requested_name)
            )
        ] as $matches
      | (
          $matches
          | sort_by(.correlation_key)
          | group_by(.correlation_key)
          | map({
              correlation_key: .[0].correlation_key,
              template_id: ([.[].template_id // empty] | unique | .[0] // null),
              signal_id: ([.[].signal_id // empty] | unique | .[0] // null),
              name: ([.[] | .name // .signal_name // .template_name // empty] | unique | .[0] // null),
              tagging_rule_ids: [.[].rule_id],
              rules: .
            })
        ) as $groups
      | if ($groups | length) == 0 then
          {
            status: "not_found",
            requested_template: $requested,
            candidates: [
              $candidates[]
              | {
                  name,
                  template_id,
                  signal_id,
                  tagging_rule_ids: [.rule_id],
                  correlation_key
                }
            ]
          }
        elif ($groups | length) > 1 then
          {
            status: "ambiguous",
            requested_template: $requested,
            matches: [
              $groups[]
              | {
                  name,
                  template_id,
                  signal_id,
                  tagging_rule_ids,
                  correlation_key
                }
            ]
          }
        else
          $groups[0] as $selected
          | ($selected.rules | map(select(.enabled == true)) | length) as $enabled_count
          | ($selected.rules | map(select(.enabled == false)) | length) as $disabled_count
          | {
              status: "selected",
              requested_template: $requested,
              template: {
                name: $selected.name,
                template_id: $selected.template_id,
                signal_id: $selected.signal_id,
                signal_name: ([($selected.rules[] | .signal_name // empty)] | unique | .[0] // $selected.name),
                correlation_key: $selected.correlation_key,
                match_strategy: (
                  if any(
                    $selected.rules[];
                    (.template_id // "") == $requested
                    or (.signal_id // "") == $requested
                    or (.rule_id // "") == $requested
                  )
                  then "stable_identifier"
                  else "display_name_exact_case_insensitive"
                  end
                ),
                enabled: (
                  if $enabled_count > 0 then true
                  elif $disabled_count > 0 and $disabled_count == ($selected.rules | length) then false
                  else null
                  end
                )
              },
              tagging_rules: ($selected.rules | sort_by((.enabled == false), (.path // ""), (.rule_id // "")))
            }
        end
    '
}

template_audit_thresholds_json() {
  [[ $# -eq 2 ]] || die 'template_audit_thresholds_json requires <thresholds-json> <selection-json>'

  local thresholds_payload="$1"
  local selection_payload="$2"

  json_stream "$thresholds_payload" "$selection_payload" |
    jq -s '
      def nonempty_scalar:
        select(. != null)
        | if type == "string" or type == "number" or type == "boolean" then tostring else empty end
        | select(length > 0);
      def first_nonempty($items): [$items[]? | nonempty_scalar][0] // null;
      def first_number($items): [$items[]? | try tonumber catch empty][0] // null;
      def plural($n; $unit): ($n | tostring) + " " + $unit + (if $n == 1 then "" else "s" end);
      def duration_label($value):
        ($value | try tonumber catch null) as $seconds
        | if $value == null then null
          elif $seconds != null and ($seconds % 86400) == 0 then plural(($seconds / 86400 | floor); "day")
          elif $seconds != null and ($seconds % 3600) == 0 then plural(($seconds / 3600 | floor); "hour")
          elif $seconds != null and ($seconds % 60) == 0 then plural(($seconds / 60 | floor); "minute")
          elif $seconds != null then plural(($seconds | floor); "second")
          else ($value | tostring)
          end;
      def threshold_id:
        first_nonempty([.id?, .threshold_id?, .reference_id?]);
      def template_id:
        first_nonempty([
          .template_id?,
          .template.id?,
          .signal.template_id?,
          .signals[]?.template_id?,
          .conditions[]?.template_id?
        ]);
      def signal_id:
        first_nonempty([
          .signal_id?,
          .signal.id?,
          .signal.reference_id?,
          .tag_id?,
          .signals[]?.id?,
          .signals[]?.signal_id?,
          .conditions[]?.signal_id?
        ]);
      def signal_name:
        first_nonempty([
          .signal_name?,
          .signal.name?,
          .signal?,
          .tag?,
          .signals[]?.name?,
          .signals[]?.signal?,
          .conditions[]?.signal?,
          .conditions[]?.tag?
        ]);
      def selected_name($template):
        first_nonempty([$template.signal_name, $template.name]);
      def match_source($template):
        if $template.signal_id != null and signal_id == $template.signal_id then "signal_id"
        elif $template.template_id != null and template_id == $template.template_id then "template_id"
        elif selected_name($template) != null and ((signal_name // "" | ascii_downcase) == (selected_name($template) | ascii_downcase)) then "display_name"
        else null
        end;

      .[0] as $threshold_response
      | .[1].template as $template
      | ($threshold_response.data // []) as $thresholds
      | [
          $thresholds[]
          | . as $raw
          | match_source($template) as $matched_by
          | select($matched_by != null)
          | first_number([
              $raw.window_seconds?,
              $raw.period_seconds?,
              $raw.time_window_seconds?,
              $raw.interval_seconds?,
              $raw.window?.seconds?,
              $raw.period?.seconds?
            ]) as $window_seconds
          | first_number([
              $raw.duration_seconds?,
              $raw.action_duration_seconds?,
              $raw.block_duration_seconds?,
              $raw.ban_duration_seconds?,
              $raw.duration?.seconds?
            ]) as $duration_seconds
          | first_nonempty([
              $raw.window?,
              $raw.period?,
              $raw.time_window?,
              $raw.interval?
            ]) as $window_raw
          | first_nonempty([
              $raw.duration?,
              $raw.action_duration?,
              $raw.block_duration?,
              $raw.ban_duration?
            ]) as $duration_raw
          | {
              threshold_id: threshold_id,
              enabled: (if $raw | has("enabled") then $raw.enabled else null end),
              signal: {
                id: signal_id,
                name: signal_name,
                template_id: template_id
              },
              count: first_number([
                $raw.count?,
                $raw.request_count?,
                $raw.signal_count?,
                $raw.threshold?,
                $raw.limit?,
                $raw.value?
              ]),
              window_seconds: $window_seconds,
              window: $window_raw,
              window_label: duration_label($window_seconds // $window_raw),
              action: first_nonempty([
                $raw.action?,
                $raw.action_type?,
                $raw.action?.type?,
                $raw.actions[]?.type?,
                $raw.enforcement_action?
              ]),
              key: first_nonempty([
                $raw.key?,
                $raw.group_by?,
                $raw.enforcement_key?,
                $raw.scope_key?,
                $raw.client_identifier?,
                $raw.client_identification?
              ]),
              duration_seconds: $duration_seconds,
              duration: $duration_raw,
              duration_label: duration_label($duration_seconds // $duration_raw),
              notification: ($raw.notification // $raw.notifications // $raw.alerting // $raw.alert // null),
              correlation: {
                matched_by: $matched_by
              },
              raw: $raw
            }
        ]
        | sort_by((.enabled == false), (.window_seconds // 999999999), (.count // 999999999), (.threshold_id // ""))
    '
}

template_audit_indicators_json() {
  [[ $# -eq 3 ]] ||
    die 'template_audit_indicators_json requires <tagging-rules-json> <thresholds-json> <retained-matches>'

  local tagging_rules_payload="$1"
  local thresholds_payload="$2"
  local retained_matches="$3"

  json_stream "$tagging_rules_payload" "$thresholds_payload" |
    jq -s --argjson retained_matches "$retained_matches" '
      def nonempty($value): ($value != null and ($value | tostring | length) > 0);
      def norm($value): ($value // "" | tostring | ascii_downcase);
      def duplicate_groups($items; $key):
        $items
        | sort_by(.[$key] // "")
        | group_by(.[$key] // "")
        | map(select(length > 1 and nonempty(.[0][$key])));

      .[0] as $tagging_rules
      | .[1] as $thresholds
      | ($tagging_rules | map(select(.enabled == true))) as $enabled_rules
      | ($tagging_rules | map(select(.enabled == false))) as $disabled_rules
      | ($thresholds | map(select(.enabled == true))) as $active_thresholds
      | ($thresholds | map(select(.enabled == false))) as $disabled_thresholds
      | duplicate_groups($tagging_rules; "condition_signature") as $duplicate_rule_conditions
      | (
          $thresholds
          | map(. + {
              identity_signature: ([
                .count,
                (.window_seconds // .window_label // .window),
                (.action // ""),
                (.key // ""),
                (.duration_seconds // .duration_label // .duration)
              ] | @json),
              window_action_signature: ([
                (.window_seconds // .window_label // .window),
                (.action // "")
              ] | @json)
            })
        ) as $threshold_signatures
      | duplicate_groups($threshold_signatures; "identity_signature") as $identical_thresholds
      | duplicate_groups(($threshold_signatures | map(select(.enabled == true))); "window_action_signature") as $duplicate_window_actions
      | ([$active_thresholds[]? | .action // empty | norm(.)] | unique) as $active_actions
      | ([$active_thresholds[]? | .duration_seconds // .duration_label // .duration // empty | tostring] | unique) as $active_durations
      | [
          (if ($disabled_rules | length) > 0 then {
            category: "configuration_observation",
            indicator: "disabled_tagging_rules",
            detail: (($disabled_rules | length | tostring) + " signal-tagging rule(s) are disabled."),
            rule_ids: [$disabled_rules[] | .rule_id]
          } else empty end),
          (if ($disabled_thresholds | length) > 0 then {
            category: "configuration_observation",
            indicator: "disabled_thresholds",
            detail: (($disabled_thresholds | length | tostring) + " associated threshold(s) are disabled."),
            threshold_ids: [$disabled_thresholds[] | .threshold_id]
          } else empty end),
          (if ($active_thresholds | length) > 0 and ($enabled_rules | length) == 0 then {
            category: "review_indicator",
            indicator: "active_thresholds_without_enabled_tagging_rules",
            detail: "Active thresholds consume this signal, but no enabled signal-tagging rules were found."
          } else empty end),
          (if ($enabled_rules | length) > 0 and ($active_thresholds | length) == 0 then {
            category: "review_indicator",
            indicator: "enabled_tagging_rules_without_active_thresholds",
            detail: "Enabled signal-tagging rules generate this signal, but no active thresholds were found."
          } else empty end),
          (if ($thresholds | length) == 0 then {
            category: "configuration_observation",
            indicator: "no_associated_thresholds",
            detail: "No associated signal thresholds were found for this templated signal."
          } else empty end),
          (if ($duplicate_rule_conditions | length) > 0 then {
            category: "review_indicator",
            indicator: "duplicate_tagging_conditions",
            detail: "Multiple signal-tagging rules have identical extracted request conditions.",
            rule_groups: [
              $duplicate_rule_conditions[]
              | {rule_ids: [.[] | .rule_id]}
            ]
          } else empty end),
          (if ($identical_thresholds | length) > 0 then {
            category: "review_indicator",
            indicator: "identical_thresholds",
            detail: "Multiple thresholds have identical count, window, action, key, and duration values.",
            threshold_groups: [
              $identical_thresholds[]
              | {threshold_ids: [.[] | .threshold_id]}
            ]
          } else empty end),
          (if ($duplicate_window_actions | length) > 0 then {
            category: "review_indicator",
            indicator: "duplicate_threshold_window_action",
            detail: "Multiple active thresholds share the same time window and action; review whether each condition has a distinct purpose.",
            threshold_groups: [
              $duplicate_window_actions[]
              | {threshold_ids: [.[] | .threshold_id]}
            ]
          } else empty end),
          (if ($active_thresholds | length) > 1 then {
            category: "threshold_relationship",
            indicator: "possible_overlap",
            detail: "Multiple active thresholds consume this signal over related windows; review whether they provide distinct burst and lower-and-slower protection."
          } else empty end),
          (if ($active_actions | length) > 1 then {
            category: "review_indicator",
            indicator: "inconsistent_enforcement_actions",
            detail: "Active thresholds for this signal use more than one enforcement action.",
            actions: $active_actions
          } else empty end),
          (if ($active_durations | length) > 1 then {
            category: "review_indicator",
            indicator: "inconsistent_action_durations",
            detail: "Active thresholds for this signal use more than one action duration.",
            durations: $active_durations
          } else empty end),
          (if $retained_matches == 0 then {
            category: "configuration_observation",
            indicator: "zero_retained_matches",
            detail: "No retained searchable request records matched this signal in the selected window."
          } else empty end)
        ]
    '
}

template_audit_report_json() {
  [[ $# -eq 3 ]] || die 'template_audit_report_json requires <workspace> <template> <days>'

  local input="$1"
  local template_input="$2"
  local days="$3"
  local cid rules_body thresholds_body candidates selection status ambiguity
  local tagging_rules thresholds retained_matches tag_value query indicators
  local signal_value drilldown_command

  request_search_prepare_scope "$input" "$days"
  cid="$REQUEST_SEARCH_CUSTOMER_ID"

  rules_body="$(
    get_all_pages "$(workspace_path "$REQUEST_SEARCH_WORKSPACE_ID")/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  thresholds_body="$(
    get "$(workspace_path "$REQUEST_SEARCH_WORKSPACE_ID")/thresholds" \
      --data-urlencode "customer_id=$cid"
  )"
  jq -e '.data | type == "array"' >/dev/null <<<"$thresholds_body" ||
    die 'thresholds returned an unexpected response; refusing to report template audit'

  candidates="$(template_audit_candidates_json "$rules_body")"
  selection="$(template_audit_select_template_json "$candidates" "$template_input")"
  status="$(jq -r '.status' <<<"$selection")"

  case "$status" in
    selected)
      ;;
    not_found)
      die "templated signal not found: $template_input"
      ;;
    ambiguous)
      ambiguity="$(
        jq -r '
          [.matches[] | ((.name // "unnamed") + " signal_id=" + (.signal_id // "-") + " template_id=" + (.template_id // "-"))]
          | join("; ")
        ' <<<"$selection"
      )"
      die "templated signal is ambiguous: $template_input; matches: $ambiguity"
      ;;
    *)
      die "internal error: unexpected template selection status: $status"
      ;;
  esac

  tagging_rules="$(jq '.tagging_rules' <<<"$selection")"
  thresholds="$(template_audit_thresholds_json "$thresholds_body" "$selection")"

  signal_value="$(
    jq -r '
      .template.signal_name
      // .template.name
      // .template.signal_id
      // .template.template_id
      // empty
    ' <<<"$selection"
  )"
  [[ -n "$signal_value" ]] ||
    die "templated signal did not expose a usable request-search tag value: $template_input"
  tag_value="$(template_audit_tag_value "$signal_value")"
  query="tag:$tag_value"

  retained_matches="$(template_audit_count_query "$query")"
  indicators="$(template_audit_indicators_json "$tagging_rules" "$thresholds" "$retained_matches")"
  drilldown_command="$(
    printf '%s %s %s %s --limit 25' \
      "$(template_audit_requests_command_prefix)" \
      "$(template_audit_shell_arg "$REQUEST_SEARCH_WORKSPACE_INPUT")" \
      "$(template_audit_shell_arg "$query")" \
      "$REQUEST_SEARCH_DAYS"
  )"

  json_stream "$selection" "$thresholds" "$indicators" |
    jq -s \
      --arg customer "$REQUEST_SEARCH_CUSTOMER" \
      --arg customer_id "$REQUEST_SEARCH_CUSTOMER_ID" \
      --arg workspace "$REQUEST_SEARCH_WORKSPACE" \
      --arg workspace_id "$REQUEST_SEARCH_WORKSPACE_ID" \
      --arg workspace_input "$REQUEST_SEARCH_WORKSPACE_INPUT" \
      --arg from "$REQUEST_SEARCH_FROM_UTC" \
      --arg until "$REQUEST_SEARCH_UNTIL_UTC" \
      --arg query "$query" \
      --arg requested_query "$query" \
      --arg drilldown_command "$drilldown_command" \
      --argjson from_epoch "$REQUEST_SEARCH_FROM_EPOCH" \
      --argjson until_epoch "$REQUEST_SEARCH_UNTIL_EPOCH" \
      --argjson days "$REQUEST_SEARCH_DAYS" \
      --argjson retained_matches "$retained_matches" '
      .[0] as $selection
      | .[1] as $associated_thresholds
      | .[2] as $review_indicators
      | {
          command: "template-audit",
          customer: $customer,
          customer_id: $customer_id,
          workspace: $workspace,
          workspace_id: $workspace_id,
          workspace_input: $workspace_input,
          days: $days,
          template: $selection.template,
          tagging_rules: $selection.tagging_rules,
          thresholds: $associated_thresholds,
          traffic: {
            query: $query,
            requested_query: $requested_query,
            retained_matches: $retained_matches,
            count_scope: "retained_searchable_request_records",
            sampling_caveat: "Counts may reflect sampled or mixed-storage request data. They are not raw traffic or scaled estimates."
          },
          drill_down: {
            command: $drilldown_command,
            query: $query,
            limit: 25
          },
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
            tagging_rules: ($selection.tagging_rules | length),
            enabled_tagging_rules: ([$selection.tagging_rules[] | select(.enabled == true)] | length),
            disabled_tagging_rules: ([$selection.tagging_rules[] | select(.enabled == false)] | length),
            thresholds: ($associated_thresholds | length),
            active_thresholds: ([$associated_thresholds[] | select(.enabled == true)] | length),
            disabled_thresholds: ([$associated_thresholds[] | select(.enabled == false)] | length),
            retained_matches: $retained_matches,
            review_indicators: ($review_indicators | length)
          },
          review_indicators: $review_indicators,
          notes: [
            "Review indicators are deterministic observations for human analysis, not automatic remediation advice.",
            "Threshold relationship indicators do not prove that any threshold is redundant or should be removed.",
            "Counts are retained searchable NGWAF records, not raw CDN traffic or scaled estimates."
          ],
          provenance: {
            data_class: "templated_signal_configuration_plus_retained_request_search",
            configuration: {
              tagging_rules_endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/rules",
              thresholds_endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/thresholds",
              pagination: "rules complete_or_fail; thresholds single response",
              correlation_policy: "Prefer signal/template identifiers; fall back to exact display-name matching; fail on ambiguity."
            },
            request_search: {
              endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/requests",
              aggregation: "response.meta.total",
              rows_requested_per_count: 1,
              missing_data_policy: "fail_closed"
            },
            workspace_resolution: "exact ID first; otherwise case-insensitive exact name",
            customer_scoped: true,
            API_access: "read_only_GET_requests"
          }
        }
    '
}

template_audit_render_human() {
  [[ $# -eq 1 ]] || die 'template_audit_render_human requires <report-json>'

  local report="$1"
  local tagging_count threshold_count indicator_count

  ui_heading "Template Audit: $(jq -r '.template.name // .template.signal_name // .template.signal_id // "unknown"' <<<"$report")"
  jq -r '
    "Customer: \(.customer) (\(.customer_id))",
    "Workspace: \(.workspace) (\(.workspace_id); input=\(.workspace_input))",
    "Signal: \(.template.signal_name // .template.name // "-")",
    "Signal ID: \(.template.signal_id // "-")",
    "Template ID: \(.template.template_id // "-")",
    "Matched by: \(.template.match_strategy)",
    "Window: \(.window.from) to \(.window.until) UTC (rolling \(.days)d; 5-minute ingestion buffer)"
  ' <<<"$report"

  tagging_count="$(jq '.tagging_rules | length' <<<"$report")"
  printf '\n'
  ui_heading 'Signal tagging rules'
  if (( tagging_count == 0 )); then
    printf '  none\n'
  else
    jq -r '
      def cell:
        if . == null or . == "" then "-"
        else tostring
        end;
      ["STATE", "METHOD", "HOST", "PATH", "RULE ID", "DESCRIPTION"],
      (
        .tagging_rules[]
        | [
            (if .enabled == true then "ENABLED" elif .enabled == false then "DISABLED" else "UNKNOWN" end),
            .method,
            .host,
            .path,
            .rule_id,
            .description
          ]
      )
      | map(cell)
      | @tsv
    ' <<<"$report" | human_table
  fi

  threshold_count="$(jq '.thresholds | length' <<<"$report")"
  printf '\n'
  ui_heading 'Thresholds'
  if (( threshold_count == 0 )); then
    printf '  none\n'
  else
    jq -r '
      def cell:
        if . == null or . == "" then "-"
        else tostring
        end;
      ["STATE", "COUNT", "WINDOW", "ACTION", "KEY", "DURATION", "THRESHOLD ID"],
      (
        .thresholds[]
        | [
            (if .enabled == true then "ENABLED" elif .enabled == false then "DISABLED" else "UNKNOWN" end),
            .count,
            (.window_label // .window),
            .action,
            .key,
            (.duration_label // .duration),
            .threshold_id
          ]
      )
      | map(cell)
      | @tsv
    ' <<<"$report" | human_table
  fi

  printf '\n'
  ui_heading 'Retained activity'
  jq -r '
    "Signal matches: \(.traffic.retained_matches)",
    "Query: \(.traffic.query)",
    "Data: retained searchable NGWAF records, not raw traffic or scaled estimates.",
    "",
    "Drill down:",
    .drill_down.command
  ' <<<"$report"

  indicator_count="$(jq '.review_indicators | length' <<<"$report")"
  printf '\n'
  ui_heading 'Review indicators'
  if (( indicator_count == 0 )); then
    printf '  - none\n'
  else
    jq -r '.review_indicators[] | "  - " + .detail' <<<"$report"
  fi
}

cmd_template_audit() {
  local usage
  usage="usage: ngwaf template-audit <workspace> <template> [days] [--days N] [--json|--format human|json]"

  local help_usage
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    help_usage="$usage"
    help_usage="${help_usage/usage: ngwaf/usage: ${USAGE_PROGRAM:-${PROGRAM_NAME:-ngwaf}}}"
    printf '%s\n' "$help_usage"
    return 0
  fi

  [[ $# -ge 2 ]] || die "$usage"

  local input="$1"
  local template_input="$2"
  shift 2

  local days=7
  local days_set=false
  local format="human"
  local report

  while (( $# > 0 )); do
    case "$1" in
      --days)
        (( $# >= 2 )) || die '--days requires an integer from 1 to 7'
        days="$2"
        days_set=true
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
        die "unknown template-audit option: $1"
        ;;
      *)
        if [[ "$days_set" == "false" ]]; then
          days="$1"
          days_set=true
          shift
        else
          die "$usage"
        fi
        ;;
    esac
  done

  case "$format" in
    human|json)
      ;;
    *)
      die 'template-audit format must be human or json'
      ;;
  esac

  report="$(template_audit_report_json "$input" "$template_input" "$days")"

  if [[ "$format" == "json" ]]; then
    jq . <<<"$report"
  else
    template_audit_render_human "$report"
  fi
}
