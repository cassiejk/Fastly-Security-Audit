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
args_file="${NGWAF_TEST_CURL_ARGS:?}"
{
  printf '%s\n' '--- request ---'
  printf '%s\n' "$@"
} >>"$args_file"

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
    printf '200'
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":2},"data":[{"id":"production","name":"Production"},{"id":"staging","name":"Staging"}]}' >"$outfile"
    printf '200'
    ;;
  */ngwaf/v1/workspaces/production/rules/test-rule)
    case "${NGWAF_TEST_RULE_MODE:-success}" in
      success)
        printf '%s\n' '{"id":"test-rule","type":"request","enabled":true,"description":"Test rule","actions":[{"type":"block"}]}' >"$outfile"
        printf '200'
        ;;
      mismatch)
        printf '%s\n' '{"id":"different-rule","type":"request","enabled":true,"actions":[]}' >"$outfile"
        printf '200'
        ;;
      missing_id)
        printf '%s\n' '{"type":"request","enabled":true,"actions":[]}' >"$outfile"
        printf '200'
        ;;
      not_found)
        printf '%s\n' '{"message":"rule not found"}' >"$outfile"
        printf '404'
        ;;
    esac
    ;;
  *)
    printf '%s\n' '{"error":"unhandled fake endpoint"}' >"$outfile"
    printf '404'
    ;;
esac
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"

export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN="test-token"
export FASTLY_CUSTOMER_ID="test-customer"
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0
export NGWAF_TEST_CURL_ARGS="$TEST_TMP/curl-args"
: >"$NGWAF_TEST_CURL_ARGS"

output="$($ROOT/ngwaf rule Production test-rule 2>"$TEST_TMP/stderr")"
jq -e '
  .id == "test-rule"
  and .enabled == true
  and .actions[0].type == "block"
  and .context.workspace == "Production"
  and .context.workspace_id == "production"
  and .context.workspace_input == "Production"
  and .context.rule_id == "test-rule"
  and .provenance.endpoint == "GET /ngwaf/v1/workspaces/{workspace_id}/rules/{rule_id}"
  and .provenance.data_class == "configuration_snapshot"
  and .provenance.customer_scoped == true
  and .provenance.pagination == "not_applicable"
' >/dev/null <<<"$output"
grep -F 'https://api.fastly.com/ngwaf/v1/workspaces/production/rules/test-rule' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'customer_id=test-customer' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'workspace scope: Production (production; resolved_by=name)' "$TEST_TMP/stderr" >/dev/null

export NGWAF_TEST_RULE_MODE=mismatch
if $ROOT/ngwaf rule Production test-rule >"$TEST_TMP/out" 2>"$TEST_TMP/mismatch-err"; then
  printf 'rule test: mismatched response ID unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'rule response ID did not match requested rule' "$TEST_TMP/mismatch-err" >/dev/null

export NGWAF_TEST_RULE_MODE=missing_id
if $ROOT/ngwaf rule Production test-rule >"$TEST_TMP/out" 2>"$TEST_TMP/missing-id-err"; then
  printf 'rule test: missing response ID unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'rule response did not contain an ID' "$TEST_TMP/missing-id-err" >/dev/null

export NGWAF_TEST_RULE_MODE=not_found
if $ROOT/ngwaf rule Production test-rule >"$TEST_TMP/out" 2>"$TEST_TMP/not-found-err"; then
  printf 'rule test: missing rule unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'Fastly API returned HTTP 404' "$TEST_TMP/not-found-err" >/dev/null
grep -F 'rule not found' "$TEST_TMP/not-found-err" >/dev/null

if $ROOT/ngwaf rule Production >"$TEST_TMP/out" 2>"$TEST_TMP/usage-err"; then
  printf 'rule test: missing rule ID unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'usage: ngwaf rule <workspace> <rule_id>' "$TEST_TMP/usage-err" >/dev/null

printf 'rules: OK\n'
