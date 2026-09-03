# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

snapshot_safe_component() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

snapshot_prepare_lists() {
  local body="$1"
  local include_entries="$2"

  if [[ "$include_entries" == "true" ]]; then
    jq '.data |= (sort_by(.id // .reference_id // .name // ""))' <<<"$body"
  else
    jq '
      .data |= (
        map(
          . as $list
          | del(.entries)
          | . + {
              snapshot_entry_count: (
                if (($list | has("entries")) and (($list.entries | type) == "array"))
                then ($list.entries | length)
                else null
                end
              ),
              snapshot_entries_present_in_response: ($list | has("entries")),
              snapshot_entries_redacted: ($list | has("entries"))
            }
        )
        | sort_by(.id // .reference_id // .name // "")
      )
    ' <<<"$body"
  fi
}

snapshot_sha256() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    printf 'unavailable\n'
  fi
}

cmd_snapshot() {
  [[ $# -ge 1 ]] ||
    die 'usage: ngwaf snapshot <workspace> [--output FILE] [--include-list-entries] [--json]'

  local input="$1"
  shift
  local output="" include_entries=false format=""
  local cid customer resolved workspace workspace_id captured_at timestamp
  local ws rules account_rules account_applying thresholds workspace_lists account_lists
  local prepared_workspace_lists prepared_account_lists parent temp_file checksum

  while (( $# > 0 )); do
    case "$1" in
      --output)
        (( $# >= 2 )) || die '--output requires a file path'
        output="$2"
        shift 2
        ;;
      --include-list-entries)
        include_entries=true
        shift
        ;;
      --json)
        format="--json"
        shift
        ;;
      *)
        die "unknown snapshot option: $1"
        ;;
    esac
  done

  cid="$(current_cid)"
  customer="$(current_customer_name)"
  resolved="$(resolve_workspace_json "$input")"
  workspace="$(jq -r '.name' <<<"$resolved")"
  workspace_id="$(jq -r '.id' <<<"$resolved")"
  captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"

  if [[ -z "$output" ]]; then
    output="ngwaf-snapshot-$(snapshot_safe_component "$cid")-$(snapshot_safe_component "$workspace_id")-$timestamp.json"
  fi

  parent="$(dirname "$output")"
  [[ -d "$parent" ]] || die "snapshot output directory does not exist: $parent"
  [[ ! -e "$output" ]] || die "refusing to overwrite existing snapshot: $output"

  ui_phase 1 5 'Reading workspace configuration'
  ws="$(get "$(workspace_path "$workspace_id")" --data-urlencode "customer_id=$cid")"
  [[ "$(jq -r '.id // empty' <<<"$ws")" == "$workspace_id" ]] ||
    die "workspace response ID did not match resolved workspace $workspace_id"

  ui_phase 2 5 'Reading complete workspace and account rule sets'
  rules="$(
    get_all_pages "$(workspace_path "$workspace_id")/rules" \
      --data-urlencode "customer_id=$cid"
  )"
  account_rules="$(
    get_all_pages "/ngwaf/v1/rules" \
      --data-urlencode "customer_id=$cid"
  )"
  account_applying="$(
    jq --arg workspace_id "$workspace_id" '
      .data = [
        .data[]
        | select(
            ((.scope.applies_to // []) | index("*")) != null
            or ((.scope.applies_to // []) | index($workspace_id)) != null
          )
      ]
      | .data |= sort_by(.id // .reference_id // .description // "")
      | .meta.total = (.data | length)
    ' <<<"$account_rules"
  )"

  ui_phase 3 5 'Reading thresholds'
  thresholds="$(
    get "$(workspace_path "$workspace_id")/thresholds" \
      --data-urlencode "customer_id=$cid"
  )"
  jq -e '.data | type == "array"' >/dev/null <<<"$thresholds" ||
    die 'threshold endpoint did not return a data array'

  ui_phase 4 5 'Reading and redacting list inventory'
  workspace_lists="$(
    get_all_pages "$(workspace_path "$workspace_id")/lists" \
      --data-urlencode "customer_id=$cid"
  )"
  account_lists="$(
    get_all_pages "/ngwaf/v1/lists" \
      --data-urlencode "customer_id=$cid"
  )"
  prepared_workspace_lists="$(snapshot_prepare_lists "$workspace_lists" "$include_entries")"
  prepared_account_lists="$(snapshot_prepare_lists "$account_lists" "$include_entries")"

  ui_phase 5 5 'Writing protected snapshot'
  umask 077
  temp_file="$(mktemp "$parent/.ngwaf-snapshot.XXXXXX")"
  if ! jq -n \
    --arg schema_version "1.0" \
    --arg tool_version "$VERSION" \
    --arg captured_at "$captured_at" \
    --arg customer "$customer" \
    --arg customer_id "$cid" \
    --arg workspace "$workspace" \
    --arg workspace_id "$workspace_id" \
    --arg workspace_input "$input" \
    --argjson include_list_entries "$include_entries" \
    --argjson ws "$ws" \
    --argjson rules "$(jq '.data | sort_by(.id // .reference_id // .description // "")' <<<"$rules")" \
    --argjson account_rules "$(jq '.data' <<<"$account_applying")" \
    --argjson thresholds "$(jq '.data | sort_by(.id // .reference_id // .name // "")' <<<"$thresholds")" \
    --argjson workspace_lists "$(jq '.data' <<<"$prepared_workspace_lists")" \
    --argjson account_lists "$(jq '.data' <<<"$prepared_account_lists")" \
    '{
      snapshot_schema_version: $schema_version,
      tool_version: $tool_version,
      captured_at: $captured_at,
      customer: {
        id: $customer_id,
        name: $customer
      },
      workspace: {
        id: $workspace_id,
        name: $workspace,
        input: $workspace_input
      },
      safety: {
        API_access: "read_only_GET_requests",
        file_mode: "0600",
        list_entries_included: $include_list_entries,
        list_entries_redacted_by_default: true
      },
      provenance: {
        data_class: "point_in_time_configuration_snapshot",
        endpoints: [
          "GET /ngwaf/v1/workspaces/{workspace_id}",
          "GET /ngwaf/v1/workspaces/{workspace_id}/rules",
          "GET /ngwaf/v1/rules",
          "GET /ngwaf/v1/workspaces/{workspace_id}/thresholds",
          "GET /ngwaf/v1/workspaces/{workspace_id}/lists",
          "GET /ngwaf/v1/lists"
        ],
        pagination: "complete_or_fail",
        account_rules_scope: "global or explicitly applicable to the resolved workspace"
      },
      configuration: {
        workspace: $ws,
        rules: {
          workspace: $rules,
          account_applying: $account_rules
        },
        thresholds: $thresholds,
        lists: {
          workspace: $workspace_lists,
          account: $account_lists
        }
      }
    }' >"$temp_file"; then
    rm -f "$temp_file"
    die 'failed to serialize snapshot'
  fi
  chmod 600 "$temp_file"
  if ! ln "$temp_file" "$output"; then
    rm -f "$temp_file"
    die "refusing to overwrite existing snapshot: $output"
  fi
  rm -f "$temp_file"
  checksum="$(snapshot_sha256 "$output")"

  if [[ "$format" == "--json" ]]; then
    jq -n \
      --arg command "snapshot" \
      --arg output "$output" \
      --arg sha256 "$checksum" \
      --arg captured_at "$captured_at" \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg workspace "$workspace" \
      --arg workspace_id "$workspace_id" \
      --argjson list_entries_included "$include_entries" \
      '{
        command: $command,
        output: $output,
        sha256: $sha256,
        captured_at: $captured_at,
        customer: $customer,
        customer_id: $customer_id,
        workspace: $workspace,
        workspace_id: $workspace_id,
        file_mode: "0600",
        list_entries_included: $list_entries_included
      }'
  else
    ui_heading 'Snapshot complete'
    ui_status pass 'Customer' "$customer ($cid)"
    ui_status pass 'Workspace' "$workspace ($workspace_id)"
    ui_status pass 'Output' "$output"
    ui_status pass 'Permissions' '0600'
    ui_status info 'SHA-256' "$checksum"
    if [[ "$include_entries" == "true" ]]; then
      ui_status warn 'List entries' 'included by explicit request; handle the file as customer-sensitive'
    else
      ui_status pass 'List entries' 'redacted; entry counts retained'
    fi
  fi
}

snapshot_validate_file() {
  local file="$1"
  [[ -r "$file" ]] || die "snapshot is not readable: $file"
  jq -e '
    def identity:
      (.id // .reference_id // .name // .description // null);
    def unique_identities($items):
      ([$items[] | identity]) as $ids
      | all($ids[]; type == "string" and length > 0)
        and (($ids | length) == ($ids | unique | length));

    .snapshot_schema_version == "1.0"
    and (.customer.id | type == "string" and length > 0)
    and (.workspace.id | type == "string" and length > 0)
    and (.configuration | type == "object")
    and (.configuration.rules.workspace | type == "array")
    and (.configuration.rules.account_applying | type == "array")
    and (.configuration.thresholds | type == "array")
    and (.configuration.lists.workspace | type == "array")
    and (.configuration.lists.account | type == "array")
    and unique_identities(.configuration.rules.workspace)
    and unique_identities(.configuration.rules.account_applying)
    and unique_identities(.configuration.thresholds)
    and unique_identities(.configuration.lists.workspace)
    and unique_identities(.configuration.lists.account)
  ' >/dev/null "$file" || die "invalid or unsupported ngwaf snapshot: $file"
}

snapshot_diff_json() {
  local before="$1"
  local after="$2"

  jq -n --slurpfile before "$before" --slurpfile after "$after" '
    def identity:
      (.id // .reference_id // .name // .description // error("snapshot object has no stable identity"))
      | tostring;

    def index:
      reduce (. // [])[] as $item ({}; .[$item | identity] = $item);

    def changed_fields($before; $after):
      (($before | keys_unsorted) + ($after | keys_unsorted) | unique)
      | map(select($before[.] != $after[.]));

    def delta($before_items; $after_items):
      ($before_items | index) as $before_index
      | ($after_items | index) as $after_index
      | ($before_index | keys) as $before_keys
      | ($after_index | keys) as $after_keys
      | {
          added: [
            ($after_keys - $before_keys)[]
            | {id: ., value: $after_index[.]}
          ],
          removed: [
            ($before_keys - $after_keys)[]
            | {id: ., value: $before_index[.]}
          ],
          modified: [
            ($before_keys - ($before_keys - $after_keys))[]
            | select($before_index[.] != $after_index[.])
            | {
                id: .,
                changed_fields: changed_fields($before_index[.]; $after_index[.]),
                before: $before_index[.],
                after: $after_index[.]
              }
          ]
        }
      | . + {
          counts: {
            added: (.added | length),
            removed: (.removed | length),
            modified: (.modified | length)
          }
        };

    ($before[0]) as $b
    | ($after[0]) as $a
    | {
        command: "diff",
        snapshot_schema_version: $b.snapshot_schema_version,
        customer: $b.customer,
        workspace: $b.workspace,
        before: {
          captured_at: $b.captured_at,
          tool_version: $b.tool_version
        },
        after: {
          captured_at: $a.captured_at,
          tool_version: $a.tool_version
        },
        list_entries: {
          before_included: ($b.safety.list_entries_included // false),
          after_included: ($a.safety.list_entries_included // false)
        },
        changes: {
          workspace: (
            if $b.configuration.workspace == $a.configuration.workspace then
              {changed: false, changed_fields: [], before: $b.configuration.workspace, after: $a.configuration.workspace}
            else
              {
                changed: true,
                changed_fields: changed_fields($b.configuration.workspace; $a.configuration.workspace),
                before: $b.configuration.workspace,
                after: $a.configuration.workspace
              }
            end
          ),
          workspace_rules: delta($b.configuration.rules.workspace; $a.configuration.rules.workspace),
          account_rules_applying: delta($b.configuration.rules.account_applying; $a.configuration.rules.account_applying),
          thresholds: delta($b.configuration.thresholds; $a.configuration.thresholds),
          workspace_lists: delta($b.configuration.lists.workspace; $a.configuration.lists.workspace),
          account_lists: delta($b.configuration.lists.account; $a.configuration.lists.account)
        },
        provenance: {
          data_class: "local_snapshot_comparison",
          API_requests_made: false,
          scope_validation: "customer and workspace IDs must match"
        }
      }
    | .changed = (
        .changes.workspace.changed
        or any([
          .changes.workspace_rules,
          .changes.account_rules_applying,
          .changes.thresholds,
          .changes.workspace_lists,
          .changes.account_lists
        ][]; (.counts.added + .counts.removed + .counts.modified) > 0)
      )
  '
}

snapshot_render_delta_line() {
  local label="$1"
  local delta="$2"
  local added removed modified
  added="$(jq '.counts.added' <<<"$delta")"
  removed="$(jq '.counts.removed' <<<"$delta")"
  modified="$(jq '.counts.modified' <<<"$delta")"

  if (( added + removed + modified == 0 )); then
    ui_status pass "$label" 'unchanged'
  else
    ui_status warn "$label" "+$added  -$removed  ~$modified"
  fi
}

snapshot_render_diff_human() {
  local report="$1"
  local modified_rules

  ui_heading 'NGWAF snapshot diff'
  printf '%s (%s) · %s (%s)\n' \
    "$(jq -r '.customer.name' <<<"$report")" \
    "$(jq -r '.customer.id' <<<"$report")" \
    "$(jq -r '.workspace.name' <<<"$report")" \
    "$(jq -r '.workspace.id' <<<"$report")"
  printf '%s → %s\n\n' \
    "$(jq -r '.before.captured_at' <<<"$report")" \
    "$(jq -r '.after.captured_at' <<<"$report")"

  if [[ "$(jq -r '.changes.workspace.changed' <<<"$report")" == "true" ]]; then
    ui_status warn 'Workspace settings' \
      "changed: $(jq -r '.changes.workspace.changed_fields | join(", ")' <<<"$report")"
  else
    ui_status pass 'Workspace settings' 'unchanged'
  fi
  snapshot_render_delta_line 'Workspace rules' "$(jq '.changes.workspace_rules' <<<"$report")"
  snapshot_render_delta_line 'Applicable account rules' "$(jq '.changes.account_rules_applying' <<<"$report")"
  snapshot_render_delta_line 'Thresholds' "$(jq '.changes.thresholds' <<<"$report")"
  snapshot_render_delta_line 'Workspace lists' "$(jq '.changes.workspace_lists' <<<"$report")"
  snapshot_render_delta_line 'Account lists' "$(jq '.changes.account_lists' <<<"$report")"

  modified_rules="$(jq '.changes.workspace_rules.modified' <<<"$report")"
  if [[ "$(jq 'length' <<<"$modified_rules")" != "0" ]]; then
    printf '\nModified workspace rules\n'
    jq -r '
      ["RULE ID", "CHANGED FIELDS", "DESCRIPTION"],
      (
        .[]
        | [
            .id,
            (.changed_fields | join(",")),
            (.after.description // .before.description // "")
          ]
      )
      | @tsv
    ' <<<"$modified_rules" | human_table
  fi

  if [[ "$(jq -r '.list_entries.before_included or .list_entries.after_included' <<<"$report")" != "true" ]]; then
    printf '\nNote: list entries were not included in either snapshot; list metadata and reported entry-count changes remain comparable.\n'
  fi
}

cmd_diff() {
  [[ $# -ge 2 ]] || die 'usage: ngwaf diff <before.json> <after.json> [--json] [--check]'

  local before="$1"
  local after="$2"
  shift 2
  local format="" check=false report changed

  while (( $# > 0 )); do
    case "$1" in
      --json)
        format="--json"
        ;;
      --check)
        check=true
        ;;
      *)
        die "unknown diff option: $1"
        ;;
    esac
    shift
  done

  snapshot_validate_file "$before"
  snapshot_validate_file "$after"

  [[ "$(jq -r '.customer.id' "$before")" == "$(jq -r '.customer.id' "$after")" ]] ||
    die 'refusing cross-customer snapshot comparison'
  [[ "$(jq -r '.workspace.id' "$before")" == "$(jq -r '.workspace.id' "$after")" ]] ||
    die 'refusing cross-workspace snapshot comparison'

  report="$(snapshot_diff_json "$before" "$after")"
  changed="$(jq -r '.changed' <<<"$report")"

  if [[ "$format" == "--json" ]]; then
    jq . <<<"$report"
  else
    snapshot_render_diff_human "$report"
  fi

  if [[ "$check" == "true" && "$changed" == "true" ]]; then
    return 1
  fi
}
