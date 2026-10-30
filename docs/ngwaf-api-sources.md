# NGWAF API sources, authentication, and evidence in `fa`

Current-checkout reference, reviewed 29 October 2026 against `fastly-audit`,
`lib/dispatch.sh`, `lib/help.sh`, the command implementations, and fake-response
tests. `fa` is the interactive alias for `fastly-audit`; command forms below use
the primary launcher. All implemented remote operations described here are
reads. This is a map of what the CLI **currently calls**, not a proposal to
query other APIs. See the [CLI reference](cli-reference.md) for all options and
the [deployment reference](ngwaf-deployment-architecture.md) for terminology.

## Authentication domains and endpoint catalog

| Domain | Base, credentials, resource model | Implemented GET paths and use | Contract boundary |
| --- | --- | --- | --- |
| **F: public Fastly API** | `https://api.fastly.com` (`API_BASE` in `fastly-audit`); `Fastly-Key: $FASTLY_API_TOKEN` through `get` or `http_get_to_file` in `lib/core.sh`. Selected customer is verified with `/customer/{customer_id}` before scoped commands. | `/customer/{customer_id}`; `/search/services` with cursor, or token-visible `/service` fallback; `/service/{id}` and `/service/{id}/version`; `/service/{id}/version/{version}/generated_vcl`; optional `/service/{id}/version/{version}/domain`. The P0 probe alone calls `/metrics/v2/platform/entities/{entity_id}/daily`. These provide customer, service, version, VCL, domain configuration or inventory, and candidate metrics observations. | Public [Service API](https://www.fastly.com/documentation/reference/api/services/service/), [NGWAF product API](https://www.fastly.com/documentation/reference/api/products/ngwaf/), and [Platform Metrics API](https://www.fastly.com/documentation/reference/api/metrics-stats/metrics-v2/platform/). A completed token-visible service search or `/service` list does not prove account-wide visibility. |
| **F: public Fastly NGWAF** | Same base and token; Fastly customer and workspace `id`/`workspace_uid` model. | `/ngwaf/v1/workspaces` and `/{workspace_id}`; workspace `/agents`, `/rules`, `/rules/{rule_id}`, `/thresholds`, `/lists`, `/requests`, `/timeseries`, `/top-attacks`; account `/ngwaf/v1/rules`, `/lists`, `/timeseries`, `/reports/signals`. Inventory, configuration, agent observations, retained requests, and time-series/report observations are different data classes. | Public [NGWAF API index](https://www.fastly.com/documentation/reference/api/ngwaf/), [Agents](https://www.fastly.com/documentation/reference/api/ngwaf/agents/), [Workspaces](https://www.fastly.com/documentation/reference/api/ngwaf/workspaces/), [Reports](https://www.fastly.com/documentation/reference/api/ngwaf/reports/), and [Timeseries](https://www.fastly.com/documentation/reference/api/ngwaf/timeseries/) references. The public individual-agent GET is documented but **not called** by `fa`. |
| **F: public product APIs** | Same base and token; enabled products attach to Fastly service IDs. | `/enabled-products/v1/{product}/services`, `/{service_id}`, `/{service_id}/configuration`; NGWAF uses product `ngwaf`. Security summaries also inspect API Discovery, Bot Management, and DDoS Protection product families. | Public [NGWAF product reference](https://www.fastly.com/documentation/reference/api/products/ngwaf/). Product attachment is configuration, not proof of live inspection; historical SigSci-managed Edge integrations may be absent. |
| **S: legacy Signal Sciences management API** | `https://dashboard.signalsciences.net/api/v0`; `x-api-user: $SIGSCI_EMAIL`, `x-api-token: $SIGSCI_TOKEN`, plus `SIGSCI_CORP`. Corp/site and hosted Cloud WAF instance model. Separate from the Fastly token. | `customer security` optionally reads `/corps/{corp}/cloudwafInstances`, each `/{instance_id}`, and `/corps/{corp}/sites/{site_name}` to validate instance-to-site association and `customer_id`. | Public [Signal Sciences API reference](https://www.fastly.com/documentation/signalsciences/api/); the exact fields used by this collector must still be validated in returned metadata. Missing credentials or incomplete/mismatched identities yield unavailable evidence. |
| **I: internal SigSci console** | `https://sigsci-console-internal.secretcdn.net/api` by default; `Cookie: dstoken=$FASTLY_DSTOKEN; VouchCookie=$FASTLY_VOUCH_COOKIE`, plus selected `SIGSCI_CORP`. This is a browser-session, corp/site identity domain. | The **only implemented internal GET** is `/v0/corps/{corp}/sites`, in `legacy_map_fetch_sites_json`. It supplies site rows and possible `serviceID` Inspection Service references for historical Edge mapping. `fa` does not call this console's per-site agents endpoint. | Internal, undocumented response contract. Session authentication, site identifiers, completeness, and field meanings cannot be transferred to the public Fastly NGWAF API. No live internal request was made for this document. |
| **Adjacent Fastly sources** | Same F token and base. | `bot workspaces` reads `/bot-management/v1/workspaces`; `bot stats` reads `/service/{id}` and `/stats/service/{id}`. Optional workspace-service domain enrichment uses the Fastly domain path above. | Bot product configuration and service stats have their own scopes; neither classifies NGWAF architecture. `ngwaf bot-rules` instead reads NGWAF workspace rules. |

The [Platform Metrics v2 API](https://www.fastly.com/documentation/reference/api/metrics-stats/metrics-v2/platform/) is used only by the temporary P0 `ngwaf platform-metrics-diagnostic` probe. Following Engineering's granularity clarification, it calls the single-entity `/metrics/v2/platform/entities/{entity_id}/daily` path after exact public workspace detail ownership validation; no production v2 collector or aggregate query exists. The diagnostic now requires a valid `workspace_uid` from exact, selected-customer-owned public workspace detail and uses it as the Metrics entity ID. An optional `--entity-id` must match that UID; missing or conflicting identity stops before Metrics. Engineering reported deploying CONSOLE-3510 on 30 October 2026, and the affected example returned the previously queried Metrics entity ID as its UID. This verifies the example relationship, not all legacy workspaces or P0 metric semantics. The earlier `/day` HTTP 400 and remaining P0 work are tracked in [NG-13](known-limitations.md#ng-13--legacy-sigsci-workspace-metrics-entity-id-gap); P1a remains blocked. See the [investigation roadmap](roadmap-platform-metrics.md). `lib/services.sh` also contains an event-assisted service-discovery helper, but current customer service discovery uses search with `/service` fallback; event history is not substituted for unavailable inventory. See `get_customer_services` and `get_token_visible_customer_services`.

## Internal SigSci/Salt console authentication

The operational workflow supplied for this document is manual: a Fastly
employee signs in to `https://sigsci-console-internal.secretcdn.net` in a
browser, uses Firefox Developer Tools to view that host's `dstoken` and
`VouchCookie` cookies, and supplies their values to the existing credential
workflow as `FASTLY_DSTOKEN` and `FASTLY_VOUCH_COOKIE`. Session changes or expiry
may invalidate them. This describes user-supplied workflow, not a verified
cookie-extraction, persistence, or refresh implementation in this repository.
Do not automate browser access or record cookie values in command examples,
debug output, fixtures, or documentation.

The browser resource shape
`https://sigsci-console-internal.secretcdn.net/corps/<corp>/sites/<site>`
is **not** the API endpoint. The implemented API base is
`https://sigsci-console-internal.secretcdn.net/api` by default (overridable
with `FASTLY_NGWAF_INTERNAL_API_BASE`). `legacy_map_fetch_sites_json` requests
only `GET /api/v0/corps/{corp}/sites`, using `SIGSCI_CORP` or the supported
`--sigsci-corp` option for the corporation slug. `fastly-audit security
legacy-map` consumes this list; `fastly-audit ngwaf workspace-services` consumes
it for historical mapping (the exact-service path requests it only when
generated VCL yields a candidate and credentials are present). The site list's
`serviceID` refers to a possible Inspection Service and requires separate
public Fastly service identity and ownership validation. Neither the site name
nor an internal agent record establishes a public workspace ID.

The checkout contains no `fa-creds` or `fastly-creds` implementation.
`dev/unifier-check/README.md` describes a separate `fastly-creds` shell workflow
that exports credential variables, but this checkout cannot verify its loading,
storage, lifetime, or refresh behavior. `fa` reads the environment variables
directly; it does not implement cookie extraction or a credential store here.
The internal request constructs `Cookie: dstoken=...; VouchCookie=...` and passes
it as a curl `-H` argument. The source does not intentionally print these
values, but local process inspection or shell tracing could expose command
arguments. Do not claim that values cannot appear in process arguments or that
an external helper keeps them only in memory.

| Surface | Hostname and status | Authentication and environment | Resource IDs | Supported evidence; documentation | Current `fa` consumers; limits |
| --- | --- | --- | --- | --- | --- |
| Public Fastly NGWAF | `api.fastly.com`; customer-accessible with authorization | `Fastly-Key` from `FASTLY_API_TOKEN` | Fastly customer, public workspace `id`/`workspace_uid`, public agent ID | Published NGWAF API: workspace configuration and Agents observations; neither proves deployment type or enforcement | `customer security`, `ngwaf workspaces`, `ngwaf agent-diagnostic`, and other public workspace commands; credential-visible and Agents completeness limits apply |
| Platform Metrics v2 | `api.fastly.com`; public beta API | `Fastly-Key` from `FASTLY_API_TOKEN` | Metrics `entity_id` from verified public workspace `workspace_uid`; legacy public `id` remains a separate selector | Candidate historical metric observations after successful entity query and response validation, not legacy metric equivalence | Temporary `ngwaf platform-metrics-diagnostic` P0 probe only; identity checked per exact detail; P0 semantics open [NG-13](known-limitations.md#ng-13--legacy-sigsci-workspace-metrics-entity-id-gap), no P1a collector |
| Legacy Signal Sciences management | `dashboard.signalsciences.net`; public management API | `x-api-user`/`x-api-token` from `SIGSCI_EMAIL`/`SIGSCI_TOKEN`, with `SIGSCI_CORP` | Corporation, site, Cloud WAF instance | Published legacy API: configured instance/site association, subject to returned identity and ownership | Optional `customer security` Cloud WAF collector; missing credentials or unresolved association remain unavailable |
| Internal SigSci/Salt console | `sigsci-console-internal.secretcdn.net`; Fastly-only | Browser-session `dstoken`/`VouchCookie` from `FASTLY_DSTOKEN`/`FASTLY_VOUCH_COOKIE`, plus corp slug | Internal corporation/site; site `serviceID` reference | Undocumented internal contract: site inventory and historical Inspection Service reference, not public Agents identity | `security legacy-map` and `ngwaf workspace-services`; internal list completeness and cross-source identity remain conditional |

### Protection and agent fields are not interchangeable

| Field | Source | Meaning and limit |
| --- | --- | --- |
| `mode` | Public NGWAF workspace API | Configured workspace protection mode; not an individual agent activity signal. |
| `agentLevel` | Legacy Signal Sciences site API | Legacy site protection-mode setting; verify its source contract before comparing it with workspace mode. |
| `agentMode` | Internal SigSci/Salt site response | Observed site protection-mode field; precise undocumented contract needs independent verification. |
| `agent_enabled` | Public NGWAF Agents API | Individual-agent enablement, not deployment type or site protection mode. |
| `agent_active` | Public NGWAF Agents API | Individual-agent activity observation, not enforcement or a site protection setting. |

Similar names and values do not make these fields contractually equivalent. An
On-Prem agent can communicate with Fastly management infrastructure. Internal
site inventory does not prove On-Prem deployment; public Agents records do not
classify On-Prem, Edge, or Cloud WAF. Similar site and workspace identifiers do
not establish a cross-API relationship without exact, unique, owned joins.

## Request accounting

Every scoped command starts with **C = one `GET /customer/{selected_id}`** through `dispatch_preflight` / `confirm_customer_scope`; some collectors make an additional customer GET. The tables below exclude C and transport retries. `get` and `http_get_to_file` use the configured curl retry budget (normally one retry); `agent-diagnostic` explicitly uses zero retries for detail and Agents requests. A failed command can stop before its full budget.

Definitions: **P** = pages of the selected customer's NGWAF workspace inventory (`limit=100`, page based); **R/L** = pages of a rule/list collection; **S** = customer service discovery pages (`/search/services` cursor, or one `/service` fallback), plus optional per-service detail enrichment; **N** = selected services; **U** = distinct internal-site `serviceID` values looked up as Inspection Services; **W** = selected production workspaces; **D** = requested days; **Q** = retained-request search pages; **I/J** = Cloud WAF instance details / unique referenced site details. Each paginated collection has at least one GET, including an empty result. `get_all_pages` aborts on early or short incomplete retrieval and bounds traversal at 1,000 pages; if `meta.total` changes it warns and uses the latest total. Service search separately validates cursor termination, count, unique IDs, and ownership metadata when returned. These are **logical GET counts**; retries can increase network attempts.

### Inventory and architecture commands

`F`, `S`, and `I` refer to the authentication domains above. Endpoints below are GETs; paths omit the base URL and query parameters. Unless noted, selected-customer scope is sent where the implementation supports it. Exact syntax is from `lib/help.sh`, with parsing in the named modules.

| Implemented command and function | Domain; paths and IDs | Requests after C; pagination and evidence limit |
| --- | --- | --- |
| `fastly-audit ngwaf workspaces` — `cmd_workspaces`, `lib/ngwaf.sh` | F `/ngwaf/v1/workspaces`; selected customer ID. | **P**. Human output lists workspace names and IDs; the underlying inventory may contain configuration fields, but this command does not report deployment or traffic proof. |
| `fastly-audit ngwaf agent-diagnostic <workspace-id> [--json]` — `cmd_ngwaf_agent_diagnostic`, `lib/agent_diagnostic.sh` | F `/ngwaf/v1/workspaces`, `/{id}`, `/{id}/agents`; exact inventoried workspace ID. | **P + 2** after successful inventory (detail, then one list GET); detail failure can skip Agents. No per-agent detail GET. Reports identity/count, returned-agent health, and public API source context, not raw agents or architecture. |
| `fastly-audit ngwaf platform-metrics-diagnostic <workspace-id> --start UTC --end UTC [--entity-id ENTITY_ID] [--save-raw-response FILE] [--json]` — `cmd_platform_metrics_diagnostic`, `lib/platform_metrics_diagnostic.sh` | F exact `/ngwaf/v1/workspaces/{id}` with `customer_id`, then `/metrics/v2/platform/entities/{entity_id}/daily` with one metric. The UID from exact detail selects the Metrics path; an optional entity ID must match it. | **1 detail + 1 Metrics first page + K advertised cursor pages**, at most ten Metrics pages after customer preflight. No workspace inventory or aggregate query. The raw option copies the first Metrics body to a new 0600 file before parsing; that body may contain customer-sensitive information. Exact public workspace owner metadata is required; the detail UID relationship can be verified for the inspected workspace; P0 remains unvalidated, so the command exits nonzero even after an HTTP 200. |
| `fastly-audit customer security [--json]` — `cmd_customer_security`, `lib/security.sh` | F customer, S services, product list/probes/config, P workspaces, one F Agents list per workspace; optional S Cloud WAF list/details/sites. | Additional customer GET + **S + product fan-out + P + one Agents GET per workspace**, with guarded UID retry only after HTTP 400, plus optional **1 + I + J** S GETs. May be expensive; product and agent source statuses remain distinct. Edge/Cloud records are configured associations, agent type stays unresolved. |
| `fastly-audit security summary [--json] [--detailed]` — `cmd_security_summary`, `lib/security.sh` | F customer, S services, security product list/probes/config, P workspaces. | Additional customer GET + **S + product fan-out + P**. `--detailed` adds supported per-service configurations. No Agents or Cloud WAF probe. |
| `fastly-audit service products [--json]` — `cmd_products`, `lib/services.sh` | F customer, S services, product list/probes/config including NGWAF. | Additional customer GET + **S + product fan-out**; attached products among token-visible services. |
| `fastly-audit service inventory [--json]` — `cmd_inventory`, `lib/services.sh` | F customer, S services, product families, P workspaces. | Additional customer GET + **S + product fan-out + P**; configuration inventory, not enforcement. Top-level `inventory` routes to the same implementation. |
| `fastly-audit service list [--json]` — `cmd_services`, `lib/services.sh` | F customer and `/search/services` or `/service`; selected customer ID. | Additional customer GET + **S**; service inventory only. The `/service` fallback is token-visible and locally filtered. |
| `fastly-audit service ngwaf-architecture <service-id-or-name> [--version N] [--show-vcl] [--json]` — `cmd_service_ngwaf_architecture`, `lib/ngwaf_architecture.sh` | F exact `/service/{id}`, possible `/service/{id}/version`, CDN `/service/{id}/version/{n}/generated_vcl`, `/enabled-products/v1/ngwaf/services/{id}`. Exact name on 404 triggers S discovery. | Normally **1 service + 1 product + 1 VCL** for CDN; optional version-list GET, name fallback S and second detail GET. Compute skips VCL. `--version` may inspect inactive configuration; Edge in/out of band is classified only with confirmed active attachment. Does not classify On-Prem. |
| `fastly-audit security legacy-map [service-name-or-id] [--sigsci-corp CORP] [--format human\|json\|csv] [--output FILE]` — `cmd_security_legacy_map`, `lib/security.sh` | F S service inventory/details, active generated VCL per selected CDN service, exact `/service/{serviceID}` for I site references; I `/v0/corps/{corp}/sites`. | Broad even with a service selector: service discovery, generated VCL per selected service, one internal corp-site list, and up to **U** Inspection Service details. Historical in-band join only after site/host/service identity and ownership checks. |
| `fastly-audit ngwaf workspace-services <workspace>\|--all [--json] [--sigsci-corp CORP] [--with-domains]` — `cmd_workspace_services`, `lib/ngwaf.sh` | F P workspace inventory, S services/product attachment/config; I site list and F generated VCL/Inspection Service lookups through `legacy-map`. | A workspace selector still triggers broad legacy mapping/service discovery; workspace inventory is read for selector and reconciliation. Optional domain GET per mapped service. Configured mapping, not current request path. Requires internal session credentials in this mode. |
| `fastly-audit ngwaf workspace-services --service-id <exact-CDN-service-ID> [--json] [--sigsci-corp CORP] [--with-domains]` — `cmd_workspace_services_service_id`, `lib/ngwaf.sh` | F exact `/service/{id}`, its active generated VCL, per-service NGWAF enablement and optional config; conditional I sites and F Inspection Service details; conditional P workspace inventory; optional F domains. | No customer service enumeration, but **1 detail + up to 1 VCL + 1 product + optional config + conditional 1 internal sites + U Inspection Service lookups + conditional P**. `U` can be large despite exact service selection. `--with-domains` adds per-mapped-service requests. Missing/conflicting ownership remains unresolved or fails closed. |

Product fan-out means list GETs for the supported security-product families, possible per-service status probes when list evidence is unusable, and configuration GETs for qualifying services in detailed modes. There is no safe fixed account-wide request total. See `discover_product_json` in `lib/services.sh` and [the CLI cost index](cli-reference.md#compatibility-routes-and-request-cost). The internal site list is not a general NGWAF deployment inventory.

### Workspace configuration and observations

All rows use F unless stated otherwise. Each `<workspace>` is resolved through **P** selected-customer inventory pages by exact ID first, otherwise one case-insensitive exact name; an exact ID does **not** currently bypass inventory. Request-search counts are retained searchable records and may be sampled or mixed-storage, not raw traffic totals.

| Implemented command and function | GET paths after workspace resolution | Requests after C; evidence limit |
| --- | --- | --- |
| `fastly-audit ngwaf workspace <workspace>` — `cmd_workspace`, `lib/ngwaf.sh` | `/{id}` under `/ngwaf/v1/workspaces` | **P + 1**; workspace configuration. |
| `fastly-audit ngwaf rule <workspace> <rule_id>` — `cmd_rule`, `lib/ngwaf.sh` | `/{id}/rules/{rule_id}` | **P + 1**; one rule configuration, exact rule ID check. |
| `fastly-audit ngwaf rules <workspace> [--list\|--json]` — `cmd_rules`, `lib/ngwaf.sh` | `/{id}/rules` | **P + R**; paginated workspace rules. |
| `fastly-audit ngwaf account-rules [--list\|--json]` — `cmd_account_rules`, `lib/ngwaf.sh` | `/ngwaf/v1/rules` | **R**; account rules, not one workspace's rules. |
| `fastly-audit ngwaf thresholds <workspace> [--json]` — `cmd_thresholds`, `lib/ngwaf.sh` | `/{id}/thresholds` | **P + 1**; threshold configuration. |
| `fastly-audit ngwaf lists <workspace> [--json]` — `cmd_lists`, `lib/ngwaf.sh` | `/{id}/lists`, `/ngwaf/v1/lists` | **P + L_workspace + L_account**; configuration inventory, not observed matches. |
| `fastly-audit ngwaf posture <workspace>` — `cmd_posture`, `lib/ngwaf.sh` | `/{id}`, `/{id}/rules`, `/ngwaf/v1/rules`, `/{id}/thresholds`, `/{id}/lists`, `/ngwaf/v1/lists` | **P + 2 + R_workspace + R_account + L_workspace + L_account**; static workspace/account configuration. |
| `fastly-audit ngwaf count <workspace> '<query>' [days]` — `cmd_count`, `lib/request_search.sh` | `/{id}/requests` | **P + 1**; `meta.total` for a bounded retained-search query. |
| `fastly-audit ngwaf requests <workspace> '<query>' [days] [--limit N] [--format auto\|json\|csv] [--output FILE]` — `cmd_requests`, `lib/request_search.sh` | `/{id}/requests` | **P + Q**, at least one search GET; requested rows may require pages. Returned retained records are not full traffic. |
| `fastly-audit ngwaf signal-count <workspace> <signal> [days]` — `cmd_signal_count`, `lib/request_search.sh` | `/{id}/requests` via `count` | **P + 1**; retained records matching a signal tag. |
| `fastly-audit ngwaf rule-audit <workspace> <rule_id> [<rule_id> ...] [--days N] [--signals CSV] [--json]` — `cmd_rule_audit`, `lib/rule_audit.sh` | `/{id}/rules/{rule_id}` and `/{id}/requests` | **P + A × (2 + K)** for A requested rules and K distinct selected signals: one rule detail, one total search, and K intersection searches per rule. Rule configuration plus retained matches; signal cohorts can overlap. The parser also accepts `--format human\|json`. |
| `fastly-audit ngwaf template-audit <workspace> <template> [days] [--json\|--format human\|json]` — `cmd_template_audit`, `lib/template_audit.sh` | `/{id}/rules`, `/{id}/thresholds`, `/{id}/requests` | **P + R + 1 threshold + conditional search GETs** after exact template selection; configuration and retained observations. |
| `fastly-audit bot rules <workspace> [--json]` or `fastly-audit ngwaf bot-rules <workspace> [--json]` — `cmd_bot_rules`, `lib/bots.sh` | `/{id}/rules` | **P + R**; heuristic subset of NGWAF rule configuration, not Bot Management workspace mode. |
| `fastly-audit snapshot ngwaf <workspace> [--output FILE] [--include-list-entries] [--json]` — `cmd_snapshot`, `lib/snapshots.sh` | `/{id}`, workspace/account rules and lists, `/{id}/thresholds` | **P + 2 + R_workspace + R_account + L_workspace + L_account**; `--include-list-entries` retains entries already present in list responses and adds no GET. Protected local configuration snapshot. Local `diff` makes no API call. |
| `fastly-audit ngwaf link '<customer-request-url>'` — `cmd_ngwaf_link`, `lib/links.sh` | `/ngwaf/v1/workspaces` via exact workspace resolution | **P**; verifies selected-customer workspace identity before translating a URL. It does not open a browser or prove the request was served. |

The `/{id}` shorthand in this table means `/ngwaf/v1/workspaces/{id}`. The configured `--output` and snapshot paths write local artifacts; they add no API source.

### Time-series and report commands

All use F. Account time series is `/ngwaf/v1/timeseries`; workspace time series is `/ngwaf/v1/workspaces/{id}/timeseries`. These are legacy NGWAF time series, **not** Platform Metrics v2. `normalize_account_timeseries_response` validates requested numeric metrics and duplicate keys; missing intervals remain visible rather than becoming zero.

| Implemented command and function | GETs and logical cost after C | What can be concluded |
| --- | --- | --- |
| `fastly-audit ngwaf overview [days] [--json]` — `cmd_overview`, `lib/metrics.sh` | One account time-series GET + **P** workspace-identity pages. | Returned daily metric observations and bounded aggregates; no proof of complete traffic or efficacy. |
| `fastly-audit ngwaf timeseries <workspace> [days] [--json]` or `<workspace> --start UTC [--end UTC] [--json]` — `cmd_timeseries`, `lib/metrics.sh` | **P + 1** workspace time-series GET. | Returned daily values for the verified workspace; gaps remain gaps. See `timeseries` help for exact RFC3339 timestamp format. |
| `fastly-audit ngwaf metrics <metrics> [days\|--start UTC --end UTC] [--json] [--diagnose-intervals]` — `cmd_metrics`, `lib/metrics.sh` | One account time-series GET + **P** identity pages. | Caller-selected returned metric values; metric names alone do not establish outcomes. |
| `fastly-audit ngwaf attack-profile [days\|FROM TO] [--json]` — `cmd_attack_profile`, `lib/attack_analysis.sh` | One account `timeseries` GET + **P** identity pages + one `/ngwaf/v1/reports/signals` GET. | `requests_attack` workspace ranking and explicitly reported signal counts; unmatched report workspaces are excluded, missing counts remain null. |
| `fastly-audit ngwaf attack-origins [days\|FROM TO] [--json]` — `cmd_attack_origins`, `lib/attack_analysis.sh` | **P + 1** account time-series GET + **W × ceil(D/7)** `/ngwaf/v1/workspaces/{id}/top-attacks` GETs. | Bounded country ranking for production-named workspaces, reconciled to a separate attack-timeseries denominator; top results are not a complete geographic partition. |

The published [NGWAF time-series](https://www.fastly.com/documentation/reference/api/ngwaf/timeseries/), [signals report](https://www.fastly.com/documentation/reference/api/ngwaf/reports/), and [workspace top-attacks](https://www.fastly.com/documentation/reference/api/ngwaf/workspaces/) paths are distinct from retained request search. See the [metrics roadmap](roadmap-platform-metrics.md#current-fa-collector-inventory) for metric equivalence and latency questions.

### Adjacent Bot Management comparison

These commands use F and inspect a different product or generic service stats.
They are included here to prevent their output being mistaken for NGWAF agent
or deployment evidence.

| Implemented command and function | GETs and logical cost after C | Evidence limit |
| --- | --- | --- |
| `fastly-audit bot workspaces [--service-id <SID>] [--json]` — `cmd_bot_workspaces`, `lib/bots.sh` | Customer mode: cursor pages of `/bot-management/v1/workspaces`; exact service mode: one `/service/{id}` then the filtered cursor pages. | Bot Management workspace inventory/configuration. The service selector avoids customer service discovery but the filtered result may still span pages. No NGWAF agent or deployment type. |
| `fastly-audit bot stats <service_id> [days\|FROM TO] [--json]` — `cmd_bot_stats`, `lib/bots.sh` | One `/service/{id}` then one `/stats/service/{id}` request for the selected window. | Service stats used for Bot Management analysis, not NGWAF request/enforcement evidence. |

## Identity and ownership: never join by resemblance

| Identifier | Returned by; reliable current correspondence | Required check or ambiguity |
| --- | --- | --- |
| Fastly customer ID | F `/customer/{id}` and selected scope; may appear in service, workspace, product, and SigSci site metadata. | Preflight requires exact authenticated customer ID and nonempty name. A corp slug or product ID is not this ID. |
| CDN or Compute service ID | F service search or `/service/{id}`. | Exact `/service/{id}` `id`, `type`, and `customer_id` for narrow service claims; token-visible search ownership metadata checked when present. A Compute service is not an Inspection Service. |
| Inspection Service ID | Internal site `serviceID` references a Fastly service; F `/service/{serviceID}` supplies its own `id`, name, type, and owner. | Validate exact ID/name/type and owner independently. Historical cross-customer ownership semantics remain unresolved; a site reference cannot override a conflicting service owner. |
| NGWAF workspace `id` / `workspace_uid` | F workspace inventory/detail. | Distinct fields. Resolver prefers exact `id`, then exact unambiguous name; `customer security` uses a distinct unique UID for Agents only after HTTP 400. UID does not automatically replace ID. |
| SigSci corporation name | S and I path component, supplied by `SIGSCI_CORP` or an explicit supported flag. | Not derivable from Fastly customer ID by spelling. Corp-site metadata must support selected-customer ownership. |
| SigSci site name or ID | S site metadata or I site list. | No general documented one-to-one mapping to public workspace ID. Exact unique site/workspace matches are conditional, not interchangeable identity. |
| Site `serviceID` | I site list. | Observed reference to an Inspection Service, not the application's CDN service ID; verify the referenced F service. |
| Agent ID | F public Agents data model and response when returned. | Identifies an agent, not infrastructure operator or deployment type. `fa` does not use public individual-agent GET. Internal site-agent IDs have no assumed public-ID equivalence. |
| Platform Metrics `entity_id` | Published v2 Metrics API; the P0 diagnostic uses a validated public workspace detail `workspace_uid`; an explicit entity ID must match it. | Exact public workspace ownership can be checked, but the UID relationship is verified by exact customer-owned detail and Engineering's reported contract, not by Metrics HTTP 200 alone; P0 metric semantics and completeness remain open. |

## Cross-source joins and failure states

| Join in current code | Keys and ownership checks | Supported result and failed-validation result |
| --- | --- | --- |
| Product-enabled service → workspace (`discover_product_json`, `customer_security_payload_json`, `workspace_services_payload_json`) | Exact selected-customer service ID and retrieved configuration `workspace_id`; unique matching workspace `id` in selected-customer inventory. Product list/customer metadata must not conflict. | Resolved attachment supports configured Edge WAF relationship. Unmatched/ambiguous IDs remain `UNRESOLVED`, counts become bounds, and a product-list failure is `UNKNOWN` or `PARTIAL`, not zero. |
| F generated VCL → I site → F Inspection Service (`legacy_map_rows_for_service_json`) | Active CDN service/version contains an Inspection Service host; I site `serviceID` resolves through exact F `/service/{id}`; normalized hostname must equal service name, type must be `wasm`, and site/service ownership must be validated. | A fully checked historical in-band mapping is `CONFIRMED`; missing, ambiguous, or conflicting evidence remains `UNKNOWN`/`UNRESOLVED`/`CONFLICTING` as applicable. A VCL hostname alone is not attachment proof. |
| I corp/site → selected Fastly customer (`legacy_map_validate_sites_customer_json`) | Returned site `customer_id` variants are compared with exact selected F customer ID, per row. | Verified rows may participate; unverified rows remain candidates or partial, conflicting customer IDs fail the verified join. A matching corp spelling is insufficient. |
| F workspace → F Agents (`customer_security_agent_inventory_json`, `cmd_ngwaf_agent_diagnostic`) | Selected-customer workspace inventory/detail and exact requested path; returned `workspace_id` must match when supplied. | Valid list observations remain `agent_based_unknown / unresolved`. Mismatches or malformed records become unavailable/unusable; absent response identity may be unverifiable. No On-Prem conclusion. |
| S Cloud WAF instance → S site → F workspace (`customer_security_cloud_inventory_json`, `customer_security_deployments_json`) | Exact instance ID/detail, `workspaceConfigs[].siteName`, S site `name` and `customer_id`, then unique site-name match to selected F workspace `id` or name. | Validated configured Cloud WAF association can be `confirmed`; missing credentials/detail/site owner or ambiguous workspace match remains unavailable/unmatched. Does not prove DNS flow or individual agent membership. |
| F account timeseries/reports → F workspace inventory (`timeseries_attach_workspace_inventory`, attack analysis) | Selected-customer ID and returned workspace IDs/names; exact/unique reconciliation and strict signals-report ID/name matching. | Matched observations may be ranked or aggregated; unmatched report records are excluded with diagnostics and missing selected-workspace counts remain null. |

The legacy mapping ownership and identity gates are deliberate safeguards: do not weaken them to make a candidate row appear confirmed. In particular, `serviceID` is a reference whose cross-customer ownership contract is still open. See [known limitations](known-limitations.md#identity-ownership-and-deployment-evidence).

## What each source proves—and does not

| Source | Direct evidence class | It does **not** establish alone |
| --- | --- | --- |
| F customer/service/workspace inventory | Token-visible resource inventory and returned owner/type metadata. | Complete account-wide inventory, deployment type, hostname coverage, or active request flow. |
| F NGWAF product enablement/configuration | Configured service-to-workspace attachment and optional ramp, after exact joins. | All historical Edge deployments, traffic inspection, or blocking efficacy. |
| F Agents list | Agent/process observations: `agent_id`, enabled/active status, last seen, version, host and module metadata when returned. | On-Prem versus Edge versus Cloud, customer-managed infrastructure, CDN attachment, complete fleet, or enforcement. `agent_enabled`, `agent_active`, and `module_detected` are not deployment-type fields. |
| I SigSci site list | Corp/site inventory and observed configuration or `serviceID` reference, conditional on owner metadata. | Public workspace identity, authoritative cross-customer Inspection Service owner, complete CDN attachment coverage, On-Prem type, or live enforcement. Its `agentMode`, if returned, is a [site-level protection setting](https://www.fastly.com/documentation/guides/next-gen-waf/about-the-protection-mode/), not an individual agent's deployment or observed blocking. |
| S hosted Cloud WAF metadata | Instance/site configuration after exact site owner and workspace association. | Current DNS routing, inspected requests, or which individual agent serves the instance. |
| F generated VCL / service metadata | Declarations in one retrieved service version and the returned service's identity/owner. | NGWAF attachment by itself, traffic routing, or efficacy. The `ngwaf_oob_enabled` setting is an Edge inspection-architecture indicator only after independent active attachment verification. |
| F rules, lists, thresholds and protection mode | Static configuration, including configured enforcement mode. | That a request reached the control or was blocked. |
| F request search, time series, signals report, top-attacks | Retained request observations or reported aggregates for stated scope/window, subject to sampling, ingestion, and endpoint coverage. | Raw complete traffic, per-hostname coverage, unique cross-source totals, or general security efficacy. A retained blocked outcome supports only a bounded observed-enforcement claim. |

Fastly Engineering reported on 29 October 2026 that returned public Agents `data[]` covers agents checked in during the previous two days, while a backend defect tracked as SDS-5073 can inflate `meta.total`. `fa` counts the returned list and keeps the raw total separate; neither value proves complete deployed-agent or historical inventory. An empty or failed Agents result cannot negate confirmed Edge or Cloud configuration. Public Agents fields cannot be inferred from the internal console's schema, even when both surfaces describe agents. See [Agents scope and count semantics](ngwaf-agent-api.md#count-metadata-and-completeness).

## Open questions

1. Which published contract, if any, binds a public agent ID to an exact On-Prem, Edge, or Cloud deployment and its infrastructure operator? Current `fa` has none.
2. What is the authoritative correspondence between historical SigSci site IDs/names, public workspace `id`/`workspace_uid`, and internal or public agent IDs?
3. What are the internal site-list completeness guarantees and the exact ownership meaning of a historical site `serviceID`, especially when F `/service/{serviceID}` reports a different customer?
4. When will SDS-5073 be fixed, and which deployment types are visible through the public Agents endpoint? Its returned two-day population does not establish complete deployment coverage.
5. Which Platform Metrics v2 `entity_id` values are supported for NGWAF workspaces, and can a Metrics response bind an accepted entity to the selected customer? The P0 candidate diagnostic checks public workspace ownership but does not resolve this cross-API join.

No authenticated Fastly or SigSci request was made to prepare this reference.
