# Known limitations and resolved defects

Register for the current `fastly-audit` (`fa`) checkout, reviewed from source,
tests, and existing repository notes on 22 October 2026. A live observation
is labeled separately from local mock validation. **Unverified** means the
repository and available evidence do not settle the external API behavior.
No authenticated Fastly requests were made to prepare this register.
Statuses are: **confirmed defect**, **fixed** (locally verified), **external
API limitation**, **unresolved question**, and **known design limitation**.
An HTTP error is not proof that an endpoint is unsupported. An empty or
unavailable source is not evidence that a deployment is absent.

## Product attachment discovery

### NG-01 — Per-service NGWAF product HTTP 400

- **Status:** Unresolved question; the HTTP 400 is a reported live observation,
  but its cause and present applicability are unverified here.
- **Affected:** `fa ngwaf workspace-services --service-id`,
  `fa service ngwaf-architecture`, and product-backed security reports.
- **Observed/reproduction:** User-supplied October 2026 scoped runs returned
  HTTP 400 from `GET /enabled-products/v1/ngwaf/services/{service_id}` for a
  historical integration. Local fake responses exercise HTTP 400, including
  recognized and unrecognized error categories. No current live body or
  authoritative explanation was independently obtained for this register.
- **Impact:** This source cannot independently confirm the attachment in that
  run. It cannot be interpreted as disabled, absent, or an unsupported API.
- **Within `fa`:** Scoped mapping retains HTTP status, endpoint template,
  response format, sanitized allowlisted error category, and failure kind.
  `service ngwaf-architecture` still inspects VCL and leaves deployment
  `UNVERIFIED` / architecture `unknown` when enablement is unconfirmed.
- **Sources:** `lib/ngwaf.sh` (`workspace_services_product_for_service_json`),
  `lib/security.sh` (`workspace_services_failure_json`),
  `lib/ngwaf_architecture.sh`; `tests/workspace-services-service-id.sh`,
  `tests/ngwaf-architecture.sh`.
- **Resolution evidence/date:** Fastly's sanitized request/response contract or
  a scoped authenticated diagnosis that explains the 400. Observation: October
  2026; local handling reviewed 22 October 2026.

### NG-02 — Enabled-product inventory is not all NGWAF deployment

- **Status:** Known design limitation.
- **Affected:** `fa service products`, `fa service inventory`,
  `fa security summary`, `fa customer security`, `fa ngwaf workspace-services`.
- **Observed/reproduction:** Product APIs list their returned service
  enablements; historical Signal Sciences-managed Edge relationships can
  require generated VCL, internal site references, and Inspection Service
  metadata instead. A successfully empty product list is empty only for that
  source. See [deployment architecture](ngwaf-deployment-architecture.md).
- **Impact:** Treating product enablement as complete deployment inventory
  would omit other methods and overstate negative conclusions.
- **Within `fa`:** `workspace-services` reconciles product and legacy sources;
  security reports preserve product scope, workspace inventory, mapping
  provenance, and unresolved evidence separately.
- **Sources:** `lib/services.sh` (`discover_product_json`), `lib/security.sh`,
  `lib/ngwaf.sh`; `tests/customer-security.sh`,
  `tests/workspace-services-service-id.sh`.
- **Resolution evidence/date:** An authoritative Fastly inventory contract
  spanning product-managed and historical integrations. Code reviewed
  22 October 2026.

## Identity, ownership, and deployment evidence

### NG-03 — Historical Inspection Service owner differs from CDN owner

- **Status:** Unresolved question about Fastly's cross-customer ownership
  semantics; an observed differing `customer_id` is not itself proof of an
  invalid deployment.
- **Affected:** `fa security legacy-map`, `fa ngwaf workspace-services`.
- **Observed/reproduction:** User-supplied scoped diagnosis reported many
  HTTP 200 Inspection Service objects rejected as `ownership_mismatch`.
  The code compares the direct service response's `customer_id` with the
  selected CDN customer's ID. A missing/empty owner becomes
  `ownership_unverified`; a different one becomes `ownership_mismatch`.
- **Impact:** A configured VCL/site/Inspection Service relationship can remain
  unresolved even when its source records are individually accessible.
- **Within `fa`:** Direct configuration relationships are retained as evidence,
  while required ownership checks fail closed. Product-confirmed mappings can
  remain independently reported, with unrelated lookup failures correlated to
  their own `serviceID`.
- **Sources:** `lib/security.sh` (`legacy_map_lookup_inspection_service_json`,
  `legacy_map_rows_for_service_json`), `lib/ngwaf.sh`;
  `tests/mapping-ownership.sh`, `tests/workspace-services-service-id.sh`.
- **Resolution evidence/date:** An authoritative Fastly ownership rule for
  historical Inspection Services plus selected-service API metadata. Live
  observation supplied in October 2026; code reviewed 22 October 2026.

### NG-04 — Broad/scoped Inspection Service ownership inconsistency

- **Status:** Fixed in the current working tree, with local synthetic tests;
  live historical ownership semantics remain NG-03.
- **Affected:** `fa security legacy-map` and
  `fa ngwaf workspace-services --service-id`.
- **Observed/reproduction:** Earlier broad mapping could promote evidence
  that the scoped path rejected for missing or conflicting Inspection Service
  ownership. Current shared validation requires a matching nonempty customer
  ID for a verified same-customer relationship; name-only VCL matches do not
  satisfy ownership.
- **Impact:** The historical defect could make `CONFIRMED` conceal an unresolved
  ownership check. The current code retains an unresolved relationship instead.
- **Within `fa`:** Same validation is used by broad and scoped mapping; failures
  keep `ownership_unverified` or `ownership_mismatch` provenance.
- **Sources:** `lib/security.sh` (`legacy_map_rows_for_service_json`, ownership
  validation helpers), `lib/ngwaf.sh`; `tests/mapping-ownership.sh`,
  `tests/workspace-services-service-id.sh`.
- **Resolution evidence/date:** Local regression and a scoped live recheck of
  a historically conflicting record would increase confidence. Current source
  reviewed 22 October 2026; do not describe this as a current confirmed defect.

### NG-05 — Mixed NGWAF site ownership was over-verified

- **Status:** Fixed in the current working tree, locally testable.
- **Affected:** `fa security legacy-map`, `fa ngwaf workspace-services`.
- **Observed/reproduction:** The historical validator could call an inventory
  `VALID` when one site had matching customer ID and another lacked one.
  Current `legacy_map_validate_sites_customer_json` assigns ownership per
  site, counts verified/unverified/conflicting records, and reports `PARTIAL`
  for a mixed inventory. Downstream joins use verified sites only.
- **Impact:** Missing site ownership no longer becomes proof for a confirmed
  relationship; otherwise usable verified records remain available.
- **Within `fa`:** `PARTIAL` and site-level statuses preserve incompleteness.
- **Sources:** `lib/security.sh` (`legacy_map_validate_sites_customer_json`,
  `legacy_map_resolve_inspection_services_json`),
  `tests/mapping-ownership.sh`, `tests/workspace-services-service-id.sh`.
- **Resolution evidence/date:** Local regression and representative live
  mixed-site metadata. Current source reviewed 22 October 2026.

### NG-06 — Workspace names and IDs are different evidence

- **Status:** Known design limitation and deliberate safeguard.
- **Affected:** Workspace selectors, `fa ngwaf workspace-services`,
  `fa customer security`.
- **Observed/reproduction:** Exact ID or unambiguous case-insensitive exact
  display name can select a workspace, but a legacy site's similar display
  name alone cannot prove the public workspace identity. Product-configured
  `workspace_id` must resolve uniquely in selected-customer inventory.
- **Impact:** A plausible name match or a missing UID stays unresolved; it
  cannot establish a service-to-workspace join.
- **Within `fa`:** Exact identity checks, rejected/ambiguous mapping rows,
  and `PARTIAL`/`UNRESOLVED` statuses retain the candidate evidence.
- **Sources:** `lib/core.sh` (`resolve_workspace_json`), `lib/ngwaf.sh`,
  `lib/security.sh`; `tests/workspace-services-service-id.sh`,
  `tests/customer-security.sh`.
- **Resolution evidence/date:** Authoritative identifier correspondence for
  historical sites and public workspaces. Code reviewed 22 October 2026.

### NG-07 — Agent records do not identify deployment architecture

- **Status:** Known design limitation.
- **Affected:** `fa customer security`, `fa ngwaf agent-diagnostic`.
- **Observed/reproduction:** An agent or `sigsci-agent-revproxy` module record
  can be observed without a CDN attachment, Cloud WAF instance, infrastructure
  owner, or request path. Fastly Engineering confirmed that the legacy backend
  can inflate Agents `meta.total` by counting some agents more than once; the
  public API passes that value through (SDS-5073). Its returned `data[]` is
  correct for agents checked in during the previous two days. See
  [Agents API scope](ngwaf-agent-api.md).
- **Impact:** Agent inventory cannot prove Edge, Cloud, On-Prem, WAFD migration,
  or effective enforcement. Empty/failed Agents results cannot negate other
  confirmed sources.
- **Evidence boundary:** CDN Edge relationships need a verified service-to-workspace
  attachment or the separately validated historical in-band join. A Compute
  service has its own service identity and Edge attachment; CDN generated-VCL
  interpretation does not transfer to Compute. Cloud WAF needs an authenticated
  hosted-instance/site association. Agent-based observations establish none of
  those joins. See the [deployment evidence matrix](ngwaf-deployment-architecture.md)
  for the distinct resource owners and API limits.
- **Within `fa`:** Agent evidence is supplemental and classified
  `agent_based_unknown / unresolved`; raw returned count and reported total
  are separate. `reported_total_status` labels an inflated value as consistent
  with SDS-5073 without treating it as missing records or complete historical
  inventory. Product and Cloud associations retain independent status.
- **Sources:** `lib/security.sh` (`customer_security_agent_inventory_json`,
  `customer_security_deployments_json`), `lib/agent_diagnostic.sh`;
  `tests/customer-security.sh`, `tests/agent-diagnostic.sh`.
- **Resolution evidence/date:** Confirm deployment of a SDS-5073 fix and
  independently validate architecture association. Engineering findings
  supplied 29 October 2026; fix deployment date unknown.

### NG-08 — VCL parameter and attachment are separate facts

- **Status:** Known design limitation.
- **Affected:** `fa service ngwaf-architecture`,
  `fa ngwaf workspace-services`, `fa security legacy-map`.
- **Observed/reproduction:** Successfully retrieved active generated VCL can
  contain an exact `ngwaf_oob_enabled` declaration while the per-service
  product lookup returns HTTP 400 or another unusable response. Conversely,
  a parameter is declared absent only after a complete generated-VCL response
  is inspected. Current parser keeps raw declaration text, boolean value,
  original line numbers, numbered context, endpoint, and retrieval status.
- **Impact:** A true/false parameter is inspection-architecture evidence for
  that service/version, not independent proof of Edge WAF attachment. Unknown
  VCL retrieval cannot become an absent-parameter finding.
- **Evidence boundary:** Edge inspection architecture (in-band or out-of-band)
  and management method (Fastly control panel or historical Signal Sciences)
  are separate dimensions. Neither setting establishes deployment ownership,
  request routing, or enforcement by itself.
- **Within `fa`:** VCL retrieval is independent of product verification;
  deployment remains `UNVERIFIED` and architecture `unknown` when attachment
  cannot be confirmed. Required VCL/version failure returns nonzero; `--json`
  still emits the structured report.
- **Sources:** `lib/ngwaf_architecture.sh`, `lib/ngwaf_architecture_vcl.pl`,
  `tests/ngwaf-architecture.sh`.
- **Resolution evidence/date:** A verified attachment from an independent
  source and successful active-version VCL retrieval. Local tests passed in
  October 2026; no post-fix live service validation recorded here.

## Request cost and service discovery

### NG-09 — Exact-service mapping can fan out across legacy sites

- **Status:** Known design limitation.
- **Affected:** `fa ngwaf workspace-services --service-id`,
  `fa security legacy-map`.
- **Observed/reproduction:** When the selected CDN VCL contains a usable
  in-band hostname, scoped mapping reads the corporation site inventory and
  makes one direct `GET /service/{serviceID}` per unique eligible site
  `serviceID`. A user-supplied run reported 67 Inspection Service lookup
  failures for one selected CDN service. The request count is not necessarily
  67: local results may be reused/deduplicated; runtime count needs a trace.
- **Impact:** A service-scoped command may still be slow and collect unrelated
  lookup failures. Relevant conflicts remain fail-closed; unrelated failures
  do not erase an independently verified product mapping.
- **Within `fa`:** `--service-id` avoids CDN-wide service enumeration and VCL
  retrieval for other CDN services; lookup failures retain `serviceID` and
  sanitized status/category. The command reports progress on stderr.
- **Sources:** `lib/ngwaf.sh` (`cmd_workspace_services_service_id`),
  `lib/security.sh` (`legacy_map_resolve_inspection_services_json`),
  `tests/workspace-services-service-id.sh`.
- **Resolution evidence/date:** A documented exact site-to-Inspection-Service
  join that narrows candidates, or a scoped trace comparing unique IDs with
  actual GETs. User observation: October 2026; code reviewed 22 October 2026.

### NG-10 — Customer inventory can be expensive and token-limited

- **Status:** Known design limitation.
- **Affected:** `fa service list/products/inventory`, `fa security summary`,
  `fa customer security/vcl-size`, broad `fa ngwaf workspace-services`, and
  other commands using customer service discovery.
- **Observed/reproduction:** `get_customer_services` first traverses
  customer-scoped `/search/services` cursors; on safe non-auth failure it can
  fall back to token-visible `/service` filtered by exact customer ID. Detail
  enrichment, per-product probes/configuration, and generated VCL may add
  per-service requests. `/ngwaf/v1/workspaces` uses page/total validation.
- **Impact:** Request counts depend on page count, service count, product
  fallback, and selected detail mode. Token-visible is not proven account-wide.
- **Within `fa`:** Cursor/page safety bounds, identity checks, fail-closed
  incomplete results, explicit provenance, and stderr progress/heartbeat.
- **Sources:** `lib/services.sh` (`search_customer_services_json`,
  `get_customer_services`, `discover_product_json`), `lib/core.sh`
  (`get_all_pages`), `lib/security.sh`; `tests/service-inventory.sh`,
  `tests/customer-security.sh`, `tests/progress.sh`.
- **Resolution evidence/date:** Complete authoritative account-inventory
  contract and request traces for the command/customer of interest. Code
  reviewed 22 October 2026.

### NG-11 — Active-version resolution and generated VCL retrieval

- **Status:** Fixed in source and fake API tests; live acceptance remains
  unverified. This is **not** listed as a current confirmed defect.
- **Affected:** `fa service ngwaf-architecture`.
- **Observed/reproduction:** Previously, missing/unusable `active_version`
  from `GET /service/{id}` skipped VCL and exited zero. Current code accepts a
  trustworthy scalar or object `active_version.number`, then makes one
  read-only `GET /service/{id}/version` if absent/invalid and selects the sole
  `active: true` record. It never selects the highest version. Conflicting,
  missing, malformed, or inaccessible version evidence remains unresolved.
- **Impact:** The historical false-success path is corrected locally; a
  failed required generated-VCL retrieval now exits nonzero after JSON output.
- **Within `fa`:** Exact service/customer validation, structured version
  resolution status, endpoint/HTTP/VCL status, and raw parameter evidence when
  retrieval succeeds. Product HTTP 400 cannot block VCL retrieval.
- **Sources:** `lib/ngwaf_architecture.sh`, `lib/ngwaf_architecture_vcl.pl`,
  `tests/ngwaf-architecture.sh`.
- **Resolution evidence/date:** Scoped post-fix run on an accessible CDN
  service confirming active version and exact VCL declaration. Local tests and
  source review: 22 October 2026; no authenticated run performed here.

## Platform Metrics v2 planning

### NG-12 — Beta metrics are not yet interchangeable with NGWAF time series

- **Status:** Planned investigation; no Platform Metrics v2 collector exists in
  `fa` yet.
- **Affected:** Future NGWAF metrics work. Current `overview`, `timeseries`,
  `metrics`, `attack-profile`, and `attack-origins` retain their existing APIs.
- **Constraint:** The published Platform Metrics v2 API is beta. Its `ngwaf`
  metric set uses different field names, sparse nonzero fields, cursor pages,
  daily retention of 365 days, and minute/hour retention of 35 days. Four
  NGWAF configuration metrics are interval-maximum gauges, not additive
  counters. Similar names do not establish equivalence with legacy fields.
- **Within `fa`:** Keep old collectors and missing-data safeguards intact.
  Do not infer zero traffic from a missing row or completeness from one page.
- **Sources:** [NGWAF-first metrics roadmap](roadmap-platform-metrics.md),
  [Fastly Platform Metrics API](https://www.fastly.com/documentation/reference/api/metrics-stats/metrics-v2/platform/),
  `lib/metrics.sh`, `lib/attack_analysis.sh`.
- **Resolution evidence/date:** Establish entity ownership, supported
  metric/entity combinations, pagination and sparse-row behavior, then compare
  settled matching UTC windows using narrow read-only probes. Documentation
  reviewed 22 October 2026; no authenticated v2 request was made.

## Maintenance

Recheck this register whenever an API behavior, evidence rule, request path,
or classifier changes. Move fixed defects to **fixed** rather than leaving
historical symptoms as current failures. For commands and flags, use the
[CLI reference](cli-reference.md) and current `lib/help.sh` / `lib/dispatch.sh`.
The [README](../README.md) is the task guide; the
[deployment architecture](ngwaf-deployment-architecture.md) and
[Agents API reference](ngwaf-agent-api.md) explain the underlying evidence
boundaries. Use scoped local fixtures first; never fill an evidence gap with
a guessed relationship or a customer-wide live scan.
