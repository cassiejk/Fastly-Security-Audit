#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
# shellcheck source=lib/ngwaf.sh
source "$ROOT/lib/ngwaf.sh"

current_cid() { printf 'customer-test\n'; }
resolve_workspace_json() {
  [[ "$1" == workspace-test ]]
  printf '%s\n' '{"id":"workspace-test","name":"Synthetic workspace"}'
}
workspace_path() { printf '/ngwaf/v1/workspaces/%s\n' "$1"; }
get() {
  [[ $# -eq 3 && "$1" == /ngwaf/v1/workspaces/workspace-test &&
     "$2" == --data-urlencode && "$3" == customer_id=customer-test ]]
  printf 'detail GET\n' >>"$TEST_TMP/requests"
  printf '%s\n' "$detail"
}

check_projection() {
  : >"$TEST_TMP/requests"
  cmd_workspace workspace-test >"$TEST_TMP/output"
  [[ "$(wc -l <"$TEST_TMP/requests" | tr -d ' ')" == 1 ]]
  jq -e '.workspace == "Synthetic workspace" and
    .workspace_id == "workspace-test" and .workspace_input == "workspace-test" and
    .mode == "block" and .immediate_blocking == 42 and
    .default_blocking_response_code == 403 and
    .provenance == {endpoint:"GET /ngwaf/v1/workspaces/{workspace_id}",
      data_class:"configuration_snapshot",customer_scoped:true}' \
    "$TEST_TMP/output" >/dev/null
}

detail='{"workspace_uid":"UID-123","mode":"block","attack_signal_thresholds":{"immediate":42},"default_blocking_response_code":403}'
check_projection
jq -e '.workspace_uid == "UID-123"' "$TEST_TMP/output" >/dev/null

detail='{"workspace_uid":"","mode":"block","attack_signal_thresholds":{"immediate":42},"default_blocking_response_code":403}'
check_projection
jq -e '.workspace_uid == ""' "$TEST_TMP/output" >/dev/null

detail='{"mode":"block","attack_signal_thresholds":{"immediate":42},"default_blocking_response_code":403}'
check_projection
jq -e 'has("workspace_uid") and .workspace_uid == null' "$TEST_TMP/output" >/dev/null

printf 'ngwaf-workspace: OK (synthetic detail response)\n'
