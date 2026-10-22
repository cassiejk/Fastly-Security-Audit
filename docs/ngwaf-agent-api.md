# NGWAF Agents API: Scope and Limitations

Developer reference, updated 20 October 2026. This describes the current checkout and the published Fastly API. The count discrepancy below comes from user-run, direct authenticated requests, not a live request from this document.

## What the endpoint answers

[`GET /ngwaf/v1/workspaces/{workspace_id}/agents`](https://www.fastly.com/documentation/reference/api/ngwaf/agents/) lists NGWAF agents deployed in a workspace. An agent is a request-decision component that uses workspace rules and communicates with Fastly's cloud engine. In a customer-managed [module-agent deployment](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/module-agent-deployment/about-module-agent-deployment/), a web-server module sends requests to the agent and applies its decision. An agent can also run as a [reverse proxy](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/reverse-proxy-deployment/configuring-agent-reverse-proxy-deployments/) without a module. Fastly says all deployment methods use an agent component, but customers install and manage it only for On-Prem WAF; Fastly manages [Edge and Cloud WAF agents](https://www.fastly.com/documentation/guides/next-gen-waf/setup-and-configuration/agent-management/getting-started-with-the-agent/). Therefore, absence from this query cannot rule out any deployment method, and an agent record alone does not locate an Edge CDN attachment.

The [published agent schema](https://www.fastly.com/documentation/reference/api/ngwaf/agents/) includes `agent_id`, `agent_active` (seen within five minutes), `agent_enabled`, `agent_last_seen_at`, agent version/build, host OS, counters and latency metrics, and `module_detected`, `module_type`, `module_server`, and `module_version`. These are agent and host observations, not a CDN service ID, workspace-to-service relationship, request-flow proof, or enforcement test. The repository consumes `data`, `meta.total`, `module_detected`, optional `agent_active`, optional `workspace_id`, and selected module descriptors. A returned agent with validated workspace association is agent-related evidence; even a detected module does not establish whether the agent is customer-managed On-Prem or Fastly-managed Edge or Cloud WAF. In particular, `sigsci-agent-revproxy` is not evidence of a customer-managed web server module. An empty successful result means only that this query returned no agents. A failed or malformed response means agent discovery is unavailable.

Agent inventory alone does not establish Edge, Cloud, or On-Prem architecture; CDN-to-workspace attachments; WAFD migration status; current request inspection; enforcement mode; blocking effectiveness; or security coverage. Agent observations can supplement independent attachment or association evidence, but cannot confirm those relationships on their own.

## Count metadata and completeness

In `customer security`, `returned_agent_count` is the length of the response `data` array; `reported_total` is the unaltered `meta.total` value; and `total_matches_returned_count` compares those two numbers. The standalone diagnostic reports the same observed count and raw total. Neither equality nor inequality establishes response completeness. Fastly's published Agents reference does not define `meta.total` sufficiently to interpret the mismatch or document an Agents pagination contract. Do not treat it as a verified agent count, expected record count, missing-record count, or complete inventory size.

Direct authenticated requests on 20 October 2026 found four workspaces whose
returned agent IDs were unique and nonempty. The API's `meta.total` was eight
times the returned `data` length in a later probe and nine times that length
in earlier probes. The cause and availability of additional records remain
unverified. No pagination or missing-record inference follows from those
figures. Customer-identifying details are omitted from this reference.

## Current implementation

| Step | Code and behavior |
| --- | --- |
| Scope and workspace inventory | [`dispatch_preflight`](../lib/dispatch.sh) requires a token and verifies the selected customer; [`collect_security_summary_json`](../lib/security.sh) gets token-visible services and paginates `GET /ngwaf/v1/workspaces?customer_id=...`. It rejects conflicting or duplicate workspace ownership metadata for `customer security`. [`get_all_pages`](../lib/core.sh) normalizes the list and rejects early/incomplete pages. |
| Agents URL and authentication | [`customer_security_agent_inventory_json`](../lib/security.sh) calls `GET $(workspace_path "$workspace_id")/agents` with the selected `customer_id` query parameter. [`workspace_path`](../lib/core.sh) URL-encodes the identifier. [`get`](../lib/core.sh) sends `Fastly-Key: $FASTLY_API_TOKEN` to `api.fastly.com`; its configured curl retries default to one via [`fastly-audit`](../fastly-audit). Non-2xx, transport failure, and invalid JSON are errors. |
| Identifier choice | [`customer_security_deployments_json`](../lib/security.sh) starts with each inventoried `id`. Only a distinct, nonempty, unique `workspace_uid` can be a fallback after HTTP 400; it never substitutes one after another status. The response must have a nonnegative integral `meta.total` and valid agent records; agent `workspace_id`, if supplied, must match the inventoried ID or eligible UID. The API [workspace schema](https://www.fastly.com/documentation/reference/api/ngwaf/workspaces/) describes `id` and `workspace_uid`, but does not explain the observed Agents total mismatch. |
| Classification and output | [`customer_security_deployments_json`](../lib/security.sh) combines separate Edge attachment, optional Cloud WAF, and agent evidence into `.ngwaf.workspaces[].deployments[]`. An agent with or without `module_detected` produces `agent_based_unknown / unresolved`; the raw module observation remains in `evidence_type` and sanitized evidence text. No recognized evidence produces `unknown / unresolved`. A valid Agents body has source status `returned`; `reported_total`, `returned_agent_count`, and `total_matches_returned_count` expose the discrepancy without asserting completeness. Invalid records or conflicting IDs remain `unavailable`. Agent visibility is reported in `.ngwaf.deployment_sources.agents[]` and per-workspace `.deployment_visibility.agents` with a sanitized reason. Optional probe failure does not erase a confirmed Edge deployment or fail the report. [`cmd_customer_security`](../lib/security.sh) emits the JSON. |
| Separate diagnostic | [`cmd_ngwaf_agent_diagnostic`](../lib/agent_diagnostic.sh), routed by [`dispatch_ngwaf_namespace`](../lib/dispatch.sh), accepts one exact inventory `id` and validates the complete selected-customer workspace inventory. It probes `GET /ngwaf/v1/workspaces/{id}?customer_id=...` detail, then makes one Agents request with `customer_id`. A validated detail supplies the identifier; on HTTP 404 `Site not found`, the exact selected-customer inventory ID supplies it instead and the detail error remains visible. Conflicting detail identity/ownership or other failures block the Agents request. It disables retries, never tries `workspace_uid` or legacy identifiers, and emits sanitized HTTP/error, counts, and agent `workspace_id` match summaries. `response_complete` is null because total semantics are unverified. It omits raw agent host data. See [README diagnostic usage](../README.md#one-workspace-agents-api-diagnostic). |

The normal `fastly-audit customer security --json` inventory probes every inventoried workspace and can use the guarded UID fallback. The classifier does not require Agents to confirm an Edge WAF attachment. It could skip Agents after a confirmed attachment, but continuing the supplemental probe preserves evidence of a possible second, agent-based method. The generated VCL and Inspection Service join runs in separate legacy mapping commands; it is not currently part of `customer security`. `fastly-audit ngwaf agent-diagnostic EXACT_WORKSPACE_ID --json` is an explicitly invoked, single-workspace identifier and response diagnostic; it does not change inventory classification. A successful empty Agents response provides no agent-to-workspace identity or deployment-absence proof.

## Use the right discovery source

| Command | Question it answers |
| --- | --- |
| `fastly-audit ngwaf workspaces` | Which NGWAF workspaces are in the selected-customer inventory? |
| `fastly-audit ngwaf agent-diagnostic` | Does one exact workspace ID pass inventory/detail checks, and what did one Agents response return? It reports counts and identity summaries, not individual agent metadata or deployment architecture. |
| `fastly-audit ngwaf workspace-services` | Which CDN-to-workspace relationships are supported by enabled-product configuration or legacy mapping evidence? |
| `fastly-audit security legacy-map` | Which legacy in-band CDN relationships are supported by generated VCL, Inspection Service metadata, and internal site records? |
| `fastly-audit customer security` | What security-product configuration, attachments, NGWAF workspace inventory, and qualified deployment evidence are visible for the selected customer? |

`customer security` combines independent evidence sources: configured Edge WAF service attachments, workspace inventory, supplemental Agents observations, and optional Cloud WAF instance associations when separate management API credentials are available. It retains unknown or unresolved classifications when evidence is insufficient. Generated VCL and Inspection Service joins belong to the separate legacy mapping commands; `customer security` does not run them.

| Need | Source | What it establishes and what it cannot establish |
| --- | --- | --- |
| Workspace existence | [`GET /ngwaf/v1/workspaces`](https://www.fastly.com/documentation/reference/api/ngwaf/workspaces/), collected by [`collect_security_summary_json`](../lib/security.sh) | Selected-customer, token-visible workspace inventory after pagination/ownership checks. It says nothing by itself about attachment, traffic, or architecture. |
| Product-enabled service relationship | [`GET /enabled-products/v1/ngwaf/services`](https://www.fastly.com/documentation/reference/api/products/ngwaf/) and per-service configuration, via [`discover_product_json`](../lib/services.sh) | NGWAF enablement on token-visible services and, when retrieved, configured `workspace_id`. This product path need not include all legacy Edge deployments. Zero qualifying rows is not zero NGWAF deployments. |
| Legacy in-band CDN relationship | `fastly-audit security legacy-map`, via [`cmd_security_legacy_map`](../lib/security.sh) and [`legacy_map_rows_for_service_json`](../lib/security.sh) | Reconciles deployed generated VCL host, Inspection Service metadata, and internal NGWAF site `serviceID`. Exact supported joins yield mapping evidence; failed/ambiguous joins stay unresolved. This requires separate legacy Signal Sciences session cookies, not the Agents API; see [`legacy_map_internal_get_to_file`](../lib/security.sh). Observed VCL is not an authoritative linkage inventory or proof of successful inspection. |
| Workspace-to-CDN-service mapping | `fastly-audit ngwaf workspace-services`, via [`cmd_workspace_services`](../lib/ngwaf.sh) and [`workspace_services_payload_json`](../lib/ngwaf.sh) | Reconciles confirmed legacy-map rows with enabled-product configuration and exact/unique workspace identity; retains mapping sources and unresolved rows. It does not inspect Agents or determine current Edge architecture. Historical joins require separate legacy credentials; an independently verified product attachment can remain mapped when those credentials are unavailable. Customer ownership checks still apply. |
| Agent-related evidence | Agents list API, via [`customer_security_agent_inventory_json`](../lib/security.sh) | May identify reported agent/module observations after identity validation. It is not the primary service-to-workspace mapping source. Failed or empty responses cannot negate other sources. |

These are different evidence levels: API inventory and configuration fields are **direct observations** of those endpoints; cross-source joins are **derived relationships** conditional on identity and completeness checks; failed, missing, conflicting, or non-discriminating sources remain **unknown**. None alone proves traffic was inspected, blocking occurred, all hostnames are covered, or a control is effective.

## Historical selected-customer investigation: 15 October 2026

Investigation notes supplied for an earlier task reported token-visible CDN
services and NGWAF workspaces, but no Edge WAF attachments from the
enabled-product inventory. The workspace-list endpoint returned HTTP 200;
workspace IDs appeared as human-readable slugs and `workspace_uid` was empty.
A workspace-detail request returned HTTP 404 `Site not found`, and its Agents
request returned HTTP 400 `Site not found`; both failures were independently
reproduced in a separate API client. These are historical observations supplied
with that task, not live checks performed for this document.

The detail and Agents failures do **not** establish that no agents or NGWAF deployments exist. The API identifier or backend compatibility issue is unresolved. The zero product-list result covers only that enabled-product path. `workspace-services` can still find legacy CDN-to-workspace relationships because its generated-VCL/Inspection-Service/internal-site joins are independent of the product-list rows. Such a result remains configuration mapping evidence, subject to its identity and retrieval limits, rather than proof of inspection.

## WAFD migration questions

Answer these independently, retaining the evidence source and unknowns for each:

1. **Which CDN services exist?** Use selected-customer, token-visible service inventory (`get_customer_services` in [`lib/services.sh`](../lib/services.sh)); do not call it proven account-wide inventory.
2. **Which CDN services have NGWAF attached?** Check enabled-product configuration and `workspace-services` legacy mapping evidence. The Agents API has no CDN service relationship.
3. **Which workspaces are associated with those services?** Reconcile configured `workspace_id` or supported legacy joins against workspace inventory, with exact identity checks.
4. **Which deployment architecture is in use?** Use separate validated architecture evidence. Agent telemetry alone cannot establish On-Prem, Cloud, or Edge ownership; an agent is not proof of legacy in-band Edge WAF. For CDN Edge in-band/out-of-band distinction, inspect the relevant service configuration, including `ngwaf_oob_enabled`, and report `unknown` if unavailable. See [Fastly's Edge architecture guide](https://www.fastly.com/documentation/guides/next-gen-waf/setup-and-configuration/edge-deployment/edge-waf-architecture-types/) and [README terminology](ngwaf-deployment-architecture.md#edge-waf-inspection-architecture).
5. **Which services have WAFD configured?** Inspect the relevant deployed VCL pragmas/configuration for each CDN service and version. This repository's Agents probe does not answer that question; WAFD is migration terminology, not a synonym for the public Edge architecture type.
6. **Which services have migration compatibility blockers?** Evaluate the migration-specific configuration and blockers for those services. Agents data cannot establish compatibility or absence of blockers.

## Troubleshooting decision guide

| Question | Inspect first | Failure or interpretation limit |
| --- | --- | --- |
| Is a workspace visible? | Workspace-list API and customer scope | Incomplete pagination or conflicting ownership blocks a trusted inventory; absence is token-scoped. |
| Which CDN service maps to a workspace? | `workspace-services` provenance, then its enabled-product and legacy-map sources | Requires exact joins; legacy credentials are needed for historical evidence. Unresolved rows are not negative findings. |
| Is there legacy in-band mapping evidence? | `security legacy-map` generated VCL, Inspection Service, and internal site evidence | Internal site retrieval, identity, or VCL match can fail; an observed mapping does not establish runtime inspection. |
| Is there agent or module evidence? | Agents API; for one failing ID, `agent-diagnostic` | Empty means no returned agents; HTTP error, malformed list, or unverified association means unavailable or unusable evidence. |
| Is WAFD configured? | Relevant deployed CDN VCL pragmas/configuration | Check the actual service/version; agent presence and workspace existence are insufficient. |
| Is WAF inspection working? | Appropriate request telemetry plus controlled enforcement tests | Retained observations alone are not complete traffic, delivery, or efficacy proof. |

## Open questions for Engineering

- For workspaces whose list `id` is a slug and `workspace_uid` is empty, which identifier and backend path should detail and Agents endpoints accept? Why does list return 200 while detail returns 404 and Agents returns 400 `Site not found`?
- Does the Agents list intentionally omit any Fastly-managed Edge or Cloud WAF agents, and what are its visibility, retention, and pagination guarantees across deployment types?
- Is `workspace_id` guaranteed in returned agent records? If absent, what authoritative association field should callers use?
- Which authenticated source should be authoritative for legacy CDN-to-workspace attachment and WAFD migration compatibility, especially when enabled-product inventory is zero?

## Existing documentation review

The [README customer security](../README.md#customer-security-configuration-overview),
[workspace-services](../README.md#workspace-service-mapping), and
[agent-diagnostic](../README.md#one-workspace-agents-api-diagnostic) sections
separate the evidence sources and their limits. Descriptions of per-workspace
architecture must retain inferred and unresolved statuses rather than imply
that every deployment type has been verified.
