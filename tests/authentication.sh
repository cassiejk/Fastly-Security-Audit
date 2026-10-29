#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=helpers.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_init

mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
outfile='' url=''
while (( $# > 0 )); do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    -H|-w|--connect-timeout|--max-time|--retry|--retry-delay|--retry-max-time)
      shift 2 ;;
    *) shift ;;
  esac
done
[[ "$url" == 'https://api.fastly.com/customer/customer-test' ]] || exit 90
printf '%s\n' "$url" >>"$AUTH_TEST_REQUESTS"
case "$AUTH_TEST_MODE" in
  invalid) printf '%s\n' '{"msg":"Provided credentials are missing or invalid"}' >"$outfile"; printf 401 ;;
  unexpected) printf '%s\n' '{"unexpected":{"session":"private-value"}}' >"$outfile"; printf 401 ;;
  empty) : >"$outfile"; printf 401 ;;
  malformed) printf '%s\n' 'not-json private-value' >"$outfile"; printf 401 ;;
  sensitive) printf '%s\n' '{"headers":{"Authorization":"Bearer private-value","Cookie":"private-value"}}' >"$outfile"; printf 401 ;;
  forbidden) printf '%s\n' '{"detail":"permission denied"}' >"$outfile"; printf 403 ;;
  bad-request) printf '%s\n' '{"detail":"bad request"}' >"$outfile"; printf 400 ;;
  missing) printf '%s\n' '{"detail":"not found"}' >"$outfile"; printf 404 ;;
  *) exit 91 ;;
esac
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"
export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN='test-token-secret' NGWAF_PROGRESS=never NGWAF_CURL_RETRIES=0
export XDG_CONFIG_HOME="$TEST_TMP/config" AUTH_TEST_REQUESTS="$TEST_TMP/requests"

for mode in invalid unexpected empty malformed sensitive forbidden bad-request missing; do
  export AUTH_TEST_MODE="$mode"
  : >"$AUTH_TEST_REQUESTS"
  if "$ROOT/fastly-audit" customer use customer-test >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'authentication: %s unexpectedly succeeded\n' "$mode" >&2; exit 1
  fi
  [[ ! -s "$TEST_TMP/out" && ! -e "$TEST_TMP/config/fastly-ngwaf/customer_id" ]]
  [[ "$(wc -l <"$AUTH_TEST_REQUESTS" | tr -d ' ')" == 1 ]]
  if rg -q 'test-token-secret|private-value|Authorization|Cookie|Provided credentials are missing or invalid' "$TEST_TMP/out" "$TEST_TMP/err"; then
    printf 'authentication: %s leaked an API error or credential\n' "$mode" >&2; exit 1
  fi
  case "$mode" in
    invalid|unexpected|empty|malformed|sensitive)
      rg -q 'Fastly API returned HTTP 401.*GET /customer/customer-test' "$TEST_TMP/err"
      grep -F 'Fastly rejected credentials supplied through FASTLY_API_TOKEN' "$TEST_TMP/err" >/dev/null
      grep -F 'reload or correct your local credential environment' "$TEST_TMP/err" >/dev/null
      grep -F 'doctor for additional checks' "$TEST_TMP/err" >/dev/null
      if rg -q 'customer.*(invalid|not found)|response body:' "$TEST_TMP/err"; then
        printf 'authentication: %s misclassified HTTP 401\n' "$mode" >&2; exit 1
      fi ;;
    forbidden)
      grep -F 'Fastly API returned HTTP 403' "$TEST_TMP/err" >/dev/null
      grep -F 'authorization failed (HTTP 403)' "$TEST_TMP/err" >/dev/null
      if grep -F 'Fastly rejected credentials' "$TEST_TMP/err" >/dev/null; then
        printf 'authentication: HTTP 403 misclassified as rejected credentials\n' >&2; exit 1
      fi ;;
    bad-request|missing)
      grep -F 'response body:' "$TEST_TMP/err" >/dev/null
      if grep -F 'authentication failed' "$TEST_TMP/err" >/dev/null; then
        printf 'authentication: %s misclassified as authentication failure\n' "$mode" >&2; exit 1
      fi ;;
  esac
done

: >"$AUTH_TEST_REQUESTS"
if env -u FASTLY_API_TOKEN "$ROOT/fastly-audit" customer use customer-test >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
  printf 'authentication: missing token unexpectedly succeeded\n' >&2; exit 1
fi
grep -F 'FASTLY_API_TOKEN is not set' "$TEST_TMP/err" >/dev/null
[[ ! -s "$AUTH_TEST_REQUESTS" ]]

printf 'authentication: OK (offline fake API)\n'
