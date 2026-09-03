# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

usage() {
  cat <<'HELP'
Fastly NGWAF read-only helper

Customer / auth and account inventory:
  ngwaf version
  ngwaf doctor [--json]
  ngwaf whoami
  ngwaf use <customer_id>
  ngwaf customer
  ngwaf services [--json]
  ngwaf products [--json]
  ngwaf inventory [--json]
  ngwaf workspaces

30-day-style analytics:
  ngwaf overview [days] [--json]
  ngwaf timeseries <workspace> [days] [--json]
  ngwaf metrics <metric1,metric2,...> [days] [--json]
  ngwaf attack-profile [days] [--json]
  ngwaf attack-profile <FROM> <TO> [--json]
  ngwaf attack-origins [days] [--json]
  ngwaf attack-origins <FROM> <TO> [--json]

Bot Management monthly stats:
  ngwaf bot-stats <service_id> [days] [--json]
  ngwaf bot-stats <service_id> <FROM> <TO> [--json]
  ngwaf intl-bot-stats [days] [--json]
  ngwaf intl-bot-stats <FROM> <TO> [--json]
  ngwaf intl-bot-types [days] [--json]
  ngwaf intl-bot-types <FROM> <TO> [--json]

Account / workspace configuration:
  ngwaf account-rules [--list|--json]
  ngwaf workspace <workspace>
  ngwaf posture <workspace>
  ngwaf rules <workspace> [--list|--json]
  ngwaf thresholds <workspace> [--json]
  ngwaf lists <workspace> [--json]
  ngwaf bot-rules <workspace> [--json]

Safe local configuration snapshots:
  ngwaf snapshot <workspace> [--output FILE] [--include-list-entries] [--json]
  ngwaf diff <before.json> <after.json> [--json] [--check]

Recent request search (1-7 days):
  ngwaf count <workspace> '<Fastly Search query>' [days]
  ngwaf signal-count <workspace> <signal> [days]

Examples:
  ngwaf doctor
  ngwaf doctor --json
  ngwaf use 6C07TtEzfBKdmffwdcdHLD
  ngwaf overview
  ngwaf overview 30 --json
  ngwaf timeseries ngwaf-production 30
  ngwaf metrics 'XSS,SQLI,HTTP404' 30
  ngwaf metrics 'SUSPECTED-BAD-BOT,DATACENTER' 30

  # QBR NGWAF attack-profile validation; TO is exclusive:
  ngwaf attack-profile 2026-08-01 2026-09-01
  ngwaf attack-profile 2026-08-01 2026-09-01 --json

  # Attack origins report is limited to 30 days:
  ngwaf attack-origins 30
  ngwaf attack-origins 30 --json

  # Historical Bot Management, default 30 complete UTC days:
  ngwaf bot-stats SERVICE_ID
  ngwaf bot-stats SERVICE_ID 30

  # Exact slide-validation window; TO is exclusive:
  ngwaf bot-stats SERVICE_ID 2026-08-01 2026-09-01

  # Current Costco international Bot Management slide:
  ngwaf intl-bot-stats 2026-08-01 2026-09-01
  ngwaf intl-bot-stats 2026-08-01 2026-09-01 --json
  ngwaf intl-bot-types 2026-08-01 2026-09-01

  ngwaf services
  ngwaf products
  ngwaf inventory
  ngwaf account-rules
  ngwaf posture production
  ngwaf lists production
  ngwaf bot-rules production
  ngwaf signal-count production SUSPECTED-BAD-BOT 7
  ngwaf count production 'ruleid:6047e66d33e0b901e666e424' 7

  # Snapshots use mode 0600 and redact list entries unless explicitly included:
  ngwaf snapshot Production
  ngwaf snapshot Production --output before.json
  ngwaf diff before.json after.json
  ngwaf diff before.json after.json --check --json

Notes:
  - doctor is non-destructive and does not require the normal command preflight.
    It collects dependency, token, customer, workspace, and HTTP-policy results;
    failures produce a non-zero exit status after the complete report is shown.
  - Customer-scoped commands validate and print the selected customer name, ID,
    and selection source on stderr. FASTLY_CUSTOMER_ID overrides the saved ID.
  - Workspace arguments may be IDs or case-insensitive exact names. Exact IDs
    win; missing or ambiguous names fail instead of being guessed.
  - Timeseries commands use complete UTC days and accept 1-30 days.
    JSON output includes an exact window, provenance, and fail-closed
    missing-data policy. Missing requested metrics are not replaced with zero.
  - attack-profile defaults to 30 complete UTC days; exact FROM/TO windows up to
    31 days are allowed for calendar-month slide validation. It ranks production
    workspaces by requests_attack and sums attack signals across the same top five.
    TO is exclusive.
  - attack-origins is intentionally limited to 30 days for this workflow. It
    resolves the selected customer workspace list first, queries each workspace
    top-attacks endpoint with customer_id + field=remote_country_code, aggregates country counts, and
    reconciles them against customer-scoped requests_attack timeseries.
  - bot-stats uses Fastly Historical Stats for one Fastly service and is
    intentionally limited to a rolling 1-30 day window for this workflow.
  - Exact Bot Management date windows are limited to 31 days so a full
    calendar month such as Aug 1 -> Sep 1 can be reproduced.
  - intl-bot-stats and intl-bot-types are intentionally scoped to the 11
    international production service names used by the current Costco QBR slide.
  - services discovers selected-customer service IDs from customer-scoped audit
    events, verifies each by direct service lookup, and maps vcl -> CDN and
    wasm -> Compute. This is an audit-observed inventory, not a guaranteed
    complete all-time service list.
  - products inventories known public service-level product enablement APIs and
    maps enabled products back to the audit-observed selected-customer service
    set. NGWAF, Bot Management, and DDoS Protection include configuration when
    the API returns it.
  - inventory combines audit-observed service counts, product enablement, and
    NGWAF workspace inventory. Product enablement does not prove meaningful
    production traffic.
  - account-level products without a service mapping are intentionally not included
    in the v20 product matrix.
  - posture includes workspace rule types/actions, standard attack thresholds,
    signal thresholds, account-level rules whose scope applies to the workspace,
    and account/workspace list inventory. List presence is inventory context only;
    it does not prove that a rule references a list.
  - account-rules reads the separate account-level NGWAF rule layer and preserves
    rule type, action, and scope details.
  - bot-rules scans the complete paginated workspace rule set for bot signal
    families, client-challenge signals/actions, and DATACENTER as bot-adjacent
    evidence. DATACENTER is not treated as a bot verdict.
  - Bot type classifications can overlap. intl-bot-types reports them side by side
    but does not treat them as mutually exclusive or force them to sum to 100%.
  - Bot Management metrics are sampled and scaled estimates. The script reports
    bot-detected / bot-analyzed for Bot % of analyzed, but it does not divide
    Bot Management counters by edge_requests because those counters are not
    directly comparable.
  - Actual metrics retention depends on the customer's entitlement.
  - Request-search commands are intentionally limited to 1-7 days.
    Their JSON includes the exact rolling from/until timestamps, a five-minute
    ingestion buffer, and request-search provenance.
  - The Fastly request-search key for a matching rule ID is ruleid:<id>.
  - count and signal-count report the request-search API's matching retained
    records. Depending on storage category, those records may be sampled or
    mixed-storage data. The result is not raw traffic or a scaled estimate, and
    ratios derived from it describe searchable matches rather than all traffic.
  - API calls show an interactive progress indicator on stderr. Set
    NGWAF_PROGRESS=never to disable it, or NGWAF_PROGRESS=always to force it.
    Set NGWAF_DEBUG=1 to show request paths and query parameters (never tokens).
  - Human output uses TTY-only color and status badges. Set NGWAF_COLOR=never
    or NO_COLOR=1 to disable color, or NGWAF_COLOR=always to force it.
  - snapshot performs read-only API requests, refuses to overwrite files, writes
    mode 0600, and redacts list entries by default. --include-list-entries may
    expose customer-sensitive values and must be used deliberately.
  - diff is entirely local and rejects snapshots with different customer or
    workspace IDs. --check exits 1 when valid snapshots contain changes, which
    is useful for CI; ordinary diff exits 0 after reporting valid changes.
  - 'metrics' passes metric names directly to Fastly; invalid metrics return
    the Fastly API error instead of silently changing the query.
HELP
}
