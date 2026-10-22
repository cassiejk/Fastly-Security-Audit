# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

legacy_usage() {
  cat <<'HELP'
Fastly NGWAF read-only helper

Customer / auth and account inventory:
  ngwaf version
  ngwaf setup [--customer-id CUSTOMER_ID] [--json]
  ngwaf doctor [--json] [--verbose]
  ngwaf whoami
  ngwaf use <customer_id>
  ngwaf customer
  ngwaf customer security [--json]
  ngwaf services [--json]
  ngwaf products [--json]
  ngwaf inventory [--json]
  ngwaf workspaces
  ngwaf link '<customer-request-url>'

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
  ngwaf rule <workspace> <rule_id>
  ngwaf rules <workspace> [--list|--json]
  ngwaf thresholds <workspace> [--json]
  ngwaf lists <workspace> [--json]
  ngwaf bot-rules <workspace> [--json]

Safe local configuration snapshots:
  ngwaf snapshot <workspace> [--output FILE] [--include-list-entries] [--json]
  ngwaf diff <before.json> <after.json> [--json] [--check]

Recent request search (1-7 days):
  ngwaf count <workspace> '<Fastly Search query>' [days]
  ngwaf requests <workspace> '<Fastly Search query>' [days] [--limit N] [--format auto|json|csv] [--output FILE]
  ngwaf rule-audit <workspace> <rule_id> [<rule_id> ...] [--days N] [--signals CSV] [--json]
  ngwaf template-audit <workspace> <template> [days] [--json|--format human|json]
  ngwaf signal-count <workspace> <signal> [days]

Examples:
  ngwaf doctor
  ngwaf setup --customer-id CUSTOMER_ID
  ngwaf doctor --json
  ngwaf doctor --verbose
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
  ngwaf rule Production 6047e66c33e0b901e666e36a
  ngwaf lists production
  ngwaf bot-rules production
  ngwaf signal-count production SUSPECTED-BAD-BOT 7
  ngwaf count production 'ruleid:6047e66d33e0b901e666e424' 7
  ngwaf requests production 'ruleid:6047e66d33e0b901e666e424 tag:SQLI' 7 --limit 25
  ngwaf rule-audit production 6047e66d33e0b901e666e424 --days 7 --json
  ngwaf template-audit production "Registration Attempt" --json

  # Snapshots use mode 0600 and redact list entries unless explicitly included:
  ngwaf snapshot Production
  ngwaf snapshot Production --output before.json
  ngwaf diff before.json after.json
  ngwaf diff before.json after.json --check --json

Notes:
  - doctor is non-destructive and does not require the normal command preflight.
    It collects dependency, token, customer, workspace, and HTTP-policy results;
    failures produce a non-zero exit status after the complete report is shown.
    Add --verbose for sanitized command paths, config paths, versions, and API
    probe status details.
  - setup is a guided first-run check for colleagues. It verifies the local
    runtime, dependencies, FASTLY_API_TOKEN presence, token API access, and
    selected customer scope. With --customer-id, a validated customer selection
    is saved locally with mode 0600. The API probes are read-only and the token
    value is never printed.
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
  - services uses customer-scoped service search with legacy GET /service
    fallback, and maps vcl -> CDN and wasm -> Compute. Complete retrieval does
    not prove the token can see every service the customer owns.
  - products inventories known public service-level product enablement APIs and
    maps enabled products back to the token-visible selected-customer service
    set. NGWAF, Bot Management, and DDoS Protection include configuration when
    the API returns it.
  - inventory combines token-visible service counts, product enablement, and
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
  - rule retrieves one workspace rule directly by ID and verifies that the API
    response ID matches the requested ID. It does not fetch the full rule list.
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
  - requests retrieves a bounded set of actual retained request-search records.
    It reports total_matches separately from rows_returned, defaults to --limit
    25 and --format auto, preserves raw nested request data in JSON, and supports
    CSV only as a flattened export of common request fields. auto prints human
    output to a terminal, JSON to non-TTY stdout, and infers JSON/CSV from
    --output .json/.csv extensions when no concrete format is supplied.
  - rule-audit retrieves live rule configuration, counts retained matches for
    ruleid:<id> and selected ruleid:<id> tag:<signal> intersections, and
    calculates percentages. Signal cohorts can overlap and must not be summed
    as unique requests. Review indicators are factual prompts for human review,
    not automatic policy-remediation claims.
  - template-audit correlates templated_signal tagging rules, associated signal
    thresholds, and retained signal activity into one logical control audit.
    It prefers exact canonical signal/template identifiers, then exact display
    names, then centralized explicit UI-name aliases such as Registration
    Attempt -> REGATTEMPT. It fails on ambiguity instead of guessing. Threshold
    relationship indicators are conservative review prompts, not remediation
    advice.
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

fastly_audit_usage() {
  cat <<'HELP'
fastly-audit — read-only Fastly configuration and security inspection

Core:
  fastly-audit version
  fastly-audit setup [--customer-id CUSTOMER_ID] [--json]
  fastly-audit doctor [--json] [--verbose]
  fastly-audit customer [show]
  fastly-audit customer setup [--customer-id CUSTOMER_ID] [--json]
  fastly-audit customer use <customer_id>
  fastly-audit customer whoami
  fastly-audit customer security [--json]
  fastly-audit customer vcl-size [--json]
  fastly-audit inventory [--json]

Service inventory:
  fastly-audit service list [--json]
  fastly-audit service products [--json]
  fastly-audit service inventory [--json]
  fastly-audit service vcl-size <service> [--json]
  fastly-audit service ngwaf-architecture <service-id-or-name> [--version N] [--show-vcl] [--json]
  fastly-audit service domains <service> [--version N] [--json]

Security products:
  fastly-audit security summary [--json] [--detailed]
  fastly-audit security legacy-map [service-name-or-id] [--sigsci-corp CORP] [--format human|json|csv] [--output FILE]

Next-Gen WAF:
  fastly-audit ngwaf workspaces
  fastly-audit ngwaf agent-diagnostic <workspace-id> [--json]
  fastly-audit ngwaf link '<customer-request-url>'
  fastly-audit ngwaf workspace <workspace>
  fastly-audit ngwaf posture <workspace>
  fastly-audit ngwaf rule <workspace> <rule_id>
  fastly-audit ngwaf rules <workspace> [--list|--json]
  fastly-audit ngwaf account-rules [--list|--json]
  fastly-audit ngwaf thresholds <workspace> [--json]
  fastly-audit ngwaf lists <workspace> [--json]
  fastly-audit ngwaf count <workspace> '<query>' [days]
  fastly-audit ngwaf requests <workspace> '<query>' [days] [--limit N] [--format auto|json|csv] [--output FILE]
  fastly-audit ngwaf rule-audit <workspace> <rule_id> [<rule_id> ...] [--days N] [--signals CSV] [--json]
  fastly-audit ngwaf template-audit <workspace> <template> [days] [--json|--format human|json]
  fastly-audit ngwaf signal-count <workspace> <signal> [days]
  fastly-audit ngwaf overview [days] [--json]
  fastly-audit ngwaf timeseries <workspace> [days] [--json]
  fastly-audit ngwaf metrics <metrics> [days] [--json]
  fastly-audit ngwaf attack-profile [days|FROM TO] [--json]
  fastly-audit ngwaf attack-origins [days|FROM TO] [--json]

DDoS Protection:
  fastly-audit ddos link '<customer-event-url>'
  fastly-audit ddos export-event <event_id> --output FILE|-

Bot Management:
  fastly-audit bot workspaces [--service-id <SID>] [--json]
  fastly-audit bot stats <service_id> [days|FROM TO] [--json]
  fastly-audit bot rules <workspace> [--json]

Protected snapshots:
  fastly-audit snapshot ngwaf <workspace> [--output FILE] [--include-list-entries] [--json]
  fastly-audit diff <before.json> <after.json> [--json] [--check]

Compatibility:
  The ngwaf command and all original flat commands remain supported.
  Run `ngwaf help` for the complete legacy command reference.
  Run `fastly-audit help legacy` to display it through this command.

Safety contract:
  API operations are read-only. Customer scope is confirmed before scoped
  requests, ambiguous names fail closed, JSON remains pipeline-safe, and
  analytical results retain window and provenance metadata.
HELP
}

ngwaf_namespace_usage() {
  cat <<'HELP'
fastly-audit ngwaf — Next-Gen WAF inspection

  workspaces
  agent-diagnostic <workspace-id> [--json]
  link '<customer-request-url>'
  workspace-services <workspace>|--all [--json] [--sigsci-corp CORP] [--with-domains]
  workspace-services --service-id <exact-CDN-service-ID> [--json] [--sigsci-corp CORP] [--with-domains]
  workspace <workspace>
  posture <workspace>
  rule <workspace> <rule_id>
  rules <workspace> [--list|--json]
  account-rules [--list|--json]
  thresholds <workspace> [--json]
  lists <workspace> [--json]
  bot-rules <workspace> [--json]
  count <workspace> '<query>' [days]
  requests <workspace> '<query>' [days] [--limit N] [--format auto|json|csv] [--output FILE]
  rule-audit <workspace> <rule_id> [<rule_id> ...] [--days N] [--signals CSV] [--json]
  template-audit <workspace> <template> [days] [--json|--format human|json]
  signal-count <workspace> <signal> [days]
  overview [days] [--json]
  timeseries <workspace> [days] [--json]
  metrics <metrics> [days] [--json]
  attack-profile [days|FROM TO] [--json]
  attack-origins [days|FROM TO] [--json]
  snapshot <workspace> [--output FILE] [--include-list-entries] [--json]
HELP
}

timeseries_usage() {
  cat <<'HELP'
Query read-only daily NGWAF traffic metrics for one workspace in the selected customer.

Usage:
  fastly-audit ngwaf timeseries <workspace> [days] [--json]
  fastly-audit ngwaf timeseries <workspace> --start YYYY-MM-DDTHH:MM:SSZ [--end YYYY-MM-DDTHH:MM:SSZ] [--json]

Arguments:
  <workspace>  Exact workspace name or ID in the selected customer.
  [days]       1-30 complete UTC days; defaults to 30. Converted to API start/end.
  --start      Required for an explicit range. UTC RFC3339 timestamp.
  --end        Optional with --start; must be later. UTC RFC3339 timestamp.
  --json       Emit JSON instead of a terminal table.
  -h, --help   Show this help before authentication or API requests.

For day counts, the start is inclusive and end is exclusive at UTC midnight.
The API documentation does not specify boundary inclusion for explicit ranges.

Examples:
  fastly-audit ngwaf timeseries vi-agent-production 7 --json
  fastly-audit ngwaf timeseries vi-agent-production --start 2026-09-01T00:00:00Z --end 2026-09-08T00:00:00Z
HELP
}

ddos_namespace_usage() {
  cat <<'HELP'
fastly-audit ddos — DDoS Protection inspection

  link '<customer-event-url>'
                      Validate event ownership and add the selected customer ID
  export-event <event_id> --output FILE|-
                      Export a complete read-only evidence bundle for one event
                      [--customer CUSTOMER_ID] [--service SERVICE_ID]

Only https://manage.fastly.com/security/ddos/protection/events/<event-id>
is supported. The generated link still requires normal employee authorization.
Evidence exports use schema fastly-ddos-evidence version 1, refuse to overwrite
files, and write JSON only to stdout when --output - is used.
HELP
}

inventory_usage() {
  local program="${USAGE_PROGRAM:-${PROGRAM_NAME:-fastly-audit}}"
  cat <<HELP
$program inventory — combined inventory for the selected customer

Usage:
  $program inventory [--json]
  $program inventory help

Use this read-only report to get an overview of the customer's token-visible
edge services, enabled service-level products, and NGWAF workspaces before
inspecting individual services or security configuration.

The default human-readable report includes:
  - Service counts: total, CDN, Compute, other, and paused, plus discovery
    source and completeness.
  - NGWAF workspace count.
  - Service-level product counts and check status.
  - Security product mappings to services and returned configuration, such as
    workspace_id, traffic_ramp, DDoS mode, and Bot Management contentguard.

Options:
  --json    Emit structured JSON with service details, product check results,
            NGWAF workspace details, and scope notes. Diagnostics go to stderr.
  help, -h, --help
            Show this help without credentials or API requests.

Scope and limits:
  Running the report requires FASTLY_API_TOKEN and a selected customer.
  Services use customer-scoped Fastly service search with cursor pagination,
  falling back to token-visible GET /service filtered by exact customer ID.
  Token visibility does not prove complete account-wide coverage.
  Products cover known public service-level enablement APIs; account-level
  products are excluded. Inconclusive checks are unknown, not disabled.
  Configuration and workspace presence do not prove production traffic,
  per-hostname protection, effective enforcement, or security efficacy.

Examples:
  $program inventory
  $program inventory --json
  $program inventory --json | jq '.edge_services.services'
HELP
}

service_namespace_usage() {
  cat <<'HELP'
fastly-audit service — selected-customer edge-service inspection

  list [--json]      Token-visible selected-customer CDN and Compute service inventory
  products [--json]   Service-level product enablement and configuration
  inventory [--json] Combined service, product, and NGWAF inventory
  vcl-size <service> [--json]
                      Read-only active generated VCL size for one VCL/CDN service
  ngwaf-architecture <service-id-or-name> [--version N] [--show-vcl] [--json]
                      Inspect generated VCL parameter and scoped Edge WAF enablement
  domains <service> [--version N] [--json]
                      Configured Fastly domain objects; active version by default

Generated VCL content is not printed. Compute services are not applicable.
Domains do not prove identical NGWAF behavior for every hostname/path.
HELP
}

security_namespace_usage() {
  cat <<'HELP'
fastly-audit security — selected-customer security-product inspection

  summary [--json] [--detailed]
                     API Discovery, Bot Management, DDoS Protection,
                     Edge WAF service attachments, and NGWAF workspace coverage
  legacy-map [service-name-or-id] [--sigsci-corp CORP] [--format human|json|csv] [--output FILE]
                     Read-only CDN service to in-band Inspection Service to NGWAF workspace evidence

Enablement is configuration inventory; it does not prove traffic,
effective enforcement, or security efficacy. Unknown checks are never
silently counted as disabled.
legacy-map validates returned NGWAF site customer_id values against the
selected Fastly customer before using internal site evidence.
HELP
}

bot_namespace_usage() {
  cat <<'HELP'
fastly-audit bot — Bot Management inspection

  workspaces [--service-id <SID>] [--json]
  stats <service_id> [days|FROM TO] [--json]
  rules <workspace> [--json]

Customer extensions, when installed:
  intl-stats [days|FROM TO] [--json]
  intl-types [days|FROM TO] [--json]
HELP
}

customer_security_usage() {
  local program="${PROGRAM_NAME:-fastly-audit}"
  cat <<HELP
$program customer security — customer security configuration overview

Usage:
  $program customer security [--json]
  $program customer security help

Read-only orientation to the selected customer's Fastly security product
configuration and complete NGWAF workspace inventory:
  - Customer identity and token-visible service count/status.
  - API Discovery, Bot Management, DDoS Protection, and Edge WAF attachments.
  - Service mappings, returned DDoS mode and Bot Management configuration,
    Edge WAF workspace/ramp mapping, and workspace mode/default block response.
  - Workspaces with or without observed Edge WAF attachments.
  - Per-workspace NGWAF deployment evidence from attachments, agents, and
    optional Cloud WAF instance associations. Multiple methods can coexist.

Options:
  --json          Versioned JSON with provenance, completeness, and scope limits.
  help, -h, --help Show help without credentials, customer selection, or API access.

The report requires FASTLY_API_TOKEN and a selected customer. It reuses the
security summary inventory, including its supported per-service configuration
retrieval. Inconclusive checks remain UNKNOWN/PARTIAL, not disabled or zero.
Workspace attachment counts are exact only when mapping evidence is complete.
Deployment status is CONFIRMED for explicit Edge WAF or Cloud WAF links,
INFERRED for detected web server modules, and UNRESOLVED when architecture
cannot be safely identified. Agents without modules do not identify reverse
proxy, PaaS, A10, or Cloud WAF. Cloud WAF lookup requires SIGSCI_CORP,
SIGSCI_EMAIL, and SIGSCI_TOKEN for the separate Next-Gen WAF API; unavailable
visibility is reported rather than treated as absence. Cloud WAF confirmation
also requires site metadata that links the site to the selected Fastly customer.
Service discovery uses customer-scoped search with legacy GET /service fallback;
the JSON provenance identifies the source and pagination/completeness evidence.

Token visibility does not prove complete account-wide service inventory.
Configuration, product attachment, and workspace existence do not prove current
traffic, active use, per-hostname protection, enforcement, or security efficacy.
A workspace with zero Edge WAF attachments is valid inventory context.
Zero attachments do not prove a workspace is undeployed. Unresolved deployment
evidence does not establish that no deployment exists.
This command provides configuration inventory, not a security assessment.

Examples:
  $program customer security
  $program customer security --json
HELP
}

customer_namespace_usage() {
  cat <<'HELP'
fastly-audit customer — authentication and customer selection

  show
  setup [--customer-id CUSTOMER_ID] [--json]
  use <customer_id>
  whoami
  security [--json] Customer security product configuration and NGWAF inventory
  vcl-size [--json]  Active generated VCL sizes for selected-customer VCL/CDN services

Customer VCL sizing is read-only, skips Compute services, and sorts largest first.
HELP
}

snapshot_namespace_usage() {
  cat <<'HELP'
fastly-audit snapshot — protected local configuration snapshots

  ngwaf <workspace> [--output FILE] [--include-list-entries] [--json]

Use `fastly-audit diff <before.json> <after.json>` to compare snapshots.
HELP
}

usage() {
  if [[ "${PROGRAM_NAME:-ngwaf}" == "ngwaf" ]]; then
    legacy_usage
  else
    fastly_audit_usage
  fi
}


bot_workspaces_usage() {
  cat <<'HELP'
fastly-audit bot workspaces [--service-id <SID>] [--json]

Requires FASTLY_API_TOKEN and an existing selected customer (FASTLY_CUSTOMER_ID
or the saved customer selection). Always sends that exact customer_id.
Uses GET /customer/{CID}, optionally GET /service/{SID} to verify CDN ownership,
then GET /bot-management/v1/workspaces with customer_id, optional service_id,
and limit=100. Subsequent pages use cursor with the same filters.
Normal request count: 2 + workspace pages with a service, 1 + pages without;
transport retries can add requests. No CDN inventory or generated VCL reads.

JSON includes schema_version, customer, scope, result, pagination, workspaces
(workspace_id, name, protection_mode, services, ownership_validation),
provenance, and limitations. Human output shows workspace fields and count.
Complete empty results succeed; authorization, schema, ownership, and incomplete
pagination failures exit nonzero with diagnostics on stderr and no result.
Bot Management workspaces configure ContentGuard and are distinct from NGWAF
workspaces. Association does not prove traffic inspection, hostname coverage,
or effective enforcement. Other associated services are API-reported, not
independently ownership-verified. Results are limited to credential visibility.
HELP
}
