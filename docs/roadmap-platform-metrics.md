# NGWAF-first Platform Metrics v2 roadmap

Status: investigation and implementation plan, updated 29 October 2026. **A
read-only P0 candidate diagnostic now exists; no Platform Metrics collector
or P1a command is implemented in `fa`.** This roadmap is
customer-agnostic and keeps the existing NGWAF collectors available until their
meaning and coverage can be reconciled with the beta API.

Sources: the published [Platform Metrics API](https://www.fastly.com/documentation/reference/api/metrics-stats/metrics-v2/platform/),
[NGWAF time series API](https://www.fastly.com/documentation/reference/api/ngwaf/timeseries/),
and [NGWAF reports API](https://www.fastly.com/documentation/reference/api/ngwaf/reports/).
The current command contracts are in [the CLI reference](cli-reference.md) and
the implementation in `lib/metrics.sh`, `lib/attack_analysis.sh`, `lib/core.sh`,
`lib/dispatch.sh`, `lib/help.sh`, and the P0 probe in
`lib/platform_metrics_diagnostic.sh`. API documentation establishes available
fields and request shapes; it does **not** establish equivalence with existing
NGWAF time series fields or confirm token access to a particular workspace.

## Current `fa` collector inventory

`fastly-audit` defines `CORE_METRICS` as `requests_total,requests_attack,requests_total_blocked`.
All commands below also use the selected-customer preflight; counts exclude that
shared request. Let **P** be the number of pages needed for the selected
customer's workspace inventory, **W** the number of selected production
workspaces, and **D** the requested days.

| Implemented command | Existing requests after preflight | Metrics and processing | Failure/completeness behavior |
| --- | --- | --- | --- |
| `fa ngwaf timeseries <workspace>` | P workspace-inventory pages to resolve ID/name, then 1 `GET /ngwaf/v1/workspaces/{id}/timeseries` | Fixed three core metrics; daily rows retained, not summed in the JSON output | Rejects missing/non-numeric requested fields and empty/malformed rows; checks complete UTC-day windows when bounded; gaps are reported, not zero-filled. |
| `fa ngwaf overview` | 1 `GET /ngwaf/v1/timeseries` plus P inventory pages | Three core metrics; normalizes split `values` objects and sums validated daily rows per workspace | Rejects duplicate/missing/nonnumeric metrics, bad timestamps, duplicate workspace/day, mismatched `meta.total`, advertised next page, and unowned/ambiguous workspace names; reports unobserved intervals and unknown completeness. |
| `fa ngwaf metrics <metrics>` | Same 1 + P | Caller-selected legacy metric names; same normalization and daily sum | Same account validation; explicit UTC window limited to 30 days. `--diagnose-intervals` exposes bounded timestamp diagnostics on stderr. |
| `fa ngwaf attack-profile` | 1 account time series + P inventory pages + 1 `GET /ngwaf/v1/reports/signals` | `requests_attack` ranks production-named workspaces; explicit signals-report counts cover only the selected top workspaces when reported | Strict ID/name matching; missing signal/workspace counts stay null. A signal count is not an enforcement outcome. |
| `fa ngwaf attack-origins` | P inventory pages + 1 account time series + W × ceil(D/7) workspace `top-attacks` GETs | `requests_attack` denominator plus bounded, possibly truncated country counts | Reports coverage against the independent denominator; a ranked top-attacks response is not a complete geographic partition. |

The account time series request uses `customer_id`, `from`, `to`,
`dimensions=workspaces,time`, and `granularity=86400`; the workspace request
uses `customer_id`, `start`, optional `end`, and `granularity=86400`.
`normalize_account_timeseries_response` merges each row's metric objects only
after validating uniqueness and numeric requested values. Existing code does
not silently turn an absent requested field into zero. Its daily timestamp
interpretation is inferred from fixtures and completeness remains unknown.
The older [NGWAF time series reference](https://www.fastly.com/documentation/reference/api/ngwaf/timeseries/)
names `requests_total`, `requests_attack`, and `requests_total_blocked` but does
not define them precisely enough to equate them with Metrics v2 outcomes.

## Platform Metrics v2 contract and compatibility matrix

The documented single-entity endpoint is
`GET /metrics/v2/platform/entities/{entity_id}/{granularity}`; a separate
`GET /metrics/v2/platform/aggregate/{granularity}` covers all entities for a
customer. The entity description includes NGWAF workspaces. Documented query
parameters include `from` (inclusive), `to` (exclusive), `metric`, `metric_set`,
`group_by`, `region`, `datacenter`, `limit` (maximum 10,000), and `cursor`.
The `ngwaf` metric set contains the twelve fields below. The response metadata
model includes `from`, `to`, `group_by`, `limit`, and `next_cursor`; rows contain
bucket-start `timestamp` and optional `region` or `datacenter` when grouped.
The documentation does not give a per-metric entity eligibility table. An
NGWAF workspace is a **candidate** entity for request and workspace gauges;
account gauge availability on that entity or on the aggregate endpoint requires
P0 verification. No existing `fa` field is classified as exactly equivalent.

In the table, **Σ** means summing validated, non-overlapping counter buckets
within a fixed entity and geographic partition. **Max/point** means retain
bucket maxima and report a chosen observation without summing over time or
geography. “Legacy arbitrary metrics” means `fa ngwaf metrics` can ask the old
API for a field by name; it does not imply an existing specialized consumer.

| Existing source/field, if any | New `ngwaf` field; kind | Candidate entity scope | Relationship | Aggregation | Equivalence evidence needed; potential `fa` consumer |
| --- | --- | --- | --- | --- | --- |
| `/ngwaf/v1/timeseries` or workspace time series: `requests_total` | `ngwaf_requests_total_count`; counter, requests | NGWAF workspace; eligibility to verify | **Unknown**: possible partial overlap, but old scope/definition is undocumented; new field includes Edge and Core WAF | Σ | Same verified workspace, UTC buckets, coverage and ingestion delay; `timeseries`, `overview`, `metrics`. |
| No direct legacy allowed-outcome field | `ngwaf_requests_allowed_count`; counter, requests | Workspace candidate | **Unknown**; `requests_total - requests_total_blocked` is not a documented allowed count | Σ | Outcome definitions and partition test; new outcome report, not `requests_attack`. |
| `/ngwaf/v1/timeseries` or workspace time series: `requests_total_blocked` | `ngwaf_requests_blocked_count`; counter, requests | Workspace candidate | **Unknown**: possible partial overlap, but scope and event basis are unverified | Σ | Side-by-side old/new blocked counts by entity and interval; `timeseries`, `overview`, `metrics`. |
| No direct legacy challenged-outcome field | `ngwaf_requests_challenged_count`; counter, requests | Workspace candidate; documented Edge WAF count | **Unknown** | Σ | Challenge event definition, repeat/solve handling; new outcome report. |
| No direct legacy logged-outcome field | `ngwaf_requests_logged_count`; counter, requests | Workspace candidate; documented Edge WAF count | **Unknown** | Σ | Whether logged overlaps other outcomes; new outcome report. |
| No direct legacy timeout-outcome field | `ngwaf_requests_timeout_count`; counter, requests | Workspace candidate; documented Edge WAF count | **Unknown** | Σ | Timeout definition and overlap; new outcome report. |
| No direct legacy unknown-outcome field | `ngwaf_requests_unknown_count`; counter, requests | Workspace candidate; documented Edge WAF count | **Unknown** | Σ | Unknown outcome definition and coverage; new outcome report. |
| `requests_attack` in NGWAF time series is an attack-tagged observation, not a bot count | `ngwaf_bot_analysis_request_count`; counter, requests | Workspace candidate | **Different** metric: Bot Management analysis versus attack tagging | Σ | Product/analysis scope and co-occurrence; possible future bot analysis, never an attack-rate replacement. |
| `fa ngwaf account-rules` configuration count at inspection time; no old gauge time series | `ngwaf_account_rules_gauge`; gauge, rules | Account-level semantics; supported query entity unverified | **Different** time basis: interval maximum versus point-in-time inventory | Max/point | Entity eligibility and snapshot/time alignment; historical configuration context. |
| Current paginated workspace inventory count; no old gauge time series | `ngwaf_account_workspaces`; gauge, workspaces | Account-level semantics; supported query entity unverified | **Different** time basis | Max/point | Entity eligibility, lifecycle and snapshot timing; historical inventory context. |
| `fa ngwaf rules` configuration count at inspection time; no old gauge time series | `ngwaf_workspace_rules_gauge`; gauge, rules | Workspace candidate | **Different** time basis | Max/point | Exact workspace identity, inherited/account-rule inclusion; historical workspace context. |
| `fa ngwaf thresholds` configuration count at inspection time; no old gauge time series | `ngwaf_workspace_thresholds_gauge`; gauge, thresholds | Workspace candidate | **Different** time basis | Max/point | Threshold inclusion and interval alignment; historical workspace context. |

There is **no documented v2 `ngwaf` metric equivalent to old
`requests_attack`**, SQLI/XSS/custom signal counts, the signals report, or
`top-attacks` country ranking. Outcome counts must not be relabeled as
detections, and no ratio of unrelated counters proves mitigation effectiveness.
The v2 request fields are documented as integer counts; the four listed gauges
are interval maxima, not summed event counts. A `metric_set=ngwaf` response may
mix account, workspace, and request fields whose eligibility differs; P0 must
establish which are actually returned for each verified entity type.

## Response handling and request-cost risks

- **Sparse fields:** The v2 data model says nonzero keys alone appear in a
  *returned* row. A missing metric key in a validated row may represent a
  documented zero, but a missing row, inaccessible metric, unsupported entity,
  malformed body, or incomplete page cannot be promoted to zero. Preserve
  present-versus-omitted provenance; define any narrow zero interpretation only
  after P0 confirms the metric was requested and supported. Do not change old
  collectors' missing-field policy globally.
- **Pagination:** Follow documented `next_cursor` with the same query and
  bounded page/row limits; reject repeated cursors, inconsistent metadata,
  duplicate entity/time/group keys, failed pages, and truncated results. Emit
  no aggregate as complete until traversal finishes. `1 + K` v2 GETs means a
  first page plus K cursor pages; K is data-dependent and grouping can raise it.
- **Windows and latency:** Use UTC-aligned, completed intervals for analysis,
  `from` inclusive and `to` exclusive. Do not query an unfinished bucket.
  Minute and hour data are retained for 35 days, daily for 365 days. Daily
  data arrives around 02:00 UTC the next day; hourly around 15 minutes after
  the hour; minute data typically after 2 minutes and sometimes 15 minutes.
  Reconciliation needs a common settled window, not a just-ended bucket.
- **Aggregation:** Counters may sum across disjoint time buckets after complete
  pagination. Gauges report each interval's maximum; summing them is invalid.
  Never add an ungrouped total to regional/POP rows or combine overlapping
  filters. Validate group key uniqueness, geography coverage, and whether POPs
  and regions form a complete partition before deriving geographic shares.
- **Beta/access:** Field sets and response shapes may change. Permission errors,
  unsupported entity/metric combinations, invalid cursors, and unavailable
  rows need separate diagnostics and nonzero/unavailable outcomes; they do not
  imply zero traffic or product absence. Keep old outputs and collectors stable.

For one exact workspace, the proposed v2 collector can need only one v2 GET
when its response fits on one page, versus the current `timeseries` path's P
inventory GETs plus one legacy GET. That is a **conditional** reduction: it
depends on a separately verified exact entity/ownership context and may need
one exact workspace verification GET and K additional cursor GETs. Existing
account `metrics`/`overview` already use one time series GET plus P identity
pages, so replacing them with aggregate v2 is not automatically cheaper.
The attack-profile signals report and attack-origins top-attacks calls have no
demonstrated v2 replacement; do not claim they can be removed.

## Milestones

P0 implementation evidence (28 October 2026): `fa ngwaf
platform-metrics-diagnostic <exact-workspace-id> --start UTC --end UTC [--json]`
uses the public Fastly token, one selected-customer preflight GET, one exact
`/ngwaf/v1/workspaces/{id}?customer_id=...` ownership check, then one
historical `/metrics/v2/platform/entities/{id}/day` GET with `from`, `to`,
`metric=ngwaf_requests_total_count`, and `limit=100`. Only a returned
`meta.next_cursor` triggers another Metrics GET, up to ten pages. It rejects
unowned or ownerless workspace details, malformed response data, repeated
cursors, and incomplete pages; sparse metric omissions and empty rows remain
distinct from zero. The code uses public workspace `id` as an **unverified
candidate** Metrics `entity_id`; the published API does not explicitly specify
whether `id` or `workspace_uid` is the correct identifier or echo an ownership
binding in its documented response. The diagnostic therefore exits nonzero
even for a valid candidate response and does not claim P0 completion. The
existing HTTP helper does not capture Content-Type, reported as null. These
request and response-shape safeguards were checked with source review and an
offline fake API. Separately reported authenticated P0 diagnostics verified
customer and exact workspace ownership, then received Metrics HTTP 400 with
no observations. The 29 October 2026 result was classified locally as
`unsupported_parameter` with the fixed message `API reports invalid parameter`,
but it did not identify the rejected parameter or establish the underlying
cause at the time. Engineering later confirmed that `day` is not an accepted
path granularity; the local diagnostic now uses `daily` and accepts optional
diagnostic-only `--entity-id ENTITY_ID`. The public workspace still requires
exact selected-customer ownership, and an external entity candidate is never
treated as a verified join. A subsequent authenticated `/daily` request with
an independently supplied Metrics entity ID returned HTTP 200 and one daily
observation. The then-current parser rejected its `meta.group_by="timestamp"`
and `meta.next_cursor=""`; this local compatibility defect is corrected.
The 30 October 2026 diagnostic then reported `success_with_data` for one
observed daily value of 112963821, with one page and complete pagination.
Legacy timeseries reported 113019418 for the same workspace and window, a
difference of 55,597 (approximately 0.049%); the difference remains
unexplained and metric equivalence is unproven. In the supplied
[Engineering discussion](https://fastly.slack.com/archives/C037JNWHR0R/p1793290562060269),
Lukas Eklund said the public Workspaces API `id` should expose the Metrics
entity ID, while affected legacy SigSci-created workspaces expose a name-like
value. Cheryl Sunley identified this as a missing integration feature owned
for investigation by the Security APIs team; no remediation ETA was available
as of 30 October. The observed Metrics response does not verify the
workspace-to-entity join or selected-customer ownership of that join. P0
remains blocked and P1a is not implemented. The diagnostic output reports only
fixed, allowlisted validation labels and the error body format; raw API error
text, headers, and credentials remain excluded from that output. The optional
raw-response file is separate and may contain customer-sensitive data.
[NG-13](known-limitations.md#ng-13--legacy-sigsci-workspace-metrics-entity-id-gap)
records the observed request, remaining identity questions, and P0 resolution
criteria. The allowlist also recognizes the `errors[].property` and
`errors[].reason` form
shown in Fastly's [Origin Inspector metrics error example](https://www.fastly.com/documentation/reference/api/metrics-stats/origin-inspector/historical/);
that related API example does not establish the Platform Metrics v2 error
schema or explain the reported 400.

### P0 — API compatibility and evidence investigation (open)

- **Dependencies:** Published v2 and NGWAF contracts; synthetic fixtures;
  resolution of [NG-13](known-limitations.md#ng-13--legacy-sigsci-workspace-metrics-entity-id-gap)
  before claiming live support.
- **Acceptance:** A field-by-field scope/units/equivalence record; verified
  entity ID and selected-customer ownership mechanism; row/meta nesting,
  pagination, grouping, sparse fields, granularity, and supported metric/entity
  combinations characterized. Explicitly identify fields with no replacement.
- **Request scope:** Further documentation/local fixture work: **0 new
  authenticated requests**. A later authorized probe should be one exact
  workspace and one completed UTC window, at most one first-page GET plus
  documented cursor pages, with a
  separately justified exact ownership check; no aggregate/customer scan.
- **Tests:** Fake v2 responses for sparse-present row, absent row, malformed
  metadata, unsupported entity, page continuation, duplicate cursor/key, and
  counter/gauge handling; no collector change in this milestone.
- **Questions:** Does v2 expose authoritative selected-customer ownership for
  `entity_id`, or must `fa` use a separate exact NGWAF detail? Which `ngwaf`
  fields are supported per entity? What is the exact error/schema behavior for
  an unsupported field and how does beta versioning surface?

### P1a — Single NGWAF workspace metrics

- **Dependencies:** P0 identity, ownership, permission, and response-shape
  answers; shared `lib/core.sh` HTTP/error conventions.
- **Acceptance:** One explicitly selected, verified workspace returns raw
  bucket observations, units, UTC window, requested/returned field presence,
  pagination/completeness, and exact provenance. An exact verified ID must not
  trigger an account-wide inventory traversal. Ambiguous or unverified identity
  fails closed; existing commands remain unchanged.
- **Request scope:** One exact-entity v2 first page + K cursor pages; only an
  exact-resource ownership GET when P0 establishes it as authoritative. No
  aggregate endpoint, service enumeration, or legacy fan-out.
- **Tests:** Local fake responses for identity/ownership failure, explicit
  zero versus omitted key, missing bucket, malformed shape, cursor failures,
  complete multi-page output, stdout/stderr separation, and request count.
- **Questions:** Can an exact customer-scoped NGWAF detail establish ownership
  in every supported case? Which first counter has reliably documented
  workspace eligibility and how are absent rows represented?

### P1b — NGWAF traffic and outcome analysis

- **Dependencies:** P1a; demonstrated outcome-field availability and meanings.
- **Acceptance:** Distinct allowed, blocked, challenged, logged, timed-out,
  unknown, total, and bot-analysis observations with explicit Edge/Core scope.
  Detection/signal counts stay separate; no inferred attack rate or efficacy.
  POP/datacenter and region views are offered only when group coverage and
  non-overlap are verified.
- **Request scope:** One entity query + K pages per requested grouping/window;
  additional groupings are separate opt-in queries, never implicit fan-out.
- **Tests:** Outcome overlap and missing-field fixtures; geographic duplicate,
  partial-coverage, and non-additive total fixtures; beta error cases.
- **Questions:** Do outcomes partition `total`, or can they overlap? Are logged
  and challenged Edge-only in all returned rows? Are regions/POPs exhaustive?

### P1c — Reconciliation and validation

- **Dependencies:** P1a/P1b plus old collector results for the same verified
  entity and settled UTC window.
- **Acceptance:** Side-by-side old/new values with independent provenance,
  scope, unit, timestamp, latency, and completeness annotations. Only
  explicitly established equivalence permits a compatibility alias; no old
  collector is removed or rewritten merely because a name looks similar.
- **Request scope:** At least one old workspace time series GET and one v2
  exact-entity first page + K cursor pages, plus justified ownership lookup;
  no customer-wide traversal when exact identity is independently verified.
- **Tests:** Mock equal, unequal, sparse, delayed, and different-scope windows;
  preserve old JSON/exit behavior and report unresolved comparisons.
- **Questions:** Do legacy and v2 counters cover the same Edge/Core paths,
  sampled populations, and bucket boundaries? How long until values settle?

### P2 — NGWAF historical security reporting

- **Dependencies:** P1c reconciliation, complete pagination, stable beta
  schema and documented retention behavior.
- **Acceptance:** Daily trends within 365 days and shorter minute/hour views
  within 35 days; no gap-filled certainty. Validated, non-overlapping time and
  geographic aggregation; gauges rendered as interval maxima or points, never
  summed. Security-review/QBR exports retain uncertainty and provenance.
- **Request scope:** One selected entity and window per report, 1 + K pages;
  any comparison or geographic grouping is explicit and separately budgeted.
- **Tests:** Retention edges, late data, sparse rows, DST/UTC boundaries,
  multiple pages/groups, incomplete geography, and gauge non-additivity.
- **Questions:** What stable historical identity exists across workspace
  rename/recreation? Can daily geographic rows be reconciled to an ungrouped
  total without double-counting?

### P3 — Other Fastly security products

- **Dependencies:** Stable NGWAF patterns and documented product metric sets.
- **Acceptance:** Evaluate Bot Management and ContentGuard-related telemetry
  first, then Anti-DDoS metric sets; label each product's scope and units.
  Historical telemetry never stands in for enforcement configuration.
- **Request scope:** One exact product entity + K pages per explicit metric
  set/window. No hidden cross-product or customer-wide collection.
- **Tests:** Unsupported product/entity, sparse and delayed data, product
  boundaries, and explicit separation from configuration findings.
- **Questions:** Which product/entity pairs and permissions are supported?
  Are Bot Management sampling semantics comparable to existing `fa bot stats`?

### P4 — Account-wide aggregation

- **Dependencies:** P1-P3 narrow-query reliability, ownership and completeness
  semantics, documented aggregate behavior.
- **Acceptance:** Explicit customer scope and request budget, bounded cursor
  traversal, progress/idle heartbeat on stderr, completeness metadata, and no
  implicit customer-wide call from a workspace command.
- **Request scope:** Opt-in `GET /metrics/v2/platform/aggregate/{granularity}`
  first page + K cursor pages; grouped views or time splits increase this
  budget and must be disclosed before execution.
- **Tests:** Multi-entity identity, duplicate keys, changing cursor, partial
  page failure, progress and stdout separation, and large-result limits.
- **Questions:** Does the aggregate preserve per-entity identity and ownership,
  and how are account gauges represented alongside workspace counters?

## Recommended first implementation after P0

**Proposed only; this is not an available `fa` command.** Following the
existing `fa ngwaf <command>` and `--json` conventions, introduce
`fa ngwaf platform-metrics <exact-workspace-id> --from UTC --to UTC [--json]`.
The first version should request **only** `ngwaf_requests_total_count` at
`daily` granularity for one completed, UTC-midnight-aligned range, using the
documented `metric` parameter. Defer `metric_set=ngwaf` and `--group-by
region|datacenter` until field eligibility and geographic completeness are
verified; do not advertise those options before implementation.

Resolve only a verified exact NGWAF workspace ID, retain the selected
customer context, and fail if the P0 ownership mechanism cannot prove that
entity belongs to it. The platform request needs one first-page GET plus K
documented cursor GETs; an exact-resource ownership GET is conditional. Use
explicit `from` inclusive and `to` exclusive; refuse unfinished/expired daily
buckets. JSON should carry `schema_version`, command, customer/workspace IDs,
requested metric and unit (`requests`), UTC window/granularity, raw timestamped
field presence and values, page count/continuation, completeness status, and
endpoint/provenance. Human output should show each daily observation and
distinguish an omitted field from an absent day. JSON stays on stdout;
progress and sanitized errors stay on stderr. A failed page, unsupported
entity, ownership conflict, malformed row, or uncertain completeness yields a
nonzero exit without a complete total. Local fake-response tests should cover
all of these cases before any authenticated, narrowly scoped validation.
