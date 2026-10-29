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
    -o) outfile="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

case "$url" in
  */tokens/self)
    printf '%s\n' '{"name":"test token","scope":["global:read"]}' >"$outfile"
    ;;
  */customer/test-customer)
    if [[ "${NGWAF_TEST_DOCTOR_MODE:-ok}" == "customer-mismatch" ]]; then
      printf '%s\n' '{"id":"wrong-customer","name":"Wrong Customer"}' >"$outfile"
    else
      printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    fi
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":2},"data":[{"id":"production","name":"Production"},{"id":"staging","name":"Staging"}]}' >"$outfile"
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
export FASTLY_API_TOKEN="test-token"
export FASTLY_CUSTOMER_ID="test-customer"
export XDG_CONFIG_HOME="$TEST_TMP/config"
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0

expected_bash="$BASH"
expected_bash_version="$BASH_VERSION"

output="$($ROOT/ngwaf doctor --json)"
jq -e \
  --arg expected_bash "$expected_bash" \
  --arg expected_bash_version "$expected_bash_version" '
  .command == "doctor"
  and .tool_version == "24.2.2"
  and .status != "fail"
  and .runtime.bash.executable == $expected_bash
  and .runtime.bash.version == $expected_bash_version
  and .runtime.bash.minimum_version == "5.2"
  and .runtime.bash.supported == true
  and any(.checks[]; .check == "bash" and .status == "pass" and (.detail | contains("minimum 5.2")))
  and any(.checks[]; .check == "token API access" and .status == "pass")
  and any(.checks[]; .check == "customer scope" and .status == "pass")
  and any(.checks[]; .check == "workspace inventory" and .status == "pass")
  and any(.checks[]; .check == "workspace names" and .status == "pass")
' >/dev/null <<<"$output"

verbose_output="$($ROOT/ngwaf doctor --json --verbose)"
jq -e --arg root "$ROOT" --arg expected_bash "$expected_bash" '
  .command == "doctor"
  and .verbose == true
  and .diagnostics.safety.read_only == true
  and .diagnostics.safety.fastly_api_token_value_displayed == false
  and .diagnostics.program.name == "ngwaf"
  and .diagnostics.program.script_root == $root
  and .diagnostics.commands.bash.path == $expected_bash
  and .diagnostics.commands.curl.version == "curl 8.0.0 fake"
  and .diagnostics.config.customer_id_file_exists == false
  and .diagnostics.environment.fastly_api_token_set == true
  and .diagnostics.environment.fastly_api_token_value_displayed == false
  and .diagnostics.customer.selection_source == "environment"
  and .diagnostics.http.policy.retries == 0
  and .diagnostics.api_probes.token.http_status == "200"
  and .diagnostics.api_probes.token.json_valid == true
  and .diagnostics.api_probes.customer.http_status == "200"
  and .diagnostics.api_probes.customer.returned_id == "test-customer"
  and .diagnostics.api_probes.workspaces.returned_count == 2
  and .diagnostics.api_probes.workspaces.duplicate_name_groups == 0
' >/dev/null <<<"$verbose_output"
! grep -F 'test-token' <<<"$verbose_output" >/dev/null

$ROOT/ngwaf doctor >"$TEST_TMP/human"
grep -F '[PASS]' "$TEST_TMP/human" >/dev/null
grep -F 'Overall:' "$TEST_TMP/human" >/dev/null

$ROOT/ngwaf doctor --verbose >"$TEST_TMP/verbose-human"
grep -F 'Troubleshooting details:' "$TEST_TMP/verbose-human" >/dev/null
grep -F 'FASTLY_API_TOKEN' "$TEST_TMP/verbose-human" >/dev/null
grep -F 'set; value hidden' "$TEST_TMP/verbose-human" >/dev/null
! grep -F 'test-token' "$TEST_TMP/verbose-human" >/dev/null

$ROOT/fastly-audit doctor >"$TEST_TMP/fastly-human"
grep -F 'fastly-audit doctor' "$TEST_TMP/fastly-human" >/dev/null

fastly_output="$($ROOT/fastly-audit doctor --json)"
jq -e '
  .command == "doctor"
  and .status != "fail"
  and any(
    .checks[];
    .check == "installed command"
    and .status == "pass"
    and (.detail | endswith("/fastly-audit"))
  )
' >/dev/null <<<"$fastly_output"

(
  unset NO_COLOR
  NGWAF_COLOR=always $ROOT/ngwaf doctor >"$TEST_TMP/color"
)
grep -F $'\033[' "$TEST_TMP/color" >/dev/null

export NGWAF_TEST_DOCTOR_MODE=customer-mismatch
if $ROOT/ngwaf doctor --json >"$TEST_TMP/mismatch.json"; then
  printf 'doctor test: customer mismatch unexpectedly succeeded\n' >&2
  exit 1
fi
jq -e '
  .status == "fail"
  and any(.checks[]; .check == "customer scope" and .status == "fail")
' >/dev/null "$TEST_TMP/mismatch.json"

printf 'doctor: OK\n'
