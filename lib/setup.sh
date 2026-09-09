# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

# Append one setup check to the temporary JSONL stream. setup is intended for
# first-run onboarding, so it records every finding instead of stopping early.
setup_record() {
  local file="$1"
  local status="$2"
  local check="$3"
  local detail="${4:-}"

  jq -nc \
    --arg status "$status" \
    --arg check "$check" \
    --arg detail "$detail" \
    '{status: $status, check: $check, detail: $detail}' >>"$file"
}

# Store the selected customer ID with owner-only permissions. The token is never
# stored by fastly-audit; users keep FASTLY_API_TOKEN in their own shell setup.
setup_save_customer_id() {
  local cid="$1"
  local old_umask rc=0

  mkdir -p "$CONFIG_DIR" || return 1
  old_umask="$(umask)"
  umask 077
  printf '%s\n' "$cid" >"$CID_FILE" || rc=$?
  umask "$old_umask"
  (( rc == 0 )) || return "$rc"
  chmod 600 "$CID_FILE" 2>/dev/null || return 1
}

# Ask for a customer ID only in an interactive shell. Non-interactive callers get
# an actionable missing-customer result instead of a blocking prompt.
setup_prompt_customer_id() {
  local cid

  [[ -t 0 ]] || return 1
  printf '%s setup: Customer ID (leave blank to skip): ' \
    "${PROGRAM_NAME:-ngwaf}" >&2
  IFS= read -r cid || return 1
  [[ -n "$cid" ]] || return 1
  printf '%s\n' "$cid"
}

setup_render_human() {
  local summary="$1"
  local status check detail

  ui_heading "${PROGRAM_NAME:-ngwaf} setup"
  printf 'Read-only first-run check and customer selection\n\n'

  while IFS=$'\t' read -r status check detail; do
    ui_status "$status" "$check" "$detail"
  done < <(jq -r '.checks[] | [.status, .check, .detail] | @tsv' <<<"$summary")

  printf '\nOverall: %s\n' "$(jq -r '.status | ascii_upcase' <<<"$summary")"

  if jq -e '.selected_customer.id != null' >/dev/null <<<"$summary"; then
    printf 'Selected customer: %s' "$(jq -r '.selected_customer.id' <<<"$summary")"
    if jq -e '.selected_customer.name != null' >/dev/null <<<"$summary"; then
      printf ' (%s)' "$(jq -r '.selected_customer.name' <<<"$summary")"
    fi
    printf '\n'
  fi

  printf '\nNext steps:\n'
  jq -r '.next_steps[]' <<<"$summary" |
    while IFS= read -r step; do
      printf '  %s\n' "$step"
    done
}

cmd_setup() {
  local usage='usage: ngwaf setup [--customer-id CUSTOMER_ID] [--json]'
  local format="human"
  local customer_id_arg="" cid="" source="" name="" returned_id=""
  local token_present=false curl_available=false column_available=false
  local token_ready=false customer_ready=false saved_customer=false prompted=false
  local should_save=false token_code="" customer_code="" generated_at=""
  local results summary overall tmp help_usage

  while (( $# > 0 )); do
    case "$1" in
      --customer-id)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "$usage"
        customer_id_arg="$2"
        shift 2
        ;;
      --json)
        format="json"
        shift
        ;;
      --help|-h)
        help_usage="$usage"
        help_usage="${help_usage/usage: ngwaf/usage: ${USAGE_PROGRAM:-${PROGRAM_NAME:-ngwaf}}}"
        printf '%s\n' "$help_usage"
        return 0
        ;;
      *)
        die "$usage"
        ;;
    esac
  done

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s setup: FAIL: jq is not installed; install jq and rerun setup\n' \
      "${PROGRAM_NAME:-ngwaf}" >&2
    return 1
  fi

  results="$(mktemp)"
  : >"$results"

  setup_record "$results" pass "bash" \
    "$(ngwaf_current_bash_executable); ${BASH_VERSION:-unknown}; minimum $NGWAF_MIN_BASH_VERSION"

  if command -v curl >/dev/null 2>&1; then
    curl_available=true
    setup_record "$results" pass "curl" "$(command -v curl)"
  else
    setup_record "$results" fail "curl" "required dependency is missing"
  fi

  setup_record "$results" pass "jq" "$(command -v jq)"

  if command -v column >/dev/null 2>&1; then
    column_available=true
    setup_record "$results" pass "column" "available for aligned tables"
  else
    setup_record "$results" warn "column" "not installed; tables will use tab-separated fallback"
  fi

  if [[ -n "${FASTLY_API_TOKEN:-}" ]]; then
    token_present=true
    setup_record "$results" pass "API token" "FASTLY_API_TOKEN is set (value not displayed)"
  else
    setup_record "$results" fail "API token" "FASTLY_API_TOKEN is not set"
  fi

  if [[ -n "$customer_id_arg" ]]; then
    cid="$customer_id_arg"
    source="argument"
    should_save=true
  elif [[ -n "${FASTLY_CUSTOMER_ID:-}" ]]; then
    cid="$FASTLY_CUSTOMER_ID"
    source="environment"
  elif [[ -s "$CID_FILE" ]]; then
    cid="$(cat "$CID_FILE")"
    source="selected_file"
  elif cid="$(setup_prompt_customer_id)"; then
    source="prompt"
    prompted=true
    should_save=true
  fi

  if [[ -n "$cid" ]]; then
    setup_record "$results" pass "customer selection" "$cid from $source"
  else
    setup_record "$results" fail "customer selection" \
      "none; rerun ${PROGRAM_NAME:-ngwaf} setup --customer-id CUSTOMER_ID"
  fi

  if [[ "$token_present" == "true" && "$curl_available" == "true" ]]; then
    tmp="$(mktemp)"
    token_code="$(NGWAF_PROGRESS=never http_get_to_file "/tokens/self" "$tmp")"
    if [[ "$token_code" == 2* ]] && jq -e 'type == "object"' >/dev/null 2>&1 <"$tmp"; then
      setup_record "$results" pass "token API access" "HTTP $token_code"
      token_ready=true
    else
      setup_record "$results" fail "token API access" \
        "GET /tokens/self returned HTTP $token_code or invalid JSON"
    fi
    rm -f "$tmp"
  else
    setup_record "$results" warn "token API access" \
      "skipped until curl and FASTLY_API_TOKEN are available"
  fi

  if [[ "$token_ready" == "true" && -n "$cid" ]]; then
    tmp="$(mktemp)"
    customer_code="$(NGWAF_PROGRESS=never http_get_to_file "/customer/$(urlencode "$cid")" "$tmp")"
    returned_id="$(jq -r '.id // empty' "$tmp" 2>/dev/null || true)"
    name="$(jq -r '.name // empty' "$tmp" 2>/dev/null || true)"
    if [[ "$customer_code" == 2* && "$returned_id" == "$cid" && -n "$name" ]]; then
      setup_record "$results" pass "customer scope" "$name ($cid)"
      customer_ready=true
    else
      setup_record "$results" fail "customer scope" \
        "selected $cid; API returned HTTP $customer_code and id=${returned_id:-missing}"
    fi
    rm -f "$tmp"
  else
    setup_record "$results" warn "customer scope" \
      "skipped because token access or customer selection was not validated"
  fi

  if [[ "$customer_ready" == "true" && "$should_save" == "true" ]]; then
    if setup_save_customer_id "$cid"; then
      saved_customer=true
      setup_record "$results" pass "saved customer" "$CID_FILE"
    else
      setup_record "$results" fail "saved customer" "could not write $CID_FILE"
    fi
  elif [[ "$customer_ready" == "true" && "$source" == "selected_file" ]]; then
    setup_record "$results" pass "saved customer" "$CID_FILE"
  elif [[ "$customer_ready" == "true" && "$source" == "environment" ]]; then
    setup_record "$results" warn "saved customer" \
      "FASTLY_CUSTOMER_ID is set; not writing a local selection file"
  else
    setup_record "$results" warn "saved customer" \
      "skipped until customer scope is validated"
  fi

  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  summary="$(
    jq -s \
      --arg version "$VERSION" \
      --arg generated_at "$generated_at" \
      --arg program "${PROGRAM_NAME:-ngwaf}" \
      --arg usage_program "${USAGE_PROGRAM:-${PROGRAM_NAME:-ngwaf}}" \
      --arg runtime_bash_path "$(ngwaf_current_bash_executable)" \
      --arg runtime_bash_version "${BASH_VERSION:-unknown}" \
      --arg runtime_bash_required "$NGWAF_MIN_BASH_VERSION" \
      --arg selected_customer_id "$cid" \
      --arg selected_customer_name "$name" \
      --arg customer_source "$source" \
      --arg customer_id_file "$CID_FILE" \
      --arg token_http_status "$token_code" \
      --arg customer_http_status "$customer_code" \
      --argjson token_present "$token_present" \
      --argjson curl_available "$curl_available" \
      --argjson column_available "$column_available" \
      --argjson token_ready "$token_ready" \
      --argjson customer_ready "$customer_ready" \
      --argjson saved_customer "$saved_customer" \
      --argjson prompted "$prompted" '
      def empty_to_null($v): if $v == "" then null else $v end;
      . as $checks
      | (
          if any($checks[]; .status == "fail") then "fail"
          elif any($checks[]; .status == "warn") then "warn"
          else "pass"
          end
        ) as $status
      | (any($checks[]; .status == "fail")) as $has_fail
      | {
          command: "setup",
          program: $program,
          usage_program: $usage_program,
          tool_version: $version,
          generated_at: $generated_at,
          status: $status,
          runtime: {
            bash: {
              executable: $runtime_bash_path,
              version: $runtime_bash_version,
              minimum_version: $runtime_bash_required,
              supported: true
            }
          },
          dependencies: {
            curl: {available: $curl_available},
            jq: {available: true},
            column: {available: $column_available}
          },
          authentication: {
            fastly_api_token_set: $token_present,
            fastly_api_token_value_displayed: false,
            token_probe_http_status: empty_to_null($token_http_status),
            token_probe_passed: $token_ready
          },
          selected_customer: {
            id: empty_to_null($selected_customer_id),
            name: empty_to_null($selected_customer_name),
            source: empty_to_null($customer_source),
            prompted: $prompted,
            saved: $saved_customer,
            file: (if $saved_customer then $customer_id_file else null end),
            customer_probe_http_status: empty_to_null($customer_http_status),
            customer_probe_passed: $customer_ready
          },
          safety: {
            read_only_api: true,
            fastly_api_token_value_displayed: false
          },
          checks: $checks,
          next_steps: (
            if $has_fail | not then
              [
                $program + " doctor --verbose",
                $program + " inventory",
                $program + " ngwaf workspaces"
              ]
            else
              ([
                (if $token_present then empty else "export FASTLY_API_TOKEN=YOUR_FASTLY_TOKEN" end),
                (if $curl_available then empty else "install curl and rerun " + $program + " setup" end),
                (if $customer_ready then empty else $program + " setup --customer-id CUSTOMER_ID" end),
                $program + " doctor --verbose"
              ])
            end
          )
        }
    ' "$results"
  )"
  rm -f "$results"
  overall="$(jq -r '.status' <<<"$summary")"

  if [[ "$format" == "json" ]]; then
    jq . <<<"$summary"
  else
    setup_render_human "$summary"
  fi

  [[ "$overall" != "fail" ]]
}
