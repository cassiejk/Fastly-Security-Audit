#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/unifier-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url='' out='' cursor='' config=''
while (( $# )); do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    --data-urlencode) [[ "$2" != cursor=* ]] || cursor="${2#cursor=}"; shift 2 ;;
    --config) [[ "$2" != '-' ]] || config="$(cat)"; shift 2 ;;
    -w|--write-out|-H|--header|--connect-timeout|--max-time|--proto|--retry|--retry-delay|--retry-max-time) shift 2 ;;
    https://*) url="$1"; shift ;;
    -X|--request) exit 8 ;;
    *) shift ;;
  esac
done
status=200
case "$url" in
  https://api.fastly.com/customer/testcustomer)
    printf '{"id":"testcustomer","name":"Example"}\n' >"$out" ;;
  https://sigsci-console-internal.secretcdn.net/api/v0/corps/testcorp/users|https://alternate-internal.secretcdn.net/api/v0/corps/testcorp/users)
    [[ "$config" == *'Cookie: dstoken=secret-dstoken; VouchCookie=secret-vouch'* && "$config" != *'x-api-token'* ]] || exit 8
    case "$UNIFIER_TEST_MODE" in
      ngwaf-401|ngwaf-403|ngwaf-404) status="${UNIFIER_TEST_MODE#ngwaf-}"; printf '{}\n' >"$out" ;;
      ngwaf-malformed) printf '{"data":{}}\n' >"$out" ;;
      ngwaf-invalid-json) printf 'not json\n' >"$out" ;;
      ngwaf-empty) printf '{"data":[]}\n' >"$out" ;;
      ngwaf-more) printf '{"data":[],"totalCount":2,"next":"more"}\n' >"$out" ;;
      duplicate) printf '{"data":[{"email":"alice@example.invalid","role":"owner","status":"active","apiUser":false},{"email":" ALICE@example.invalid ","role":"owner","status":"active","apiUser":false}]}\n' >"$out" ;;
      inactive|api-only|unknown-status|missing-email)
        email='"email":"alice@example.invalid",'; status_value=active; api=false
        [[ "$UNIFIER_TEST_MODE" != missing-email ]] || email=''
        [[ "$UNIFIER_TEST_MODE" != inactive ]] || status_value=inactive
        [[ "$UNIFIER_TEST_MODE" != unknown-status ]] || status_value=pending
        [[ "$UNIFIER_TEST_MODE" != api-only ]] || api=true
        printf '{"data":[{%s"role":"owner","status":"%s","apiUser":%s}]}\n' "$email" "$status_value" "$api" >"$out" ;;
      *) printf '{"data":[{"name":"Alice Private","email":"alice@example.invalid","role":"owner","status":"active","apiUser":false}]}\n' >"$out" ;;
    esac ;;
  https://api.fastly.com/customer/testcustomer/users)
    [[ "$config" == *'Fastly-Key: secret-fastly'* ]] || exit 8
    case "$UNIFIER_TEST_MODE" in
      fastly-401|fastly-403|fastly-404) status="${UNIFIER_TEST_MODE#fastly-}"; printf '{}\n' >"$out" ;;
      fastly-malformed) printf '{}\n' >"$out" ;;
      fastly-empty) printf '[]\n' >"$out" ;;
      fastly-wrong-customer) printf '[{"login":"alice@example.invalid","customer_id":"othercustomer","role":"superuser","roles":["role-super"]}]\n' >"$out" ;;
      fastly-duplicate) printf '[{"login":"alice@example.invalid","customer_id":"testcustomer","role":"superuser","roles":["role-super"]},{"login":" ALICE@example.invalid ","customer_id":"testcustomer","role":"superuser","roles":["role-super"]}]\n' >"$out" ;;
      fastly-deleted) printf '[{"login":"alice@example.invalid","customer_id":"testcustomer","role":"superuser","roles":["role-super"],"deleted_at":"2026-01-01"}]\n' >"$out" ;;
      fastly-locked) printf '[{"login":"alice@example.invalid","customer_id":"testcustomer","role":"superuser","roles":["role-super"],"locked":true}]\n' >"$out" ;;
      case-match) printf '[{"login":" ALICE@EXAMPLE.INVALID ","customer_id":"testcustomer","role":"superuser","roles":["role-super"]}]\n' >"$out" ;;
      conflict) printf '[{"login":"alice@example.invalid","customer_id":"testcustomer","role":"user","roles":["role-super"]}]\n' >"$out" ;;
      unknown-role) printf '[{"login":"alice@example.invalid","customer_id":"testcustomer","role":"superuser","roles":["unknown-id"]}]\n' >"$out" ;;
      missing-role) printf '[{"login":"alice@example.invalid","customer_id":"testcustomer","roles":["role-super"]}]\n' >"$out" ;;
      no-iam-roles) printf '[{"login":"alice@example.invalid","customer_id":"testcustomer","role":"superuser","roles":[]}]\n' >"$out" ;;
      *) printf '[{"name":"Alice Private","login":"alice@example.invalid","customer_id":"testcustomer","role":"superuser","roles":["role-super"]}]\n' >"$out" ;;
    esac ;;
  https://api.fastly.com/iam/v1/roles)
    [[ "$config" == *'Fastly-Key: secret-fastly'* ]] || exit 8
    if [[ "$UNIFIER_TEST_MODE" == iam-403 ]]; then status=403; printf '{}\n' >"$out"
    elif [[ "$cursor" == next-page ]]; then
      printf '{"data":[{"id":"role-super","name":"Superuser","display_name":"Superuser"}],"next_cursor":"","limit":1}\n' >"$out"
    else
      printf '{"data":[{"id":"role-user","name":"User","display_name":"User"}],"next_cursor":"next-page","limit":1}\n' >"$out"
    fi ;;
  *) printf 'unexpected URL: %s\n' "$url" >&2; exit 9 ;;
esac
printf '%s' "$status"
MOCK
chmod 700 "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
export FASTLY_DSTOKEN=secret-dstoken FASTLY_VOUCH_COOKIE=secret-vouch FASTLY_API_TOKEN=secret-fastly
unset SIGSCI_EMAIL SIGSCI_TOKEN

check() {
  local mode="$1" expected_rc="$2" filter="$3" rc=0 dir
  export UNIFIER_TEST_MODE="$mode"
  "$here/probe.sh" --customer-id testcustomer --corp testcorp >"$tmp/out" 2>"$tmp/err" || rc=$?
  [[ "$rc" -eq "$expected_rc" ]] || { printf '%s: expected %s, got %s\n' "$mode" "$expected_rc" "$rc" >&2; cat "$tmp/err" >&2; exit 1; }
  dir="$(sed -n 's/^Sanitized results: //p' "$tmp/err")"
  [[ -d "$dir" ]] || { printf '%s: no result directory\n' "$mode" >&2; exit 1; }
  jq -e '.selected_customer_id == "testcustomer" and .selected_corp == "testcorp"' "$tmp/out" >/dev/null
  if jq -e '.. | objects | has("normalized_email")' "$dir/correlation.json" >/dev/null; then
    printf '%s: saved report contains reveal field\n' "$mode" >&2
    exit 1
  fi
  if rg -q 'Alice|alice@|secret-' "$dir" "$tmp/out" "$tmp/err"; then printf '%s: leak\n' "$mode" >&2; exit 1; fi
  jq -e "$filter" "$dir/correlation.json" >/dev/null || { printf '%s: assertion failed\n' "$mode" >&2; exit 1; }
  jq -e '.corp_customer_mapping == "unverified" and .completeness.ngwaf == "not_demonstrated" and .completeness.fastly == "not_demonstrated"' "$dir/correlation.json" >/dev/null
  rm -rf -- "$dir"
}
check success 0 '.result == "matches_found" and .confirmed_matching_record_count == 1 and .ngwaf_owner_count == 1 and .fastly_superuser_count == 1'
check case-match 0 '.confirmed_matching_record_count == 1'
check duplicate 0 '.result == "inconclusive" and .unresolved_identity_count == 1 and .unresolved_record_count == 3'
check fastly-duplicate 0 '.result == "inconclusive" and .unresolved_identity_count == 1 and .unresolved_record_count == 3'
check conflict 0 '.result == "inconclusive" and .fastly_superuser_count == 0'
check unknown-role 1 '.result == "inconclusive"'
check missing-role 0 '.result == "inconclusive"'
check no-iam-roles 0 '.result == "inconclusive" and .api_status.iam_roles == "not_required"'
check inactive 0 '.result == "no_matches_observed" and .ngwaf_owner_count == 0'
check api-only 0 '.result == "no_matches_observed" and .ngwaf_owner_count == 0'
check unknown-status 0 '.result == "inconclusive"'
check missing-email 0 '.result == "inconclusive" and .missing_identifier_counts.ngwaf == 1'
check fastly-empty 0 '.result == "no_matches_observed" and .ngwaf_owner_only_count == 1'
check ngwaf-empty 0 '.result == "no_matches_observed" and .fastly_superuser_only_count == 1'
check ngwaf-more 0 '.result == "inconclusive" and .pagination_indicates_more_ngwaf_records == true'
check fastly-deleted 0 '.result == "no_matches_observed" and .fastly_superuser_count == 0'
check fastly-locked 0 '.result == "inconclusive"'
for mode in ngwaf-401 ngwaf-403 ngwaf-404 ngwaf-malformed ngwaf-invalid-json fastly-401 fastly-403 fastly-404 fastly-malformed fastly-wrong-customer iam-403; do
  check "$mode" 1 '.result == "inconclusive"'
done
unset FASTLY_DSTOKEN
check missing-cookie 1 '.api_status.ngwaf == "missing_credential" and .result == "inconclusive"'
export FASTLY_DSTOKEN=secret-dstoken
unset FASTLY_API_TOKEN
check missing-fastly-token 1 '.api_status.fastly == "missing_credential" and .result == "inconclusive"'
export FASTLY_API_TOKEN=secret-fastly
export FASTLY_NGWAF_INTERNAL_API_BASE=https://alternate-internal.secretcdn.net/api
check internal-override 0 '.result == "matches_found"'
unset FASTLY_NGWAF_INTERNAL_API_BASE
if "$here/probe.sh" --customer-id testcustomer >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
  printf 'missing corp was accepted\n' >&2
  exit 1
fi
if "$here/probe.sh" --customer-id testcustomer --corp testcorp --show-identities \
  >"$tmp/redirected.out" 2>"$tmp/redirected.err"; then
  printf 'reveal accepted redirected stdout\n' >&2
  exit 1
fi
[[ ! -s "$tmp/redirected.out" ]]
rg -q 'requires an interactive terminal.*no requests were made' "$tmp/redirected.err"
if rg -q 'Sanitized results:' "$tmp/redirected.err"; then
  printf 'reveal redirect created results\n' >&2
  exit 1
fi

UNIFIER_PROBE_PATH="$here/probe.sh" python3 - <<'PY'
import errno
import json
import os
import pty
import re
import select
import shutil
import subprocess

probe = os.environ["UNIFIER_PROBE_PATH"]
for mode, category in [
    ("success", "matching_records"),
    ("fastly-empty", "ngwaf_owner_only"),
    ("conflict", "unresolved"),
]:
    out_master, out_slave = pty.openpty()
    err_master, err_slave = pty.openpty()
    env = os.environ.copy()
    env["UNIFIER_TEST_MODE"] = mode
    proc = subprocess.Popen(
        [probe, "--customer-id", "testcustomer", "--corp", "testcorp", "--show-identities"],
        stdin=out_slave,
        stdout=out_slave,
        stderr=err_slave,
        env=env,
    )
    os.close(out_slave)
    os.close(err_slave)
    chunks = {out_master: [], err_master: []}
    pending = set(chunks)
    while pending:
        ready, _, _ = select.select(list(pending), [], [], 30)
        if not ready:
            proc.kill()
            raise AssertionError(f"{mode}: terminal output timed out")
        for fd in ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    chunk = b""
                else:
                    raise
            if chunk:
                chunks[fd].append(chunk)
            else:
                pending.remove(fd)
    os.close(out_master)
    os.close(err_master)
    stdout = b"".join(chunks[out_master]).decode().replace("\r\n", "\n")
    stderr = b"".join(chunks[err_master]).decode().replace("\r\n", "\n")
    assert proc.wait() == 0, f"{mode}: probe failed: {stderr}"
    summary = json.loads(stdout)
    assert "alice@" not in json.dumps(summary)
    reveal = json.loads(stderr[stderr.index("{"):])
    assert reveal["warning"] == "Matching email addresses do not prove shared authenticated identity."
    assert reveal["identities"] == [{
        "local_id": "U1",
        "category": category,
        "normalized_email": "alice@example.invalid",
    }], (mode, reveal)
    match = re.search(r"^Sanitized results: (.+)$", stderr, re.MULTILINE)
    assert match, (mode, stderr)
    directory = match.group(1)
    try:
        for name in os.listdir(directory):
            with open(os.path.join(directory, name), encoding="utf-8") as report:
                contents = report.read()
            assert "alice@" not in contents, (mode, name)
            assert "normalized_email" not in contents, (mode, name)
    finally:
        shutil.rmtree(directory)

# A terminal stdin and stderr do not permit reveal when stdout is a pipe.
results_dir = os.path.join(os.path.dirname(probe), "results")
before = set(os.listdir(results_dir))
in_master, in_slave = pty.openpty()
err_master, err_slave = pty.openpty()
proc = subprocess.Popen(
    [probe, "--customer-id", "testcustomer", "--corp", "testcorp", "--show-identities"],
    stdin=in_slave,
    stdout=subprocess.PIPE,
    stderr=err_slave,
    env=os.environ.copy(),
)
os.close(in_slave)
os.close(err_slave)
stdout = proc.stdout.read()
stderr_chunks = []
while True:
    try:
        chunk = os.read(err_master, 65536)
    except OSError as error:
        if error.errno == errno.EIO:
            break
        raise
    if not chunk:
        break
    stderr_chunks.append(chunk)
os.close(in_master)
os.close(err_master)
assert proc.wait() == 2
assert stdout == b""
assert set(os.listdir(results_dir)) == before
PY
printf 'unifier probe mock tests: passed\n'
