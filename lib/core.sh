# shellcheck shell=bash
# Date-window globals are consumed by other sourced modules.
# shellcheck disable=SC2034
# Sourced by the ngwaf entry point; do not execute directly.

die() {
  local message="$*"
  local program="${PROGRAM_NAME:-ngwaf}"
  local usage_program="${USAGE_PROGRAM:-$program}"

  if [[ "$message" == *'usage: ngwaf'* ]]; then
    message="${message/usage: ngwaf/usage: $usage_program}"
  fi
  printf '%s: %s\n' "$program" "$message" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

confirm_expensive_inspection() {
  local warning="$1" skip_prompt="${2:-false}" answer='' status
  printf '⚠ Expensive inspection: %s\n' "$warning" >&2
  [[ "$skip_prompt" == true ]] && return 0
  [[ -t 0 ]] || return 0
  if ! { : </dev/tty; } 2>/dev/null; then
    return 0
  fi
  printf 'Continue? [y/N] ' >&2
  if IFS= read -r answer </dev/tty; then
    case "${answer,,}" in
      y|yes) return 0 ;;
    esac
  else
    status=$?
    (( status < 128 )) || return 130
  fi
  printf 'Inspection cancelled.\n' >&2
  return 1
}

# Stream structured JSON to jq through stdin. Large JSON values passed through
# --argjson contribute to the operating system's process-argument limit.
json_stream() {
  local document
  for document in "$@"; do
    printf '%s\n' "$document"
  done
}

urlencode() {
  jq -rn --arg v "$1" '$v | @uri'
}

# Centralize the debug flag so helper functions all agree on what "debug mode"
# means. Debug output must stay sanitized: paths and query parameters are useful,
# but authentication headers should never be printed.
debug_enabled() {
  [[ "${NGWAF_DEBUG:-0}" == "1" ]]
}

color_enabled() {
  [[ -z "${NO_COLOR+x}" ]] || return 1

  case "${NGWAF_COLOR:-auto}" in
    always|1|true|yes)
      return 0
      ;;
    never|0|false|no)
      return 1
      ;;
    auto|'')
      [[ -t 1 ]]
      ;;
    *)
      die 'NGWAF_COLOR must be auto, always, or never'
      ;;
  esac
}

ui_paint() {
  local code="$1"
  shift
  if color_enabled; then
    printf '\033[%sm%s\033[0m' "$code" "$*"
  else
    printf '%s' "$*"
  fi
}

ui_heading() {
  ui_paint '1;36' "$*"
  printf '\n'
}

ui_phase() {
  local current="$1"
  local total="$2"
  shift 2
  if [[ -n "${NGWAF_PROGRESS_JOB_STATE:-}" ]]; then
    [[ -z "${NGWAF_PROGRESS_PHASE_TOTAL:-}" ]] || total="$NGWAF_PROGRESS_PHASE_TOTAL"
    progress_job_phase "[$current/$total] $*"
    return
  fi
  [[ -z "${NGWAF_PROGRESS_COMMAND:-}" ]] || return 0
  printf '%s %s\n' "$(ui_paint '1;36' "[$current/$total]")" "$*" >&2
}

ui_status() {
  local status="$1"
  local label="$2"
  local detail="${3:-}"
  local badge color

  case "$status" in
    pass)
      badge='PASS'
      color='1;32'
      ;;
    warn)
      badge='WARN'
      color='1;33'
      ;;
    fail)
      badge='FAIL'
      color='1;31'
      ;;
    info)
      badge='INFO'
      color='1;36'
      ;;
    *)
      badge="$status"
      color='0'
      ;;
  esac

  printf '%s  %-24s %s\n' "$(ui_paint "$color" "[$badge]")" "$label" "$detail"
}

progress_enabled() {
  case "${NGWAF_PROGRESS:-auto}" in
    always|1|true|yes)
      return 0
      ;;
    never|0|false|no)
      return 1
      ;;
    auto|'')
      [[ -t 2 && "${TERM:-dumb}" != "dumb" ]]
      ;;
    *)
      die 'NGWAF_PROGRESS must be auto, always, or never'
      ;;
  esac
}

# Command-level progress shares NGWAF_PROGRESS with the existing HTTP spinner.
# Its state file lets helpers running in command substitutions report the active
# phase/API operation without changing their stdout or return values.
progress_job_elapsed() {
  local elapsed=$(( $(date +%s) - NGWAF_PROGRESS_JOB_STARTED ))
  printf '%02d:%02d' "$((elapsed / 60))" "$((elapsed % 60))"
}

progress_job_phase() {
  [[ -n "${NGWAF_PROGRESS_JOB_STATE:-}" ]] || return 0
  local label="$1" now
  now="$(date +%s)"
  printf '%s\t%s\t\n' "$now" "$label" >"$NGWAF_PROGRESS_JOB_STATE"
  printf '[%s] %s\n' "$(progress_job_elapsed)" "$label" >&2
}

progress_job_note() {
  [[ -n "${NGWAF_PROGRESS_JOB_STATE:-}" ]] || return 0
  local message="$1" last phase api now
  IFS=$'\t' read -r last phase api <"$NGWAF_PROGRESS_JOB_STATE" || return 0
  now="$(date +%s)"
  printf '%s\t%s\t%s\n' "$now" "$phase" "$api" >"$NGWAF_PROGRESS_JOB_STATE"
  printf '[%s] %s\n' "$(progress_job_elapsed)" "$message" >&2
}

progress_job_milestone() {
  [[ -n "${NGWAF_PROGRESS_JOB_STATE:-}" ]] || return 0
  local label="$1" current="$2" total="$3" last phase api now interval="${NGWAF_PROGRESS_MILESTONE_SECONDS:-10}"
  [[ "$current" =~ ^[0-9]+$ && "$total" =~ ^[1-9][0-9]*$ ]] || return 0
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=10
  IFS=$'\t' read -r last phase api <"$NGWAF_PROGRESS_JOB_STATE" || return 0
  now="$(date +%s)"
  if (( current >= total || now - last >= interval )); then
    progress_job_note "$label: $current/$total"
  fi
}

progress_safe_path() {
  local path="${1%%\?*}"
  if [[ "$path" =~ ^/[A-Za-z0-9/_{}.-]+$ ]]; then
    printf '%s' "$path"
  else
    printf '[redacted path]'
  fi
}

progress_job_api_start() {
  [[ -n "${NGWAF_PROGRESS_JOB_STATE:-}" ]] || return 0
  local last phase api
  IFS=$'\t' read -r last phase api <"$NGWAF_PROGRESS_JOB_STATE" || return 0
  printf '%s\t%s\tGET %s\n' "$last" "$phase" "$(progress_safe_path "$1")" >"$NGWAF_PROGRESS_JOB_STATE"
}

progress_job_api_end() {
  [[ -n "${NGWAF_PROGRESS_JOB_STATE:-}" ]] || return 0
  local last phase api
  IFS=$'\t' read -r last phase api <"$NGWAF_PROGRESS_JOB_STATE" || return 0
  printf '%s\t%s\t\n' "$last" "$phase" >"$NGWAF_PROGRESS_JOB_STATE"
}

progress_http_timing() {
  local path="$1" elapsed="$2" code="$3" threshold="${NGWAF_PROGRESS_SLOW_SECONDS:-10}"
  progress_enabled || return 0
  [[ "$threshold" =~ ^[1-9][0-9]*$ ]] || threshold=10
  (( elapsed >= threshold )) || return 0
  printf '[%s] Slow API request: GET %s (%ss, HTTP %s)\n' \
    "$(if [[ -n "${NGWAF_PROGRESS_JOB_STATE:-}" ]]; then progress_job_elapsed; else printf '%02d:%02d' "$((elapsed / 60))" "$((elapsed % 60))"; fi)" \
    "$(progress_safe_path "$path")" "$elapsed" "$code" >&2
}

progress_job_finish() {
  [[ -n "${NGWAF_PROGRESS_JOB_STATE:-}" ]] || return 0
  local outcome="$1" code="${2:-0}" last phase api
  IFS=$'\t' read -r last phase api <"$NGWAF_PROGRESS_JOB_STATE" || phase='current operation'
  kill "${NGWAF_PROGRESS_JOB_PID:-}" 2>/dev/null || true
  wait "${NGWAF_PROGRESS_JOB_PID:-}" 2>/dev/null || true
  rm -f "$NGWAF_PROGRESS_JOB_STATE"
  unset NGWAF_PROGRESS_JOB_STATE NGWAF_PROGRESS_JOB_STARTED NGWAF_PROGRESS_JOB_PID NGWAF_PROGRESS_PHASE_TOTAL NGWAF_PROGRESS_COMMAND
  trap - EXIT INT TERM
  case "$outcome" in
    success) printf '[%s] Completed successfully\n' "${NGWAF_PROGRESS_JOB_FINAL_TIME:-00:00}" >&2 ;;
    interrupted) printf '[%s] Interrupted by user (SIG%s)\n' "${NGWAF_PROGRESS_JOB_FINAL_TIME:-00:00}" "$code" >&2 ;;
    *) printf '[%s] Failed: %s (exit=%s)\n' "${NGWAF_PROGRESS_JOB_FINAL_TIME:-00:00}" "$phase" "$code" >&2 ;;
  esac
  unset NGWAF_PROGRESS_JOB_FINAL_TIME
}

progress_job_exit() {
  local code="$1"
  NGWAF_PROGRESS_JOB_FINAL_TIME="$(progress_job_elapsed)"
  if (( code == 0 )); then progress_job_finish success 0
  else progress_job_finish failure "$code"; fi
}

progress_job_signal() {
  local signal="$1" code=130
  [[ "$signal" != TERM ]] || code=143
  NGWAF_PROGRESS_JOB_FINAL_TIME="$(progress_job_elapsed)"
  progress_job_finish interrupted "$signal"
  exit "$code"
}

progress_job_begin() {
  local label="$1" owner interval
  progress_enabled || return 0
  [[ -z "${NGWAF_PROGRESS_JOB_STATE:-}" ]] || die 'progress job already active'
  interval="${NGWAF_PROGRESS_HEARTBEAT_SECONDS:-10}"
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=10
  NGWAF_PROGRESS_JOB_STARTED="$(date +%s)"
  NGWAF_PROGRESS_JOB_STATE="$(mktemp)" || return 1
  export NGWAF_PROGRESS_JOB_STARTED NGWAF_PROGRESS_JOB_STATE
  printf '%s\t%s\t\n' "$NGWAF_PROGRESS_JOB_STARTED" "$label" >"$NGWAF_PROGRESS_JOB_STATE"
  printf '[%s] Starting %s\n' "$(progress_job_elapsed)" "$label" >&2
  owner="$BASHPID"
  (
    local last_emitted="$NGWAF_PROGRESS_JOB_STARTED" last phase api now sleeper=''
    trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi; exit 0' INT TERM HUP
    while :; do
      sleep 2 &
      sleeper=$!
      wait "$sleeper" 2>/dev/null || true
      sleeper=''
      kill -0 "$owner" 2>/dev/null || exit 0
      IFS=$'\t' read -r last phase api <"$NGWAF_PROGRESS_JOB_STATE" || continue
      [[ "$last" =~ ^[0-9]+$ && -n "$phase" ]] || continue
      if (( last > last_emitted )); then last_emitted="$last"; fi
      now="$(date +%s)"
      if (( now - last_emitted >= interval )); then
        printf '[%s] Still working: %s%s\n' \
          "$(progress_job_elapsed)" "$phase" "${api:+; $api}" >&2
        last_emitted="$now"
      fi
    done
  ) &
  NGWAF_PROGRESS_JOB_PID=$!
  trap 'progress_job_exit $?' EXIT
  trap 'progress_job_signal INT' INT
  trap 'progress_job_signal TERM' TERM
}

progress_run() {
  local label="$1"
  shift
  NGWAF_PROGRESS_COMMAND=1
  export NGWAF_PROGRESS_COMMAND
  progress_job_begin "$label"
  "$@"
  if [[ -n "${NGWAF_PROGRESS_JOB_STATE:-}" ]]; then
    NGWAF_PROGRESS_JOB_FINAL_TIME="$(progress_job_elapsed)"
    progress_job_finish success 0
  fi
  unset NGWAF_PROGRESS_COMMAND
}

_ngwaf_progress_pid=""
_ngwaf_progress_label=""
_ngwaf_progress_started=0

progress_start() {
  local label="$1"
  local frames='|/-'

  _ngwaf_progress_pid=""
  _ngwaf_progress_label="$label"
  _ngwaf_progress_started="$(date +%s)"

  [[ -z "${NGWAF_PROGRESS_JOB_STATE:-}" ]] || return 0
  progress_enabled || return 0

  printf '\r%s: %s %s (0s)' "${PROGRAM_NAME:-ngwaf}" "${frames:0:1}" "$label" >&2
  (
    local i=1 now elapsed frame
    trap 'exit 0' INT TERM HUP
    while :; do
      sleep 0.2
      now="$(date +%s)"
      elapsed=$((now - _ngwaf_progress_started))
      frame="${frames:$((i % 3)):1}"
      printf '\r%s: %s %s (%ss)' "${PROGRAM_NAME:-ngwaf}" "$frame" "$label" "$elapsed" >&2
      i=$((i + 1))
    done
  ) &
  _ngwaf_progress_pid=$!
}

progress_stop() {
  local outcome="${1:-success}"
  local now elapsed slow_threshold="${NGWAF_PROGRESS_SLOW_SECONDS:-10}"

  [[ -n "$_ngwaf_progress_pid" ]] || return 0

  kill "$_ngwaf_progress_pid" 2>/dev/null || true
  wait "$_ngwaf_progress_pid" 2>/dev/null || true
  _ngwaf_progress_pid=""

  now="$(date +%s)"
  elapsed=$((now - _ngwaf_progress_started))
  [[ "$slow_threshold" =~ ^[1-9][0-9]*$ ]] || slow_threshold=10

  if [[ -t 2 ]]; then
    printf '\r\033[2K' >&2
  else
    printf '\n' >&2
  fi

  if [[ "$outcome" == "success" && "$elapsed" -ge 2 && "$elapsed" -lt "$slow_threshold" ]]; then
    printf '%s: %s %s in %ss\n' \
      "${PROGRAM_NAME:-ngwaf}" \
      "$(ui_paint '1;32' 'completed')" \
      "$_ngwaf_progress_label" \
      "$elapsed" >&2
  fi
}

# Print request metadata only when the caller opts in with NGWAF_DEBUG=1.
# Curl receives the token header separately, and this function intentionally
# ignores headers so debug logs are safe to share.
debug_get_request() {
  debug_enabled || return 0

  local path="$1"
  shift
  local arg expect_value=false

  # Timeseries debug output is intended to be shareable for schema diagnosis.
  # Do not include workspace IDs, customer IDs, or query values here.
  if [[ -n "${NGWAF_TIMESERIES_DEBUG:-}" ]]; then
    printf '%s: debug: GET NGWAF %s timeseries (scope and query values redacted)\n' \
      "${PROGRAM_NAME:-ngwaf}" "$NGWAF_TIMESERIES_DEBUG" >&2
    return 0
  fi

  printf '%s: debug: GET %s%s\n' "${PROGRAM_NAME:-ngwaf}" "$API_BASE" "$path" >&2
  for arg in "$@"; do
    if [[ "$expect_value" == "true" ]]; then
      [[ "$arg" != cursor=* ]] || arg='cursor=<redacted>'
      printf '%s: debug: query parameter: %s\n' "${PROGRAM_NAME:-ngwaf}" "$arg" >&2
      expect_value=false
    elif [[ "$arg" == "--data-urlencode" ]]; then
      expect_value=true
    elif [[ "$arg" == --data-urlencode=* ]]; then
      [[ "$arg" != --data-urlencode=cursor=* ]] || arg='--data-urlencode=cursor=<redacted>'
      printf '%s: debug: query parameter: %s\n' "${PROGRAM_NAME:-ngwaf}" "${arg#--data-urlencode=}" >&2
    fi
  done
}

validate_http_settings() {
  [[ "$CURL_CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] ||
    die 'NGWAF_CURL_CONNECT_TIMEOUT must be a non-negative integer'
  [[ "$CURL_MAX_TIME" =~ ^[0-9]+$ ]] ||
    die 'NGWAF_CURL_MAX_TIME must be a non-negative integer'
  [[ "$CURL_RETRIES" =~ ^[0-9]+$ ]] ||
    die 'NGWAF_CURL_RETRIES must be a non-negative integer'
  [[ "$CURL_RETRY_MAX_TIME" =~ ^[0-9]+$ ]] ||
    die 'NGWAF_CURL_RETRY_MAX_TIME must be a non-negative integer'
}

# Common curl exit codes are much easier to troubleshoot when translated from
# numbers into likely local-network, proxy, TLS, or timeout causes.
print_curl_failure_hint() {
  local rc="$1"

  case "$rc" in
    6)
      printf '%s: hint: DNS lookup failed; check network, VPN, proxy, or api.fastly.com resolution\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    7)
      printf '%s: hint: connection failed; check network, firewall, proxy, or VPN access to api.fastly.com\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    28)
      printf '%s: hint: request exceeded the configured timeout policy; try again later or raise NGWAF_CURL_MAX_TIME\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    35|51|58|60|77)
      printf '%s: hint: TLS/certificate validation failed; check local certificates or corporate proxy settings\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    52|56)
      printf '%s: hint: connection was interrupted while reading the response; retrying later may succeed\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    130)
      printf '%s: hint: request was interrupted locally\n' "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    *)
      printf '%s: hint: curl reported a transport error before an HTTP response was available\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
  esac
}

# HTTP status codes tell us whether troubleshooting should focus on request
# shape, token permissions, resource identity, rate limits, or Fastly-side
# availability. Keep this generic so every API-backed command can reuse it.
print_http_status_hint() {
  local code="$1"

  case "$code" in
    400)
      printf '%s: hint: Fastly rejected the request; check command options, date ranges, and search syntax\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    401)
      printf '%s: authentication failed (HTTP 401): Fastly rejected credentials supplied through FASTLY_API_TOKEN\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      printf '%s: hint: verify the intended Fastly API token is loaded; an incorrect, expired, revoked, empty, or incorrectly loaded token can cause this response\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      printf '%s: hint: reload or correct your local credential environment, then retry the original command; run %s doctor for additional checks\n' \
        "${PROGRAM_NAME:-ngwaf}" "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    403)
      printf '%s: authorization failed (HTTP 403): Fastly refused access to this resource; check token permissions and resource authorization with %s doctor\n' \
        "${PROGRAM_NAME:-ngwaf}" "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    404)
      printf '%s: hint: Fastly could not find this endpoint or resource; check the selected customer and resource ID\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    408|409|425|429)
      printf '%s: hint: Fastly asked the client to slow down or retry; try again after a short wait\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    5??)
      printf '%s: hint: Fastly or an upstream service returned a server error; retry later or inspect status pages\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
    *)
      printf '%s: hint: inspect the response body below for Fastly-specific error details\n' \
        "${PROGRAM_NAME:-ngwaf}" >&2
      ;;
  esac
}

# Give every failed API request the same next steps. This keeps normal output
# short while pointing users toward the two best troubleshooting tools.
print_troubleshooting_hint() {
  if debug_enabled; then
    printf '%s: debug: request path and query parameters were printed above\n' \
      "${PROGRAM_NAME:-ngwaf}" >&2
  else
    printf '%s: tip: rerun with NGWAF_DEBUG=1 to show sanitized request details\n' \
      "${PROGRAM_NAME:-ngwaf}" >&2
  fi

  printf '%s: tip: run %s doctor to check dependencies, token access, and selected customer scope\n' \
    "${PROGRAM_NAME:-ngwaf}" "${PROGRAM_NAME:-ngwaf}" >&2
}

# Show a response body without making callers know whether Fastly returned JSON.
# Non-JSON previews stay debug-only for 2xx responses because they may be large
# or surprising. Other HTTP errors retain the historical response preview;
# authentication and authorization failures omit it in get().
print_response_body() {
  local file="$1"

  if [[ ! -s "$file" ]]; then
    printf '%s: response body was empty\n' "${PROGRAM_NAME:-ngwaf}" >&2
    return
  fi

  jq . "$file" >&2 2>/dev/null || cat "$file" >&2
}

print_invalid_json_preview() {
  local file="$1"

  if [[ ! -s "$file" ]]; then
    printf '%s: response body was empty\n' "${PROGRAM_NAME:-ngwaf}" >&2
    return
  fi

  if debug_enabled; then
    printf '%s: debug: response preview follows\n' "${PROGRAM_NAME:-ngwaf}" >&2
    sed -n '1,20p' "$file" >&2
  else
    printf '%s: response body was not valid JSON; set NGWAF_DEBUG=1 to print a short preview\n' \
      "${PROGRAM_NAME:-ngwaf}" >&2
  fi
}

print_curl_failure() {
  local rc="$1"
  local path="$2"
  local errfile="$3"
  local elapsed="${4:-}"
  local elapsed_text=""

  [[ -n "$elapsed" ]] && elapsed_text=" after ${elapsed}s"

  case "$rc" in
    28)
      printf '%s: Fastly API request timed out%s: GET %s\n' \
        "${PROGRAM_NAME:-ngwaf}" "$elapsed_text" "$path" >&2
      printf '%s: timeout limits: connect=%ss, transfer=%ss, retry-window=%ss\n' \
        "${PROGRAM_NAME:-ngwaf}" "$CURL_CONNECT_TIMEOUT" "$CURL_MAX_TIME" "$CURL_RETRY_MAX_TIME" >&2
      ;;
    130)
      printf '%s: Fastly API request interrupted%s: GET %s\n' \
        "${PROGRAM_NAME:-ngwaf}" "$elapsed_text" "$path" >&2
      ;;
    *)
      printf '%s: Fastly API transport failed%s (curl exit %s): GET %s\n' \
        "${PROGRAM_NAME:-ngwaf}" "$elapsed_text" "$rc" "$path" >&2
      ;;
  esac

  if [[ -s "$errfile" && "${NGWAF_HTTP_REDACT_CURL_STDERR:-0}" != 1 ]]; then
    sed "s/^/${PROGRAM_NAME:-ngwaf}: curl: /" "$errfile" >&2
  fi

  print_curl_failure_hint "$rc"
  print_troubleshooting_hint
}

# Perform a GET request and return parsed JSON on stdout. All progress and
# diagnostics stay on stderr so callers can safely pipe stdout into jq.
get() {
  local path="$1"
  shift

  local tmp err_tmp code curl_rc=0 started_at elapsed elapsed_text
  # Keep the array non-empty for macOS Bash 3.2 with `set -u`. Expanding an
  # empty array under nounset exits on that shell. curl accepts --retry 0, so
  # including the base option unconditionally is safe.
  local -a retry_args=(--retry "$CURL_RETRIES")
  tmp="$(mktemp)"
  err_tmp="$(mktemp)"

  validate_http_settings
  debug_get_request "$path" "$@"
  if (( CURL_RETRIES > 0 )); then
    retry_args+=(
      --retry-delay 1
      --retry-max-time "$CURL_RETRY_MAX_TIME"
      --retry-connrefused
    )
  fi

  progress_start "${NGWAF_PROGRESS_LABEL:-querying Fastly API: $path}"
  progress_job_api_start "$path"
  started_at="$(date +%s)"

  if code="$(
    curl -sS -G \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      "${retry_args[@]}" \
      -o "$tmp" \
      -w '%{http_code}' \
      -H "Fastly-Key: $FASTLY_API_TOKEN" \
      -H "Accept: application/json" \
      "$@" \
      "$API_BASE$path" \
      2>"$err_tmp"
  )"; then
    curl_rc=0
  else
    curl_rc=$?
  fi
  elapsed=$(( $(date +%s) - started_at ))
  elapsed_text=" after ${elapsed}s"
  progress_job_api_end

  if (( curl_rc != 0 )); then
    progress_stop error
    progress_http_timing "$path" "$elapsed" 000
    print_curl_failure "$curl_rc" "$path" "$err_tmp" "$elapsed"
    rm -f "$tmp" "$err_tmp"
    exit 1
  fi

  case "$code" in
    2*)
      progress_stop success
      progress_http_timing "$path" "$elapsed" "$code"
      if ! jq -e . "$tmp" >/dev/null 2>&1; then
        printf '%s: Fastly API returned invalid JSON%s: GET %s\n' \
          "${PROGRAM_NAME:-ngwaf}" "$elapsed_text" "$path" >&2
        print_invalid_json_preview "$tmp"
        print_troubleshooting_hint
        rm -f "$tmp" "$err_tmp"
        exit 1
      fi
      cat "$tmp"
      ;;
    *)
      progress_stop error
      progress_http_timing "$path" "$elapsed" "$code"
      printf '%s: Fastly API returned HTTP %s%s: GET %s\n' \
        "${PROGRAM_NAME:-ngwaf}" "$code" "$elapsed_text" "$path" >&2
      if [[ "$code" == 400 && "${NGWAF_HTTP_ERROR_CONTEXT:-}" == timeseries ]] &&
        jq -e 'tostring | test("(start|end)"; "i")' "$tmp" >/dev/null 2>&1; then
        printf '%s: timeseries date parameters were rejected; use --start and optional --end as UTC RFC3339 timestamps, or use a 1-30 day count\n' "${PROGRAM_NAME:-ngwaf}" >&2
        printf '%s: example: %s ngwaf timeseries vi-agent-production 7 --json\n' "${PROGRAM_NAME:-ngwaf}" "${PROGRAM_NAME:-fastly-audit}" >&2
      fi
      print_http_status_hint "$code"
      if [[ "$code" == 401 || "$code" == 403 ]]; then
        printf '%s: API response body omitted for credential safety\n' "${PROGRAM_NAME:-ngwaf}" >&2
      else
        printf '%s: response body:\n' "${PROGRAM_NAME:-ngwaf}" >&2
        print_response_body "$tmp"
        print_troubleshooting_hint
      fi
      rm -f "$tmp" "$err_tmp"
      exit 1
      ;;
  esac

  rm -f "$tmp" "$err_tmp"
}

# Read-only probe helper for inventory discovery. Unlike get(), this does not
# fail on a non-2xx response. The caller receives the HTTP status on stdout and
# can inspect the response body at the supplied path. This is used so product
# discovery can distinguish enabled, disabled/not-found, and permission errors
# without turning an inventory command into a write-risky or fail-open workflow.

http_get_to_file() {
  [[ $# -ge 2 ]] || die 'http_get_to_file requires <path> <output-file>'

  local path="$1"
  local outfile="$2"
  shift 2

  local code err_tmp curl_rc=0 started_at elapsed
  # See get(): the base option prevents an empty-array nounset failure on the
  # Bash 3.2 version included with macOS.
  local -a retry_args=(--retry "$CURL_RETRIES")
  err_tmp="$(mktemp)"

  validate_http_settings
  debug_get_request "$path" "$@"
  if (( CURL_RETRIES > 0 )); then
    retry_args+=(
      --retry-delay 1
      --retry-max-time "$CURL_RETRY_MAX_TIME"
      --retry-connrefused
    )
  fi

  progress_start "${NGWAF_PROGRESS_LABEL:-querying Fastly API: $path}"
  progress_job_api_start "$path"
  started_at="$(date +%s)"

  if code="$(
    curl -sS -G \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      "${retry_args[@]}" \
      -o "$outfile" \
      -w '%{http_code}' \
      -H "Fastly-Key: $FASTLY_API_TOKEN" \
      -H "Accept: application/json" \
      "$@" \
      "$API_BASE$path" \
      2>"$err_tmp"
  )"; then
    curl_rc=0
  else
    curl_rc=$?
  fi
  elapsed=$(( $(date +%s) - started_at ))
  progress_job_api_end

  if (( curl_rc != 0 )); then
    progress_stop error
    progress_http_timing "$path" "$elapsed" 000
    print_curl_failure "$curl_rc" "$path" "$err_tmp" "$elapsed"
    rm -f "$err_tmp"
    printf '000\n'
    return
  fi

  case "$code" in
    2*) progress_stop success ;;
    *) progress_stop error ;;
  esac
  progress_http_timing "$path" "$elapsed" "$code"

  rm -f "$err_tmp"
  printf '%s\n' "$code"
}

# Fetch every page from NGWAF list endpoints that use limit/page pagination.
# Returns one normalized object:
#   {"meta":{"limit":100,"total":N,"pages_fetched":P},"data":[...]}
#
# Safety behavior: if the API advertises more rows than we can retrieve,
# fail rather than silently returning a partial security configuration.

get_all_pages() {
  [[ $# -ge 1 ]] || die 'get_all_pages requires an API path'

  local path="$1"
  shift

  local limit=100
  local page=1
  local pages_fetched=0
  local fetched=0
  local total=-1
  local body count page_total
  local pages_tmp

  pages_tmp="$(mktemp)"

  while :; do
    body="$(
      get "$path" \
        "$@" \
        --data-urlencode "limit=$limit" \
        --data-urlencode "page=$page"
    )"

    jq -e '.data | type == "array"' >/dev/null <<<"$body" ||
      {
        rm -f "$pages_tmp"
        die "paginated endpoint $path did not return a data array"
      }

    count="$(jq '.data | length' <<<"$body")"
    page_total="$(jq -r '.meta.total // empty' <<<"$body")"

    if [[ -n "$page_total" && "$page_total" =~ ^[0-9]+$ ]]; then
      if (( total < 0 )); then
        total="$page_total"
      elif (( page_total != total )); then
        printf 'WARNING: pagination total changed from %s to %s while reading %s; using latest total.\n' \
          "$total" "$page_total" "$path" >&2
        total="$page_total"
      fi
    elif (( total < 0 )); then
      # Metadata should normally contain meta.total. If it does not,
      # a short page is the only safe completion signal available.
      total=0
    fi

    jq '.data' <<<"$body" >>"$pages_tmp"
    fetched=$(( fetched + count ))
    pages_fetched=$(( pages_fetched + 1 ))
    if (( total > 0 )); then
      progress_job_milestone 'List records retrieved' "$fetched" "$total"
    fi

    if (( total > 0 && fetched >= total )); then
      break
    fi

    if (( count == 0 )); then
      if (( total > fetched )); then
        rm -f "$pages_tmp"
        die "pagination for $path stopped early: retrieved $fetched of $total items"
      fi
      total="$fetched"
      break
    fi

    if (( count < limit )); then
      if (( total > fetched )); then
        rm -f "$pages_tmp"
        die "pagination for $path returned a short page before completion: retrieved $fetched of $total items"
      fi
      total="$fetched"
      break
    fi

    page=$(( page + 1 ))
    (( page <= 1000 )) || {
      rm -f "$pages_tmp"
      die "pagination safety limit exceeded for $path"
    }
  done

  if (( total == 0 )); then
    total="$fetched"
  fi

  if (( fetched < total )); then
    rm -f "$pages_tmp"
    die "pagination for $path incomplete: retrieved $fetched of $total items"
  fi

  jq -s \
    --argjson limit "$limit" \
    --argjson total "$total" \
    --argjson pages_fetched "$pages_fetched" \
    '{
      meta: {
        limit: $limit,
        total: $total,
        pages_fetched: $pages_fetched
      },
      data: (add // [])
    }' "$pages_tmp"

  rm -f "$pages_tmp"
}

current_cid() {
  if [[ -n "${FASTLY_CUSTOMER_ID:-}" ]]; then
    printf '%s\n' "$FASTLY_CUSTOMER_ID"
  elif [[ -s "$CID_FILE" ]]; then
    cat "$CID_FILE"
  else
    die 'no customer selected; run: ngwaf use <customer_id>'
  fi
}

customer_context_source() {
  if [[ -n "${FASTLY_CUSTOMER_ID:-}" ]]; then
    printf 'environment\n'
  else
    printf 'selected_file\n'
  fi
}

load_customer_context() {
  local cid source body returned_id name

  [[ -z "$NGWAF_CUSTOMER_CONTEXT_JSON" ]] || return 0

  cid="$(current_cid)"
  source="$(customer_context_source)"
  body="$(NGWAF_PROGRESS_LABEL="confirming customer scope" get "/customer/$(urlencode "$cid")")"
  returned_id="$(jq -r '.id // empty' <<<"$body")"
  name="$(jq -r '.name // empty' <<<"$body")"

  [[ "$returned_id" == "$cid" ]] ||
    die "customer-scope validation mismatch: selected $cid but API returned ${returned_id:-no id}"
  [[ -n "$name" ]] ||
    die "customer-scope validation failed: customer $cid response did not include a name"

  NGWAF_CUSTOMER_CONTEXT_JSON="$(
    jq -n \
      --arg id "$cid" \
      --arg name "$name" \
      --arg source "$source" \
      '{id: $id, name: $name, source: $source}'
  )"
}

confirm_customer_scope() {
  load_customer_context
  printf '%s: %s: %s (%s; source=%s)\n' \
    "${PROGRAM_NAME:-ngwaf}" \
    "$(ui_paint '1;36' 'customer scope')" \
    "$(jq -r '.name' <<<"$NGWAF_CUSTOMER_CONTEXT_JSON")" \
    "$(jq -r '.id' <<<"$NGWAF_CUSTOMER_CONTEXT_JSON")" \
    "$(jq -r '.source' <<<"$NGWAF_CUSTOMER_CONTEXT_JSON")" >&2
}

current_customer_name() {
  load_customer_context
  jq -r '.name' <<<"$NGWAF_CUSTOMER_CONTEXT_JSON"
}

workspace_path() {
  printf '/ngwaf/v1/workspaces/%s' "$(urlencode "$1")"
}

# Resolve a workspace argument against the selected customer's complete
# workspace collection. Exact ID matches win; otherwise require one
# case-insensitive exact name match. Never guess on partial or ambiguous names.
resolve_workspace_json() {
  [[ $# -eq 1 ]] || die 'resolve_workspace_json requires one workspace ID or name'

  local input="$1"
  local cid body matches count resolution resolved
  cid="$(current_cid)"
  body="$(
    NGWAF_PROGRESS_LABEL="resolving workspace $input" \
    get_all_pages "/ngwaf/v1/workspaces" \
      --data-urlencode "customer_id=$cid"
  )"

  matches="$(jq --arg input "$input" '[.data[] | select(.id == $input)]' <<<"$body")"
  count="$(jq 'length' <<<"$matches")"
  resolution="id"

  if (( count == 0 )); then
    matches="$(
      jq --arg input "$input" \
        '[.data[] | select(((.name // "") | ascii_downcase) == ($input | ascii_downcase))]' \
        <<<"$body"
    )"
    count="$(jq 'length' <<<"$matches")"
    resolution="name"
  fi

  (( count > 0 )) ||
    die "workspace not found for selected customer: $input"
  (( count == 1 )) ||
    die "workspace name is ambiguous for selected customer: $input"

  resolved="$(
    jq --arg input "$input" --arg resolution "$resolution" '
      .[0]
      | select((.id // "") != "" and (.name // "") != "")
      | {
          id,
          name,
          input: $input,
          resolved_by: $resolution
        }
    ' <<<"$matches"
  )"
  [[ -n "$resolved" ]] ||
    die "workspace resolution returned an incomplete object for: $input"

  printf '%s: %s: %s (%s; resolved_by=%s)\n' \
    "${PROGRAM_NAME:-ngwaf}" \
    "$(ui_paint '1;36' 'workspace scope')" \
    "$(jq -r '.name' <<<"$resolved")" \
    "$(jq -r '.id' <<<"$resolved")" \
    "$(jq -r '.resolved_by' <<<"$resolved")" >&2
  printf '%s\n' "$resolved"
}

normalize_account_timeseries_response() {
  [[ $# -eq 3 ]] || die 'normalize_account_timeseries_response requires <body> <metrics> <context>'

  local body="$1" metrics="$2" context="$3" duplicates missing

  jq -e '.data | type == "array" and length > 0' >/dev/null <<<"$body" ||
    die "$context returned no timeseries rows; refusing to treat missing data as zero"
  jq -e 'all(.data[]; (.dimensions.workspace | type) == "string" and
    (.values | type) == "array" and all(.values[]; type == "object"))' >/dev/null <<<"$body" ||
    die "$context returned malformed timeseries rows or metric values"

  duplicates="$(jq -r '[.data[] | [.values[] | keys[]] | group_by(.)[] |
    select(length > 1) | .[0]] | unique | join(",")' <<<"$body")"
  [[ -z "$duplicates" ]] ||
    die "$context returned duplicate metric key(s): $duplicates; refusing to overwrite values"

  missing="$(jq -r --arg metrics "$metrics" '
    def numeric: (type == "number") or
      (type == "string" and test("^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$") and (tonumber? != null));
    ($metrics | split(",")) as $names
    | [.data[] | (reduce .values[] as $metric ({}; . + $metric)) as $values
      | $names[] | select((($values[.]? | numeric) | not))]
    | unique | join(",")
  ' <<<"$body")"
  [[ -z "$missing" ]] ||
    die "$context omitted or returned non-numeric requested metric(s): $missing; refusing to substitute zero"

  jq '.data |= map(.values |= [reduce .[] as $metric ({}; . + $metric)])' <<<"$body"
}

validate_timeseries_response() {
  [[ $# -eq 3 ]] || die 'validate_timeseries_response requires <body> <metrics> <context>'

  local body="$1"
  local metrics="$2"
  local context="$3"
  local missing

  jq -e '.data | type == "array" and length > 0' >/dev/null <<<"$body" ||
    die "$context returned no timeseries rows; refusing to treat missing data as zero"

  missing="$(
    jq -r --arg metrics "$metrics" '
      def numeric:
        (type == "number") or (type == "string" and (tonumber? != null));
      ($metrics | split(",")) as $metrics
      | [
          .data[]
          | . as $row
          | $metrics[]
          | select(
              (($row.values[0]? | type) != "object")
              or (($row.values[0][.]? | numeric) | not)
            )
        ]
      | unique
      | join(",")
    ' <<<"$body"
  )"

  [[ -z "$missing" ]] ||
    die "$context omitted or returned non-numeric requested metric(s): $missing; refusing to substitute zero"
}

validate_historical_response() {
  [[ $# -eq 3 ]] || die 'validate_historical_response requires <body> <fields> <context>'

  local body="$1"
  local fields="$2"
  local context="$3"
  local missing

  jq -e '.data | type == "array" and length > 0' >/dev/null <<<"$body" ||
    die "$context returned no historical rows; refusing to treat missing data as zero"

  missing="$(
    jq -r --arg fields "$fields" '
      def numeric:
        (type == "number") or (type == "string" and (tonumber? != null));
      ($fields | split(",")) as $fields
      | [
          .data[]
          | . as $row
          | $fields[]
          | select((($row[.]? | numeric) | not))
        ]
      | unique
      | join(",")
    ' <<<"$body"
  )"

  [[ -z "$missing" ]] ||
    die "$context omitted or returned non-numeric requested field(s): $missing; refusing to substitute zero"
}

epoch_to_utc() {
  local epoch="$1"
  if date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

validate_timeseries_days() {
  local days="$1"
  [[ "$days" =~ ^[0-9]+$ ]] || die 'days must be an integer'
  (( days >= 1 && days <= 30 )) ||
    die 'timeseries days must be between 1 and 30'
}

validate_request_days() {
  local days="$1"
  [[ "$days" =~ ^[0-9]+$ ]] || die 'days must be an integer'
  (( days >= 1 && days <= 7 )) ||
    die 'request-search days must be between 1 and 7'
}

# Use complete UTC days for timeseries summaries so repeated reports are comparable.
TS_FROM=""
TS_TO=""

make_timeseries_window() {
  local days="$1"
  validate_timeseries_days "$days"

  TS_TO="$(date -u '+%Y-%m-%dT00:00:00Z')"

  if date -u -v-"${days}"d '+%Y-%m-%dT00:00:00Z' >/dev/null 2>&1; then
    TS_FROM="$(date -u -v-"${days}"d '+%Y-%m-%dT00:00:00Z')"
  else
    TS_FROM="$(date -u -d "$days days ago" '+%Y-%m-%dT00:00:00Z')"
  fi
}

validate_historical_days() {
  local days="$1"
  [[ "$days" =~ ^[0-9]+$ ]] || die 'bot historical-stats days must be an integer'
  (( days >= 1 && days <= 30 )) ||
    die 'bot historical-stats days must be between 1 and 30 for this workflow'
}

HIST_FROM=""
HIST_TO=""

make_historical_window_days() {
  local days="$1"
  validate_historical_days "$days"

  HIST_TO="$(date -u '+%Y-%m-%dT00:00:00Z')"

  if date -u -v-"${days}"d '+%Y-%m-%dT00:00:00Z' >/dev/null 2>&1; then
    HIST_FROM="$(date -u -v-"${days}"d '+%Y-%m-%dT00:00:00Z')"
  else
    HIST_FROM="$(date -u -d "$days days ago" '+%Y-%m-%dT00:00:00Z')"
  fi
}

set_historical_window_dates() {
  local from_date="$1"
  local to_date="$2"

  [[ "$from_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
    die 'from date must be YYYY-MM-DD'
  [[ "$to_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
    die 'to date must be YYYY-MM-DD'

  HIST_FROM="${from_date}T00:00:00Z"
  HIST_TO="${to_date}T00:00:00Z"
}

validate_monthly_historical_window() {
  local from_date="$1"
  local to_date="$2"
  local from_epoch to_epoch span_days

  if date -u -j -f "%Y-%m-%d" "$from_date" "+%s" >/dev/null 2>&1; then
    from_epoch="$(date -u -j -f "%Y-%m-%d" "$from_date" "+%s")"
    to_epoch="$(date -u -j -f "%Y-%m-%d" "$to_date" "+%s")"
  else
    from_epoch="$(date -u -d "$from_date" "+%s")"
    to_epoch="$(date -u -d "$to_date" "+%s")"
  fi

  (( to_epoch > from_epoch )) || die 'TO date must be after FROM date'
  span_days=$(( (to_epoch - from_epoch) / 86400 ))

  # Allow a full calendar month such as Aug 1 -> Sep 1 (31 days),
  # but intentionally reject quarter-length windows for this workflow.
  (( span_days <= 31 )) ||
    die 'exact Bot Management date range must be 31 days or less for this workflow'
}

human_table() {
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
  else
    cat
  fi
}


# Summarize a normalized rules collection without assuming that every customer
# uses the same rule types or actions. The dynamic type/action maps preserve
# unknown/new API values while the convenience counters expose common controls.

summarize_rules_json() {
  jq '
    def norm:
      tostring | gsub("[^A-Za-z0-9]"; "") | ascii_downcase;

    def counts($items):
      ($items | sort | group_by(.) | map({key: .[0], value: length}) | from_entries);

    . as $body
    | ($body.data // []) as $rules
    | {
        total: ($rules | length),
        enabled: ([$rules[] | select(.enabled == true)] | length),
        disabled: ([$rules[] | select(.enabled == false)] | length),
        enabled_allow_rules: (
          [$rules[] | select(.enabled == true and ([.actions[]?.type // empty | norm] | index("allow") != null))]
          | length
        ),
        enabled_block_rules: (
          [$rules[] | select(.enabled == true and ([.actions[]?.type // empty | norm] | index("block") != null))]
          | length
        ),
        enabled_browser_challenge_rules: (
          [$rules[] | select(.enabled == true and ([.actions[]?.type // empty | norm] | index("browserchallenge") != null))]
          | length
        ),
        enabled_rate_limit_rules: (
          [$rules[] | select(.enabled == true and ((.type // "") | norm | test("ratelimit")))]
          | length
        ),
        enabled_signal_exclusion_rules: (
          [$rules[] | select(.enabled == true and ((.type // "") | norm | test("signalexclusion")))]
          | length
        ),
        rule_types: counts([$rules[] | (.type // "unknown")]),
        enabled_actions: counts([$rules[] | select(.enabled == true) | .actions[]?.type // "unknown"]),
        pages_fetched: ($body.meta.pages_fetched // 1)
      }
  '
}

summarize_lists_json() {
  jq '
    def counts($items):
      ($items | sort | group_by(.) | map({key: .[0], value: length}) | from_entries);

    . as $body
    | ($body.data // []) as $lists
    | {
        total: ($lists | length),
        by_type: counts([$lists[] | (.type // "unknown")]),
        total_entries_returned: ([$lists[] | ((.entries // []) | length)] | add // 0),
        pages_fetched: ($body.meta.pages_fetched // 1)
      }
  '
}
