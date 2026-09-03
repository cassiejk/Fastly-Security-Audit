# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

cmd_workspaces() {
  local cid body total returned
  cid="$(current_cid)"

  body="$(
    get_all_pages "/ngwaf/v1/workspaces" \
      --data-urlencode "customer_id=$cid"
  )"

  total="$(jq -r '.meta.total // (.data | length)' <<<"$body")"
  returned="$(jq -r '.data | length' <<<"$body")"

  printf 'Total NGWAF workspaces: %s\n\n' "$total"

  jq -r '
    ["NAME", "ID"],
    (.data | sort_by(.name) | .[] | [.name, .id])
    | @tsv
  ' <<<"$body" | human_table

  printf '\nSource: GET /ngwaf/v1/workspaces (selected customer; complete pagination or failure)\n'

  if (( total > returned )); then
    printf '\nWARNING: API returned %s of %s workspaces.\n' \
      "$returned" "$total" >&2
  fi
}

cmd_workspace() {
  [[ $# -eq 1 ]] || die 'usage: ngwaf workspace <workspace>'

  local cid input resolved w ws_id body
  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"

  body="$(get "$(workspace_path "$ws_id")" --data-urlencode "customer_id=$cid")"
  jq --arg input "$input" --arg workspace "$w" --arg workspace_id "$ws_id" '{
      workspace: $workspace,
      workspace_id: $workspace_id,
      workspace_input: $input,
      mode,
      immediate_blocking: (.attack_signal_thresholds.immediate // null),
      default_blocking_response_code,
      provenance: {
        endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}",
        data_class: "configuration_snapshot",
        customer_scoped: true
      }
    }' <<<"$body"
}

cmd_rule() {
  [[ $# -eq 2 ]] || die 'usage: ngwaf rule <workspace> <rule_id>'

  local cid input rule_id encoded_rule_id resolved w ws_id body actual_rule_id
  local NGWAF_PROGRESS_LABEL
  cid="$(current_cid)"
  input="$1"
  rule_id="$2"
  [[ -n "$rule_id" ]] || die 'rule ID must not be empty'

  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
  encoded_rule_id="$(urlencode "$rule_id")"
  NGWAF_PROGRESS_LABEL="retrieving rule $rule_id from $w"

  body="$(
    get "$(workspace_path "$ws_id")/rules/$encoded_rule_id" \
      --data-urlencode "customer_id=$cid"
  )"

  actual_rule_id="$(jq -r '.id // empty' <<<"$body")"
  [[ -n "$actual_rule_id" ]] ||
    die "rule response did not contain an ID: $rule_id"
  [[ "$actual_rule_id" == "$rule_id" ]] ||
    die "rule response ID did not match requested rule: expected $rule_id, received $actual_rule_id"

  jq \
    --arg workspace "$w" \
    --arg workspace_id "$ws_id" \
    --arg workspace_input "$input" \
    --arg rule_id "$rule_id" \
    '. + {
      context: {
        workspace: $workspace,
        workspace_id: $workspace_id,
        workspace_input: $workspace_input,
        rule_id: $rule_id
      },
      provenance: {
        endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/rules/{rule_id}",
        data_class: "configuration_snapshot",
        customer_scoped: true,
        pagination: "not_applicable"
      }
    }' <<<"$body"
}

cmd_rules() {
  [[ $# -ge 1 ]] || die 'usage: ngwaf rules <workspace> [--list|--json]'

  local cid input resolved w ws_id mode body summary
  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
  mode="${2:-}"

  body="$(
    get_all_pages "$(workspace_path "$ws_id")/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  if [[ "$mode" == "--json" ]]; then
    jq \
      --arg workspace "$w" \
      --arg workspace_id "$ws_id" \
      --arg workspace_input "$input" \
      '. + {
        context: {
          workspace: $workspace,
          workspace_id: $workspace_id,
          workspace_input: $workspace_input
        },
        provenance: {
          endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/rules",
          data_class: "configuration_snapshot",
          pagination: "complete_or_fail"
        }
      }' <<<"$body"
    return
  fi

  summary="$(summarize_rules_json <<<"$body")"

  jq --arg w "$w" --arg wsid "$ws_id" --arg input "$input" \
    '. + {workspace: $w, workspace_id: $wsid, workspace_input: $input}' <<<"$summary" |
    jq '{
      workspace,
      workspace_id,
      workspace_input,
      total_rules: .total,
      enabled_rules: .enabled,
      disabled_rules: .disabled,
      enabled_allow_rules,
      enabled_block_rules,
      enabled_browser_challenge_rules,
      enabled_rate_limit_rules,
      enabled_signal_exclusion_rules,
      rule_types,
      enabled_actions,
      pages_fetched
    }'

  if [[ "$mode" == "--list" ]]; then
    printf '\n'
    jq -r '
      ["TYPE", "ENABLED", "ACTIONS", "DESCRIPTION"],
      (
        .data[]
        | [
            (.type // "unknown"),
            (.enabled | tostring),
            ([.actions[]?.type] | join(",")),
            (.description // "")
          ]
      )
      | @tsv
    ' <<<"$body" | human_table
  fi
}

cmd_account_rules() {
  [[ $# -le 1 ]] || die 'usage: ngwaf account-rules [--list|--json]'

  local cid mode body summary
  cid="$(current_cid)"
  mode="${1:-}"

  [[ -z "$mode" || "$mode" == "--list" || "$mode" == "--json" ]] ||
    die 'usage: ngwaf account-rules [--list|--json]'

  body="$(
    get_all_pages "/ngwaf/v1/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  if [[ "$mode" == "--json" ]]; then
    jq --arg customer_id "$cid" '. + {
      context: {customer_id: $customer_id},
      provenance: {
        endpoint: "GET /ngwaf/v1/rules",
        data_class: "configuration_snapshot",
        pagination: "complete_or_fail"
      }
    }' <<<"$body"
    return
  fi

  summary="$(summarize_rules_json <<<"$body")"

  jq --arg cid "$cid" '
    . + {
      customer_id: $cid,
      global_rules: 0,
      workspace_scoped_rules: 0,
      provenance: {
        endpoint: "GET /ngwaf/v1/rules",
        data_class: "configuration_snapshot",
        pagination: "complete_or_fail"
      }
    }
  ' <<<"$summary" |
  jq --argjson globals "$(jq '[.data[] | select(((.scope.applies_to // []) | index("*")) != null)] | length' <<<"$body")" \
     --argjson scoped "$(jq '[.data[] | select(((.scope.applies_to // []) | index("*")) == null)] | length' <<<"$body")" \
    '.global_rules = $globals | .workspace_scoped_rules = $scoped'

  if [[ "$mode" == "--list" ]]; then
    printf '\n'
    jq -r '
      ["TYPE", "ENABLED", "APPLIES TO", "ACTIONS", "DESCRIPTION"],
      (
        .data[]
        | [
            (.type // "unknown"),
            (.enabled | tostring),
            ((.scope.applies_to // []) | join(",")),
            ([.actions[]?.type] | join(",")),
            (.description // "")
          ]
      )
      | @tsv
    ' <<<"$body" | human_table
  fi
}

cmd_thresholds() {
  [[ $# -ge 1 ]] || die 'usage: ngwaf thresholds <workspace> [--json]'

  local cid input resolved w ws_id mode body
  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
  mode="${2:-}"

  body="$(
    get "$(workspace_path "$ws_id")/thresholds" \
      --data-urlencode "customer_id=$cid"
  )"

  if [[ "$mode" == "--json" ]]; then
    jq --arg workspace "$w" --arg workspace_id "$ws_id" --arg workspace_input "$input" '
      . + {
        context: {
          workspace: $workspace,
          workspace_id: $workspace_id,
          workspace_input: $workspace_input
        },
        provenance: {
          endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/thresholds",
          data_class: "configuration_snapshot"
        }
      }
    ' <<<"$body"
    return
  fi

  jq --arg w "$w" --arg wsid "$ws_id" --arg input "$input" '{
    workspace: $w,
    workspace_id: $wsid,
    workspace_input: $input,
    total_thresholds: (.data | length),
    enabled_thresholds: ([.data[] | select(.enabled == true)] | length),
    disabled_thresholds: ([.data[] | select(.enabled == false)] | length)
  }' <<<"$body"
}

cmd_posture() {
  [[ $# -eq 1 ]] || die 'usage: ngwaf posture <workspace>'

  local cid input resolved w ws ws_id rules account_rules account_applying thresholds
  local workspace_lists account_lists
  local rules_summary account_summary workspace_lists_summary account_lists_summary
  local threshold_summary

  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"

  ws="$(
    get "$(workspace_path "$ws_id")" \
      --data-urlencode "customer_id=$cid"
  )"

  [[ "$(jq -r '.id // empty' <<<"$ws")" == "$ws_id" ]] ||
    die "workspace response ID did not match resolved workspace $ws_id"

  rules="$(
    get_all_pages "$(workspace_path "$ws_id")/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  # Account-level rules are a separate control layer. Filter their scope to
  # rules that are global (*) or explicitly include this workspace ID.
  account_rules="$(
    get_all_pages "/ngwaf/v1/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  account_applying="$(
    jq --arg wsid "$ws_id" '
      .data = [
        .data[]
        | select(
            ((.scope.applies_to // []) | index("*")) != null
            or ((.scope.applies_to // []) | index($wsid)) != null
          )
      ]
      | .meta.total = (.data | length)
    ' <<<"$account_rules"
  )"

  thresholds="$(
    get "$(workspace_path "$ws_id")/thresholds" \
      --data-urlencode "customer_id=$cid"
  )"

  # Lists are inventory context: rules may reference account- or workspace-level
  # lists. Presence of a list does not prove that any specific rule uses it.
  workspace_lists="$(
    get_all_pages "$(workspace_path "$ws_id")/lists" \
      --data-urlencode "customer_id=$cid"
  )"

  account_lists="$(
    get_all_pages "/ngwaf/v1/lists" \
      --data-urlencode "customer_id=$cid"
  )"

  rules_summary="$(summarize_rules_json <<<"$rules")"
  account_summary="$(summarize_rules_json <<<"$account_applying")"
  workspace_lists_summary="$(summarize_lists_json <<<"$workspace_lists")"
  account_lists_summary="$(summarize_lists_json <<<"$account_lists")"

  threshold_summary="$(
    jq '
      def counts($items):
        ($items | sort | group_by(.) | map({key: .[0], value: length}) | from_entries);
      {
        total: (.data | length),
        enabled: ([.data[] | select(.enabled == true)] | length),
        disabled: ([.data[] | select(.enabled == false)] | length),
        enabled_by_action: counts([.data[] | select(.enabled == true) | (.action // "unknown")]),
        enabled_block_immediately: ([.data[] | select(.enabled == true and .action == "block_immediately")] | length)
      }
    ' <<<"$thresholds"
  )"

  jq -n \
    --arg workspace "$w" \
    --arg workspace_id "$ws_id" \
    --arg workspace_input "$input" \
    --arg customer_id "$cid" \
    --argjson ws "$ws" \
    --argjson rules "$rules_summary" \
    --argjson account_rules "$account_summary" \
    --argjson account_global "$(jq '[.data[] | select(((.scope.applies_to // []) | index("*")) != null)] | length' <<<"$account_applying")" \
    --argjson account_specific "$(jq --arg wsid "$ws_id" '[.data[] | select(((.scope.applies_to // []) | index("*")) == null and ((.scope.applies_to // []) | index($wsid)) != null)] | length' <<<"$account_applying")" \
    --argjson thresholds "$threshold_summary" \
    --argjson workspace_lists "$workspace_lists_summary" \
    --argjson account_lists "$account_lists_summary" \
    '{
      workspace: $workspace,
      workspace_id: $workspace_id,
      workspace_input: $workspace_input,
      customer_id: $customer_id,
      enforcement: {
        mode: ($ws.mode // "unknown"),
        immediate_blocking: ($ws.attack_signal_thresholds.immediate // null),
        default_blocking_response_code: ($ws.default_blocking_response_code // null)
      },
      attack_thresholds: ($ws.attack_signal_thresholds // {}),
      rules: $rules,
      account_rules_applying: (
        $account_rules
        + {
            global: $account_global,
            workspace_specific: $account_specific,
            note: "Filtered to account rules whose scope.applies_to is * or this workspace ID."
          }
      ),
      signal_thresholds: $thresholds,
      lists: {
        workspace: $workspace_lists,
        account: $account_lists,
        note: "List inventory only. Presence of a list does not establish that a rule references it."
      },
      provenance: {
        data_class: "configuration_snapshot",
        workspace_resolution: "exact ID first; otherwise case-insensitive exact name",
        pagination: "complete_or_fail"
      }
    }'
}

cmd_lists() {
  [[ $# -ge 1 && $# -le 2 ]] || die 'usage: ngwaf lists <workspace> [--json]'

  local cid input resolved w mode ws_id workspace_lists account_lists
  local workspace_summary account_summary
  cid="$(current_cid)"
  input="$1"
  resolved="$(resolve_workspace_json "$input")"
  w="$(jq -r '.name' <<<"$resolved")"
  ws_id="$(jq -r '.id' <<<"$resolved")"
  mode="${2:-}"

  [[ -z "$mode" || "$mode" == "--json" ]] ||
    die 'usage: ngwaf lists <workspace> [--json]'

  workspace_lists="$(
    get_all_pages "$(workspace_path "$ws_id")/lists" \
      --data-urlencode "customer_id=$cid"
  )"
  account_lists="$(
    get_all_pages "/ngwaf/v1/lists" \
      --data-urlencode "customer_id=$cid"
  )"

  if [[ "$mode" == "--json" ]]; then
    jq -n \
      --arg workspace "$w" \
      --arg workspace_id "$ws_id" \
      --arg workspace_input "$input" \
      --argjson workspace_lists "$workspace_lists" \
      --argjson account_lists "$account_lists" \
      '{
        workspace: $workspace,
        workspace_id: $workspace_id,
        workspace_input: $workspace_input,
        workspace_lists: $workspace_lists,
        account_lists: $account_lists,
        provenance: {
          data_class: "configuration_snapshot",
          workspace_endpoint: "GET /ngwaf/v1/workspaces/{workspace_id}/lists",
          account_endpoint: "GET /ngwaf/v1/lists",
          pagination: "complete_or_fail"
        }
      }'
    return
  fi

  workspace_summary="$(summarize_lists_json <<<"$workspace_lists")"
  account_summary="$(summarize_lists_json <<<"$account_lists")"

  jq -n \
    --arg workspace "$w" \
    --arg workspace_id "$ws_id" \
    --arg workspace_input "$input" \
    --argjson workspace_lists "$workspace_summary" \
    --argjson account_lists "$account_summary" \
    '{
      workspace: $workspace,
      workspace_id: $workspace_id,
      workspace_input: $workspace_input,
      workspace_lists: $workspace_lists,
      account_lists: $account_lists,
      note: "List inventory only; this does not prove which lists are referenced by effective rules."
    }'
}
