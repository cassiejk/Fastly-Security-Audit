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
  */customer/6v6Bi5Y1nCtHThSbVurBys)
    printf '%s\n' '{"id":"6v6Bi5Y1nCtHThSbVurBys","name":"The RealReal"}' >"$outfile"
    printf '200'
    ;;
  */customer/other-customer-id)
    printf '%s\n' '{"id":"other-customer-id","name":"Other Customer"}' >"$outfile"
    printf '200'
    ;;
  */ddos-protection/v1/events/*)
    event_id="${url##*/events/}"
    case "${FASTLY_TEST_DDOS_LINK_MODE:-success}" in
      success)
        printf '{"id":"%s","customer_id":"%s","service_id":"service-1"}\n' \
          "$event_id" "${FASTLY_CUSTOMER_ID:?}" >"$outfile"
        printf '200'
        ;;
      mismatch)
        printf '{"id":"%s","customer_id":"different-customer","service_id":"service-1"}\n' \
          "$event_id" >"$outfile"
        printf '200'
        ;;
      unknown)
        printf '%s\n' '{"detail":"event not found"}' >"$outfile"
        printf '404'
        ;;
      failure)
        printf '%s\n' '{"detail":"upstream unavailable"}' >"$outfile"
        printf '503'
        ;;
      missing-ownership)
        printf '{"id":"%s","name":"event without ownership"}\n' "$event_id" >"$outfile"
        printf '200'
        ;;
      service-only)
        printf '{"id":"%s","service_id":"service-1"}\n' "$event_id" >"$outfile"
        printf '200'
        ;;
      id-mismatch)
        printf '%s\n' '{"id":"different-event","customer_id":"6v6Bi5Y1nCtHThSbVurBys"}' >"$outfile"
        printf '200'
        ;;
    esac
    ;;
  */service/service-1)
    printf '{"id":"service-1","name":"Example service","customer_id":"%s","type":"vcl"}\n' \
      "${FASTLY_TEST_DDOS_SERVICE_CUSTOMER_ID:-${FASTLY_CUSTOMER_ID:?}}" >"$outfile"
    printf '200'
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"example-workspace","name":"Example Workspace"}]}' >"$outfile"
    printf '200'
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
export FASTLY_CUSTOMER_ID='6v6Bi5Y1nCtHThSbVurBys'
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0

event_url='https://manage.fastly.com/security/ddos/protection/events/fXvPWh9qdzJbWdGNl4tmMf'
expected_url="${event_url}?customerId=6v6Bi5Y1nCtHThSbVurBys"

output="$("$ROOT/fastly-audit" ddos link "$event_url" 2>"$TEST_TMP/valid-err")"
[[ "$output" == "$expected_url" ]]
grep -F 'customer scope: The RealReal (6v6Bi5Y1nCtHThSbVurBys; source=environment)' "$TEST_TMP/valid-err" >/dev/null

export FASTLY_CUSTOMER_ID='other-customer-id'
other_url='https://manage.fastly.com/security/ddos/protection/events/aQ8fFCpKTEskNVKhmuP5aG'
output="$("$ROOT/fastly-audit" ddos link "$other_url" 2>"$TEST_TMP/other-err")"
[[ "$output" == "${other_url}?customerId=other-customer-id" ]]
export FASTLY_CUSTOMER_ID='6v6Bi5Y1nCtHThSbVurBys'

assert_ddos_failure() {
  local name="$1" expected="$2"
  shift 2
  if "$ROOT/fastly-audit" ddos link "$@" >"$TEST_TMP/$name-out" 2>"$TEST_TMP/$name-err"; then
    printf 'ddos-link test: %s unexpectedly succeeded\n' "$name" >&2
    exit 1
  fi
  [[ ! -s "$TEST_TMP/$name-out" ]]
  grep -F "$expected" "$TEST_TMP/$name-err" >/dev/null
}

assert_ddos_failure missing 'usage: fastly-audit ddos link'
assert_ddos_failure hostname 'must use manage.fastly.com' \
  'https://example.com/security/ddos/protection/events/fXvPWh9qdzJbWdGNl4tmMf'
assert_ddos_failure invalid-event 'unsupported DDoS event URL path' \
  'https://manage.fastly.com/security/ddos/protection/events/'
assert_ddos_failure encoded 'URL-encoded DDoS event paths are not supported' \
  'https://manage.fastly.com/security/ddos/protection/events/%ZZ'
assert_ddos_failure duplicate-customer 'duplicate or unexpected query parameters' \
  "${event_url}?customerId=6v6Bi5Y1nCtHThSbVurBys&customerId=6v6Bi5Y1nCtHThSbVurBys"
assert_ddos_failure conflicting-customer 'does not match selected customer The RealReal' \
  "${event_url}?customerId=other-customer-id"

output="$("$ROOT/fastly-audit" ddos link \
  "${event_url}?customerId=6v6Bi5Y1nCtHThSbVurBys" 2>"$TEST_TMP/matching-err")"
[[ "$output" == "$expected_url" ]]

export FASTLY_TEST_DDOS_LINK_MODE=mismatch
assert_ddos_failure ownership-mismatch 'does not belong to selected customer The RealReal' "$event_url"

export FASTLY_TEST_DDOS_LINK_MODE=unknown
assert_ddos_failure unknown-event 'Fastly API returned HTTP 404' "$event_url"

export FASTLY_TEST_DDOS_LINK_MODE=failure
assert_ddos_failure api-failure 'Fastly API returned HTTP 503' "$event_url"

export FASTLY_TEST_DDOS_LINK_MODE=missing-ownership
assert_ddos_failure missing-ownership 'ownership could not be established' "$event_url"

export FASTLY_TEST_DDOS_LINK_MODE=id-mismatch
assert_ddos_failure id-mismatch 'mismatched event ID' "$event_url"

export FASTLY_TEST_DDOS_LINK_MODE=service-only
output="$("$ROOT/fastly-audit" ddos link "$event_url" 2>"$TEST_TMP/service-only-err")"
[[ "$output" == "$expected_url" ]]

export FASTLY_TEST_DDOS_SERVICE_CUSTOMER_ID='different-customer'
assert_ddos_failure service-ownership-mismatch 'does not belong to selected customer The RealReal' "$event_url"
unset FASTLY_TEST_DDOS_SERVICE_CUSTOMER_ID

unset FASTLY_TEST_DDOS_LINK_MODE FASTLY_CUSTOMER_ID
assert_ddos_failure no-customer 'no customer selected' "$event_url"

export FASTLY_CUSTOMER_ID='6v6Bi5Y1nCtHThSbVurBys'
ngwaf_url='https://manage.fastly.com/security/ngwaf/workspaces/example-workspace/requests/example-request'
output="$("$ROOT/fastly-audit" ngwaf link "$ngwaf_url" 2>"$TEST_TMP/ngwaf-err")"
[[ "$output" == "${ngwaf_url}?customerId=6v6Bi5Y1nCtHThSbVurBys" ]]

if grep -R -F 'test-token-secret' "$TEST_TMP" >/dev/null; then
  printf 'ddos-link test: token value leaked into output\n' >&2
  exit 1
fi

printf 'ddos-link: OK\n'
