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

if [[ "${1:-}" == "--version" ]]; then
  printf 'curl 8.0.0 fake\n'
  exit 0
fi

while (( $# > 0 )); do
  case "$1" in
    -o)
      outfile="$2"
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  */tokens/self)
    if [[ "${NGWAF_TEST_SETUP_MODE:-ok}" == "token-401" ]]; then
      printf '%s\n' '{"error":"secret authentication detail"}' >"$outfile"
      printf '401'
      exit 0
    fi
    printf '%s\n' '{"name":"test token","scope":["global:read"]}' >"$outfile"
    ;;
  */customer/test-customer)
    if [[ "${NGWAF_TEST_SETUP_MODE:-ok}" == "customer-403" ]]; then
      printf '%s\n' '{"error":"secret authorization detail"}' >"$outfile"
      printf '403'
      exit 0
    elif [[ "${NGWAF_TEST_SETUP_MODE:-ok}" == "customer-mismatch" ]]; then
      printf '%s\n' '{"id":"wrong-customer","name":"Wrong Customer"}' >"$outfile"
    else
      printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    fi
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
ln -s "$ROOT/fastly-audit" "$TEST_TMP/bin/fastly-audit"
ln -s "$ROOT/ngwaf" "$TEST_TMP/bin/ngwaf"

export PATH="$TEST_TMP/bin:$PATH"
export XDG_CONFIG_HOME="$TEST_TMP/config"
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0
unset FASTLY_API_TOKEN FASTLY_CUSTOMER_ID

if $ROOT/fastly-audit setup >"$TEST_TMP/no-token"; then
  printf 'setup test: missing token unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'FASTLY_API_TOKEN is not set' "$TEST_TMP/no-token" >/dev/null
grep -F 'approved local credential workflow' "$TEST_TMP/no-token" >/dev/null
grep -F 'fastly-audit setup --customer-id CUSTOMER_ID' "$TEST_TMP/no-token" >/dev/null
grep -F 'Fastly Customer ID is required to verify ownership' "$TEST_TMP/no-token" >/dev/null

export FASTLY_API_TOKEN="test-token"

output="$($ROOT/fastly-audit setup --customer-id test-customer --json)"
jq -e \
  --arg expected_bash "$BASH" \
  --arg cid_file "$XDG_CONFIG_HOME/fastly-ngwaf/customer_id" '
  .command == "setup"
  and .program == "fastly-audit"
  and .tool_version == "24.2.3"
  and .status != "fail"
  and .runtime.bash.executable == $expected_bash
  and .runtime.bash.minimum_version == "5.2"
  and .runtime.bash.supported == true
  and .authentication.fastly_api_token_set == true
  and .authentication.fastly_api_token_value_displayed == false
  and .authentication.token_probe_http_status == "200"
  and .authentication.token_probe_passed == true
  and .selected_customer.id == "test-customer"
  and .selected_customer.name == "Test Customer"
  and .selected_customer.source == "argument"
  and .selected_customer.saved == true
  and .selected_customer.file == $cid_file
  and .selected_customer.customer_probe_passed == true
  and .safety.read_only_api == true
  and any(.checks[]; .check == "bash" and .status == "pass")
  and any(.checks[]; .check == "token API access" and .status == "pass")
  and any(.checks[]; .check == "customer scope" and .status == "pass")
  and any(.next_steps[]; . == "fastly-audit doctor --verbose")
' >/dev/null <<<"$output"
! grep -F 'test-token' <<<"$output" >/dev/null
[[ "$(cat "$XDG_CONFIG_HOME/fastly-ngwaf/customer_id")" == "test-customer" ]]
[[ "$(test_file_mode "$XDG_CONFIG_HOME/fastly-ngwaf/customer_id")" == "600" ]]

$ROOT/fastly-audit setup --customer-id test-customer >"$TEST_TMP/human"
grep -F 'fastly-audit setup' "$TEST_TMP/human" >/dev/null
grep -F '[PASS]' "$TEST_TMP/human" >/dev/null
grep -F 'Verified customer: Test Customer (test-customer)' "$TEST_TMP/human" >/dev/null
grep -F 'Customer selection: saved locally.' "$TEST_TMP/human" >/dev/null
grep -F 'Next: fa doctor (operational verification).' "$TEST_TMP/human" >/dev/null

ngwaf_output="$($ROOT/ngwaf setup --customer-id test-customer --json)"
jq -e '
  .command == "setup"
  and .program == "ngwaf"
  and .status != "fail"
  and any(.next_steps[]; . == "ngwaf doctor --verbose")
' >/dev/null <<<"$ngwaf_output"

customer_output="$($ROOT/fastly-audit customer setup --customer-id test-customer --json)"
jq -e '
  .command == "setup"
  and .program == "fastly-audit"
  and .usage_program == "fastly-audit customer"
  and .status != "fail"
' >/dev/null <<<"$customer_output"

export NGWAF_TEST_SETUP_MODE=customer-mismatch
if $ROOT/fastly-audit setup --customer-id test-customer --json >"$TEST_TMP/mismatch.json"; then
  printf 'setup test: customer mismatch unexpectedly succeeded\n' >&2
  exit 1
fi
jq -e '
  .status == "fail"
  and any(.checks[]; .check == "customer scope" and .status == "fail")
' >/dev/null "$TEST_TMP/mismatch.json"

export NGWAF_TEST_SETUP_MODE=token-401
if $ROOT/fastly-audit setup --customer-id test-customer >"$TEST_TMP/token-401"; then
  printf 'setup test: rejected token unexpectedly succeeded\n' >&2; exit 1
fi
grep -F 'HTTP 401: Fastly rejected these credentials' "$TEST_TMP/token-401" >/dev/null
! grep -F 'secret authentication detail' "$TEST_TMP/token-401" >/dev/null

export NGWAF_TEST_SETUP_MODE=customer-403
if $ROOT/fastly-audit setup --customer-id test-customer >"$TEST_TMP/customer-403"; then
  printf 'setup test: forbidden customer unexpectedly succeeded\n' >&2; exit 1
fi
grep -F 'HTTP 403: token authentication does not grant access to the selected customer' "$TEST_TMP/customer-403" >/dev/null
! grep -F 'secret authorization detail' "$TEST_TMP/customer-403" >/dev/null

printf 'setup: OK\n'
