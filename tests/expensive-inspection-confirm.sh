#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
fail() { printf 'expensive inspection: %s\n' "$1" >&2; exit 1; }
mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
out='' url=''
while (( $# )); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$FA_CONFIRM_LOG"
case "$url" in
  */customer/test-customer) printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$out" ;;
  */service) printf '%s\n' '{"meta":{"total":0},"data":[]}' >"$out" ;;
  */service/cdn-target) printf '%s\n' '{"id":"cdn-target","name":"Target CDN","type":"vcl","customer_id":"test-customer","active_version":7}' >"$out" ;;
  */service/cdn-target/version/7/generated_vcl)
    if [[ "${FA_CONFIRM_VCL_MODE:-legacy}" == legacy ]]; then
      printf '%s\n' '{"content":"set req.http.X-Inspection = \"se--examplecorp--prod.edgecompute.app\";"}' >"$out"
    else
      printf '%s\n' '{"content":"sub vcl_recv { return(pass); }"}' >"$out"
    fi ;;
  */v0/corps/examplecorp/sites) printf '%s\n' '{"data":[{"id":"site-test","name":"Synthetic Site","customer_id":"test-customer","serviceID":null}]}' >"$out" ;;
  *) printf '%s\n' '{"error":"fixture stops after confirmation"}' >"$out"; printf 599; exit 0 ;;
esac
printf 200
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"
export PATH="$TEST_TMP/bin:$PATH" FA_CONFIRM_LOG="$TEST_TMP/calls"
export FASTLY_API_TOKEN=synthetic-token FASTLY_CUSTOMER_ID=test-customer
export FASTLY_DSTOKEN=synthetic-dstoken FASTLY_VOUCH_COOKIE=synthetic-vouch
export NGWAF_PROGRESS=never NGWAF_COLOR=never NGWAF_CURL_RETRIES=0
export XDG_CONFIG_HOME="$TEST_TMP/config"

# The child keeps terminal stdin while stdout is a pipe. Its prompt must use
# /dev/tty, and the parent sends input only after the prompt is visible.
run_tty() {
  local reply="$1"; shift
  python3 - "$TEST_TMP" "$reply" "$@" <<'PY'
import errno, os, pty, select, signal, sys, time
folder, reply, *command = sys.argv[1:]
out_read, out_write = os.pipe()
pid, master = pty.fork()
if pid == 0:
    os.close(out_read)
    os.dup2(out_write, 1)
    os.close(out_write)
    os.execvpe(command[0], command, os.environ)
os.close(out_write)
seen = b''
deadline = time.monotonic() + 8
while b'Continue? [y/N]' not in seen and time.monotonic() < deadline:
    ready, _, _ = select.select([master], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(master, 4096)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
            chunk = b''
        if not chunk:
            break
        seen += chunk
if b'Continue? [y/N]' not in seen:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    raise SystemExit('missing interactive prompt')
if reply == 'EOF':
    os.write(master, b'\x04')
elif reply == 'INT':
    os.write(master, b'\x03')
else:
    os.write(master, reply.encode() + b'\n')
output = b''
status = None
deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    ready, _, _ = select.select([out_read, master], [], [], 0.1)
    for descriptor in ready:
        try:
            chunk = os.read(descriptor, 4096)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
            chunk = b''
        if descriptor == out_read:
            output += chunk
        else:
            seen += chunk
    completed, value = os.waitpid(pid, os.WNOHANG)
    if completed:
        status = 128 + os.WTERMSIG(value) if os.WIFSIGNALED(value) else os.WEXITSTATUS(value)
        break
if status is None:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    raise SystemExit('interactive command blocked')
os.close(master)
os.close(out_read)
open(folder + '/stdout', 'wb').write(output)
open(folder + '/stderr', 'wb').write(seen)
open(folder + '/status', 'w').write(str(status))
PY
}

legacy=("$ROOT/fastly-audit" security legacy-map --sigsci-corp examplecorp --format json)
scoped=("$ROOT/fastly-audit" ngwaf workspace-services --service-id cdn-target --sigsci-corp examplecorp --json)
# The inner Bash expands its positional argument after shellcheck's outer pass.
# shellcheck disable=SC2016
helper=(bash -c 'source "$1"; confirm_expensive_inspection "Synthetic warning" false' bash "$ROOT/lib/core.sh")
for answer in y YES '' n EOF INT; do
  : >"$FA_CONFIRM_LOG"
  run_tty "$answer" "${helper[@]}"
  case "$answer" in
    y|YES)
      [[ "$(cat "$TEST_TMP/status")" == 0 ]] || fail 'approval did not continue' ;;
    INT)
      [[ "$(cat "$TEST_TMP/status")" == 130 ]] || fail "Ctrl-C returned $(cat "$TEST_TMP/status"), expected 130"
      ;;
    *)
      [[ "$(cat "$TEST_TMP/status")" == 1 ]] || fail "decline '$answer' returned $(cat "$TEST_TMP/status"), expected 1"
      ;;
  esac
  [[ ! -s "$TEST_TMP/stdout" ]] || fail 'prompt or partial output reached stdout'
done

: >"$FA_CONFIRM_LOG"
run_tty y "${legacy[@]}"
rg -q '/service$' "$FA_CONFIRM_LOG" || fail 'interactive approval did not start legacy service discovery'
jq -e . "$TEST_TMP/stdout" >/dev/null || { tail -8 "$TEST_TMP/stderr" >&2; fail 'interactive legacy JSON stdout was missing or corrupted'; }

: >"$FA_CONFIRM_LOG"
run_tty n "${legacy[@]}" --output "$TEST_TMP/declined.json"
[[ "$(cat "$TEST_TMP/status")" == 1 ]] || fail 'legacy decline did not return 1'
! rg -q '/service$|/search/services$' "$FA_CONFIRM_LOG" || fail 'legacy decline started service discovery'
[[ ! -e "$TEST_TMP/declined.json" ]] || fail 'legacy decline created output file'

: >"$FA_CONFIRM_LOG"
run_tty n "${scoped[@]}"
[[ "$(cat "$TEST_TMP/status")" == 1 ]] || fail 'scoped decline did not return 1'
rg -q '/generated_vcl$' "$FA_CONFIRM_LOG" || fail 'scoped path did not reach VCL'
! rg -q '/v0/corps/|/service/inspection-' "$FA_CONFIRM_LOG" || fail 'scoped decline entered legacy discovery'
[[ ! -s "$TEST_TMP/stdout" ]] || fail 'scoped decline emitted partial JSON'

: >"$FA_CONFIRM_LOG"
run_tty y "${scoped[@]}"
rg -q '/v0/corps/' "$FA_CONFIRM_LOG" || fail 'interactive approval did not start scoped legacy discovery'
jq -e . "$TEST_TMP/stdout" >/dev/null || fail 'interactive scoped JSON stdout was missing or corrupted'

: >"$FA_CONFIRM_LOG"
bash -c 'source "$1"; confirm_expensive_inspection "Synthetic warning" true' bash "$ROOT/lib/core.sh" </dev/null >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr"
rg -q 'Expensive inspection:' "$TEST_TMP/stderr" || fail 'noninteractive --yes hid warning'
! rg -q 'Continue?' "$TEST_TMP/stderr" || fail 'noninteractive --yes prompted'

: >"$FA_CONFIRM_LOG"
bash -c 'source "$1"; confirm_expensive_inspection "Synthetic warning" false' bash "$ROOT/lib/core.sh" </dev/null >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr"
rg -q 'Expensive inspection:' "$TEST_TMP/stderr" || fail 'noninteractive warning absent'
! rg -q 'Continue?' "$TEST_TMP/stderr" || fail 'noninteractive command prompted'

: >"$FA_CONFIRM_LOG"
"${legacy[@]}" --yes </dev/null >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr" || true
rg -q 'Expensive inspection:' "$TEST_TMP/stderr" || fail 'legacy --yes hid warning'
! rg -q 'Continue?' "$TEST_TMP/stderr" || fail 'legacy --yes prompted'
rg -q '/service$' "$FA_CONFIRM_LOG" || fail 'legacy --yes did not continue'
jq -e . "$TEST_TMP/stdout" >/dev/null || fail 'legacy --yes JSON stdout was missing or corrupted'

: >"$FA_CONFIRM_LOG"
"${scoped[@]}" --yes </dev/null >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr" || true
rg -q 'Expensive inspection:' "$TEST_TMP/stderr" || fail 'scoped --yes hid warning'
! rg -q 'Continue?' "$TEST_TMP/stderr" || fail 'scoped --yes prompted'
rg -q '/v0/corps/' "$FA_CONFIRM_LOG" || fail 'scoped --yes did not continue'
jq -e . "$TEST_TMP/stdout" >/dev/null || fail 'scoped --yes JSON stdout was missing or corrupted'

: >"$FA_CONFIRM_LOG"
"${scoped[@]}" </dev/null >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr" || true
rg -q 'Expensive inspection:' "$TEST_TMP/stderr" || fail 'redirected stdin hid warning'
! rg -q 'Continue?' "$TEST_TMP/stderr" || fail 'redirected stdin prompted'
rg -q '/v0/corps/' "$FA_CONFIRM_LOG" || fail 'redirected stdin did not continue'

: >"$FA_CONFIRM_LOG"
FA_CONFIRM_VCL_MODE=none "${scoped[@]}" </dev/null >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr" || true
! rg -q 'Expensive inspection:|Continue?' "$TEST_TMP/stderr" || fail 'nonlegacy branch warned'
! rg -q '/v0/corps/' "$FA_CONFIRM_LOG" || fail 'nonlegacy branch fetched sites'
printf 'expensive inspection confirmation: OK\n'
