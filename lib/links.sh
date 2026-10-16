# shellcheck shell=bash
# Sourced by the fastly-audit entry point; do not execute directly.

manage_fastly_link_parse_url_json() {
  [[ $# -eq 2 ]] || die 'manage_fastly_link_parse_url_json requires <url> <resource-label>'

  local input="$1" label="$2" remainder authority resource path query=''
  local supplied_customer_id=''

  [[ -n "$input" ]] || die "$label URL must not be empty"
  [[ ! "$input" =~ [[:cntrl:]] ]] || die "$label URL contains invalid control characters"
  [[ "$input" == https://* ]] || die "$label URL must use HTTPS"

  remainder="${input#https://}"
  [[ "$remainder" == */* ]] || die "unsupported $label URL"
  authority="${remainder%%/*}"
  resource="/${remainder#*/}"

  [[ "${authority,,}" == 'manage.fastly.com' ]] ||
    die "$label URL must use manage.fastly.com without credentials or a port"
  [[ "$resource" != *'#'* ]] || die "$label URL fragments are not supported"

  if [[ "$resource" == *'?'* ]]; then
    path="${resource%%\?*}"
    query="${resource#*\?}"
    [[ "$query" != *'?'* ]] || die "$label URL contains an ambiguous query string"
    [[ -n "$query" ]] || die "$label URL contains an empty query string"
  else
    path="$resource"
  fi

  [[ "$path" != *'%'* ]] || die "URL-encoded $label paths are not supported"
  if [[ -n "$query" ]]; then
    [[ "$query" != *'&'* && "$query" != *';'* ]] ||
      die "$label URL contains duplicate or unexpected query parameters"
    [[ "$query" =~ ^customerId=([A-Za-z0-9][A-Za-z0-9._~-]*)$ ]] ||
      die "$label URL contains an unsupported or malformed query parameter"
    supplied_customer_id="${BASH_REMATCH[1]}"
  fi

  jq -n \
    --arg path "$path" \
    --arg supplied_customer_id "$supplied_customer_id" \
    '{
      path: $path,
      supplied_customer_id: (if $supplied_customer_id == "" then null else $supplied_customer_id end)
    }'
}

ngwaf_link_parse_url_json() {
  [[ $# -eq 1 ]] || die 'ngwaf_link_parse_url_json requires one URL'

  local parsed path workspace_id request_id
  local path_pattern='^/security/ngwaf/workspaces/([A-Za-z0-9][A-Za-z0-9._~-]*)/requests/([A-Za-z0-9][A-Za-z0-9._~-]*)$'
  parsed="$(manage_fastly_link_parse_url_json "$1" 'NGWAF request')"
  path="$(jq -r '.path' <<<"$parsed")"

  [[ "$path" =~ $path_pattern ]] ||
    die 'unsupported NGWAF request URL path; expected /security/ngwaf/workspaces/<workspace-id>/requests/<request-id>'
  workspace_id="${BASH_REMATCH[1]}"
  request_id="${BASH_REMATCH[2]}"
  [[ "$workspace_id" != '.' && "$workspace_id" != '..' &&
     "$request_id" != '.' && "$request_id" != '..' ]] ||
    die 'NGWAF request URL contains a traversal-like path segment'

  jq --arg workspace_id "$workspace_id" --arg request_id "$request_id" '
    del(.path) + {workspace_id: $workspace_id, request_id: $request_id}
  ' <<<"$parsed"
}

cmd_ngwaf_link() {
  [[ $# -eq 1 ]] || die "usage: ngwaf link '<customer-request-url>'"

  local parsed cid customer_name workspace_id request_id supplied_customer_id
  local resolved resolved_id encoded_workspace encoded_request encoded_cid
  parsed="$(ngwaf_link_parse_url_json "$1")"
  cid="$(current_cid)"
  customer_name="$(current_customer_name)"
  workspace_id="$(jq -r '.workspace_id' <<<"$parsed")"
  request_id="$(jq -r '.request_id' <<<"$parsed")"
  supplied_customer_id="$(jq -r '.supplied_customer_id // empty' <<<"$parsed")"

  if [[ -n "$supplied_customer_id" && "$supplied_customer_id" != "$cid" ]]; then
    die "customerId in NGWAF request URL does not match selected customer $customer_name ($cid)"
  fi

  if ! resolved="$(resolve_workspace_json "$workspace_id")"; then
    printf '%s: error: NGWAF workspace ownership could not be verified for the selected customer.\n' \
      "${PROGRAM_NAME:-ngwaf}" >&2
    printf '%s: selected customer: %s (%s)\n' \
      "${PROGRAM_NAME:-ngwaf}" "$customer_name" "$cid" >&2
    printf '%s: requested workspace: %s\n' \
      "${PROGRAM_NAME:-ngwaf}" "$workspace_id" >&2
    printf '%s: hint: select the correct customer and retry.\n' \
      "${PROGRAM_NAME:-ngwaf}" >&2
    return 1
  fi
  resolved_id="$(jq -r '.id' <<<"$resolved")"
  [[ "$resolved_id" == "$workspace_id" ]] ||
    die "NGWAF workspace URL ID does not exactly match resolved selected-customer workspace: $workspace_id"

  encoded_workspace="$(urlencode "$workspace_id")"
  encoded_request="$(urlencode "$request_id")"
  encoded_cid="$(urlencode "$cid")"
  printf 'https://manage.fastly.com/security/ngwaf/workspaces/%s/requests/%s?customerId=%s\n' \
    "$encoded_workspace" "$encoded_request" "$encoded_cid"
}

ddos_link_parse_url_json() {
  [[ $# -eq 1 ]] || die 'ddos_link_parse_url_json requires one URL'

  local parsed path event_id
  local path_pattern='^/security/ddos/protection/events/([A-Za-z0-9][A-Za-z0-9._~-]*)$'
  parsed="$(manage_fastly_link_parse_url_json "$1" 'DDoS event')"
  path="$(jq -r '.path' <<<"$parsed")"

  [[ "$path" =~ $path_pattern ]] ||
    die 'unsupported DDoS event URL path; expected /security/ddos/protection/events/<event-id>'
  event_id="${BASH_REMATCH[1]}"
  [[ "$event_id" != '.' && "$event_id" != '..' ]] ||
    die 'DDoS event URL contains a traversal-like path segment'

  jq --arg event_id "$event_id" 'del(.path) + {event_id: $event_id}' <<<"$parsed"
}

ddos_event_service_customer_id() {
  [[ $# -eq 1 ]] || die 'ddos_event_service_customer_id requires one service ID'

  local service_id="$1" body customer_id
  body="$(NGWAF_PROGRESS_LABEL="verifying DDoS event service ownership" \
    get "/service/$(urlencode "$service_id")")"
  customer_id="$(
    jq -er --arg service_id "$service_id" '
      def service:
        if type == "object" and (.id | type) == "string" then .
        elif type == "object" and (.ServiceID | type) == "string" then
          {id: .ServiceID, customer_id: (.CustomerID // .CustomerId // null)}
        elif type == "object" and (.data | type) == "object" then
          (.data | if (.attributes | type) == "object" then . + .attributes else . end)
        else error("unrecognized service response shape")
        end;
      service
      | select(.id == $service_id)
      | .customer_id
      | select(type == "string" and length > 0)
    ' <<<"$body"
  )" || die "DDoS event service ownership response was incomplete for service $service_id"
  printf '%s\n' "$customer_id"
}

cmd_ddos_link() {
  [[ $# -eq 1 ]] || die "usage: fastly-audit ddos link '<customer-event-url>'"

  local parsed cid customer_name event_id supplied_customer_id endpoint body event
  local event_customer_id event_service_id encoded_event encoded_cid
  parsed="$(ddos_link_parse_url_json "$1")"
  cid="$(current_cid)"
  customer_name="$(current_customer_name)"
  event_id="$(jq -r '.event_id' <<<"$parsed")"
  supplied_customer_id="$(jq -r '.supplied_customer_id // empty' <<<"$parsed")"

  if [[ -n "$supplied_customer_id" && "$supplied_customer_id" != "$cid" ]]; then
    die "customerId in DDoS event URL does not match selected customer $customer_name ($cid)"
  fi

  endpoint="/ddos-protection/v1/events/$(urlencode "$event_id")"
  body="$(NGWAF_PROGRESS_LABEL="verifying DDoS event ownership" get "$endpoint")"
  if ! event="$(jq -ec --arg event_id "$event_id" '
    if type != "object" then error("DDoS event response is not an object") else . end
    | select((.id // "") == $event_id)
    | if (((.customer_id // null) == null or
           ((.customer_id | type) == "string" and (.customer_id | length) > 0)) and
          ((.service_id // null) == null or
           ((.service_id | type) == "string" and (.service_id | length) > 0)))
      then . else error("DDoS event ownership fields are malformed") end
    | {
        id,
        customer_id: (.customer_id // null),
        service_id: (.service_id // null)
      }
  ' <<<"$body")" || [[ -z "$event" ]]; then
    die "DDoS event lookup returned an unrecognized object or mismatched event ID: $event_id"
  fi

  event_customer_id="$(jq -r '.customer_id // empty' <<<"$event")"
  event_service_id="$(jq -r '.service_id // empty' <<<"$event")"
  if [[ -z "$event_customer_id" && -n "$event_service_id" ]]; then
    event_customer_id="$(ddos_event_service_customer_id "$event_service_id")"
  fi
  [[ -n "$event_customer_id" ]] ||
    die "DDoS event ownership could not be established: event $event_id has no customer_id or verifiable service_id"
  [[ "$event_customer_id" == "$cid" ]] ||
    die "DDoS event does not belong to selected customer $customer_name ($cid)"

  encoded_event="$(urlencode "$event_id")"
  encoded_cid="$(urlencode "$cid")"
  printf 'https://manage.fastly.com/security/ddos/protection/events/%s?customerId=%s\n' \
    "$encoded_event" "$encoded_cid"
}
