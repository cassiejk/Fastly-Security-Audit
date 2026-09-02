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
    .data
    | sort_by(.name)
    | .[]
    | .name
  ' <<<"$body"

  if (( total > returned )); then
    printf '\nWARNING: API returned %s of %s workspaces.\n' \
      "$returned" "$total" >&2
  fi
}

cmd_workspace() {
  [[ $# -eq 1 ]] || die 'usage: ngwaf workspace <workspace>'

  local cid w
  cid="$(current_cid)"
  w="$1"

  get "$(workspace_path "$w")" \
    --data-urlencode "customer_id=$cid" |
    jq '{
      name,
      mode,
      immediate_blocking: (.attack_signal_thresholds.immediate // null),
      default_blocking_response_code
    }'
}

cmd_rules() {
  [[ $# -ge 1 ]] || die 'usage: ngwaf rules <workspace> [--list|--json]'

  local cid w mode body summary
  cid="$(current_cid)"
  w="$1"
  mode="${2:-}"

  body="$(
    get_all_pages "$(workspace_path "$w")/rules" \
      --data-urlencode "customer_id=$cid"
  )"

  if [[ "$mode" == "--json" ]]; then
    jq . <<<"$body"
    return
  fi

  summary="$(summarize_rules_json <<<"$body")"

  jq --arg w "$w" '. + {workspace: $w}' <<<"$summary" |
    jq '{
      workspace,
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
    jq . <<<"$body"
    return
  fi

  summary="$(summarize_rules_json <<<"$body")"

  jq --arg cid "$cid" '
    . + {
      customer_id: $cid,
      global_rules: 0,
      workspace_scoped_rules: 0
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

  local cid w mode body
  cid="$(current_cid)"
  w="$1"
  mode="${2:-}"

  body="$(
    get "$(workspace_path "$w")/thresholds" \
      --data-urlencode "customer_id=$cid"
  )"

  if [[ "$mode" == "--json" ]]; then
    jq . <<<"$body"
    return
  fi

  jq --arg w "$w" '{
    workspace: $w,
    total_thresholds: (.data | length),
    enabled_thresholds: ([.data[] | select(.enabled == true)] | length),
    disabled_thresholds: ([.data[] | select(.enabled == false)] | length)
  }' <<<"$body"
}

cmd_posture() {
  [[ $# -eq 1 ]] || die 'usage: ngwaf posture <workspace>'

  local cid w ws ws_id rules account_rules account_applying thresholds
  local workspace_lists account_lists
  local rules_summary account_summary workspace_lists_summary account_lists_summary
  local threshold_summary

  cid="$(current_cid)"
  w="$1"

  ws="$(
    get "$(workspace_path "$w")" \
      --data-urlencode "customer_id=$cid"
  )"

  ws_id="$(jq -r '.id // empty' <<<"$ws")"
  [[ -n "$ws_id" ]] || die "workspace $w response did not include an id"

  rules="$(
    get_all_pages "$(workspace_path "$w")/rules" \
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
    get "$(workspace_path "$w")/thresholds" \
      --data-urlencode "customer_id=$cid"
  )"

  # Lists are inventory context: rules may reference account- or workspace-level
  # lists. Presence of a list does not prove that any specific rule uses it.
  workspace_lists="$(
    get_all_pages "$(workspace_path "$w")/lists" \
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
      }
    }'
}

cmd_lists() {
  [[ $# -ge 1 && $# -le 2 ]] || die 'usage: ngwaf lists <workspace> [--json]'

  local cid w mode ws_body ws_id workspace_lists account_lists
  local workspace_summary account_summary
  cid="$(current_cid)"
  w="$1"
  mode="${2:-}"

  [[ -z "$mode" || "$mode" == "--json" ]] ||
    die 'usage: ngwaf lists <workspace> [--json]'

  ws_body="$(get "$(workspace_path "$w")" --data-urlencode "customer_id=$cid")"
  ws_id="$(jq -r '.id // empty' <<<"$ws_body")"
  [[ -n "$ws_id" ]] || die "workspace $w response did not include an id"

  workspace_lists="$(
    get_all_pages "$(workspace_path "$w")/lists" \
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
      --argjson workspace_lists "$workspace_lists" \
      --argjson account_lists "$account_lists" \
      '{workspace: $workspace, workspace_id: $workspace_id, workspace_lists: $workspace_lists, account_lists: $account_lists}'
    return
  fi

  workspace_summary="$(summarize_lists_json <<<"$workspace_lists")"
  account_summary="$(summarize_lists_json <<<"$account_lists")"

  jq -n \
    --arg workspace "$w" \
    --arg workspace_id "$ws_id" \
    --argjson workspace_lists "$workspace_summary" \
    --argjson account_lists "$account_summary" \
    '{
      workspace: $workspace,
      workspace_id: $workspace_id,
      workspace_lists: $workspace_lists,
      account_lists: $account_lists,
      note: "List inventory only; this does not prove which lists are referenced by effective rules."
    }'
}

