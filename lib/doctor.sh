# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

# Append one machine-readable check result to the temporary doctor stream.
# The final report is assembled from these records after every check has run.
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

# Return a portable numeric file mode. macOS and GNU stat use different flags,
# so keep that difference hidden from the diagnostic checks below.
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

# Return a command's first --version line when the command supports it. Verbose
# diagnostics use this to make support/debug output more self-contained.
doctor_command_version() {
  local command="$1"
  local output

  [[ -n "$command" ]] || return 0
  if [[ "$command" != */* ]]; then
    command -v "$command" >/dev/null 2>&1 || return 0
  fi

  case "$command" in
    *bash|*curl|*jq)
      output="$("$command" --version 2>/dev/null || true)"
      printf '%s\n' "${output%%$'\n'*}"
      ;;
  esac
}

doctor_render_human() {
  local summary="$1"
  local status check detail label

  ui_heading "${PROGRAM_NAME:-ngwaf} doctor"
  printf 'Version %s · read-only diagnostics\n\n' "$VERSION"

  while IFS=$'\t' read -r status check detail; do
    ui_status "$status" "$check" "$detail"
  done < <(jq -r '.checks[] | [.status, .check, .detail] | @tsv' <<<"$summary")

  printf '\nOverall: %s (%s passed, %s warnings, %s failures)\n' \
    "$(jq -r '.status | ascii_upcase' <<<"$summary")" \
    "$(jq '[.checks[] | select(.status == "pass")] | length' <<<"$summary")" \
    "$(jq '[.checks[] | select(.status == "warn")] | length' <<<"$summary")" \
    "$(jq '[.checks[] | select(.status == "fail")] | length' <<<"$summary")"

  [[ "$(jq -r '.verbose // false' <<<"$summary")" == "true" ]] || return 0

  printf '\nTroubleshooting details:\n'
  while IFS=$'\t' read -r label detail; do
    printf '  %-24s %s\n' "$label" "$detail"
  done < <(
    jq -r '
      def yn($v): if $v then "yes" else "no" end;
      def val($v): if $v == null or $v == "" then "-" else ($v | tostring) end;

      .diagnostics as $d
      | [
          ["Program", $d.program.name + " " + $d.program.version],
          ["Script root", $d.program.script_root],
          ["Installed command", val($d.program.install_path)],
          ["Install symlink", val($d.program.install_symlink_target)],
          ["Config directory", $d.config.dir + " (exists=" + yn($d.config.dir_exists) + ", writable=" + yn($d.config.dir_writable) + ")"],
          ["Customer ID file", $d.config.customer_id_file + " (exists=" + yn($d.config.customer_id_file_exists) + ", readable=" + yn($d.config.customer_id_file_readable) + ", mode=" + val($d.config.customer_id_file_mode) + ")"],
          ["Customer source", val($d.customer.selection_source)],
          ["FASTLY_API_TOKEN", if $d.environment.fastly_api_token_set then "set; value hidden" else "not set" end],
          ["API base", $d.http.api_base],
          ["HTTP policy", "connect=" + ($d.http.policy.connect_timeout_seconds | tostring) + "s transfer=" + ($d.http.policy.max_time_seconds | tostring) + "s retries=" + ($d.http.policy.retries | tostring) + " retry-window=" + ($d.http.policy.retry_max_time_seconds | tostring) + "s"],
          ["curl", val($d.commands.curl.path) + " / " + val($d.commands.curl.version)],
          ["jq", val($d.commands.jq.path) + " / " + val($d.commands.jq.version)],
          ["bash", val($d.commands.bash.path) + " / " + val($d.commands.bash.version)],
          ["Token probe", "HTTP " + val($d.api_probes.token.http_status) + "; json=" + yn($d.api_probes.token.json_valid)],
          ["Customer probe", "HTTP " + val($d.api_probes.customer.http_status) + "; id=" + val($d.api_probes.customer.returned_id)],
          ["Workspace probe", "count=" + val($d.api_probes.workspaces.returned_count) + "; pages=" + val($d.api_probes.workspaces.pages_fetched) + "; invalid=" + val($d.api_probes.workspaces.invalid_objects) + "; duplicate groups=" + val($d.api_probes.workspaces.duplicate_name_groups)]
        ][]
      | @tsv
    ' <<<"$summary"
  )
}

cmd_doctor() {
  local usage='usage: ngwaf doctor [--json] [--verbose]'
  local format="human"
  local verbose=false

  while (( $# > 0 )); do
    case "$1" in
      --json)
        format="json"
        shift
        ;;
      --verbose|-v)
        verbose=true
        shift
        ;;
      *)
        die "$usage"
        ;;
    esac
  done

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s doctor: FAIL: jq is not installed; JSON diagnostics cannot run\n' \
      "${PROGRAM_NAME:-ngwaf}" >&2
    return 1
  fi

  local results summary overall generated_at
  local token_present=false cid="" source="" api_ready=false customer_ready=false
  local http_policy_ready=false
  local tmp code scopes workspace_body duplicates count
  local returned_id="" name="" invalid_workspaces=""
  local config_mode install_path
  local token_code="" token_json_valid=false customer_code="" customer_json_valid=false
  local workspace_count="" workspace_pages="" duplicate_groups=""
  local config_dir_exists=false config_dir_readable=false config_dir_writable=false
  local cid_file_exists=false cid_file_readable=false cid_file_mode=""
  local install_symlink_target="" curl_path="" curl_version="" jq_path="" jq_version=""
  local bash_path="" bash_version_short="" column_path=""
  local runtime_bash_path runtime_bash_version runtime_bash_version_line
  local runtime_bash_supported=false
  results="$(mktemp)"
  : >"$results"

  runtime_bash_path="$(ngwaf_current_bash_executable)"
  runtime_bash_version="${BASH_VERSION:-unknown}"
  runtime_bash_version_line="$(doctor_command_version "$runtime_bash_path")"
  [[ -n "$runtime_bash_version_line" ]] || runtime_bash_version_line="$runtime_bash_version"
  bash_path="$runtime_bash_path"
  bash_version_short="$runtime_bash_version_line"

  if ngwaf_bash_version_at_least "${BASH_VERSINFO[0]:-0}" "${BASH_VERSINFO[1]:-0}"; then
    runtime_bash_supported=true
    doctor_record "$results" pass "bash" \
      "$runtime_bash_path; $runtime_bash_version_line; minimum $NGWAF_MIN_BASH_VERSION"
  else
    doctor_record "$results" fail "bash" \
      "$runtime_bash_path; $runtime_bash_version_line; minimum $NGWAF_MIN_BASH_VERSION"
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

  install_path="$(command -v "${PROGRAM_NAME:-ngwaf}" 2>/dev/null || true)"
  if [[ -n "$install_path" ]]; then
    doctor_record "$results" pass "installed command" "$install_path"
    if [[ -L "$install_path" ]]; then
      install_symlink_target="$(readlink "$install_path" 2>/dev/null || true)"
    fi
  else
    doctor_record "$results" warn "installed command" \
      "${PROGRAM_NAME:-ngwaf} is not discoverable through PATH"
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
    if [[ "${PROGRAM_NAME:-ngwaf}" == "fastly-audit" ]]; then
      doctor_record "$results" fail "customer selection" \
        "none; run fastly-audit customer use <customer_id>"
    else
      doctor_record "$results" fail "customer selection" \
        "none; run ngwaf use <customer_id>"
    fi
  fi

  if [[ "$token_present" == "true" && "$http_policy_ready" == "true" && -x "$(command -v curl 2>/dev/null || true)" ]]; then
    tmp="$(mktemp)"
    code="$(NGWAF_PROGRESS=never http_get_to_file "/tokens/self" "$tmp")"
    token_code="$code"
    if [[ "$code" == 2* ]] && jq -e 'type == "object"' >/dev/null 2>&1 <"$tmp"; then
      token_json_valid=true
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
    customer_code="$code"
    if jq -e 'type == "object"' >/dev/null 2>&1 <"$tmp"; then
      customer_json_valid=true
    fi
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
      workspace_count="$count"
      workspace_pages="$(jq -r '.meta.pages_fetched // 1' <<<"$workspace_body")"
      duplicate_groups="$(jq 'length' <<<"$duplicates")"
    else
      doctor_record "$results" fail "workspace inventory" "customer-scoped pagination failed"
    fi
  else
    doctor_record "$results" warn "workspace inventory" "skipped because customer scope was not validated"
  fi

  if [[ "$verbose" == "true" ]]; then
    [[ -d "$CONFIG_DIR" ]] && config_dir_exists=true
    [[ -r "$CONFIG_DIR" ]] && config_dir_readable=true
    [[ -w "$CONFIG_DIR" ]] && config_dir_writable=true
    [[ -e "$CID_FILE" ]] && cid_file_exists=true
    [[ -r "$CID_FILE" ]] && cid_file_readable=true
    if [[ "$cid_file_exists" == "true" ]]; then
      cid_file_mode="$(doctor_file_mode "$CID_FILE")"
    fi

    curl_path="$(command -v curl 2>/dev/null || true)"
    jq_path="$(command -v jq 2>/dev/null || true)"
    column_path="$(command -v column 2>/dev/null || true)"
    curl_version="$(doctor_command_version curl)"
    jq_version="$(doctor_command_version jq)"
  fi

  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  summary="$(
    jq -s \
      --arg version "$VERSION" \
      --arg generated_at "$generated_at" \
      --argjson verbose "$verbose" \
      --arg program "${PROGRAM_NAME:-ngwaf}" \
      --arg usage_program "${USAGE_PROGRAM:-${PROGRAM_NAME:-ngwaf}}" \
      --arg ngwaf_root "$NGWAF_ROOT" \
      --arg runtime_bash_path "$runtime_bash_path" \
      --arg runtime_bash_version "$runtime_bash_version" \
      --arg runtime_bash_version_line "$runtime_bash_version_line" \
      --arg runtime_bash_required "$NGWAF_MIN_BASH_VERSION" \
      --argjson runtime_bash_supported "$runtime_bash_supported" \
      --arg install_path "$install_path" \
      --arg install_symlink_target "$install_symlink_target" \
      --arg config_dir "$CONFIG_DIR" \
      --arg customer_id_file "$CID_FILE" \
      --argjson config_dir_exists "$config_dir_exists" \
      --argjson config_dir_readable "$config_dir_readable" \
      --argjson config_dir_writable "$config_dir_writable" \
      --argjson cid_file_exists "$cid_file_exists" \
      --argjson cid_file_readable "$cid_file_readable" \
      --arg cid_file_mode "$cid_file_mode" \
      --argjson token_present "$token_present" \
      --argjson fastly_customer_id_set "$(if [[ -n "${FASTLY_CUSTOMER_ID:-}" ]]; then printf 'true'; else printf 'false'; fi)" \
      --arg customer_source "$source" \
      --arg selected_customer_id "$cid" \
      --arg api_base "$API_BASE" \
      --arg connect_timeout "$CURL_CONNECT_TIMEOUT" \
      --arg max_time "$CURL_MAX_TIME" \
      --arg retries "$CURL_RETRIES" \
      --arg retry_max_time "$CURL_RETRY_MAX_TIME" \
      --arg ngwaf_progress "${NGWAF_PROGRESS:-auto}" \
      --arg ngwaf_color "${NGWAF_COLOR:-auto}" \
      --argjson ngwaf_debug "$(if debug_enabled; then printf 'true'; else printf 'false'; fi)" \
      --arg curl_path "$curl_path" \
      --arg curl_version "$curl_version" \
      --arg jq_path "$jq_path" \
      --arg jq_version "$jq_version" \
      --arg bash_path "$bash_path" \
      --arg bash_version "$bash_version_short" \
      --arg column_path "$column_path" \
      --arg token_code "$token_code" \
      --argjson token_json_valid "$token_json_valid" \
      --arg customer_code "$customer_code" \
      --argjson customer_json_valid "$customer_json_valid" \
      --arg returned_id "$returned_id" \
      --arg returned_name "$name" \
      --arg workspace_count "$workspace_count" \
      --arg workspace_pages "$workspace_pages" \
      --arg invalid_workspaces "$invalid_workspaces" \
      --arg duplicate_groups "$duplicate_groups" '
      def empty_to_null($v): if $v == "" then null else $v end;
      def number_or_null($v): if $v == "" then null else (try ($v | tonumber) catch null) end;
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
          runtime: {
            bash: {
              executable: $runtime_bash_path,
              version: $runtime_bash_version,
              version_line: $runtime_bash_version_line,
              minimum_version: $runtime_bash_required,
              supported: $runtime_bash_supported
            }
          },
          checks: $checks
        }
      + (
          if $verbose then
            {
              verbose: true,
              diagnostics: {
                safety: {
                  read_only: true,
                  fastly_api_token_value_displayed: false
                },
                program: {
                  name: $program,
                  usage_program: $usage_program,
                  version: $version,
                  script_root: $ngwaf_root,
                  install_path: empty_to_null($install_path),
                  install_symlink_target: empty_to_null($install_symlink_target)
                },
                commands: {
                  bash: {
                    path: empty_to_null($bash_path),
                    version: empty_to_null($bash_version)
                  },
                  curl: {
                    path: empty_to_null($curl_path),
                    version: empty_to_null($curl_version)
                  },
                  jq: {
                    path: empty_to_null($jq_path),
                    version: empty_to_null($jq_version)
                  },
                  column: {
                    path: empty_to_null($column_path)
                  }
                },
                config: {
                  dir: $config_dir,
                  dir_exists: $config_dir_exists,
                  dir_readable: $config_dir_readable,
                  dir_writable: $config_dir_writable,
                  customer_id_file: $customer_id_file,
                  customer_id_file_exists: $cid_file_exists,
                  customer_id_file_readable: $cid_file_readable,
                  customer_id_file_mode: empty_to_null($cid_file_mode)
                },
                environment: {
                  fastly_api_token_set: $token_present,
                  fastly_api_token_value_displayed: false,
                  fastly_customer_id_set: $fastly_customer_id_set,
                  ngwaf_progress: $ngwaf_progress,
                  ngwaf_color: $ngwaf_color,
                  ngwaf_debug: $ngwaf_debug
                },
                customer: {
                  selected_customer_id: empty_to_null($selected_customer_id),
                  selection_source: empty_to_null($customer_source)
                },
                http: {
                  api_base: $api_base,
                  policy: {
                    connect_timeout_seconds: number_or_null($connect_timeout),
                    max_time_seconds: number_or_null($max_time),
                    retries: number_or_null($retries),
                    retry_max_time_seconds: number_or_null($retry_max_time)
                  }
                },
                api_probes: {
                  token: {
                    path: "/tokens/self",
                    http_status: empty_to_null($token_code),
                    json_valid: $token_json_valid
                  },
                  customer: {
                    path: (if $selected_customer_id == "" then null else "/customer/{selected_customer_id}" end),
                    http_status: empty_to_null($customer_code),
                    json_valid: $customer_json_valid,
                    returned_id: empty_to_null($returned_id),
                    returned_name: empty_to_null($returned_name)
                  },
                  workspaces: {
                    path: "/ngwaf/v1/workspaces",
                    returned_count: number_or_null($workspace_count),
                    pages_fetched: number_or_null($workspace_pages),
                    invalid_objects: number_or_null($invalid_workspaces),
                    duplicate_name_groups: number_or_null($duplicate_groups)
                  }
                }
              }
            }
          else
            {}
          end
        )
    ' "$results"
  )"
  rm -f "$results"
  overall="$(jq -r '.status' <<<"$summary")"

  if [[ "$format" == "json" ]]; then
    jq . <<<"$summary"
  else
    doctor_render_human "$summary"
  fi

  [[ "$overall" != "fail" ]]
}
