# NGWAF-first Platform Metrics v2 roadmap

Status: investigation and implementation plan, updated 30 October 2026. **A
read-only P0 diagnostic now exists; no Platform Metrics collector
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
The documentation names NGWAF workspaces as single-query entities but does not
give a per-metric entity eligibility table. Workspace request/gauge fields are
only **candidates** for that entity class; account gauge availability on a
workspace or on the aggregate endpoint requires verification. No existing `fa`
field is classified as exactly equivalent.
The separate aggregate endpoint is described as covering all entities for a
customer; it is not a documented account-level entity ID. No account-level
entity identifier or complete NGWAF metric-by-entity eligibility matrix is
established. The only reported successful combination is
`ngwaf_requests_total_count` on one verified workspace UID. Other combinations
are **undocumented or unobserved**, not confirmed unsupported.

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
  *returned* row. An explicit numeric zero, if returned, is a zero observation;
  the published sparse rule normally omits zero-valued keys. An omitted
  requested key is consistent with zero **only after** metric/entity support
  and the returned row's scope are established. An empty `data[]`, missing
  expected timestamp, inaccessible or unsupported metric/entity, malformed
  response, or incomplete retrieval is not documented as zero traffic. Preserve
  all of these states separately. Do not change old collectors' missing-field
  policy globally.
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
  Approximate availability is not a published finalization or correction
  guarantee; no response watermark establishing historical finality is known.
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
distinct from zero. The initial probe used public workspace `id` as an
**unverified candidate** Metrics `entity_id`; the published API did not
establish that join. The diagnostic exits nonzero even for a successful Metrics
response and does not claim P0 completion. The
existing HTTP helper does not capture Content-Type, reported as null. These
request and response-shape safeguards were checked with source review and an
offline fake API. Separately reported authenticated P0 diagnostics verified
customer and exact workspace ownership, then received Metrics HTTP 400 with
no observations. The 29 October 2026 result was classified locally as
`unsupported_parameter` with the fixed message `API reports invalid parameter`,
but it did not identify the rejected parameter or establish the underlying
cause at the time. Engineering later confirmed that `day` is not an accepted
path granularity; the local diagnostic now uses `daily`. A subsequent
authenticated `/daily` request with
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
for investigation by the Security APIs team. Engineering then reported
deploying [CONSOLE-3510](https://fastly.atlassian.net/browse/CONSOLE-3510)
on 30 October; assigned engineer Abraham Kwok confirmed that `workspace_uid`
holds the Metrics entity ID. A read-only public detail inspection for the
affected workspace returned the same UID previously queried successfully in
Metrics. This verifies that example's identifier relationship using the
reported contract, without establishing coverage for all legacy workspaces.
The reported 30 October automatic-UID diagnostic then returned HTTP 200 and
`success_with_data` for the same daily value (112963821), with complete
pagination, `mapping_verification=verified_public_workspace_detail_uid`, and
`p0_validated=false`. This is one tested workspace, not a population-wide
identity or metric-completeness result.
The diagnostic now requires a valid UID from exact, customer-owned workspace
detail; an explicit `--entity-id` must match it. This allows identity
verification for an inspected workspace but does not resolve metric semantics,
supported entity/metric combinations, or completeness. P0 remains open and
P1a is not implemented. The diagnostic output reports only
fixed, allowlisted validation labels and the error body format; raw API error
text, headers, and credentials remain excluded from that output. The optional
raw-response file is separate and may contain customer-sensitive data.
[NG-13](known-limitations.md#ng-13--legacy-sigsci-workspace-metrics-entity-id-gap)
records the observed request, remaining population-wide identity questions, and P0 resolution
criteria. The allowlist also recognizes the `errors[].property` and
`errors[].reason` form
shown in Fastly's [Origin Inspector metrics error example](https://www.fastly.com/documentation/reference/api/metrics-stats/origin-inspector/historical/);
that related API example does not establish the Platform Metrics v2 error
schema or explain the reported 400.

### P0 — API compatibility and evidence investigation (open)

- **Dependencies:** Published v2 and NGWAF contracts; synthetic fixtures;
  exact UID and customer ownership verification for an inspected workspace;
  remaining [NG-13](known-limitations.md#ng-13--legacy-sigsci-workspace-metrics-entity-id-gap)
  semantics and completeness work before claiming P0 support.
- **Acceptance:** A field-by-field scope/units record with equivalence marked
  known or unknown; verified entity ID and selected-customer ownership
  mechanism; row/meta nesting, pagination, grouping, sparse fields, and
  granularity characterized for the narrow first metric/entity combination.
  Record other combinations as unverified and identify fields with no
  documented replacement. Legacy equivalence is not required for a native
  v2-only collector.
- **Request scope:** Further documentation/local fixture work: **0 new
  authenticated requests**. A later authorized probe should be one exact
  workspace and one completed UTC window, at most one first-page GET plus
  documented cursor pages, with a
  separately justified exact ownership check; no aggregate/customer scan.
- **Tests:** Existing fake v2 responses cover sparse-present and absent rows,
  malformed metadata, unsupported entity, page continuation, and duplicate
  cursor/key. Gauge handling is a later collector test; no collector change in
  this milestone.
- **Questions:** Does v2 expose authoritative selected-customer ownership for
  `entity_id` beyond the verified exact public detail UID relationship for the
  tested workspace? Which `ngwaf` fields are supported per entity? What is the
  exact error/schema behavior for an unsupported field and how does beta
  versioning surface?

#### P0 evidence matrix (30 October 2026)

“Observed” below means the authenticated results **reported for this
investigation**, not requests made while preparing this document. Synthetic
fixtures test `fa` behavior, not the service's data contract. The twelve
published NGWAF fields, descriptions, and counter/gauge types are listed in
the compatibility matrix above; the published reference does not assign each
field to every entity type.

| Requirement | Published contract | Reported live observation | Offline synthetic evidence | Unknown; P1a impact | Next verification |
| --- | --- | --- | --- | --- | --- |
| Entity and metric eligibility | Single-entity endpoint includes NGWAF workspaces; aggregate is all entities for a customer; `ngwaf` set has eight request/bot counters and four configuration gauges. No complete per-metric/per-entity matrix or account entity ID is documented. | `ngwaf_requests_total_count` returned one value for one workspace UID. No account or aggregate query was reported. | Fake response accepts that one fixed metric on a synthetic UID. | Other workspace metrics, account-level entities, and aggregate combinations are undocumented or unobserved, **not** proven unsupported. Minimal P1a can be restricted to the observed workspace total metric; expanding metrics needs eligibility evidence. | Ask Metrics/Observability Engineering for the eligibility matrix; probe only narrowly justified combinations later. |
| Identity and ownership | Published Metrics path takes `entity_id`; its response does not document a selected-customer owner proof. | Engineering reported CONSOLE-3510 deployment and identified `workspace_uid` as the Metrics ID; exact customer-owned detail returned the working UID, and automatic-UID Metrics retrieval succeeded for the tested workspace. | Missing, malformed, empty, or conflicting UID and ownership stop before Metrics; explicit `--entity-id` must match the detail UID. | Other historical workspaces are not population-verified. P1a must repeat exact detail/ownership/UID checks per workspace. | Keep the exact checks; investigate a different workspace only if that scope is needed or conflicting evidence appears. |
| Sparse observations and bucket presence | Only nonzero keys appear in a returned row. No published guarantee says zero-only daily buckets produce a row. | One positive daily value; no reported live explicit zero, omitted requested key, empty `data[]`, or missing day. | Fixtures distinguish explicit zero, omitted key, empty data, malformed row, and absent/incomplete result. | Explicit zero is a zero value; omitted key may mean zero only for a supported metric in a valid row. Empty data, missing timestamp, unsupported combination, and failed retrieval remain distinct unknowns. P1a may report missing buckets as unknown without claiming a complete traffic total. | Ask whether supported zero-only buckets always appear and what an omitted supported key means. |
| UTC window, retention, and finality | `from` inclusive, `to` exclusive; daily buckets use UTC days. Daily availability is around 02:00 UTC next day; daily retention 365 days, minute/hour 35 days. No finalization or correction policy is published here. | One completed 26 October daily bucket was returned. | Argument checks require one completed UTC day, within retention and after the two-hour guard; returned timestamp and bounds are checked. | Approximate availability does not prove immutable historical totals. P1a can label observations provisional/unknown-finality; settled-total claims need a finality contract. | Ask for finalization and late-correction policy. |
| Pagination and completeness | `meta.from`, `meta.to`, `meta.group_by`, `meta.limit`, and `meta.next_cursor` describe scope and continuation. | Returned `group_by="timestamp"`, terminal `next_cursor=""`, one page and one bucket. | Validator checks response envelope, bounds, row key, cursor shape, duplicates/repeats, and ten-page cap; incomplete traversal fails closed. | Complete cursor traversal proves retrieval of advertised pages only. It does not prove bucket coverage, ingestion finality, or metric population completeness. P1a must label these separately. | Obtain row-emission and finality contracts; exercise additional pages only when a scoped query actually advertises them. |
| Counter/gauge aggregation | Counters sum events within intervals; NGWAF account/workspace configuration gauges are interval maxima and cannot be summed across time. | Only one request counter was observed. | Diagnostic tests one counter; no live gauge semantics were tested. | Gauge entity eligibility and meaning remain open. Minimal P1a need not collect gauges; later reporting must not sum them. | Use the published types; establish gauge eligibility before any gauge collector. |
| Legacy comparison | V2 total is described as Edge WAF and Core WAF requests; legacy `requests_total` is named but not defined as equivalent. No v2 replacement for `requests_attack` is documented. | Same UTC day: legacy `113019418`, v2 `112963821`; difference `55597` (about `0.049%`). | No synthetic test can establish live semantic equivalence. | Cause unknown: coverage, inclusion, attribution, and settlement are possibilities, **not established explanations**. Native v2-only P1a does not require equivalence; replacing legacy fields or creating aliases does. | Ask Engineering for definitions and reconciliation guidance before compatibility claims. |

The diagnostic's successful `pagination_complete=true` means **retrieval
completeness** for the returned pages. **Bucket coverage** asks whether every
expected timestamp is present. **Ingestion finality** asks whether later data
can change a bucket. **Metric population completeness** asks whether the
supported metric covers all events in its defined scope. None of the last
three follows from cursor exhaustion or HTTP 200. The diagnostic remains a P0
probe and always reports `p0_validated=false`.

#### P0 acceptance checklist and P1a boundary

Status labels describe evidence, not a new assertion that P0 has passed.

| Requirement | Status | Minimal P1a requirement or later phase |
| --- | --- | --- |
| API path and `daily` granularity | Completed for the tested request | Use the corrected `/daily` path; retain dated `/day` failure as history. |
| Exact workspace identity and selected-customer ownership | Completed in current diagnostic; must be repeated per inspected workspace | **Required:** exact public detail, matching owner, no inventory inference. |
| `workspace_uid` mapping | Verified for the tested workspace; population coverage open | **Required:** use the valid UID from that exact owned detail; reject absent/conflicting values. |
| Supported metric/entity combinations | Partially verified: one workspace total counter | **Required:** limit initial P1a to a combination with sufficient evidence; obtain eligibility evidence before adding other fields or aggregate/account scope. |
| Response envelope and cursor pagination | Locally validated; one live terminal page observed | **Required:** preserve shape, bounds, duplicate, cursor, and partial-page failures; do not label capped traversal complete. |
| Sparse-field handling | Published rule and local distinction; live zero/omission behavior open | **Required:** retain explicit value, omitted-key, and absent-row provenance. |
| Bucket-presence interpretation | Open | A constrained P1a may report absent buckets as **unknown** without totals or zero-fill; a complete-window claim needs a row-emission contract. |
| Historical data finality | Open | A constrained P1a may report observed values with unknown finality; immutable/settled totals need a correction policy. |
| Counter/gauge semantics | Published types; gauge entity eligibility open | **Required:** do not sum gauges; initial counter-only P1a can defer gauge eligibility. |
| Legacy compatibility assumptions | Open; observed values differ | Native v2-only P1a may proceed without legacy equivalence. **No alias or replacement of legacy collectors** until definitions and reconciliation are established. |

P0's investigation status remains **incomplete**. P1a readiness means a
narrow, native-v2 output contract that carries the unresolved coverage and
finality states explicitly; it does not mean those states have become known.
Broader metrics, account aggregation, and legacy reconciliation belong to
later milestones.

#### Questions for Metrics/Observability Engineering

No Metrics/Observability owner, commitment, ticket, or ETA is established in
the supplied evidence. Security APIs ownership of the historical UID issue
and CONSOLE-3510 should not be transferred to these metric-contract questions.

1. Which of the twelve NGWAF metrics are valid on individual workspace entities, account-level entities (if any), and customer aggregate queries?
2. For a supported requested metric, what does an omitted key in an otherwise valid bucket mean?
3. Are zero-only daily buckets guaranteed to produce timestamp rows, or can whole rows be omitted?
4. Is there a historical finalization or correction policy beyond approximate ingestion latency?
5. Is `ngwaf_requests_total_count` intended to be definitionally equivalent to legacy `requests_total`; if so, what are the inclusion and time-attribution rules?

#### Resuming Platform Metrics Work

No production v2 collector or P1a command exists. The implemented
[`fa ngwaf platform-metrics-diagnostic` syntax](cli-reference.md#next-gen-waf)
accepts one exact workspace ID, `--start` and `--end` for one completed UTC
day, and optional `--entity-id`, `--save-raw-response`, and `--json`. It uses
the exact customer-owned public detail UID, a single Metrics metric, and only
advertised cursor pages; it exits nonzero with `p0_validated=false` even after
a valid observation. Review the current implementation before any new probe.

P0 is still open because metric eligibility, sparse bucket emission, finality,
and legacy definitions lack sufficient contracts. The
[NG-13 limitation](known-limitations.md#ng-13--legacy-sigsci-workspace-metrics-entity-id-gap)
records the supplied [Engineering Slack discussion](https://fastly.slack.com/archives/C037JNWHR0R/p1793290562060269),
reported [CONSOLE-3510 deployment](https://fastly.atlassian.net/browse/CONSOLE-3510),
and the dated Costco example as **historical evidence only**. Do not repeat
that workspace's successful identity probe without new contradictory evidence.
Next obtain the five contract answers above; then decide whether one narrow,
authorized diagnostic extension and probe is necessary. Keep any absent bucket
unknown, preserve current legacy collectors, and do not implement P1a or claim
P0 complete from the one successful live response.

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
  in every supported case? Beyond the observed total counter on one workspace,
  which metric/entity combinations are documented? Can absent rows be left
  explicitly unknown without claiming complete-window totals?

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
