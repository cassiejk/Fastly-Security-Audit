#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_TMP="$(mktemp -d)"
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$TEST_TMP/bin"

cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
outfile=""
url=""
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

case "$url" in
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"production","name":"Production"}]}' >"$outfile"
    ;;
  */ngwaf/v1/workspaces/production)
    printf '%s\n' '{"id":"production","name":"Production","mode":"blocking","default_blocking_response_code":406}' >"$outfile"
    ;;
  */ngwaf/v1/workspaces/production/rules)
    if [[ "${NGWAF_TEST_SNAPSHOT_MODE:-before}" == "after" ]]; then
      printf '%s\n' '{"meta":{"total":2},"data":[{"id":"r1","enabled":false,"description":"Rule one","actions":[{"type":"allow"}]},{"id":"r2","enabled":true,"description":"Rule two","actions":[{"type":"block"}]}]}' >"$outfile"
    else
      printf '%s\n' '{"meta":{"total":1},"data":[{"id":"r1","enabled":true,"description":"Rule one","actions":[{"type":"allow"}]}]}' >"$outfile"
    fi
    ;;
  */ngwaf/v1/rules)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"ar1","enabled":true,"scope":{"applies_to":["*"]},"actions":[{"type":"add_signal"}]}]}' >"$outfile"
    ;;
  */ngwaf/v1/workspaces/production/thresholds)
    printf '%s\n' '{"data":[{"id":"t1","enabled":true,"action":"block_immediately"}]}' >"$outfile"
    ;;
  */ngwaf/v1/workspaces/production/lists)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"wl1","name":"Workspace list","entries":["192.0.2.1","192.0.2.2"]}]}' >"$outfile"
    ;;
  */ngwaf/v1/lists)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"al1","name":"Account list","entries":["example"]}]}' >"$outfile"
    ;;
  *)
    printf '%s\n' '{"error":"unhandled fake endpoint"}' >"$outfile"
    printf '404'
    exit 0
    ;;
esac
printf '200'
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"

export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN="test-token"
export FASTLY_CUSTOMER_ID="test-customer"
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0

before="$TEST_TMP/before.json"
after="$TEST_TMP/after.json"

$ROOT/ngwaf snapshot Production --output "$before" --json >"$TEST_TMP/before-result.json" 2>"$TEST_TMP/before-err"
jq -e '
  .snapshot_schema_version == "1.0"
  and .customer.id == "test-customer"
  and .workspace.id == "production"
  and .safety.list_entries_included == false
  and .configuration.lists.workspace[0].snapshot_entries_redacted == true
  and .configuration.lists.workspace[0].snapshot_entry_count == 2
  and (.configuration.lists.workspace[0] | has("entries") | not)
' >/dev/null "$before"
[[ "$(stat -c '%a' "$before" 2>/dev/null || stat -f '%Lp' "$before")" == "600" ]]

if $ROOT/ngwaf snapshot Production --output "$before" --json >"$TEST_TMP/out" 2>"$TEST_TMP/overwrite-err"; then
  printf 'snapshot test: existing file was overwritten\n' >&2
  exit 1
fi
grep -F 'refusing to overwrite existing snapshot' "$TEST_TMP/overwrite-err" >/dev/null

export NGWAF_TEST_SNAPSHOT_MODE=after
$ROOT/ngwaf snapshot production --output "$after" --json >"$TEST_TMP/after-result.json" 2>"$TEST_TMP/after-err"

report="$($ROOT/ngwaf diff "$before" "$after" --json)"
jq -e '
  .changed == true
  and .provenance.API_requests_made == false
  and .changes.workspace_rules.counts.added == 1
  and .changes.workspace_rules.counts.removed == 0
  and .changes.workspace_rules.counts.modified == 1
  and .changes.workspace_rules.modified[0].changed_fields == ["enabled"]
' >/dev/null <<<"$report"

$ROOT/ngwaf diff "$before" "$after" >"$TEST_TMP/human-diff"
grep -F 'NGWAF snapshot diff' "$TEST_TMP/human-diff" >/dev/null
grep -F 'Workspace rules' "$TEST_TMP/human-diff" >/dev/null

sensitive="$TEST_TMP/sensitive.json"
$ROOT/ngwaf snapshot production \
  --output "$sensitive" \
  --include-list-entries \
  --json >"$TEST_TMP/sensitive-result.json" 2>"$TEST_TMP/sensitive-err"
jq -e '
  .safety.list_entries_included == true
  and .configuration.lists.workspace[0].entries == ["192.0.2.1", "192.0.2.2"]
' >/dev/null "$sensitive"

if $ROOT/ngwaf diff "$before" "$after" --check --json >"$TEST_TMP/check-report.json"; then
  printf 'snapshot test: diff --check did not report configuration drift\n' >&2
  exit 1
fi
jq -e '.changed == true' >/dev/null "$TEST_TMP/check-report.json"

jq '.workspace.id = "other"' "$after" >"$TEST_TMP/other.json"
if $ROOT/ngwaf diff "$before" "$TEST_TMP/other.json" --json >"$TEST_TMP/out" 2>"$TEST_TMP/scope-err"; then
  printf 'snapshot test: cross-workspace comparison unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'refusing cross-workspace snapshot comparison' "$TEST_TMP/scope-err" >/dev/null

printf 'snapshots: OK\n'
