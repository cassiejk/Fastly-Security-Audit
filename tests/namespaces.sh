#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init

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
  */ngwaf/v1/workspaces/production/rules/test-rule)
    printf '%s\n' '{"id":"test-rule","type":"request","enabled":true,"actions":[{"type":"block"}]}' >"$outfile"
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

"$ROOT/fastly-audit" help >"$TEST_TMP/help"
grep -F 'fastly-audit ngwaf rule <workspace> <rule_id>' "$TEST_TMP/help" >/dev/null
grep -F 'original flat commands remain supported' "$TEST_TMP/help" >/dev/null

"$ROOT/ngwaf" help >"$TEST_TMP/legacy-help"
grep -F 'ngwaf rule <workspace> <rule_id>' "$TEST_TMP/legacy-help" >/dev/null

"$ROOT/fastly-audit" help legacy >"$TEST_TMP/fastly-legacy-help"
grep -F 'ngwaf rule <workspace> <rule_id>' "$TEST_TMP/fastly-legacy-help" >/dev/null

"$ROOT/fastly-audit" ngwaf help >"$TEST_TMP/ngwaf-help"
grep -F 'rule <workspace> <rule_id>' "$TEST_TMP/ngwaf-help" >/dev/null

"$ROOT/fastly-audit" service help >"$TEST_TMP/service-help"
grep -F 'list [--json]' "$TEST_TMP/service-help" >/dev/null

"$ROOT/fastly-audit" bot help >"$TEST_TMP/bot-help"
grep -F 'stats <service_id>' "$TEST_TMP/bot-help" >/dev/null

"$ROOT/fastly-audit" snapshot help >"$TEST_TMP/snapshot-help"
grep -F 'ngwaf <workspace>' "$TEST_TMP/snapshot-help" >/dev/null

customer="$("$ROOT/fastly-audit" customer show 2>"$TEST_TMP/customer-err")"
jq -e '
  .id == "test-customer"
  and .name == "Test Customer"
  and .source == "environment"
' >/dev/null <<<"$customer"

rule="$("$ROOT/fastly-audit" ngwaf rule Production test-rule 2>"$TEST_TMP/rule-err")"
jq -e '
  .id == "test-rule"
  and .context.workspace == "Production"
  and .context.workspace_id == "production"
  and .context.rule_id == "test-rule"
' >/dev/null <<<"$rule"
grep -F 'fastly-audit: customer scope:' "$TEST_TMP/rule-err" >/dev/null
grep -F 'fastly-audit: workspace scope:' "$TEST_TMP/rule-err" >/dev/null

legacy="$("$ROOT/ngwaf" rule Production test-rule 2>"$TEST_TMP/legacy-err")"
jq -e '.id == "test-rule"' >/dev/null <<<"$legacy"
grep -F 'ngwaf: customer scope:' "$TEST_TMP/legacy-err" >/dev/null

if "$ROOT/fastly-audit" ngwaf nope >"$TEST_TMP/out" 2>"$TEST_TMP/error"; then
  printf 'namespace test: unknown command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'unknown NGWAF command: nope' "$TEST_TMP/error" >/dev/null

printf 'namespaces: OK\n'
