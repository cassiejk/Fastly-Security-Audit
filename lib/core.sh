# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

die() {
  printf 'ngwaf: %s\n' "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

require curl
require jq

case "${1:-help}" in
  help|-h|--help|version)
    ;;
  *)
    [[ -n "${FASTLY_API_TOKEN:-}" ]] ||
      die 'FASTLY_API_TOKEN is not set'
    ;;
esac

urlencode() {
  jq -rn --arg v "$1" '$v | @uri'
}

get() {
  local path="$1"
  shift

  local tmp code
  tmp="$(mktemp)"

  code="$(
    curl -sS -G \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -o "$tmp" \
      -w '%{http_code}' \
      -H "Fastly-Key: $FASTLY_API_TOKEN" \
      -H "Accept: application/json" \
      "$@" \
      "$API_BASE$path"
  )" || {
    rm -f "$tmp"
    die "curl request failed"
  }

  case "$code" in
    2*)
      cat "$tmp"
      ;;
    *)
      printf 'Fastly API returned HTTP %s\n' "$code" >&2
      jq . "$tmp" 2>/dev/null >&2 || cat "$tmp" >&2
      rm -f "$tmp"
      exit 1
      ;;
  esac

  rm -f "$tmp"
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

  local code
  code="$(
    curl -sS -G \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -o "$outfile" \
      -w '%{http_code}' \
      -H "Fastly-Key: $FASTLY_API_TOKEN" \
      -H "Accept: application/json" \
      "$@" \
      "$API_BASE$path"
  )" || {
    printf '000\n'
    return
  }

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

workspace_path() {
  printf '/ngwaf/v1/workspaces/%s' "$(urlencode "$1")"
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

