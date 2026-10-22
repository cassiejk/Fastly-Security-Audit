# fastly-audit v24.1

v24.1 adds a customer-scoped security-product inventory spanning API
Discovery, Bot Management, DDoS Protection, Edge WAF service attachments,
and the complete NGWAF workspace collection. Product-list queries explicitly
carry the selected customer ID and validate the response customer before data
is accepted.

The summary distinguishes configuration enablement from observed traffic or
security efficacy, preserves inconclusive results as unknown, and uses
token-visible selected-customer service inventory. All v24.0 namespaces and the
complete `ngwaf` compatibility interface remain supported.

## Layout

For current commands, selectors, JSON modes, API scope, and source locations,
see the [CLI command reference](docs/cli-reference.md). For verified fixes,
open questions, and evidence or performance limits, see the
[known limitations register](docs/known-limitations.md).

See [NGWAF deployment architecture and resource identity](docs/ngwaf-deployment-architecture.md)
for the five deployment types, Edge inspection and management methods,
resource ownership, and the API evidence each relationship requires.

```text
ngwaf-helper/
├── install.sh             # GitHub Release installer for first-time users
├── fastly-audit          # primary CLI bootstrap
├── ngwaf                 # backward-compatible entry point
├── ngwaf-update          # package-aware installer
├── .github/workflows/
│   ├── check.yml          # Ubuntu/macOS validation
│   └── release.yml        # GitHub Release asset packaging/upload
├── lib/
│   ├── runtime.sh         # Bash runtime requirement and version checks
│   ├── core.sh            # HTTP, pagination, dates, shared JSON helpers
│   ├── dispatch.sh        # flat compatibility + namespaced routing
│   ├── doctor.sh          # dependency, authentication, and scope diagnostics
│   ├── setup.sh           # first-run onboarding and customer selection
│   ├── account.sh         # version, auth identity, customer selection
│   ├── services.sh        # CDN/Compute + product inventory
│   ├── security.sh        # cross-product security coverage summary
│   ├── ngwaf.sh           # workspaces, rules, thresholds, posture, lists
│   ├── bots.sh            # bot rules + Bot Management historical stats
│   ├── metrics.sh         # timeseries and metric summaries
│   ├── request_search.sh  # request-search counts and drill-down rows
│   ├── rule_audit.sh      # rule configuration plus retained-match analysis
│   ├── template_audit.sh  # templated signal control correlation
│   ├── attack_analysis.sh # attack-profile and request-origin reports
│   ├── snapshots.sh       # protected snapshots + local semantic diffs
│   └── help.sh            # CLI help
├── customer/
│   └── costco.sh          # Costco-specific international QBR commands
├── scripts/
│   ├── check              # syntax + optional ShellCheck + smoke tests
│   └── package-release    # builds GitHub Release assets
└── tests/
    ├── smoke.sh
    ├── count.sh
    ├── requests.sh
    ├── rule-audit.sh
    ├── template-audit.sh
    ├── metrics.sh
    ├── doctor.sh
    ├── setup.sh
    ├── package-release.sh
    ├── install.sh
    ├── helpers.sh
    ├── runtime.sh
    └── snapshots.sh
```

## Development

`fastly-audit` requires Bash 5.2 or newer. On macOS, `/bin/bash` is the
system Bash 3.2 build and is unsupported. Install a modern Bash with Homebrew:

```bash
brew install bash
```

The launchers use `#!/usr/bin/env bash`, which selects the first `bash` found
in `PATH`. Ensure Homebrew's bin directory appears before `/bin`, then verify:

```bash
command -v bash
bash --version
```

Run directly from the repository:

```bash
./ngwaf version
./ngwaf posture production
```

### Colleague Quickstart

For a first-time user, the preferred path is the latest GitHub Release:

```bash
curl -fsSLO https://github.com/cassiejk/ngwaf-helper/releases/latest/download/fastly-audit-installer.sh
bash fastly-audit-installer.sh
export FASTLY_API_TOKEN=YOUR_FASTLY_TOKEN
fastly-audit setup --customer-id CUSTOMER_ID
```

The installer downloads `fastly-audit.tar.gz` and
`fastly-audit.tar.gz.sha256` from the same release, verifies the checksum,
installs `fastly-audit`, `ngwaf`, and `ngwaf-update`, and prints the setup
command to run next. It does not edit shell startup files.

For development from a local checkout:

```bash
mkdir -p ~/bin
install -m 755 ./ngwaf-update ~/bin/ngwaf-update
~/bin/ngwaf-update ./ngwaf
export PATH="$HOME/bin:$PATH"
export FASTLY_API_TOKEN=YOUR_FASTLY_TOKEN
fastly-audit setup --customer-id CUSTOMER_ID
fastly-audit doctor --verbose
```

`setup` is read-only against the Fastly API. It verifies the selected Bash,
required local commands, token presence, token API access, and customer scope.
When `--customer-id` validates successfully, the customer selection is saved to
`~/.config/fastly-ngwaf/customer_id` with owner-only permissions. The token
value is never printed or stored.

Before committing:

```bash
./scripts/check
```

API requests show an interactive spinner and elapsed time on stderr, leaving
stdout safe for JSON pipelines. Failures include status-specific hints and
point to `doctor` or debug mode when those would help. Useful controls:

```bash
NGWAF_PROGRESS=never ngwaf count production 'tag:XSS' 7
NGWAF_DEBUG=1 ngwaf count production 'ruleid:RULE_ID' 7
NGWAF_CURL_CONNECT_TIMEOUT=5 NGWAF_CURL_MAX_TIME=60 ngwaf workspaces
```

The default transport policy performs one retry, with a 90-second retry window.
Override it with `NGWAF_CURL_RETRIES` and `NGWAF_CURL_RETRY_MAX_TIME`.

Human output uses color only when stdout is a terminal. Disable it with either
`NGWAF_COLOR=never` or the conventional `NO_COLOR=1`; force it with
`NGWAF_COLOR=always`. Progress and scope messages stay on stderr, so stdout
remains suitable for JSON pipelines.

### Diagnostics

`doctor` collects diagnostics instead of exiting on the first failure:

```bash
ngwaf setup --customer-id CUSTOMER_ID
ngwaf doctor
ngwaf doctor --json
ngwaf doctor --verbose
```

It checks Bash and command dependencies, HTTP policy values, token presence and
API access, customer selection and identity, complete workspace enumeration,
and case-insensitive workspace-name collisions. It never prints the API token.
Add `--verbose` to include sanitized command paths, versions, config paths, HTTP
settings, and API probe statuses for troubleshooting.
Failures produce a non-zero exit status after the report is emitted; warnings
do not.

### Protected configuration snapshots

Create a point-in-time configuration snapshot using read-only API requests:

```bash
ngwaf snapshot Production
ngwaf snapshot Production --output before.json
```

Snapshots include workspace settings, complete workspace rules, applicable
account rules, thresholds, and workspace/account list metadata. The command:

- refuses to overwrite an existing path;
- writes the file with mode `0600`;
- excludes API credentials;
- redacts list entries by default while retaining entry counts when the list
  endpoint supplies entries; and
- records schema, tool version, capture time, scope, and endpoint provenance.

Default `ngwaf-snapshot-*.json` filenames are ignored by the repository's
`.gitignore` to reduce the chance of committing customer configuration.

List values can be included deliberately when required:

```bash
ngwaf snapshot Production \
  --output sensitive-snapshot.json \
  --include-list-entries
```

Treat that file as customer-sensitive.

Compare two snapshots without making API requests:

```bash
ngwaf diff before.json after.json
ngwaf diff before.json after.json --json
ngwaf diff before.json after.json --check
```

The comparison reports workspace-setting changes plus added, removed, and
modified workspace rules, applicable account rules, thresholds, and lists. It
rejects cross-customer and cross-workspace comparisons. Valid differences are
normally informational and exit `0`; `--check` exits `1` when drift exists for
CI or scripted checks.

### Customer and workspace scope

Every customer-scoped command validates the selected customer against
`GET /customer/{customer_id}` and prints the confirmed name, ID, and selection
source on stderr. `FASTLY_CUSTOMER_ID` takes precedence over the saved selection
in `~/.config/fastly-ngwaf/customer_id`.

Workspace commands accept either a workspace ID or a case-insensitive exact
workspace name. Resolution is performed against the complete workspace list for
the selected customer. Exact IDs take precedence; missing and ambiguous names
fail instead of being inserted directly into an API path.

Because scope messages go to stderr, JSON pipelines remain safe:

```bash
ngwaf rules Production --json | jq '.data | length'
```

Query one NGWAF workspace's daily traffic metrics with a complete UTC-day
window (1-30 days, default 30), or an explicit UTC RFC3339 range:

```bash
fastly-audit ngwaf timeseries vi-agent-production 7 --json
fastly-audit ngwaf timeseries vi-agent-production --start 2026-09-01T00:00:00Z --end 2026-09-08T00:00:00Z
```

Syntax: `timeseries <workspace> [days] [--json]` or
`timeseries <workspace> --start YYYY-MM-DDTHH:MM:SSZ [--end YYYY-MM-DDTHH:MM:SSZ] [--json]`.
The day-count form sends `start` and `end` at UTC midnight with an inclusive
start and exclusive end. The API documentation does not specify boundary
inclusion for explicit ranges. `--end` is optional only with `--start`.
Use `fastly-audit ngwaf timeseries --help` for full command help.

Account `metrics`, `overview`, and `attack-profile` validate each returned
workspace/day key before summing. They reject malformed or out-of-window daily
timestamps, duplicate keys, incomplete `meta.total` when supplied, a signaled
next page, and current workspace inventory name collisions. JSON includes a
`validation` object with requested and observed interval counts, dates not
observed for each returned workspace, and inventory workspaces with no rows.
An unobserved interval is not assigned zero:
the NGWAF timeseries documentation does not establish whether a zero-traffic day
must appear as a row. `validation.completeness` therefore remains `unknown`
even when all requested dates appear. Workspace IDs in account summaries are
matched to the selected customer's current inventory by display name; this
cannot establish historical identity across workspace renames.
The reference describes timestamps as RFC 3339 data-point times but does not
say whether they mark bucket starts or ends. Calendar-day validation uses the
midnight bucket-start convention shown in the repository fixtures and labels
that inference in `validation.timestamp_interpretation`. Equivalent RFC 3339
offsets and zero fractional seconds are compared as the same UTC instant.
Account responses observed with rows timestamped exactly at the requested `to`
boundary exclude those rows from aggregation and count them in
`validation.excluded_end_boundary_rows`; a warning is printed to stderr.
Rows before `from` or after `to` still fail. This boundary handling does not
establish whether Fastly labels buckets by their starts or ends, and totals
remain uncertified for completeness.
For `metrics`, add `--diagnose-intervals` to print out-of-window timestamps,
workspace names, and the requested window to stderr when that check fails.
This opt-in output contains no credentials, metric values, or response body;
the command still rejects the response.

For a repeatable complete UTC-day account query, use an explicit window:

```bash
fastly-audit ngwaf metrics requests_attack \
  --start 2026-09-16T00:00:00Z --end 2026-10-16T00:00:00Z --json
```

`metrics` includes every returned workspace. Filter production names with your
`prd` or `prod` naming convention when preparing a production-only
report, and review `validation.workspace_intervals` for those workspaces.

`attack-profile` ranks production workspaces using the validated
`requests_attack` timeseries. It obtains per-signal counts from
`GET /ngwaf/v1/reports/signals`, whose response lists signal counts by workspace
ID. The report has no documented `customer_id` parameter, so every reported
workspace ID and name is checked against the selected customer's inventory.
For each signal, the top production workspace total is emitted only when
every selected workspace ID (up to five) appears in that signal's
`top_workspaces` list.
An absent signal or workspace is reported with `requests: null` and an
availability status; it is never assigned zero. Fastly calls this a *top*
workspace list, so the command does not assume it enumerates every workspace.
Report workspace entries whose ID and name do not both match the selected
customer's current inventory are excluded. JSON lists their unique IDs and
count in `signal_report_diagnostics`, and stderr prints a concise warning.
The attack-signal totals have no per-day interval metadata; the timeseries
`validation` object applies to the ranking only.
Fastly does not document whether the signals report treats `to` as inclusive
or exclusive. Review this boundary limitation before using its counts in a
customer-facing period comparison.

For a selected reporting window, save the JSON outside the repository:

```bash
fa ngwaf attack-profile 2026-01-01 2026-01-30 --json > ~/Desktop/attack-profile.json
```

Translate a customer-provided NGWAF request-detail URL into the corresponding
employee navigation URL for the currently selected customer:

```bash
fastly-audit ngwaf link \
  'https://manage.fastly.com/security/ngwaf/workspaces/example-workspace/requests/example-request-id'
```

The command accepts only the observed route
`https://manage.fastly.com/security/ngwaf/workspaces/<workspace-id>/requests/<request-id>`.
It verifies the workspace against the selected customer's complete workspace
inventory, then adds the verified customer ID as the `customerId` query
parameter. An existing matching parameter is normalized rather than duplicated;
a conflicting or ambiguous parameter is rejected. The resulting link still
requires normal employee authentication and authorization. This helper does not
translate arbitrary Fastly URLs or internal SigSci console URLs, and it does not
open a browser.

Translate a customer-provided DDoS Protection event URL in the same way:

```bash
fastly-audit ddos link \
  'https://manage.fastly.com/security/ddos/protection/events/example-event-id'
```

This command accepts only the observed DDoS event-detail route. It retrieves
`GET /ddos-protection/v1/events/{event_id}` using the existing Fastly API token
and compares the event's `customer_id` with the selected customer. If the event
omits `customer_id` but includes `service_id`, the command verifies that service
through `GET /service/{service_id}` instead. Missing, conflicting, or
unverifiable ownership fails closed without printing a translated URL. The
generated link does not bypass normal authentication or authorization.

Export complete read-only DDoS event evidence for offline investigation:

```bash
fastly-audit ddos export-event example-event-id --output investigation.json
fastly-audit ddos export-event example-event-id --service example-service-id --output -
```

The export command validates the selected customer scope, retrieves
`GET /ddos-protection/v1/events/{event_id}`, verifies the event's customer or
service ownership where the API response provides enough evidence, then reads
the event-specific rule list with cursor pagination. For each associated rule
ID returned by that event-rule endpoint, it retrieves current rule details and
event/rule traffic statistics:

- `GET /ddos-protection/v1/events/{event_id}`;
- `GET /ddos-protection/v1/events/{event_id}/rules`;
- `GET /ddos-protection/v1/rules/{rule_id}`; and
- `GET /ddos-protection/v1/events/{event_id}/rules/{rule_id}/traffic-stats`.

The command does not call DDoS write endpoints, does not infer rule association
from service membership, and does not calculate false-positive classifications,
mitigation advice, or aggregate traffic totals. Event-specific rule evidence,
current rule details, and traffic-statistics responses are preserved separately.

The JSON contract is `schema: "fastly-ddos-evidence"` with
`schema_version: 1`. A sanitized envelope looks like:

```json
{
  "schema": "fastly-ddos-evidence",
  "schema_version": 1,
  "collected_at": "2026-09-23T18:00:00Z",
  "collector": {"name": "fastly-audit", "version": "24.1"},
  "scope": {
    "event_id": "example-event-id",
    "requested_customer_id": "example-customer-id",
    "customer_id": "example-customer-id",
    "service_id": "example-service-id",
    "requested_service_id": null
  },
  "collection": {
    "status": "complete",
    "missing_data_policy": "fail_closed",
    "partial_evidence_supported": true,
    "errors": [],
    "api_access": "read_only_GET_requests"
  },
  "data": {
    "event": {"response": {"id": "example-event-id"}},
    "event_rules": {"records": [], "raw_pages": []},
    "rule_details": [],
    "traffic_stats": []
  }
}
```

`--output FILE` writes with mode `0600`, refuses to overwrite an existing path,
and uses a temporary file plus atomic link into place. `--output -` writes one
valid JSON document to stdout; diagnostics and customer-scope messages stay on
stderr. A failed API request, malformed JSON response, invalid pagination
cursor, duplicate event-rule ID, mismatched event/customer/service ID, or failed
traffic-statistics request exits nonzero and does not publish a successful
bundle. The contract reserves `collection.errors` for future partial-evidence
support, but this initial implementation only emits complete bundles.

The exported file is intended as input for the separate `fastly-ddos`
investigation tool, for example:

```bash
fastly-ddos investigate investigation.json
```

Retrieve one workspace rule directly by ID without downloading the complete
rule collection:

```bash
ngwaf rule Production RULE_ID
```

The response preserves the rule object at the top level and adds `context` and
`provenance`. The command verifies that the API response contains the requested
rule ID; missing rules, malformed responses, and mismatched IDs fail closed.

### Generated VCL size

Measure active generated VCL for Fastly VCL/CDN services without printing the
generated VCL contents:

```bash
fastly-audit service vcl-size <service>
fastly-audit service vcl-size <service> --json
fastly-audit customer vcl-size
fastly-audit customer vcl-size --json
```

The single-service command resolves the service within the selected customer
token-visible service inventory, uses the active version reported by service
metadata, and retrieves `GET /service/{service_id}/version/{version}/generated_vcl`.
The customer command filters to the selected customer, skips Compute services
as not applicable, measures VCL/CDN services sequentially, and sorts successful
rows largest-first. Measurements count bytes and lines of the generated VCL
content only; JSON response overhead and HTTP headers are not counted.

### Configured Fastly Domains

```bash
fastly-audit service domains staging-is
fastly-audit service domains staging-is --version 111 --json
fastly-audit ngwaf workspace-services WORKSPACE_ID --sigsci-corp examplecorp --with-domains
fastly-audit ngwaf workspace-services --all --sigsci-corp examplecorp --with-domains --json
```

Domain discovery reads `GET /service/{service_id}/version/{version}/domain`
for the active version by default. The standalone command resolves a CDN service
by name or ID within the selected customer's token-visible inventory and needs
only public Fastly authentication. `--with-domains` preserves the mapping
command's internal credential requirements and reuses mapped service IDs and
active versions, querying each unique service/version once.

These are configured Fastly domain objects, not VCL hostname references or a
guarantee of identical NGWAF behavior for every hostname/path. A successful
empty response has COMPLETE status and count 0. Failed or malformed retrieval
has UNKNOWN status and null domains/count, and returns a nonzero exit status.
JSON enrichment adds `domains` (names), `domain_count`, and `domain_inventory`
(status, reason, endpoint, timestamp, HTTP status) to mapped services.
With enrichment, `mapping_status` preserves the mapping result,
`domain_inventory_status` reports domain retrieval independently, `domain_queries`
counts unique service/version queries, and overall `status` becomes PARTIAL
when otherwise complete mappings have incomplete domain retrieval.

### Workspace-Service Mapping

Observe workspace to CDN service mappings using existing configuration evidence:

```bash
fastly-audit ngwaf workspace-services WORKSPACE_ID --sigsci-corp examplecorp
fastly-audit ngwaf workspace-services --all --json --sigsci-corp examplecorp
CDN_SERVICE_ID='replace-with-exact-CDN-service-ID'
fastly-audit ngwaf workspace-services --service-id "$CDN_SERVICE_ID" --json --sigsci-corp examplecorp > workspace-services.json
```

This reverses confirmed `security legacy-map` generated-VCL evidence and merges
Edge WAF enabled-product configuration relationships. Each relationship retains
`mapping_sources` and source-specific evidence. In-band VCL evidence is observed
deployed configuration, not an authoritative API linkage. No observed mapping
does not prove absence of linkage. Internal site identity is reconciled to the
workspace inventory only by exact ID. A matching display name alone is retained
as unresolved legacy evidence and makes coverage incomplete. The workspace-selector
and `--all` forms scan all token-visible CDN services. They use the legacy-map internal
authentication and corp validation requirements. Incomplete source retrieval or
unresolved inspections produce PARTIAL/UNKNOWN output and a nonzero exit status;
JSON includes unresolved services and source provenance.
`legacy_service_evidence[].status = "CONFIRMED"` confirms the generated-VCL to
internal-site join; it does not by itself verify the public workspace identity.

`--service-id` selects exactly one CDN/VCL service by ID and cannot be combined
with a workspace selector or `--all`. It verifies the selected customer's
metadata and the service's exact ID, customer ID, and VCL type before reading
its configuration. It requires `FASTLY_API_TOKEN` for public Fastly APIs,
and uses `FASTLY_DSTOKEN` and `FASTLY_VOUCH_COOKIE` from a legacy Signal Sciences
dashboard session plus `--sigsci-corp CORP` or `SIGSCI_CORP` when querying the
internal site inventory. Missing legacy credentials leave that evidence
unavailable; they do not prevent a verified enabled-product mapping. Every
returned site must have a customer ID matching the
selected Fastly customer; Inspection Service ownership is also checked before
its metadata can confirm a mapping. JSON includes `selected_service`, `customer_id`,
`legacy_service_evidence`, mapped `workspaces[].services[]` with
`mapping_sources` and `mapping_evidence`, `unresolved_services`,
`unmatched_workspace_relationships`, `unresolved_product_configurations`,
`mapping_conflicts`, `relationship_status`, `status`, and `provenance`.
`NO_OBSERVED_MAPPING` describes the inspected sources, not a confirmed absence
of NGWAF attachment or deployment.

The service-scoped path requests `GET /customer/{customer_id}` for scope,
`GET /service/{service_id}` once for ownership and version, generated VCL for
that service's active version when present, and the per-service NGWAF
enabled-product probe. It requests the per-service product configuration only
when the probe succeeds. If the selected VCL contains an in-band Inspection
Service hostname, it also retrieves the shared internal NGWAF site inventory
and makes one direct `GET /service/{serviceID}` lookup per unique site
`serviceID`; this can still be costly when the corp has many sites. It reads
the paginated public workspace inventory only when either source identifies a
workspace candidate. Domain requests occur only with `--with-domains`. This
path does not enumerate CDN services or fetch generated VCL for other CDN
services. Incomplete or conflicting evidence is reported with a nonzero exit
status. These mappings do not classify deployment architecture or establish
WAFD migration eligibility.

With one workspace page, an active version, and no in-band hostname, a
negative product probe takes four requests (customer, service, generated VCL,
product probe). A product-only mapping adds its configuration and workspace
inventory, for six requests. An in-band mapping with a negative product probe
takes six plus one request per unique internal site `serviceID`: customer,
selected service, generated VCL, internal sites, product probe, workspace
inventory, and the direct Inspection Service lookups. Additional workspace
pages add requests. These counts describe the current mocked call path; they
are not live customer measurements.

JSON uses `in_band_vcl_evidence` in mapping source values and the provenance key,
and `summary.in_band_vcl_evidence_relationships` for the evidence count. These
replace the previous `legacy_generated_vcl` names without deprecated aliases.
This source identifies how a mapping was observed; it does not establish a CDN
service's current architecture. This command does not detect architecture.

Fastly's public [Edge WAF architecture terminology](https://www.fastly.com/documentation/guides/next-gen-waf/setup-and-configuration/edge-deployment/edge-waf-architecture-types/)
uses **in-band** for inline inspection and **out-of-band** for inspection that
returns a decision to the CDN service before request processing continues.
For CDN services, `ngwaf_oob_enabled = true` means out-of-band; `false` or an
unset parameter means in-band. Future architecture fields reserve `in_band`,
`out_of_band`, and `unknown`. WAFD refers specifically to internal implementation
or migration terminology associated with out-of-band, rather than a synonym
for the public architecture type.

### Customer-Scoped Service Discovery

Shared selected-customer inventory commands first use Fastly's service-search
endpoint, `GET /search/services`, with the authenticated customer ID preserved
exactly. Requests use `limit=100`, `sort=name`, and cursor pagination. An inventory
is complete only when every page is valid, cursors terminate without repetition,
service IDs are unique, totals remain consistent, and the collected count equals
`meta.total`. A validated customer can legitimately have zero visible services.

Service search is a UI-backed fast path; this project does not treat it as a
documented or stable public Service API. Unsupported responses, transport/server
failures, malformed data, or inconclusive pagination trigger a diagnosed fallback
to the existing token-visible `GET /service` inventory with exact local customer
filtering. Search HTTP 401/403 or conflicting ownership metadata fail without
fallback. If fallback also fails, the command fails rather than reporting zero.

JSON discovery provenance records the source, scope, pagination/completeness,
and whether fallback was used. Progress and fallback diagnostics stay on stderr;
cursor values are excluded from report metadata and redacted in request debug logs.
`COMPLETE` describes the returned token-visible inventory, not proof that the
token can see every service belonging to the customer.

Search `vcl` and `wasm` retain their existing CDN/Compute interpretation. Search
state and version fields remain distinct: `inactive` is not assumed to mean
`paused`, and `production_version_number` is not renamed to `active_version`.
Unavailable legacy fields remain null. Commands needing legacy active-version
or paused metadata retrieve and verify individual service details when necessary;
product/security reports do not add those detail requests. Single-service VCL
and domain commands enrich only the selected service, and an explicit domain
version requires no version enrichment.

The raw legacy inventory helper and the direct `/service` discovery in the bespoke
Costco reporting extension remain unchanged. No caching or new concurrency is
introduced by this discovery path.

### Customer Security Configuration Overview

For a concise orientation to a newly assigned customer's security configuration:

```bash
fastly-audit customer security
fastly-audit customer security --json
fastly-audit customer security help
ngwaf customer security
```

This read-only command combines the selected customer identity, token-visible
service count/status, API Discovery, Bot Management, DDoS Protection, Edge WAF
service attachments, and the complete NGWAF workspace inventory. It reuses the
security summary collector in its existing detailed configuration mode, so
DDoS mode and Bot Management ContentGuard are reported when returned by the
supported APIs. No additional product endpoints or workspace inspection calls
are introduced by the shared security summary collector. Customer security
additionally queries the Fastly NGWAF agents endpoint for each workspace.
When `SIGSCI_CORP`, `SIGSCI_EMAIL`, and `SIGSCI_TOKEN` are set, it also queries
the separate Next-Gen WAF Cloud WAF API. Missing access or inconclusive data
is reported as unavailable, not as a negative result. A Cloud WAF record needs
an exact, unique site-to-workspace match and authenticated site metadata tying
that site to the selected Fastly customer; the documented legacy site schema
does not promise this customer ID, so Cloud WAF may remain unresolved even with
valid credentials.

Human output shows product counts/status, service mappings, returned configuration,
and all workspaces, including those with zero Edge WAF attachments. Configuration
retrieval status is separate from product enablement status. Missing fields are
shown as `not reported`; unavailable configuration is never assigned a default.
Workspace attachment counts become unknown or lower bounds when mapping evidence
is incomplete. Conclusively empty product inventories are distinguished from
`UNKNOWN` or `PARTIAL` retrieval.

`ngwaf.attachment_mapping_result.status` applies only to NGWAF product-enabled
service attachments. `COMPLETE` means that product inventory was retrieved and
each returned service's configured `workspace_id` resolved uniquely in the
selected-customer workspace inventory. An empty product-enable result can be
`COMPLETE` within that scope while other deployment methods remain unverified.
The product-enable attachment counts are preserved even when a workspace join
fails. In that case, `ngwaf.attachments[]` retains the configured ID and reports
`mapping_validation.status: UNRESOLVED` with reason codes; workspace attachment counts
become lower bounds and the unresolved link cannot confirm an Edge deployment.

`NGWAF DEPLOYMENTS` reports architecture per workspace; a customer or workspace
may have multiple methods. Edge WAF service links and verified Cloud WAF
instance associations are `CONFIRMED`. Agents with or without a reported module
remain `agent_based_unknown / UNRESOLVED` until architecture is independently
verified. In particular, `sigsci-agent-revproxy` does not by itself establish
customer-managed On-Prem deployment. Zero Edge WAF
attachments do not mean no NGWAF deployment. JSON exposes stable deployment
records in `ngwaf.workspaces[].deployments[]` and source visibility separately.
Agents probes include the selected `customer_id`; failed or empty results remain
separate from workspace existence and service attachment evidence.
For a valid Agents response, `returned_agent_count` and the API's `reported_total`
are shown separately, with `total_matches_returned_count`. Their relationship
does not establish whether the list is complete because the published Agents
API does not define the meaning of `meta.total`. Returned records can support
positive agent or module observations; an empty array cannot prove absence.
Invalid records or conflicting workspace IDs remain unavailable.

JSON uses schema version 1 with `command: "customer security"`, retaining the
existing security-summary product, result, inventory-section, and provenance
structures. It omits detailed reconciliation findings but retains mapping
anomalies on configured attachments and an unresolved-attachment summary. JSON
goes to stdout; diagnostics and progress go
to stderr. Help (`help`, `-h`, or `--help`) works without credentials or customer
selection. The report requires the existing token and selected customer.

This is configuration inventory. Token-visible services do not prove complete
account-wide visibility. Product attachment and workspace existence do not prove
traffic, active workspace use, per-hostname protection, enforcement, or security
efficacy. Workspaces with no Edge WAF attachments are valid inventory context.
The command does not perform a security assessment or traffic analysis.

### One-workspace Agents API diagnostic

To inspect identifier compatibility for one authorized workspace, run:

```bash
fastly-audit ngwaf agent-diagnostic 'EXACT_WORKSPACE_ID' --json
```

The argument must exactly match an `id` from the selected customer's NGWAF
workspace inventory. The diagnostic retrieves the customer-scoped inventory,
then `GET /ngwaf/v1/workspaces/{workspace_id}?customer_id=...`. A verified
detail record supplies the ID for exactly one
`GET /ngwaf/v1/workspaces/{workspace_id}/agents?customer_id=...` request.
If detail returns HTTP 404 `Site not found`, the diagnostic uses the exact ID
from the validated selected-customer inventory and still reports the detail
failure. Both the diagnostic and `customer security` use
the selected `customer_id` for Agents requests. A successful empty response
does not establish that a workspace has no NGWAF deployment.
It does not try `workspace_uid`, legacy site names, or legacy APIs. The JSON
reports both identifier sets, the attempted path, HTTP status, a limited
sanitized error, and whether returned agent records explicitly reference the
same workspace ID. A failed Agents request or response without workspace IDs
remains unverifiable; it does not prove no agents or deployment. Agent host
telemetry and authentication headers are omitted. The command runs only when
invoked explicitly and does not alter `customer security` detection.

If workspace detail fails for another reason, or returns conflicting identity
or ownership metadata, the diagnostic exits nonzero with `status: "blocked"`.
`workspace_detail_request` reports the GET URL including
the selected-customer query parameter, path, HTTP status, sanitized `api_error`
fields, and `error_body_format`. Its `status: "lookup_failed"` is distinct from
`identifier_mismatch`, `workspace_uid_mismatch`, or `ownership_mismatch` after a
successful detail response. Malformed error bodies are labeled `invalid_json`
without printing their raw content. Every blocked result has
`agents_request.status: "skipped"`; no Agents request is made.

### Security Product Summary

Inspect selected-customer security-product coverage without querying unrelated
delivery and observability products:

```bash
fastly-audit security summary
fastly-audit security summary --json
fastly-audit security summary --detailed
```

The summary uses the shared customer-scoped service search, with fallback to
token-visible service inventory filtered by exact customer ID, and then
checks API Discovery, Bot Management, DDoS Protection, and Edge WAF service
attachments against that service set. The default summary is attachment-focused
and does not fetch Bot Management or DDoS per-service configuration. Use
`--detailed` to retrieve configuration fields such as DDoS mode and Bot
Management ContentGuard state. Edge WAF workspace/traffic-ramp mapping and the
complete NGWAF workspace collection remain included as separate context.
Product attachment coverage is sourced from the product-specific enabled-service
APIs, validated against the selected-customer service inventory, and displayed
as enabled services over token-visible customer services.

For NGWAF, Edge WAF service attachment and workspace inventory are reported as
separate facts. The command joins service-level Edge WAF attachment configuration
(`workspace_id`, `traffic_ramp`) to the discovered NGWAF workspace inventory
where possible, and flags mismatches such as missing workspaces, missing or
low traffic ramps, and duplicate attachment rows. A workspace without an Edge
WAF service attachment is reported as inventory context, not as an anomaly by
itself.

The service count is intentionally described as token-visible inventory. It
does not prove that the authenticated token can see every service in the
customer account. If the service inventory API is unavailable or returns an
unexpected shape, the command fails closed instead of substituting an
audit-event-derived count.

An enabled mapping means the product is attached in Fastly configuration. It
does not prove that the service carries current production traffic, that a
specific enforcement path is active, or that the control is effective. A
non-2xx enablement probe other than 404 is reported as unknown rather than
silently counted as disabled.

Security-product counts carry explicit result semantics. `COMPLETE` with
`count: 0` means Fastly successfully reported no matching enabled mappings.
`PARTIAL` reports `count_lower_bound` and is rendered as `>=N` in human output.
`UNKNOWN` means the count is unavailable because every relevant probe failed or
was malformed. Failures keep source, reason, and HTTP status context in JSON
under each product's `result` object.

### In-Band NGWAF Mapping Evidence

Build a read-only map from selected-customer CDN services to in-band
Inspection Services and internal NGWAF workspaces:

```bash
fastly-audit security legacy-map
fastly-audit security legacy-map example-cdn-service
fastly-audit security legacy-map example-cdn-service --format json
fastly-audit security legacy-map example-cdn-service --sigsci-corp examplecorp
fastly-audit security legacy-map --format csv --output legacy-map.csv
```

The command uses the selected-customer Fastly service inventory, inspects only
CDN/VCL services, retrieves active generated VCL, and searches for
in-band NGWAF Inspection Service hostnames such as
`se--...--....edgecompute.app`. It then reads the internal NGWAF sites inventory
for `SIGSCI_CORP` using `FASTLY_DSTOKEN` and `FASTLY_VOUCH_COOKIE`, resolves
each site `serviceID` as a Fastly Inspection Service, and confirms mappings
only when the generated-VCL Inspection Service hostname joins exactly to the
Fastly Inspection Service name and site `serviceID`.
In the production CLI, these two cookie variables are needed only for
employee/internal NGWAF site inventory used by `security legacy-map` and
`ngwaf workspace-services`. They come from a legacy Signal Sciences dashboard
session; they are not normal Fastly API credentials. `FASTLY_API_TOKEN`
authenticates requests to `api.fastly.com` independently. The current
`manage.fastly.com` authentication flow uses OIDC/OAuth and does not provide
these legacy cookies. Fastly is actively moving customers toward dashboard
unification. If employee access to the legacy Signal Sciences
dashboard/session authentication path becomes unavailable, commands that
depend on these cookies will require a replacement authentication mechanism.
`--sigsci-corp <corp>` overrides `SIGSCI_CORP` for one run.
Direct Inspection Service lookups use bounded concurrency; set
`FASTLY_AUDIT_LOOKUP_CONCURRENCY` to a positive integer up to `16` to override
the default of `8`.

Before using internal site evidence, the command validates the returned NGWAF
site `customer_id` values against the selected Fastly customer ID. A successful
query to the wrong corp, multiple returned customer IDs, or missing customer ID
evidence fails closed instead of producing ordinary unresolved rows.

`CONFIRMED` rows have direct evidence for that exact join. `UNRESOLVED`,
`AMBIGUOUS`, `NOT_FOUND`, and `UNKNOWN` rows avoid name inference and do not
claim that a workspace is absent or disabled. Cookies are required for the
internal site inventory but are not printed or persisted by the command.
JSON preserves older `legacy_ess_*` and `ess_service_id` fields as
compatibility aliases, as do the tested `legacy_inspection_service_*` fields
and historical summary keys. Prefer `inspection_service_host`,
`inspection_service_name`, and `inspection_service_id` in new consumers.
The `legacy-map` command name, helpers, trace/concurrency environment variables,
and test harness names remain historical identifiers for compatibility; they
do not assert current architecture. Its VCL evidence alone is not architecture
detection.

### Data and output contracts

| Command family | Primary source | Data class | Important interpretation |
|---|---|---|---|
| `workspace`, `rule`, `rules`, `thresholds`, `lists`, `posture` | NGWAF configuration APIs | Point-in-time configuration | Single-rule responses are identity-checked; paginated collections complete or fail; rule summaries do not simulate rule precedence. |
| `overview`, `timeseries`, `metrics` | NGWAF timeseries API | Aggregated timeseries | Uses complete UTC days; `to` is exclusive; every requested metric must be present and numeric in every returned row. |
| `attack-profile` | NGWAF timeseries and signals report APIs | Attack ranking and explicitly reported per-workspace signal counts | Timeseries ranking retains interval validation. Missing report signal or workspace counts are unavailable, not zero. |
| `count`, `signal-count`, `requests` | NGWAF request-search API | Retained searchable request records | Uses a rolling window ending five minutes before execution; `meta.total` may reflect sampled or mixed-storage records and is not raw traffic. `requests` returns a bounded set of actual rows separately from the total cohort size. |
| `rule-audit` | NGWAF rule API plus request-search API | Rule configuration plus retained-search cohort counts | Retrieves live rule configuration, counts `ruleid:<id>` and selected `ruleid:<id> tag:<signal>` intersections over one shared rolling window, and emits deterministic review indicators without treating overlapping signal cohorts as additive. |
| `template-audit` | NGWAF rules, signal thresholds, and request-search APIs | Templated signal configuration plus retained-search count | Correlates `templated_signal` tagging rules and signal thresholds into one logical control, counts retained `tag:<signal>` matches, and emits conservative review indicators without declaring remediation. |
| `ddos export-event` | DDoS Protection Events API | Event evidence bundle | Preserves the event, event-specific rules, current rule details, traffic stats, source endpoints, and cursor-pagination metadata. Collection is complete-or-fail and does not analyze, deduplicate traffic, or recommend mitigations. |
| `bot-stats` | Fastly Historical Stats | Daily service statistics | Bot metrics are sampled and scaled estimates; they are not directly comparable to unsampled `edge_requests`. |
| `services`, `products`, `inventory` | Customer-scoped service search with legacy service-inventory fallback, plus service/product APIs | Token-visible selected-customer inventory | Search uses validated exact customer scope and complete cursor traversal; fallback filters locally. Neither proves complete customer visibility. |
| `security summary`, `customer security` | Shared customer-scoped service discovery, security-product enablement/configuration APIs, and NGWAF workspaces | Cross-product configuration inventory | Service count is token-visible and selected-customer scoped; enabled does not prove traffic or enforcement; inconclusive probes remain unknown. |
| `security legacy-map` | Fastly service inventory, generated VCL, internal NGWAF sites, and Inspection Service lookups | Read-only migration mapping evidence | `CONFIRMED` requires exact CDN service generated-VCL hostname -> Inspection Service name -> site `serviceID`; unresolved or failed joins remain unknown/unresolved. |
| `attack-origins` | Per-workspace top-attacks plus NGWAF timeseries | Ranked/truncated attack dimensions | Production workspaces are selected by a documented name regex and country rows are reconciled to `requests_attack`. |

Analytical JSON includes a `window` object and a `provenance` object. Request
search reports the exact `from` and `until` values sent to the endpoint without
inventing boundary semantics that the response does not state. Workspace
JSON also reports `workspace`, `workspace_id`, and the original
`workspace_input`. These fields make the exact query interval, endpoint family,
aggregation, and missing-data policy inspectable downstream.

Missing requested metrics or non-numeric values are errors. The helper does not silently
replace those values with zero. A literal zero returned by the API remains zero.

### Large JSON transport safety

Structured JSON such as API responses, rule collections, signal summaries,
service inventories, and snapshots is streamed to `jq` through standard input.
It is not passed as a process argument using `--argjson`.

This avoids operating-system argument-size failures when inspecting customers
with large configurations, request datasets, or service inventories. Bounded
scalar numbers, booleans, and deliberately small selector arrays may continue
to use `--argjson`.

The `tests/json-transport.sh` regression test validates this contract using a
multi-megabyte JSON document and rejects known structured-payload variables
passed through `--argjson`.

### Request-search count semantics

`count` and `signal-count` return Fastly's request-search `meta.total` value.
This is a count of retained searchable request records, which may include
sampled or mixed-storage data depending on the matching signals and storage
category. It is not raw traffic and the helper does not scale it into an
estimated traffic total. Ratios calculated from these values describe shares
of searchable matches, not exact shares of all production traffic.

### Request-search drill-down

Retrieve actual retained request-search rows for a bounded cohort:

```bash
fastly-audit ngwaf requests production \
  'ruleid:RULE_ID tag:SQLI' 7 --limit 25
```

The command uses the same workspace resolution, `rule:` to `ruleid:`
normalization, 1-7 day rolling window, and five-minute ingestion buffer as
`count`. Output defaults to `--format auto`: human-readable results when stdout
is a terminal, JSON when stdout is piped or redirected, and `.json`/`.csv`
format inference for `--output` paths when no concrete format is supplied. A
concrete `--format json` or `--format csv` overrides the file extension with a
warning when they conflict.

JSON preserves each raw request object under `requests[].raw` while also
exposing common fields such as timestamp, request ID, host, path, method, source
IP, user-agent, signal names, and response code when those fields exist in the
API response.

`total_matches` reports the request-search `meta.total` cohort size when the
API supplies it. `rows_returned` reports only the bounded rows actually
retrieved. The default limit is 25 and the safety cap is controlled by
`NGWAF_REQUEST_SEARCH_MAX_LIMIT` (default 1000).

```bash
fastly-audit ngwaf requests production 'tag:SUSPECTED-BAD-BOT' \
  --limit 100 --output bad-bot-requests.json
fastly-audit ngwaf requests production 'tag:SQLI' \
  --limit 25 --format csv --output sqli-requests.csv
```

Files written with `--output` use mode `0600` and refuse to overwrite an
existing path because request rows can contain customer-sensitive details. The
success message reports the row count, for example:
`fastly-audit: wrote 25 request records to requests.json`.

### Rule audit

Automate the manual rule-analysis workflow for one or more rule IDs:

```bash
fastly-audit ngwaf rule-audit production \
  RULE_ID \
  --days 7
```

The command retrieves each rule's live configuration, counts retained matches
for `ruleid:<rule_id>`, counts selected signal intersections such as
`ruleid:<rule_id> tag:SQLI`, and reports the signal count as a percentage of
that rule's retained match count. The default signals are `SQLI`, `XSS`,
`CMDEXE`, `TRAVERSAL`, `SCANNER`, `SUSPECTED-BAD-BOT`, and `DATACENTER`.
Override them with:

```bash
fastly-audit ngwaf rule-audit production RULE_ID \
  --signals SQLI,XSS,SUSPECTED-BAD-BOT --json
```

The audit uses one shared request-search window per command invocation, with
the same 1-7 day limit and five-minute ingestion buffer as `count`. Signal
cohorts can overlap and must not be summed as unique requests. Review
indicators are deterministic observations for human review; they are not
automatic remediation advice and do not assert that traffic is malicious.

### Template Audit

Correlate a templated NGWAF signal/control as one logical unit:

```bash
fastly-audit ngwaf template-audit production "Registration Attempt"
fastly-audit ngwaf template-audit production REGATTEMPT
fastly-audit ngwaf template-audit production "Registration Attempt" --json
```

The command inventories all matching `templated_signal` tagging rules,
preserving both enabled and disabled rules, then correlates thresholds that
consume the same signal. It reports the extracted method/path/host when those
fields are present, threshold counts/windows/actions/durations, retained
request-search matches for the signal, and a drill-down command using
`fastly-audit ngwaf requests`.

Template selection prefers exact canonical signal/template identifiers such as
`REGATTEMPT`, then exact display names from API metadata. For known UI/API name
mismatches, supported exact UI labels such as `Registration Attempt` and
`Registration Attempts` resolve to the canonical signal. Partial or fuzzy names
are not guessed, and ambiguous matches fail closed.

Review indicators are intentionally conservative. They flag observations such
as disabled tagging rules, active thresholds without enabled tagging rules,
enabled tagging rules without active thresholds, identical thresholds,
duplicate tagging conditions, mixed actions/durations, and possible threshold
overlap. They do not claim that a threshold is useless, redundant, or safe to
remove.

## Installation

`fastly-audit`, `ngwaf`, and `ngwaf-update` require Bash 5.2 or newer.
On macOS, install Bash through Homebrew:

```bash
brew install bash
```

The launchers use `#!/usr/bin/env bash`, which selects the first `bash` found
in `PATH`. `/bin/bash` on macOS is Bash 3.2 and is unsupported, so ensure
Homebrew's bin directory precedes `/bin`. Verify the selected interpreter with:

```bash
command -v bash
bash --version
```

### Install From A GitHub Release

Download and run the Release installer:

```bash
curl -fsSLO https://github.com/cassiejk/ngwaf-helper/releases/latest/download/fastly-audit-installer.sh
bash fastly-audit-installer.sh
```

The Release must contain these three assets:

```text
fastly-audit-installer.sh
fastly-audit.tar.gz
fastly-audit.tar.gz.sha256
```

To install a specific release tag:

```bash
bash fastly-audit-installer.sh --version v24.1
```

To carry the first setup command into the installer output:

```bash
bash fastly-audit-installer.sh --customer-id CUSTOMER_ID
```

If `FASTLY_API_TOKEN` is already set, the installer runs the read-only setup
check for that customer. Otherwise it prints the exact command to run after the
token is available.

### Publish Release Assets

When you publish a GitHub Release for a tag that matches the script version
such as `v24.1`, the Release workflow runs the full check suite and uploads:

```text
fastly-audit-installer.sh
fastly-audit.tar.gz
fastly-audit.tar.gz.sha256
```

You can build the same assets locally without publishing anything:

```bash
./scripts/package-release --dist dist --tag v24.1
```

The packaging script refuses a tag that does not match `fastly-audit version`.

### Install From A Local Checkout

The old `ngwaf-update ./ngwaf` workflow is preserved, but the updater installs
the whole package under `~/.local/share/fastly-audit` and symlinks
`~/bin/fastly-audit`, `~/bin/ngwaf`, and `~/bin/ngwaf-update` to its entry
points.

Install the new updater once:

```bash
mkdir -p ~/bin
install -m 755 ./ngwaf-update ~/bin/ngwaf-update
```

Then future updates remain:

```bash
~/bin/ngwaf-update ./ngwaf
```

After installation, a colleague can validate their own machine and account
access with:

```bash
fastly-audit setup --customer-id CUSTOMER_ID
fastly-audit doctor --verbose
```

If `fastly-audit` is not found after installation, add `~/bin` to `PATH` and
open a new terminal. The updater prints this reminder when needed, but it does
not rewrite shell startup files.

## Refactor history

v21 deliberately did **not** change API semantics. Existing functions were moved intact from v20 into modules so behavioral regressions could be distinguished from the refactor. v21.1 was the first post-refactor behavioral release, v21.2 fixed the zero-retry test path on macOS Bash 3.2, and v21.3 made request-search sampling semantics explicit in every count result. v22 added explicit scope resolution and data-quality contracts. v23 adds diagnostics, protected configuration snapshots, local semantic diffs, and TTY-aware presentation. v23.1 adds direct single-rule retrieval with response identity validation. v23.2 hardens structured JSON transport for large customer datasets and adds dual-launcher installation validation.

### Known scope caveat retained from v20

`customer/costco.sh` contains the customer-specific `intl-bot-stats` and `intl-bot-types` commands. They remain behaviorally unchanged in v21. They should not be generalized to other customers without explicit refactoring and validation.


## Namespaced command structure

`fastly-audit` groups commands by product or resource while the `ngwaf`
compatibility command and all original flat commands continue to work:

```text
fastly-audit customer show
fastly-audit service list --json
fastly-audit service products --json
fastly-audit ngwaf rule Production RULE_ID
fastly-audit ngwaf rules Production --json
fastly-audit bot stats SERVICE_ID 30 --json
fastly-audit bot rules Production --json
fastly-audit ngwaf requests Production 'tag:SQLI' 7 --limit 25
fastly-audit ngwaf rule-audit Production RULE_ID --days 7
fastly-audit ngwaf template-audit Production "Registration Attempt"
fastly-audit snapshot ngwaf Production --output before.json
fastly-audit diff before.json after.json --check --json
```

Use `fastly-audit <namespace> help` for focused help. Existing commands such as
`ngwaf rule`, `ngwaf count`, and `fastly-audit services` remain compatibility
paths; namespacing does not alter API endpoints, scope validation, or JSON data.


### Bot Management workspace discovery

```sh
fastly-audit bot workspaces
fastly-audit bot workspaces --json
fastly-audit bot workspaces --service-id ServiceAlpha --json
```

Requires `FASTLY_API_TOKEN` with access to the selected customer and resources.
Customer scope comes from `FASTLY_CUSTOMER_ID`, or the existing saved customer
selection when that variable is unset. The command validates that customer with
`GET /customer/{CID}` and sends the exact `customer_id` on every workspace page.
It does not change the customer selection or any customer configuration.

With `--service-id`, a direct `GET /service/{SID}` must return the exact ID,
selected customer ID, and CDN (`vcl`) type before collection begins. The workspace
request is `GET /bot-management/v1/workspaces` with `customer_id`, the optional
exact `service_id`, and `limit=100`. Additional pages use `meta.next_cursor` as
`cursor`, preserving both filters. Pagination requires valid totals and an
explicit terminal `next_cursor: null`; missing metadata, changing totals,
repeated cursors, duplicate workspace IDs, or incomplete counts fail closed.
Normal request counts are **2 + P** for one service and **1 + P** for customer-wide
listing, where P is the number of workspace pages (at least one). Configured
transport retries can add requests. Neither mode enumerates CDN services, reads
generated VCL, discovers NGWAF workspaces, calls legacy Signal Sciences APIs,
collects product configuration inventories, or retrieves historical statistics.

JSON output contains `schema_version`, `customer`, `scope.service_id`,
`result.status/count/reason`, `pagination.complete/pages_fetched/total`,
`workspaces[]`, `provenance`, and `limitations[]`. Each workspace includes
`workspace_id`, `name`, `protection_mode`, `services[]`, and
`ownership_validation`. Human output shows the same workspace identifiers, names,
protection modes, service IDs, and collection count. A complete empty collection
succeeds with count zero and an explicit no-matches message. Authorization,
transport, API, schema, ownership, and pagination failures exit nonzero with
stderr diagnostics and no successful result on stdout. Scope/progress messages
also go to stderr, preserving pipeline-safe JSON.

Bot Management workspaces configure **ContentGuard pre-cache inspection** and
are distinct from **NGWAF workspaces** and NGWAF post-cache bot rules. No category
policy or individual bot overrides are retrieved. Association and configured
protection mode do not prove active inspection, runtime traffic, per-hostname
coverage, or effective enforcement. Results reflect credential-visible data.
Explicit returned customer metadata must match selected scope. A missing optional
workspace customer field is accepted based on the authenticated customer-filtered
request; it is not represented as independent ownership proof. In service mode,
the requested service association is checked against its authenticated direct
lookup. Other associated service IDs remain API-reported and are not independently
ownership-verified. Empty results do not establish that Bot Management is disabled.


### Boolean configuration evidence

ContentGuard mapping text preserves explicit Boolean `true`/`false` and string
`on`/`off` values; null or missing values display as `contentguard=unknown`.
Raw product configuration JSON, retrieval statuses, and summary counts are unchanged.
NGWAF rule-audit JSON preserves Boolean `enabled` in both `rules[].enabled` and
`rules[].configuration.enabled`, consistently with `configuration.raw.enabled`;
missing or null enablement is null and displays as `unknown`.

`fastly-audit bot rules <workspace> [--json]` (including the `bot-rules` aliases)
now returns nullable `rules[].enabled`: explicit true/false remain Booleans,
while null or missing source enablement is null, rather than an inferred false.
The human ENABLED column displays `true`, `false`, or `unknown`. Consumers must
check `.enabled == true` or `.enabled == false` explicitly and handle null as
unknown/not reported. Other fields and rule match counts are unchanged. This
change does not affect `bot workspaces` or its JSON schema.
