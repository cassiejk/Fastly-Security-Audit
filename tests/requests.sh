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
limit="25"
page=""
args_file="${NGWAF_TEST_CURL_ARGS:?}"
{
  printf '%s\n' '--- request ---'
  printf '%s\n' "$@"
} >>"$args_file"

while (( $# > 0 )); do
  case "$1" in
    -o)
      outfile="$2"
      shift 2
      ;;
    --data-urlencode)
      case "$2" in
        limit=*) limit="${2#limit=}" ;;
        page=*) page="${2#page=}" ;;
      esac
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

write_success_requests() {
  jq -n --argjson limit "$limit" '{
    meta: {total: 3},
    data: ([
      {
        id: "req-1",
        timestamp: "2026-09-08T12:00:00Z",
        method: "GET",
        path: "/login",
        uri: "/login?x=1",
        remote_ip: "203.0.113.10",
        user_agent: "curl/8.0",
        server_hostname: "www.example.com",
        remote_hostname: "client.example.net",
        response_code: 406,
        agent_response_code: 406,
        workspace_id: "production",
        request_headers: [{name: "Host", value: "www.example.com"}],
        signals: [
          {type: "SQLI", detector: "libinjection", location: "QUERYSTRING"},
          {type: "BLOCKED"}
        ]
      },
      {
        id: "req-2",
        timestamp: "2026-09-08T12:01:00Z",
        method: "POST",
        path: "/checkout",
        uri: "/checkout",
        remote_ip: "203.0.113.11",
        request_headers: [
          {name: "Host", value: "shop.example.com"},
          {name: "User-Agent", value: "Mozilla/5.0"}
        ],
        response_code: 200,
        workspace_id: "production",
        signals: [{type: "SQLI"}]
      },
      {
        id: "req-3",
        timestamp: "2026-09-08T12:02:00Z",
        method: "GET",
        path: "/search",
        remote_ip: "203.0.113.12",
        response_code: 403,
        signals: [{type: "XSS"}]
      }
    ] | .[0:$limit])
  }' >"$outfile"
}

write_paged_requests() {
  local page_num="${page:-1}"
  local start end
  start=$(( ((page_num - 1) * 100) + 1 ))
  end=$(( start + limit - 1 ))
  (( start > 125 )) && end=$(( start - 1 ))
  (( end > 125 )) && end=125

  jq -n \
    --argjson start "$start" \
    --argjson end "$end" \
    '{
      meta: {total: 125},
      data: [
        range($start; ($end + 1)) as $i
        | {
            id: ("req-" + ($i | tostring)),
            timestamp: "2026-09-08T12:00:00Z",
            method: "GET",
            path: ("/item/" + ($i | tostring)),
            uri: ("/item/" + ($i | tostring)),
            remote_ip: "203.0.113.20",
            user_agent: "test-agent",
            server_hostname: "www.example.com",
            response_code: 406,
            workspace_id: "production",
            signals: [{type: "SQLI"}]
          }
      ]
    }' >"$outfile"
}

case "$url" in
  */customer/test-customer)
    printf '%s\n' '{"id":"test-customer","name":"Test Customer"}' >"$outfile"
    printf '200'
    ;;
  */ngwaf/v1/workspaces)
    printf '%s\n' '{"meta":{"total":1},"data":[{"id":"production","name":"Production"}]}' >"$outfile"
    printf '200'
    ;;
  */ngwaf/v1/workspaces/production/requests)
    case "${NGWAF_TEST_REQUEST_MODE:-success}" in
      success)
        write_success_requests
        printf '200'
        ;;
      paged)
        write_paged_requests
        printf '200'
        ;;
      malformed)
        printf '%s\n' '{"meta":{"total":2},"data":{"unexpected":true}}' >"$outfile"
        printf '200'
        ;;
      *)
        printf '%s\n' '{"error":"unknown test mode"}' >"$outfile"
        printf '500'
        ;;
    esac
    ;;
  *)
    printf '%s\n' '{"error":"unhandled fake endpoint"}' >"$outfile"
    printf '404'
    ;;
esac
FAKE_CURL
chmod +x "$TEST_TMP/bin/curl"

export PATH="$TEST_TMP/bin:$PATH"
export FASTLY_API_TOKEN="test-token"
export FASTLY_CUSTOMER_ID="test-customer"
export NGWAF_PROGRESS=never
export NGWAF_COLOR=never
export NGWAF_CURL_RETRIES=0
export NGWAF_TEST_CURL_ARGS="$TEST_TMP/curl-args"
: >"$NGWAF_TEST_CURL_ARGS"

"$ROOT/fastly-audit" ngwaf help >"$TEST_TMP/help"
grep -F "requests <workspace> '<query>' [days]" "$TEST_TMP/help" >/dev/null
grep -F "[--format auto|json|csv]" "$TEST_TMP/help" >/dev/null

output="$(
  "$ROOT/fastly-audit" ngwaf requests \
    Production \
    'rule:abc123 tag:SQLI' \
    7 \
    --limit 2 \
    --format json \
    2>"$TEST_TMP/stderr"
)"
jq -e '
  .customer == "Test Customer"
  and .customer_id == "test-customer"
  and .workspace == "Production"
  and .workspace_id == "production"
  and .workspace_input == "Production"
  and .days == 7
  and .query == "ruleid:abc123 tag:SQLI"
  and .requested_query == "rule:abc123 tag:SQLI"
  and .query_normalized == true
  and .limit == 2
  and .total_matches == 3
  and .rows_returned == 2
  and .count_scope == "retained_searchable_request_records"
  and .window.type == "rolling"
  and .window.ingestion_buffer_seconds == 300
  and ((.window.until_epoch - .window.from_epoch) == (7 * 86400))
  and .provenance.endpoint == "GET /ngwaf/v1/workspaces/{workspace_id}/requests"
  and .provenance.data_class == "retained_request_search"
  and .provenance.aggregation == "response.data"
  and .provenance.rows_requested == 2
  and .provenance.rows_returned == 2
  and .provenance.pagination == "single_request"
  and .provenance.missing_data_policy == "fail_closed"
  and .requests[0].timestamp == "2026-09-08T12:00:00Z"
  and .requests[0].request_id == "req-1"
  and .requests[0].host == "www.example.com"
  and .requests[0].method == "GET"
  and .requests[0].path == "/login"
  and .requests[0].uri == "/login?x=1"
  and .requests[0].source_ip == "203.0.113.10"
  and .requests[0].user_agent == "curl/8.0"
  and .requests[0].response_code == 406
  and .requests[0].agent_response_code == 406
  and .requests[0].signal_names == ["SQLI", "BLOCKED"]
  and .requests[0].raw.id == "req-1"
  and .requests[1].host == "shop.example.com"
  and .requests[1].user_agent == "Mozilla/5.0"
' >/dev/null <<<"$output"

grep -F 'fastly-audit: customer scope: Test Customer (test-customer; source=environment)' "$TEST_TMP/stderr" >/dev/null
grep -F 'fastly-audit: workspace scope: Production (production; resolved_by=name)' "$TEST_TMP/stderr" >/dev/null
grep -F 'normalized search key rule: to ruleid:' "$TEST_TMP/stderr" >/dev/null
grep -F 'https://api.fastly.com/ngwaf/v1/workspaces/production/requests' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'customer_id=test-customer' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'limit=2' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -E '^q=from:[0-9]+ until:[0-9]+ ruleid:abc123 tag:SQLI$' "$NGWAF_TEST_CURL_ARGS" >/dev/null

: >"$NGWAF_TEST_CURL_ARGS"
auto_output="$("$ROOT/ngwaf" requests Production 'tag:SQLI' 2>"$TEST_TMP/auto-err")"
jq -e '
  .limit == 25
  and .rows_returned == 3
  and .requests[2].request_id == "req-3"
' >/dev/null <<<"$auto_output"
grep -F 'limit=25' "$NGWAF_TEST_CURL_ARGS" >/dev/null

csv="$("$ROOT/ngwaf" requests Production 'tag:SQLI' --limit 1 --format csv 2>"$TEST_TMP/csv-err")"
printf '%s\n' "$csv" | sed -n '1p' | grep -F '"customer","customer_id","workspace","workspace_id"' >/dev/null
printf '%s\n' "$csv" | sed -n '2p' | grep -F '"Test Customer","test-customer","Production","production"' >/dev/null
printf '%s\n' "$csv" | sed -n '2p' | grep -F '"SQLI;BLOCKED"' >/dev/null

output_file="$TEST_TMP/requests.json"
"$ROOT/ngwaf" requests production 'tag:XSS' \
  --limit 1 \
  --output "$output_file" \
  >"$TEST_TMP/output-stdout" \
  2>"$TEST_TMP/output-stderr"
[[ ! -s "$TEST_TMP/output-stdout" ]]
[[ -r "$output_file" ]]
[[ "$(test_file_mode "$output_file")" == "600" ]]
jq -e '.rows_returned == 1 and .requests[0].request_id == "req-1"' >/dev/null "$output_file"
grep -F 'wrote 1 request record to' "$TEST_TMP/output-stderr" >/dev/null

csv_output_file="$TEST_TMP/requests.CSV"
"$ROOT/ngwaf" requests production 'tag:SQLI' \
  --limit 1 \
  --format auto \
  --output "$csv_output_file" \
  >"$TEST_TMP/csv-output-stdout" \
  2>"$TEST_TMP/csv-output-stderr"
[[ ! -s "$TEST_TMP/csv-output-stdout" ]]
printf '%s\n' "$(sed -n '1p' "$csv_output_file")" | grep -F '"customer","customer_id","workspace","workspace_id"' >/dev/null
printf '%s\n' "$(sed -n '2p' "$csv_output_file")" | grep -F '"Test Customer","test-customer","Production","production"' >/dev/null
grep -F 'wrote 1 request record to' "$TEST_TMP/csv-output-stderr" >/dev/null

conflict_output_file="$TEST_TMP/conflict.csv"
"$ROOT/ngwaf" requests production 'tag:XSS' \
  --limit 1 \
  --format json \
  --output "$conflict_output_file" \
  >"$TEST_TMP/conflict-stdout" \
  2>"$TEST_TMP/conflict-stderr"
[[ ! -s "$TEST_TMP/conflict-stdout" ]]
jq -e '.rows_returned == 1 and .requests[0].request_id == "req-1"' >/dev/null "$conflict_output_file"
grep -F 'warning: --format json overrides .csv output extension' "$TEST_TMP/conflict-stderr" >/dev/null

if "$ROOT/ngwaf" requests production 'tag:XSS' --limit 1 --output "$output_file" >"$TEST_TMP/out" 2>"$TEST_TMP/overwrite-err"; then
  printf 'requests test: existing output file was overwritten\n' >&2
  exit 1
fi
grep -F 'refusing to overwrite existing requests output' "$TEST_TMP/overwrite-err" >/dev/null

if "$ROOT/ngwaf" requests Production 'tag:SQLI' --limit 0 >"$TEST_TMP/out" 2>"$TEST_TMP/limit-err"; then
  printf 'requests test: invalid limit unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'request limit must be at least 1' "$TEST_TMP/limit-err" >/dev/null

if "$ROOT/ngwaf" requests Production 'tag:SQLI' --limit -5 >"$TEST_TMP/out" 2>"$TEST_TMP/negative-limit-err"; then
  printf 'requests test: negative limit unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'request limit must be at least 1' "$TEST_TMP/negative-limit-err" >/dev/null

if "$ROOT/ngwaf" requests Production 'tag:SQLI' --limit abc >"$TEST_TMP/out" 2>"$TEST_TMP/string-limit-err"; then
  printf 'requests test: string limit unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'request limit must be a positive integer' "$TEST_TMP/string-limit-err" >/dev/null

if "$ROOT/ngwaf" requests Production 'tag:SQLI' --format yaml >"$TEST_TMP/out" 2>"$TEST_TMP/format-err"; then
  printf 'requests test: invalid format unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'requests format must be auto, json, or csv' "$TEST_TMP/format-err" >/dev/null

export NGWAF_TEST_REQUEST_MODE=malformed
if "$ROOT/ngwaf" requests Production 'tag:SQLI' --limit 2 >"$TEST_TMP/out" 2>"$TEST_TMP/malformed-err"; then
  printf 'requests test: malformed response unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'request search returned an unexpected response' "$TEST_TMP/malformed-err" >/dev/null

export NGWAF_TEST_REQUEST_MODE=paged
: >"$NGWAF_TEST_CURL_ARGS"
paged="$("$ROOT/ngwaf" requests Production 'tag:SQLI' --limit 125 2>"$TEST_TMP/paged-err")"
jq -e '
  .limit == 125
  and .total_matches == 125
  and .rows_returned == 125
  and .meta.pages_fetched == 2
  and .provenance.pagination == "bounded_page_loop"
  and .provenance.pages_fetched == 2
  and .requests[0].request_id == "req-1"
  and .requests[124].request_id == "req-125"
' >/dev/null <<<"$paged"
grep -F 'page=1' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'page=2' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'limit=100' "$NGWAF_TEST_CURL_ARGS" >/dev/null
grep -F 'limit=25' "$NGWAF_TEST_CURL_ARGS" >/dev/null

printf 'requests: OK\n'
