# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

cmd_version() {
  printf 'ngwaf %s\n' "$VERSION"
}

cmd_whoami() {
  get "/tokens/self" |
    jq '{name, scope, expires_at}'
}

cmd_use() {
  [[ $# -eq 1 ]] || die 'usage: ngwaf use <customer_id>'

  local cid="$1"
  local body

  body="$(get "/customer/$(urlencode "$cid")")"

  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$cid" > "$CID_FILE"

  printf 'Selected customer: %s (%s)\n' \
    "$(jq -r '.name' <<<"$body")" \
    "$cid"
}

cmd_customer() {
  load_customer_context
  jq '{id, name, source}' <<<"$NGWAF_CUSTOMER_CONTEXT_JSON"
}

# Service discovery for a selected customer must not enumerate the global
# /service collection. With a root:read token, /service is effectively global
# and the endpoint does not honor customer_id as a documented filter.
#
# Instead, discover service IDs from customer-scoped audit events, then fetch
# each observed service directly by ID and verify its customer_id before using
# it. Fastly retains audit events for a finite window, so this is deliberately
# reported as an observed-service inventory rather than a guaranteed complete
# all-time account inventory.
#
# Discovery sources:
#   1. version.activate events within SERVICE_AUDIT_DAYS (default 365), because
#      they provide a relatively low-noise record of services actively deployed.
#   2. the most recent page of all customer events, which helps surface newly
#      configured services (for example a fresh product PoC) before activation.
#
# SERVICE_AUDIT_MAX_PAGES bounds activation-event pagination so a very active
# account cannot silently turn this command into a long-running crawl.
