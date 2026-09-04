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

export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN="test-token"
export FASTLY_CUSTOMER_ID="test-customer"
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0

output="$($ROOT/ngwaf doctor --json)"
jq -e '
  .command == "doctor"
  and .tool_version == "23.2"
  and .status != "fail"
  and any(.checks[]; .check == "token API access" and .status == "pass")
  and any(.checks[]; .check == "customer scope" and .status == "pass")
  and any(.checks[]; .check == "workspace inventory" and .status == "pass")
  and any(.checks[]; .check == "workspace names" and .status == "pass")
' >/dev/null <<<"$output"

$ROOT/ngwaf doctor >"$TEST_TMP/human"
grep -F '[PASS]' "$TEST_TMP/human" >/dev/null
grep -F 'Overall:' "$TEST_TMP/human" >/dev/null

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
