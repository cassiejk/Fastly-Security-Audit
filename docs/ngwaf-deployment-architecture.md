# NGWAF deployment architecture and resource identity

Engineering reference for `fastly-audit`. Public architecture statements below
are linked to Fastly documentation. The [current CLI behavior](#current-cli-coverage-and-limits)
section describes this repository; it is not a statement about every Fastly
deployment. A workspace may use more than one deployment type. Configuration,
agent observations, and live inspection are separate evidence layers.

## Deployment types

Fastly [lists five deployment types](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/about-deploying-the-next-gen-waf/).
The requirement for a Fastly service below means a requirement of the *deployment
type*, not whether an application might independently use Fastly CDN or Compute.

| Type | Location and infrastructure operator | Integration and request path | Fastly CDN or Compute required? | Potential API evidence and its limit |
| --- | --- | --- | --- | --- |
| Edge WAF | [Fastly Edge Cloud POPs](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/edge-deployment/); Fastly manages the WAF infrastructure. | An Edge WAF is integrated with a CDN or Compute service. Request inspection follows the [in-band or out-of-band flow](#edge-waf-inspection-architecture). | Yes, a CDN or Compute service. | Product configuration or an authenticated Edge attachment can identify a configured service relationship. Service configuration may identify the Edge inspection architecture. Neither proves a request was inspected. |
| On-Prem WAF | Customer environment; customer manages the deployment. | A web/application [module sends request information to an agent](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/module-agent-deployment/about-module-agent-deployment/), which returns a decision, or the [agent runs as a reverse proxy](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/reverse-proxy-deployment/configuring-agent-reverse-proxy-deployments/) in the request path. | No. | Agent/module observations may be visible, but do not alone establish infrastructure ownership, traffic routing, or this deployment type. |
| PaaS | A supported vendor platform; the customer manages its NGWAF deployment within that platform. | The agent is embedded or integrated through the platform's supported mechanism; application traffic reaches that integration. [Supported platforms](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/paas/paas-install-intro/) include Heroku, OpenShift, Azure App Service, AWS Lambda, and others. | No. | Workspace and agent observations may be available. They do not identify the PaaS integration or prove requests traverse it. |
| A10 Networks | Supported A10 Thunder or vThunder ADC; A10 supports the integration and the customer manages the deployment. | NGWAF is an embedded service on supported ADCs in the application request path; activation requires an A10 feature license. | No. | General workspace/agent data cannot by itself establish the ADC integration or traffic path. See Fastly's [deployment guide](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/about-deploying-the-next-gen-waf/). |
| Cloud WAF | Fastly cloud infrastructure; Fastly manages the hosted instances. | A [hosted reverse proxy](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/cloud-waf/cloud-waf-overview/) receives client traffic and forwards allowed requests to the configured origin. DNS normally points at a Cloud WAF instance; traffic can also arrive from Fastly's Edge. | No. | An authenticated Cloud WAF instance-to-site association supports a configured Cloud WAF relationship. It does not prove current DNS routing, inspection, or enforcement. |

On-Prem module-agent deployments install both components: a module in the web
server or application request path and an agent that evaluates the request.
The reverse-proxy option uses the agent as the proxy without requiring a web
server module. Fastly documents [Kubernetes patterns](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/kubernetes/)
including agent sidecar plus module, reverse-proxy sidecar, ingress-controller
plus module, and Envoy or Istio integrations. Their topology must be verified
from deployment configuration, not guessed from an agent's `module_type`.
Cloud WAF is Fastly-hosted reverse-proxy infrastructure; it is **not** Edge WAF.
Fastly's [Cloud WAF overview](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/cloud-waf/cloud-waf-overview/)
describes eligibility by control-panel access, but does not provide a retirement
date or a customer migration commitment.

## Edge WAF inspection architecture

Fastly's [Edge WAF architecture guide](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/edge-deployment/edge-waf-architecture-types/)
distinguishes the following request flows. Both are Edge WAF architectures,
not separate NGWAF products.

| Architecture | Request and decision flow | Service and historical considerations |
| --- | --- | --- |
| In-band | The application request is routed inline through the Edge WAF. After inspection, the Edge WAF forwards an allowed request to the origin. | Documented for CDN services. Historical setups may use an Inspection Service or edge security service and an in-band generated-VCL reference. That reference is configuration evidence, not proof that an individual request followed the path. |
| Out-of-band | The Fastly service sends the request to the WAF agent for inspection, receives an allow/block decision, then continues its own request flow. The WAF is beside, rather than the origin-forwarding hop in, the application path. | Documented for CDN and Compute services. Fastly notes different VCL-variable availability and support for features such as Brotli. A Compute Edge WAF deployment is out-of-band. |

The public guide says out-of-band is the default for NGWAF purchased on or
after 5 August 2026 and describes migration of existing in-band customers.
That publication does **not** establish the architecture or migration state
of any particular service. Fastly internally uses **WAFD** for newer
out-of-band migration work; public-facing documentation calls the architecture
*out-of-band inspection*. This internal terminology is context supplied for
this reference, not a separate product or deployment type.

For an *already established CDN Edge WAF deployment*, the published guide says
`pragma optional_param ngwaf_oob_enabled` in Complete VCL means out-of-band
when `true`, and in-band when `false` or unset. That conditional interpretation
must not be reversed: a missing or false parameter alone does not establish
that NGWAF is attached, enabled, or protecting the CDN service. Check the
relevant deployed service version and an independent attachment or integration
source before classifying a service.

## Management method is a separate dimension

The following is Fastly's published [Edge WAF management compatibility matrix](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/edge-deployment/edge-waf-architecture-types/),
condensed without changing its restrictions. “Existing only” means the method
is available to deployments already using it; it is not a new-deployment
recommendation.

| Management method | CDN out-of-band (`true`) | CDN in-band (`false`) | CDN in-band (unset) | Compute with WAF in Fastly control panel | Compute without that access |
| --- | --- | --- | --- | --- | --- |
| Fastly control panel and API | Yes | Yes, without mTLS | No | Yes | No |
| Fastly Terraform provider | Yes | Yes, without mTLS | No | Yes | No |
| Next-Gen WAF / Signal Sciences API | Existing only | Yes, with mTLS | Yes | Existing only | Yes |
| Signal Sciences Terraform provider | Existing only | Yes, with mTLS | Yes | Existing only | Yes |

Management method describes which control plane configures a deployment.
Inspection architecture describes how requests are inspected. Their
compatibility is constrained, but neither is a substitute for evidence of
the other. Older workflows can remain supported for existing deployments.
Do not classify a deployment as “legacy NGWAF”; describe its verified type,
architecture, and management evidence separately.

## Resource identities, ownership, and association

The following are distinct identifiers; names and similar-looking strings are
not identity joins.

| Identifier | Meaning and evidence boundary |
| --- | --- |
| Fastly customer ID | Identifies the customer account. The [Customer API](https://www.fastly.com/documentation/reference/api/account/customer/) describes a customer as owning users and services. Validate the selected customer before customer-scoped reporting. |
| CDN service ID; Compute service ID | Both are Fastly Service IDs, with different service types. The [Service API](https://www.fastly.com/documentation/reference/api/services/service/) returns `id`, `type`, and `customer_id`; `customer_id` identifies that **service's** customer. A CDN service ID is not an NGWAF workspace ID. |
| Signal Sciences corporation identifier | Identifies the NGWAF account/corp in the Next-Gen WAF control plane. It is not interchangeable with the Fastly customer ID merely because the accounts are associated. Fastly's [deployment guide](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/about-deploying-the-next-gen-waf/) describes corp and site provisioning. |
| Signal Sciences site identifier | Identifies a site in the Signal Sciences API; public guides also call a site a workspace. Verify the relevant API's identifier shape before joining it to a Fastly NGWAF workspace ID. |
| NGWAF workspace `id`; `workspace_uid` | Distinct fields in the [public workspace API](https://www.fastly.com/documentation/reference/api/ngwaf/workspaces/). A UID, if present, is not an automatic replacement for `id`; the CLI validates identity before using either. |
| Inspection Service / edge security service ID | Fastly Service ID of a service used for an Edge WAF integration, where applicable. Its [Service API](https://www.fastly.com/documentation/reference/api/services/service/) `customer_id` describes the returned service's owner; a reference to it does not prove it shares the CDN service's owner. |
| NGWAF site `serviceID` | Field observed by this repository in the internal site inventory and used as a reference to a Fastly Inspection Service. Its ownership semantics need authoritative clarification; the reference alone does not verify Service API ownership. |
| Product-enabled attachment IDs | The [NGWAF product API](https://www.fastly.com/documentation/reference/api/products/ngwaf/) identifies the enabled Fastly service and configuration `workspace_id`. These identify a configured relationship, subject to exact service, customer, and workspace validation. |

Keep four questions independent: **Who owns the Fastly service?** **Which
NGWAF site or workspace is associated with it?** **How is its traffic
inspected?** **Which control plane manages it?** An association never implies
identical ownership. Equally, this document does not assert that cross-customer
Inspection Service ownership is supported: the Service API describes its
`customer_id`, but the public references above do not establish the expected
ownership relationship for every historical Inspection Service. Explicitly
conflicting identifiers must remain conflicts until that relationship is
verified through authoritative evidence.

## API evidence matrix

“Configuration” below means an observed API state or deployed configuration,
not proof of live inspection. `FASTLY_API_TOKEN` and Signal Sciences API or
legacy dashboard credentials are separate authentication domains.

| Source | Credentials and identifiers | Relationship it can support; applicable deployment | Limit; live inspection? |
| --- | --- | --- | --- |
| [Fastly Service API](https://www.fastly.com/documentation/reference/api/services/service/) | Fastly API token; service `id`, `type`, `customer_id`. | Ownership and type of the returned CDN, Compute, or Inspection Service. | Does not establish NGWAF attachment or request routing. No. |
| [NGWAF product enablement/configuration API](https://www.fastly.com/documentation/reference/api/products/ngwaf/) | Fastly API token; service ID and configuration `workspace_id`. | Configured Fastly service-to-workspace attachment, principally Edge WAF. | Depends on response identity, ownership, and inventory completeness; historical integrations may be elsewhere. No. |
| [NGWAF workspace inventory](https://www.fastly.com/documentation/reference/api/ngwaf/workspaces/) | Fastly API token; workspace `id`, optional `workspace_uid`, name and mode. | Workspace existence and workspace configuration across deployment types. | Existence, mode, or a similar name does not attach a service. No. |
| Signal Sciences site inventory | Separate Signal Sciences API credentials, or legacy dashboard session credentials for this CLI's internal path; corp/site identifiers and observed `serviceID`. | A site record and its Inspection Service reference where available; historical Edge integration. | Site-to-public-workspace identity and service ownership require separate validation. Internal endpoint behavior is not a published public API contract. No. |
| [`edgeDeployment.ServicesAttached`](https://www.fastly.com/documentation/guides/next-gen-waf/deployment-types/edge-deployment/ngwaf-api/setting-up-edge-waf-deployments-using-the-next-gen-waf-api/) | Signal Sciences API user/token; corp/site and attached Fastly service IDs. | Documented site-to-service Edge attachment for that management path. | Validate returned IDs and scope; absence from this source does not exclude other management paths. No. |
| Generated VCL | Fastly API token; selected CDN service ID/version and observed Inspection Service hostname or `ngwaf_oob_enabled` pragma. | Deployed CDN configuration consistent with an integration or, for a verified Edge deployment, its published architecture indicator. | A hostname must be joined to the correct site and service; a pragma alone does not establish attachment. No. |
| Inspection Service metadata | Fastly API token; direct service ID, name, type, `customer_id`. | Exact identity/name check in a historical in-band join and ownership of the returned service. | Name alone is not a join; cross-customer ownership expectations remain unresolved. No. |
| [Agents API](https://www.fastly.com/documentation/reference/api/ngwaf/agents/) | Fastly API token; workspace path ID, agent ID, optional workspace association and module observations. | Supplemental agent/process evidence in any deployment type. | Does not identify the infrastructure operator, CDN attachment, Edge architecture, full inventory, or current inspection. No. |
| [Cloud WAF instance metadata](https://www.fastly.com/documentation/signalsciences/api/) | Signal Sciences API user/token; instance ID and `workspaceConfigs[].siteName`. | Configured hosted Cloud WAF instance-to-site association after exact site validation. | Instance configuration alone does not prove DNS routing or request inspection. No. |

Request telemetry or a controlled request test is needed to make a bounded
claim that traffic was observed or a policy was enforced. Even retained
requests do not establish complete hostname/path coverage or efficacy.

## Detection and report language

Report each dimension independently: `deployment_type`, Edge inspection
architecture, management method, service-to-workspace attachment, resource
ownership, and evidence completeness. Use source, retrieved status, exact IDs,
and confidence with each claim. Do not promote one dimension into another.

| Evidence state | Appropriate report wording |
| --- | --- |
| Verified attachment | “Configured service-to-workspace attachment verified by the enabled-product API and exact workspace identity.” |
| Configured but unresolved attachment | “Attachment configuration references a workspace that could not be uniquely verified; relationship unresolved.” |
| Inferred evidence | “Generated VCL contains an Inspection Service hostname; workspace join remains inferred or unresolved.” |
| Conflicting identities | “Service or workspace identity conflicts with authenticated metadata; mapping not confirmed.” |
| API unavailable | “Attachment source unavailable; attachment state unknown.” |
| No attachment returned by one discovery method | “No attachment returned by this source; other deployment paths were not excluded.” |

An empty enabled-product list is a finding about that API's visible attachment
records, **not** a finding that NGWAF is absent. Similar names, agent records,
and missing `ngwaf_oob_enabled` cannot supply missing identity evidence.

## Current CLI coverage and limits

This section describes the current checkout, not Fastly's full capabilities.

- `fa customer security` collects token-visible services, product attachment
  inventory, NGWAF workspaces, supplemental Agents observations, and optional
  Cloud WAF associations. Its confirmed Edge records use resolved product
  attachments; agent records remain `agent_based_unknown / unresolved`.
- `fa ngwaf workspace-services` combines enabled-product configuration with
  selected-service generated VCL, internal site inventory, and direct
  Inspection Service metadata. A confirmed in-band join requires exact
  service-name, site `serviceID`, and workspace identity checks. The
  product-enabled path does not cover every historical integration.
- `--service-id` verifies one selected CDN service but, when an in-band host is
  present, currently looks up every distinct `serviceID` in the selected
  corporation's site inventory. This can fan out well beyond the selected
  service. Missing or conflicting Inspection Service ownership leaves the
  join unresolved; its cross-customer semantics need authoritative review.
- Cloud WAF associations require separate Signal Sciences credentials and
  exact site ownership/identity checks. Missing credentials mean unavailable
  evidence, not no Cloud WAF deployment.
- The CLI does not establish a service's WAFD migration status from Agents
  records, nor does deployment metadata prove current request inspection,
  blocking, complete traffic coverage, or security efficacy.

See [Agents API scope and limitations](ngwaf-agent-api.md) for its response
semantics and [`workspace-services` in the README](../README.md#workspace-service-mapping)
for current command behavior.

## Open identity and ownership questions

1. For historical Inspection Services referenced by a site `serviceID`, what
   authoritative contract defines the expected Service API `customer_id`?
   A site-to-service reference does not settle a conflicting owner ID.
2. Which site ID or UID, if any, is guaranteed to correspond to the
   `se--{corp}--{SiteUID}` hostname? Can it safely narrow direct lookups
   before fetching every corporation site service?
3. What is the authoritative correspondence between Signal Sciences site
   identifiers, public workspace `id`, and optional `workspace_uid` across
   older and current deployments?
4. Which attachment source is complete for each management path, and what
   access or retention limits apply? An empty source cannot answer for all
   paths.
5. What service/version-specific evidence is authoritative for WAFD migration
   state and compatibility beyond the published CDN pragma meaning?
