#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/config"

cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

outfile=''
url=''
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

case "$url" in
  */customer/tHYft17nv2e3hrPd0bfuZ)
    printf '%s\n' '{"id":"tHYft17nv2e3hrPd0bfuZ","name":"Costco"}' >"$outfile"
    printf '200'
    ;;
  */customer/other-customer-id)
    printf '%s\n' '{"id":"other-customer-id","name":"Other Customer"}' >"$outfile"
    printf '200'
    ;;
  */ngwaf/v1/workspaces)
    case "${FASTLY_TEST_LINK_MODE:-success}" in
      success)
        if [[ "${FASTLY_CUSTOMER_ID:-}" == 'other-customer-id' ]]; then
          printf '%s\n' '{"meta":{"total":1},"data":[{"id":"other-workspace","name":"Other Workspace"}]}' >"$outfile"
        else
          printf '%s\n' '{"meta":{"total":1},"data":[{"id":"gdx-costco-prd-uscabc","name":"Costco Production"}]}' >"$outfile"
        fi
        printf '200'
        ;;
      mismatch)
        printf '%s\n' '{"meta":{"total":1},"data":[{"id":"different-workspace","name":"Different Workspace"}]}' >"$outfile"
        printf '200'
        ;;
      failure)
        printf '%s\n' '{"errors":[{"detail":"workspace lookup failed"}]}' >"$outfile"
        printf '503'
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
export XDG_CONFIG_HOME="$TEST_TMP/config"
export FASTLY_API_TOKEN='test-token-secret'
export FASTLY_CUSTOMER_ID='tHYft17nv2e3hrPd0bfuZ'
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0

costco_url='https://manage.fastly.com/security/ngwaf/workspaces/gdx-costco-prd-uscabc/requests/67d4df38c5f74f38b7c5000000000001'
expected_costco_url="${costco_url}?customerId=tHYft17nv2e3hrPd0bfuZ"

output="$("$ROOT/fastly-audit" ngwaf link "$costco_url" 2>"$TEST_TMP/valid-err")"
[[ "$output" == "$expected_costco_url" ]]
grep -F 'customer scope: Costco (tHYft17nv2e3hrPd0bfuZ; source=environment)' "$TEST_TMP/valid-err" >/dev/null
grep -F 'workspace scope: Costco Production (gdx-costco-prd-uscabc; resolved_by=id)' "$TEST_TMP/valid-err" >/dev/null

export FASTLY_CUSTOMER_ID='other-customer-id'
other_url='https://manage.fastly.com/security/ngwaf/workspaces/other-workspace/requests/other-request'
output="$("$ROOT/fastly-audit" ngwaf link "$other_url" 2>"$TEST_TMP/other-err")"
[[ "$output" == "${other_url}?customerId=other-customer-id" ]]

export FASTLY_CUSTOMER_ID='tHYft17nv2e3hrPd0bfuZ'

assert_link_failure() {
  local name="$1" expected="$2"
  shift 2
  if "$ROOT/fastly-audit" ngwaf link "$@" >"$TEST_TMP/$name-out" 2>"$TEST_TMP/$name-err"; then
    printf 'link test: %s unexpectedly succeeded\n' "$name" >&2
    exit 1
  fi
  [[ ! -s "$TEST_TMP/$name-out" ]]
  grep -F "$expected" "$TEST_TMP/$name-err" >/dev/null
}

assert_link_failure missing 'usage: fastly-audit ngwaf link'
assert_link_failure hostname 'must use manage.fastly.com' \
  'https://example.com/security/ngwaf/workspaces/gdx-costco-prd-uscabc/requests/request-id'
assert_link_failure http 'must use HTTPS' \
  'http://manage.fastly.com/security/ngwaf/workspaces/gdx-costco-prd-uscabc/requests/request-id'
assert_link_failure path 'unsupported NGWAF request URL path' \
  'https://manage.fastly.com/security/ngwaf/workspaces/gdx-costco-prd-uscabc/rules/rule-id'
assert_link_failure missing-request 'unsupported NGWAF request URL path' \
  'https://manage.fastly.com/security/ngwaf/workspaces/gdx-costco-prd-uscabc/requests/'
assert_link_failure encoded 'URL-encoded NGWAF request paths are not supported' \
  'https://manage.fastly.com/security/ngwaf/workspaces/gdx-costco-prd-uscabc/requests/%ZZ'
assert_link_failure traversal 'URL-encoded NGWAF request paths are not supported' \
  'https://manage.fastly.com/security/ngwaf/workspaces/gdx-costco-prd-uscabc/requests/%2e%2e'
assert_link_failure fragment 'fragments are not supported' \
  "${costco_url}#details"
assert_link_failure port 'must use manage.fastly.com' \
  'https://manage.fastly.com:443/security/ngwaf/workspaces/gdx-costco-prd-uscabc/requests/request-id'
assert_link_failure credentials 'must use manage.fastly.com' \
  'https://user@manage.fastly.com/security/ngwaf/workspaces/gdx-costco-prd-uscabc/requests/request-id'
assert_link_failure unexpected-query 'unsupported or malformed query parameter' \
  "${costco_url}?foo=bar"
assert_link_failure duplicate-customer 'duplicate or unexpected query parameters' \
  "${costco_url}?customerId=tHYft17nv2e3hrPd0bfuZ&customerId=tHYft17nv2e3hrPd0bfuZ"
assert_link_failure conflicting-customer 'does not match selected customer Costco' \
  "${costco_url}?customerId=other-customer-id"

output="$("$ROOT/fastly-audit" ngwaf link \
  "${costco_url}?customerId=tHYft17nv2e3hrPd0bfuZ" 2>"$TEST_TMP/matching-err")"
[[ "$output" == "$expected_costco_url" ]]

export FASTLY_TEST_LINK_MODE=mismatch
assert_link_failure workspace-mismatch 'workspace ownership could not be verified' "$costco_url"
grep -F 'selected customer: Costco (tHYft17nv2e3hrPd0bfuZ)' "$TEST_TMP/workspace-mismatch-err" >/dev/null
grep -F 'requested workspace: gdx-costco-prd-uscabc' "$TEST_TMP/workspace-mismatch-err" >/dev/null

export FASTLY_TEST_LINK_MODE=failure
assert_link_failure workspace-failure 'Fastly API returned HTTP 503' "$costco_url"
grep -F 'workspace ownership could not be verified' "$TEST_TMP/workspace-failure-err" >/dev/null

unset FASTLY_TEST_LINK_MODE FASTLY_CUSTOMER_ID
assert_link_failure no-customer 'no customer selected' "$costco_url"

if grep -R -F 'test-token-secret' "$TEST_TMP" >/dev/null; then
  printf 'link test: token value leaked into output\n' >&2
  exit 1
fi

printf 'link: OK\n'
