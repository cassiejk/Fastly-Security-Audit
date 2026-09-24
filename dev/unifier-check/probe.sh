#!/usr/bin/env bash
# Read-only, standalone employee audit. No account writes.
set -euo pipefail
set +x
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
customer_id=''
corp=''
show_identities=false

usage() {
  printf 'usage: %s --customer-id ID --corp SLUG [--show-identities]\n' "$0" >&2
  exit 2
}

while (( $# )); do
  case "$1" in
    --show-identities)
      show_identities=true
      shift
      ;;
    --customer-id|--corp)
      (( $# >= 2 )) || usage
      case "$1" in
        --customer-id) customer_id="$2" ;;
        --corp) corp="$2" ;;
      esac
      shift 2
      ;;
    --help|-h)
      printf 'usage: %s --customer-id ID --corp SLUG [--show-identities]\n' "$0"
      exit 0
      ;;
    *) usage ;;
  esac
done

[[ "$customer_id" =~ ^[A-Za-z0-9]+$ ]] || usage
[[ "$corp" =~ ^[a-z0-9_.-]+$ ]] || usage
if [[ "$show_identities" == true ]]; then
  if [[ ! -t 0 || ! -t 1 || ! -t 2 ]]; then
    printf '%s\n' '--show-identities requires an interactive terminal on stdin, stdout, and stderr; no requests were made' >&2
    exit 2
  fi
fi
command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 2; }
command -v curl >/dev/null || { printf 'curl is required\n' >&2; exit 2; }

# A quote, backslash, or newline could alter curl config supplied on stdin.
safe_header_value() {
  [[ "$1" != *$'\r'* && "$1" != *$'\n'* && "$1" != *\"* && "$1" != *\\* ]]
}

mkdir -p "$script_dir/results"
run_dir="$(mktemp -d "$script_dir/results/run.XXXXXX")"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/unifier-check.XXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT

# Secrets travel to curl on stdin, not in argv, logs, or result files.
# Curl's response body and stderr remain in a private temporary directory.
request_json() {
  local auth="$1" url="$2" body="$3"
  shift 3
  local code rc=0
  if code="$(
    {
      printf 'header = "Accept: application/json"\n'
      case "$auth" in
        ngwaf)
          printf 'header = "Cookie: dstoken=%s; VouchCookie=%s"\n' \
            "$FASTLY_DSTOKEN" "$FASTLY_VOUCH_COOKIE"
          ;;
        fastly)
          printf 'header = "Fastly-Key: %s"\n' "$FASTLY_API_TOKEN"
          ;;
      esac
    } | curl --silent --show-error --get --proto '=https' \
      --connect-timeout 5 --max-time 60 --config - \
      --output "$body" --write-out '%{http_code}' \
      "$@" "$url" 2>"$tmp_dir/curl.err"
  )"; then
    rc=0
  else
    rc=$?
  fi
  REQUEST_HTTP_STATUS="${code:-000}"
  REQUEST_CURL_EXIT="$rc"
}

response_shape() {
  local file="$1"
  if [[ -s "$file" ]] && jq -e . "$file" >/dev/null 2>&1; then
    jq -c '{type: type, fields: (if type == "object" then keys_unsorted else null end)}' "$file"
  else
    printf 'null\n'
  fi
}

http_failure_kind() {
  case "$1" in
    401|403) printf 'access_failure\n' ;;
    301|302|303|307|308) printf 'auth_or_location_redirect\n' ;;
    *) printf 'http_failure\n' ;;
  esac
}

write_failure() {
  local file="$1" endpoint="$2" outcome="$3" reason="$4"
  local http_status="${5:-null}" curl_exit="${6:-null}" body="${7:-}"
  local shape='null'
  [[ -z "$body" ]] || shape="$(response_shape "$body")"
  jq -n --arg endpoint "$endpoint" --arg outcome "$outcome" \
    --arg reason "$reason" --arg status "$http_status" --arg exit_code "$curl_exit" \
    --argjson response_shape "$shape" \
    '{endpoint: $endpoint, outcome: $outcome, reason: $reason,
      http_status: (if $status == "null" then null else $status end),
      curl_exit: (if $exit_code == "null" then null else ($exit_code | tonumber) end),
      response_shape: $response_shape, completeness: "not_demonstrated"}' >"$file"
}

ngwaf_result="$run_dir/ngwaf-users.json"
fastly_result="$run_dir/fastly-users.json"
roles_result="$run_dir/iam-roles.json"
ngwaf_ok=false
fastly_ok=false
roles_ok=true
roles_required=false

internal_base="${FASTLY_NGWAF_INTERNAL_API_BASE:-https://sigsci-console-internal.secretcdn.net/api}"
[[ "$internal_base" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/api/?$ ]] || {
  printf 'FASTLY_NGWAF_INTERNAL_API_BASE must be an HTTPS /api base\n' >&2
  exit 2
}
internal_base="${internal_base%/}"
ngwaf_endpoint="GET $internal_base/v0/corps/{corpName}/users"
if [[ -z "${FASTLY_DSTOKEN:-}" || -z "${FASTLY_VOUCH_COOKIE:-}" ]]; then
  write_failure "$ngwaf_result" "$ngwaf_endpoint" missing_credential \
    'FASTLY_DSTOKEN and FASTLY_VOUCH_COOKIE are required for the internal NGWAF API'
elif ! safe_header_value "$FASTLY_DSTOKEN" || ! safe_header_value "$FASTLY_VOUCH_COOKIE"; then
  write_failure "$ngwaf_result" "$ngwaf_endpoint" invalid_credential_format \
    'NGWAF cookie contains a character unsafe for curl stdin config'
else
  ngwaf_raw="$tmp_dir/ngwaf-users.json"
  request_json ngwaf \
    "$internal_base/v0/corps/$corp/users" "$ngwaf_raw"
  if (( REQUEST_CURL_EXIT != 0 )); then
    write_failure "$ngwaf_result" "$ngwaf_endpoint" transport_failure \
      'curl could not complete the NGWAF request' "$REQUEST_HTTP_STATUS" "$REQUEST_CURL_EXIT" "$ngwaf_raw"
  elif [[ "$REQUEST_HTTP_STATUS" != 200 ]]; then
    write_failure "$ngwaf_result" "$ngwaf_endpoint" \
      "$(http_failure_kind "$REQUEST_HTTP_STATUS")" \
      'NGWAF API did not return HTTP 200; a failed request is not an empty list' \
      "$REQUEST_HTTP_STATUS" "$REQUEST_CURL_EXIT" "$ngwaf_raw"
  elif ! jq -e '
    type == "object" and (.data | type) == "array"
    and all(.data[];
      type == "object"
      and (.role == null or (.role | type) == "string")
      and (.status == null or (.status | type) == "string")
      and (.apiUser == null or (.apiUser | type) == "boolean"))
  ' "$ngwaf_raw" >/dev/null 2>&1; then
    write_failure "$ngwaf_result" "$ngwaf_endpoint" unexpected_shape \
      'HTTP 200 response was not an object with an array of user objects' \
      "$REQUEST_HTTP_STATUS" "$REQUEST_CURL_EXIT" "$ngwaf_raw"
  else
    jq --arg endpoint "$ngwaf_endpoint" '
      {
        endpoint: $endpoint,
        outcome: (if (.data | length) == 0 then "empty" else "retrieved" end),
        http_status: "200",
        response_shape: {type: type, fields: keys_unsorted},
        record_count: (.data | length),
        user_fields: ([.data[] | keys_unsorted[]] | unique),
        pagination: {
          fields: ([keys_unsorted[] | select(test("(?i)(total|next|page|limit|cursor)"))]),
          totalCount: (.totalCount // null),
          meta: (if (.meta | type) == "object" then {
            fields: (.meta | keys_unsorted), total: .meta.total,
            limit: .meta.limit, page: .meta.page,
            next_cursor_present: ((.meta.next_cursor // "") != "")
          } else null end),
          next_present: (.next != null)
        },
        completeness: "not_demonstrated",
        users: [.data[] | {
          fields: keys_unsorted,
          email_present: (.email | if type == "string" then length > 0 else false end),
          role: (.role // null), status: (.status // null),
          apiUser: (if has("apiUser") then .apiUser else null end),
          authStatus: (.authStatus // null), corpAuthType: (.corpAuthType // null)
        }]
      }
    ' "$ngwaf_raw" >"$ngwaf_result"
    ngwaf_ok=true
  fi
fi

# Keep NGWAF independent: a missing/failed Fastly credential does not skip it.
fastly_endpoint='GET https://api.fastly.com/customer/{customer_id}/users'
if [[ -z "${FASTLY_API_TOKEN:-}" ]]; then
  write_failure "$fastly_result" "$fastly_endpoint" missing_credential \
    'FASTLY_API_TOKEN is required for the Fastly API'
elif ! safe_header_value "$FASTLY_API_TOKEN"; then
  write_failure "$fastly_result" "$fastly_endpoint" invalid_credential_format \
    'Fastly token contains a character unsafe for curl stdin config'
elif ! FASTLY_CUSTOMER_ID="$customer_id" NGWAF_PROGRESS=never \
  "$repo_root/fastly-audit" customer show \
  >"$tmp_dir/customer.json" 2>"$tmp_dir/customer.err"; then
  write_failure "$fastly_result" "$fastly_endpoint" scope_validation_failure \
    'existing fastly-audit customer-scope check failed; user list was not requested'
elif ! jq -e --arg cid "$customer_id" '.id == $cid' "$tmp_dir/customer.json" >/dev/null 2>&1; then
  write_failure "$fastly_result" "$fastly_endpoint" scope_validation_failure \
    'selected customer did not match the customer-scope response'
else
  fastly_raw="$tmp_dir/fastly-users.json"
  request_json fastly "https://api.fastly.com/customer/$customer_id/users" "$fastly_raw"
  if (( REQUEST_CURL_EXIT != 0 )); then
    write_failure "$fastly_result" "$fastly_endpoint" transport_failure \
      'curl could not complete the Fastly request' "$REQUEST_HTTP_STATUS" "$REQUEST_CURL_EXIT" "$fastly_raw"
  elif [[ "$REQUEST_HTTP_STATUS" != 200 ]]; then
    write_failure "$fastly_result" "$fastly_endpoint" \
      "$(http_failure_kind "$REQUEST_HTTP_STATUS")" \
      'Fastly API did not return HTTP 200; a failed request is not an empty list' \
      "$REQUEST_HTTP_STATUS" "$REQUEST_CURL_EXIT" "$fastly_raw"
  elif ! jq -e '
    type == "array" and all(.[];
      type == "object"
      and (.role == null or (.role | type) == "string")
      and (.roles == null or
        ((.roles | type) == "array" and all(.roles[]; type == "string"))))
  ' \
    "$fastly_raw" >/dev/null 2>&1; then
    write_failure "$fastly_result" "$fastly_endpoint" unexpected_shape \
      'HTTP 200 response was not an array of user objects' \
      "$REQUEST_HTTP_STATUS" "$REQUEST_CURL_EXIT" "$fastly_raw"
  else
    jq --arg endpoint "$fastly_endpoint" --arg cid "$customer_id" '
      {
        endpoint: $endpoint,
        outcome: (if length == 0 then "empty"
                  elif any(.[]; .customer_id != $cid) then "scope_mismatch"
                  else "retrieved" end),
        http_status: "200",
        response_shape: {type: type}, record_count: length,
        user_fields: ([.[] | keys_unsorted[]] | unique),
        pagination: {fields: [], documented: false},
        completeness: "not_demonstrated",
        users: [.[] | {
          fields: keys_unsorted,
          login_present: (.login | if type == "string" then length > 0 else false end),
          login_looks_like_email: (.login | if type == "string"
            then test("^[^@[:space:]]+@[^@[:space:]]+$") else false end),
          customer_matches_selection: (.customer_id == $cid),
          role: (.role // null),
          roles: (if has("roles") then .roles else null end),
          deleted_at_present: has("deleted_at"),
          deleted_at_nonnull: (.deleted_at != null),
          locked: (if has("locked") then .locked else null end)
        }]
      }
    ' "$fastly_raw" >"$fastly_result"
    if [[ "$(jq -r '.outcome' "$fastly_result")" == scope_mismatch ]]; then
      fastly_ok=false
    else
      fastly_ok=true
      if jq -e 'any(.[]; (.roles | if type == "array" then length > 0 else false end))' \
        "$fastly_raw" >/dev/null; then
        roles_required=true
      fi
    fi
  fi
fi

if [[ "$roles_required" != true ]]; then
  jq -n '{endpoint: "GET https://api.fastly.com/iam/v1/roles",
    outcome: "not_required", reason: "no assigned Fastly role IDs require resolution"}' \
    >"$roles_result"
else
  roles_endpoint='GET https://api.fastly.com/iam/v1/roles'
  cursor=''
  pages=0
  seen_cursors="$tmp_dir/seen-cursors"
  : >"$seen_cursors"
  roles_ok=false
  while :; do
    pages=$((pages + 1))
    if (( pages > 100 )); then
      write_failure "$roles_result" "$roles_endpoint" pagination_failure \
        'IAM role pagination exceeded 100 pages'
      break
    fi
    role_raw="$tmp_dir/roles-$pages.json"
    query=(--data-urlencode 'limit=1000')
    [[ -z "$cursor" ]] || query+=(--data-urlencode "cursor=$cursor")
    request_json fastly 'https://api.fastly.com/iam/v1/roles' "$role_raw" "${query[@]}"
    if (( REQUEST_CURL_EXIT != 0 )); then
      write_failure "$roles_result" "$roles_endpoint" transport_failure \
        'curl could not complete an IAM roles page' "$REQUEST_HTTP_STATUS" "$REQUEST_CURL_EXIT" "$role_raw"
      break
    elif [[ "$REQUEST_HTTP_STATUS" != 200 ]]; then
      write_failure "$roles_result" "$roles_endpoint" \
        "$(http_failure_kind "$REQUEST_HTTP_STATUS")" \
        'IAM roles API did not return HTTP 200' \
        "$REQUEST_HTTP_STATUS" "$REQUEST_CURL_EXIT" "$role_raw"
      break
    elif ! jq -e '
      type == "object" and (.data | type) == "array"
      and all(.data[];
        type == "object"
        and (.id | type) == "string"
        and (.name | type) == "string")
    ' "$role_raw" >/dev/null 2>&1; then
      write_failure "$roles_result" "$roles_endpoint" unexpected_shape \
        'IAM roles page was not an object with an array of role objects' \
        "$REQUEST_HTTP_STATUS" "$REQUEST_CURL_EXIT" "$role_raw"
      break
    elif ! jq -e '
      ((.next_cursor // .meta.next_cursor // "") | type) == "string"
    ' "$role_raw" >/dev/null 2>&1; then
      write_failure "$roles_result" "$roles_endpoint" pagination_failure \
        'IAM roles cursor was not a string or null'
      break
    fi

    next="$(jq -r '.next_cursor // .meta.next_cursor // ""' "$role_raw")"
    [[ -n "$next" ]] || { roles_ok=true; break; }
    if grep -F -x -- "$next" "$seen_cursors" >/dev/null; then
      write_failure "$roles_result" "$roles_endpoint" pagination_failure \
        'IAM roles cursor repeated'
      break
    fi
    printf '%s\n' "$next" >>"$seen_cursors"
    cursor="$next"
  done

  if [[ "$roles_ok" == true ]]; then
    jq -s --slurpfile users "$fastly_raw" --arg endpoint "$roles_endpoint" '
      ([.[] | .data[] | select(.id != null) | .id] | unique) as $known
      | ([$users[0][] | .roles? | select(type == "array") | .[]] | unique) as $assigned
      | {
          endpoint: $endpoint,
          outcome: (if (($assigned - $known) | length) == 0
            then "retrieved" else "unresolved_role_ids" end),
          http_status: "200", pages_fetched: length,
          record_count: ([.[] | .data[]] | length),
          pagination: [.[] | {
            fields: keys_unsorted,
            meta_fields: (if (.meta | type) == "object"
              then (.meta | keys_unsorted) else [] end),
            returned_count: (.data | length),
            limit: (.limit // .meta.limit // null),
            total: (.total // .meta.total // null),
            next_cursor_present: ((.next_cursor // .meta.next_cursor // "") != "")
          }],
          completeness: "cursor_chain_exhausted_response_contract_unverified",
          assigned_role_ids: $assigned,
          unresolved_role_ids: ($assigned - $known),
          roles: [.[].data[] | {id, name, display_name}]
        }
    ' "$tmp_dir"/roles-*.json >"$roles_result"
    [[ "$(jq -r '.outcome' "$roles_result")" == retrieved ]] || roles_ok=false
  fi
fi

ngwaf_correlation="$tmp_dir/ngwaf-correlation.json"
fastly_correlation="$tmp_dir/fastly-correlation.json"
if [[ "$ngwaf_ok" == true ]]; then
  ngwaf_correlation="$ngwaf_raw"
else
  printf '{"data":[]}\n' >"$ngwaf_correlation"
fi
if [[ "$fastly_ok" == true ]]; then
  fastly_correlation="$fastly_raw"
else
  printf '[]\n' >"$fastly_correlation"
fi

correlate() {
  local reveal="$1"
  jq -n --from-file "$script_dir/correlate.jq" \
    --argjson show_identities "$reveal" \
    --arg customer_id "$customer_id" --arg corp "$corp" \
    --slurpfile ngwaf_raw "$ngwaf_correlation" \
    --slurpfile fastly_raw "$fastly_correlation" \
    --slurpfile ngwaf_report "$ngwaf_result" \
    --slurpfile fastly_report "$fastly_result" \
    --slurpfile roles_report "$roles_result"
}

correlate false >"$run_dir/correlation.json"

printf 'Sanitized results: %s\n' "$run_dir" >&2
jq -c 'del(.identities)' "$run_dir/correlation.json"
if [[ "$show_identities" == true ]]; then
  correlate true >&2
fi
if [[ "$ngwaf_ok" == true && "$fastly_ok" == true && "$roles_ok" == true ]]; then
  exit 0
fi
exit 1
