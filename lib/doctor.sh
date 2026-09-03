# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

doctor_record() {
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

doctor_file_mode() {
  local path="$1"
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  elif stat -c '%a' "$path" >/dev/null 2>&1; then
    stat -c '%a' "$path"
  else
    printf 'unknown\n'
  fi
}

doctor_render_human() {
  local summary="$1"
  local status check detail

  ui_heading 'ngwaf doctor'
  printf 'Version %s · read-only diagnostics\n\n' "$VERSION"

  while IFS=$'\t' read -r status check detail; do
    ui_status "$status" "$check" "$detail"
  done < <(jq -r '.checks[] | [.status, .check, .detail] | @tsv' <<<"$summary")

  printf '\nOverall: %s (%s passed, %s warnings, %s failures)\n' \
    "$(jq -r '.status | ascii_upcase' <<<"$summary")" \
    "$(jq '[.checks[] | select(.status == "pass")] | length' <<<"$summary")" \
    "$(jq '[.checks[] | select(.status == "warn")] | length' <<<"$summary")" \
    "$(jq '[.checks[] | select(.status == "fail")] | length' <<<"$summary")"
}

cmd_doctor() {
  [[ $# -le 1 ]] || die 'usage: ngwaf doctor [--json]'
  local format="${1:-}"
  [[ -z "$format" || "$format" == "--json" ]] ||
    die 'usage: ngwaf doctor [--json]'

  if ! command -v jq >/dev/null 2>&1; then
    printf 'ngwaf doctor: FAIL: jq is not installed; JSON diagnostics cannot run\n' >&2
    return 1
  fi

  local results summary overall generated_at
  local token_present=false cid="" source="" api_ready=false customer_ready=false
  local http_policy_ready=false
  local tmp code returned_id name scopes workspace_body duplicates count invalid_workspaces
  local config_mode install_path
  results="$(mktemp)"
  : >"$results"

  if (( BASH_VERSINFO[0] > 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] >= 2) )); then
    doctor_record "$results" pass "bash" "${BASH_VERSION} (supported)"
  else
    doctor_record "$results" fail "bash" "${BASH_VERSION}; version 3.2 or newer is required"
  fi

  if command -v curl >/dev/null 2>&1; then
    doctor_record "$results" pass "curl" "$(command -v curl)"
  else
    doctor_record "$results" fail "curl" "required dependency is missing"
  fi

  doctor_record "$results" pass "jq" "$(command -v jq)"

  if command -v column >/dev/null 2>&1; then
    doctor_record "$results" pass "column" "available for aligned tables"
  else
    doctor_record "$results" warn "column" "not installed; tables will use tab-separated fallback"
  fi

  install_path="$(command -v ngwaf 2>/dev/null || true)"
  if [[ -n "$install_path" ]]; then
    doctor_record "$results" pass "installed command" "$install_path"
  else
    doctor_record "$results" warn "installed command" "ngwaf is not discoverable through PATH"
  fi

  if [[ "$CURL_CONNECT_TIMEOUT" =~ ^[0-9]+$ \
    && "$CURL_MAX_TIME" =~ ^[0-9]+$ \
    && "$CURL_RETRIES" =~ ^[0-9]+$ \
    && "$CURL_RETRY_MAX_TIME" =~ ^[0-9]+$ ]]; then
    doctor_record "$results" pass "HTTP policy" \
      "connect=${CURL_CONNECT_TIMEOUT}s transfer=${CURL_MAX_TIME}s retries=${CURL_RETRIES} retry-window=${CURL_RETRY_MAX_TIME}s"
    http_policy_ready=true
  else
    doctor_record "$results" fail "HTTP policy" "one or more NGWAF_CURL_* values are not non-negative integers"
  fi

  if [[ -n "${FASTLY_API_TOKEN:-}" ]]; then
    token_present=true
    doctor_record "$results" pass "API token" "FASTLY_API_TOKEN is set (value not displayed)"
  else
    doctor_record "$results" fail "API token" "FASTLY_API_TOKEN is not set"
  fi

  if [[ -n "${FASTLY_CUSTOMER_ID:-}" ]]; then
    cid="$FASTLY_CUSTOMER_ID"
    source="environment"
    doctor_record "$results" pass "customer selection" "$cid from FASTLY_CUSTOMER_ID"
  elif [[ -s "$CID_FILE" ]]; then
    cid="$(cat "$CID_FILE")"
    source="selected_file"
    config_mode="$(doctor_file_mode "$CID_FILE")"
    doctor_record "$results" pass "customer selection" "$cid from $CID_FILE (mode $config_mode)"
  else
    doctor_record "$results" fail "customer selection" "none; run ngwaf use <customer_id>"
  fi

  if [[ "$token_present" == "true" && "$http_policy_ready" == "true" && -x "$(command -v curl 2>/dev/null || true)" ]]; then
    tmp="$(mktemp)"
    code="$(NGWAF_PROGRESS=never http_get_to_file "/tokens/self" "$tmp")"
    if [[ "$code" == 2* ]] && jq -e 'type == "object"' >/dev/null 2>&1 <"$tmp"; then
      scopes="$(jq -r '(.scope // "unknown") | if type == "array" then join(",") else tostring end' "$tmp")"
      doctor_record "$results" pass "token API access" "HTTP $code; scope=$scopes"
      api_ready=true
    else
      doctor_record "$results" fail "token API access" "GET /tokens/self returned HTTP $code or invalid JSON"
    fi
    rm -f "$tmp"
  else
    doctor_record "$results" warn "token API access" "skipped until curl, token, and valid HTTP settings are available"
  fi

  if [[ "$api_ready" == "true" && -n "$cid" ]]; then
    tmp="$(mktemp)"
    code="$(NGWAF_PROGRESS=never http_get_to_file "/customer/$(urlencode "$cid")" "$tmp")"
    returned_id="$(jq -r '.id // empty' "$tmp" 2>/dev/null || true)"
    name="$(jq -r '.name // empty' "$tmp" 2>/dev/null || true)"
    if [[ "$code" == 2* && "$returned_id" == "$cid" && -n "$name" ]]; then
      doctor_record "$results" pass "customer scope" "$name ($cid; source=$source)"
      customer_ready=true
    else
      doctor_record "$results" fail "customer scope" "selected $cid; API returned HTTP $code and id=${returned_id:-missing}"
    fi
    rm -f "$tmp"
  else
    doctor_record "$results" warn "customer scope" "skipped because token access or customer selection was not validated"
  fi

  if [[ "$customer_ready" == "true" ]]; then
    if workspace_body="$(
      NGWAF_PROGRESS=never get_all_pages "/ngwaf/v1/workspaces" \
        --data-urlencode "customer_id=$cid"
    )"; then
      count="$(jq '.data | length' <<<"$workspace_body")"
      invalid_workspaces="$(
        jq '[.data[] | select((.id // "") == "" or (.name // "") == "")] | length' \
          <<<"$workspace_body"
      )"
      duplicates="$(
        jq '[
          .data
          | sort_by((.name // "") | ascii_downcase)
          | group_by((.name // "") | ascii_downcase)[]
          | select(length > 1)
          | map({id, name})
        ]' <<<"$workspace_body"
      )"
      if [[ "$invalid_workspaces" == "0" ]]; then
        doctor_record "$results" pass "workspace inventory" \
          "$count workspace(s), $(jq '.meta.pages_fetched // 1' <<<"$workspace_body") page(s), complete"
      else
        doctor_record "$results" fail "workspace inventory" \
          "$invalid_workspaces workspace object(s) omitted an ID or name"
      fi
      if [[ "$(jq 'length' <<<"$duplicates")" == "0" ]]; then
        doctor_record "$results" pass "workspace names" "no case-insensitive exact-name collisions"
      else
        doctor_record "$results" fail "workspace names" \
          "ambiguous names: $(jq -c '.' <<<"$duplicates")"
      fi
    else
      doctor_record "$results" fail "workspace inventory" "customer-scoped pagination failed"
    fi
  else
    doctor_record "$results" warn "workspace inventory" "skipped because customer scope was not validated"
  fi

  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  summary="$(
    jq -s --arg version "$VERSION" --arg generated_at "$generated_at" '
      . as $checks
      | {
          command: "doctor",
          tool_version: $version,
          generated_at: $generated_at,
          status: (
            if any($checks[]; .status == "fail") then "fail"
            elif any($checks[]; .status == "warn") then "warn"
            else "pass"
            end
          ),
          checks: $checks
        }
    ' "$results"
  )"
  rm -f "$results"
  overall="$(jq -r '.status' <<<"$summary")"

  if [[ "$format" == "--json" ]]; then
    jq . <<<"$summary"
  else
    doctor_render_human "$summary"
  fi

  [[ "$overall" != "fail" ]]
}
