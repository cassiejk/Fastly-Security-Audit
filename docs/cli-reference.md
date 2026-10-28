# `fa` command reference

Current checkout reference, verified against `fastly-audit`, `lib/dispatch.sh`,
`lib/help.sh`, and the named command implementations on 22 October 2026.
`fa` is an interactive alias for `fastly-audit`; use `fastly-audit` in scripts.
This is the supported inspection interface. The `ngwaf` launcher and original
flat commands remain compatibility routes, not separate implementations.
Run `fa -h` or `fa <namespace> -h` for the full current usage text. The table
below is an index of *implemented* routes, not a replacement for help.
For API hosts, credentials, endpoint dependencies, request fan-out, and the
claims each response supports, see [NGWAF API sources](ngwaf-api-sources.md).

## Scope and evidence conventions

- Except for `version`, local `diff`, and some setup/doctor checks, commands
  require a token and selected customer. `lib/dispatch.sh` and `lib/core.sh`
  perform preflight and authenticated customer checks. `customer use` and
  `setup --customer-id` update the local selection; snapshot and DDoS export
  may write local files. Fastly API operations are read-only.
- **E** means an exact resource request; **W** means a workspace command that
  first resolves its selector through the selected customer's *paginated*
  workspace inventory; **C** means customer-wide discovery or aggregation;
  **L** means local only. Service name selectors usually require **C** service
  discovery. An exact service ID is not necessarily an exact-request path:
  inspect the row before using a command on a large customer.
- Workspace selectors in `lib/core.sh` accept an exact ID before a
  case-insensitive exact name and reject missing or ambiguous names. Service
  selection varies by command; `service ngwaf-architecture` tries direct ID
  metadata first and broadens to selected-customer service discovery only for
  name resolution after HTTP 404. `ngwaf workspace-services --service-id`
  requires an exact CDN service ID. Selected-customer ownership and resource
  identity checks can stop a command before configuration is read.
- JSON column: **flag** means `--json`; **default** means JSON without a flag;
  **format** means `--format json`; **no** means no JSON mode. `--list` is not a
  JSON flag. All machine-readable output remains on stdout; progress and
  diagnostics go to stderr.
- Evidence: **configuration** is returned settings/inventory; **association**
  is a validated relationship between resources; **observation** is retained
  metric/request data; **local** is local validation or snapshot comparison.
  None alone proves current enforcement or every hostname's coverage.

### Core and customer

<!-- CLI_INVENTORY_START -->
| Command path | Required arguments; verified options | JSON | Scope and API dependency | Implementation / evidence |
| --- | --- | --- | --- | --- |
| `version` | none | no | L; no API | `lib/account.sh`; local version |
| `setup` | `--customer-id ID` optional; `--json` | flag | E token/customer probes; may save local selected ID | `lib/setup.sh`; local/auth validation |
| `doctor` | `--json`, `--verbose` optional | flag | E token/customer probes; workspace inventory check | `lib/doctor.sh`; diagnostics |
| `customer` | optional `show` | default | E `/customer/{customer_id}` from scope context | `lib/account.sh`; selected identity |
| `customer setup` | same as `setup` | flag | same as `setup` | `lib/setup.sh`; compatibility route in customer namespace |
| `customer use` | exact customer ID | no | E `/customer/{customer_id}`; saves local selection | `lib/account.sh`; identity |
| `customer whoami` | none | default | E `/tokens/self` | `lib/account.sh`; token metadata |
| `customer security` | `--json` | flag | C service/product/workspace inventory; Agents per workspace; optional Cloud WAF lookup | `lib/security.sh`; configuration and separately validated associations |
| `customer vcl-size` | `--json` | flag | C service discovery/details; generated VCL per CDN service | `lib/services.sh`; measured configuration |
| `inventory` | `--json` | flag | C service, product, and NGWAF workspace discovery | `lib/services.sh`; configuration inventory |

### Services and security products

| Command path | Required arguments; verified options | JSON | Scope and API dependency | Implementation / evidence |
| --- | --- | --- | --- | --- |
| `service list` | `--json` | flag | C `/search/services` cursor traversal, with validated token-visible `/service` fallback | `lib/services.sh`; token-visible inventory |
| `service products` | `--json` | flag | C service discovery; `/enabled-products/v1/{product}/services`, per-service probes/config where needed | `lib/services.sh`; product configuration |
| `service inventory` | `--json` | flag | C same product/service sources plus paginated `/ngwaf/v1/workspaces` | `lib/services.sh`; configuration inventory |
| `service vcl-size` | service ID or exact name; `--json` | flag | C service resolution, then E detail and `/service/{id}/version/{v}/generated_vcl` | `lib/services.sh`; generated VCL size |
| `service ngwaf-architecture` | service ID or exact name; `--version N`, `--show-vcl`, `--json` | flag | E `/service/{id}`; one `/version` fallback if active version missing; generated VCL; per-service NGWAF product probe; C only for name fallback | `lib/ngwaf_architecture.sh`, `lib/ngwaf_architecture_vcl.pl`; raw VCL observation separate from attachment |
| `service domains` | CDN service ID or exact name; `--version N`, `--json` | flag | C service resolution, then E `/service/{id}/version/{v}/domain` | `lib/services.sh`; configured domains |
| `security summary` | `--json`, `--detailed` | flag | C selected services, security-product enablement, paginated workspaces; detail mode adds product configuration | `lib/security.sh`; configuration/association with completeness status |
| `security legacy-map` | optional service name or ID; `--sigsci-corp CORP`, `--format human\|json\|csv`, `--output FILE` | format | C service discovery and VCL; internal NGWAF site inventory; E Inspection Service lookup per site `serviceID` | `lib/security.sh`; conditional in-band association |

### Next-Gen WAF

| Command path | Required arguments; verified options | JSON | Scope and API dependency | Implementation / evidence |
| --- | --- | --- | --- | --- |
| `ngwaf workspaces` | none | no | C paginated `/ngwaf/v1/workspaces` | `lib/ngwaf.sh`; workspace inventory |
| `ngwaf agent-diagnostic` | exact inventoried workspace ID; `--json` | flag | C workspace inventory, then E detail and Agents GET with `customer_id` | `lib/agent_diagnostic.sh`; agent observation, not deployment type |
| `ngwaf link` | exact customer request URL | no | W workspace identity; emits translated URL without opening browser | `lib/links.sh`; verified URL association |
| `ngwaf workspace-services` | workspace ID/exact name or `--all`, **or** `--service-id` exact CDN ID; `--json`, `--sigsci-corp CORP`, `--with-domains` | flag | W/C for workspace or all; exact CDN detail for `--service-id`, but internal site lookup can fan out; product and optional domain APIs | `lib/ngwaf.sh`, `lib/security.sh`; configured/derived mapping |
| `ngwaf workspace` | workspace ID/exact name | default | W plus E `/ngwaf/v1/workspaces/{id}` | `lib/ngwaf.sh`; configuration |
| `ngwaf posture` | workspace ID/exact name | default | W plus workspace detail, paginated workspace/account rules and lists, thresholds | `lib/ngwaf.sh`; configuration summary |
| `ngwaf rule` | workspace ID/exact name, exact rule ID | default | W plus E workspace rule GET | `lib/ngwaf.sh`; rule configuration |
| `ngwaf rules` | workspace ID/exact name; `--list` or `--json` | flag (summary JSON by default) | W plus paginated workspace rules | `lib/ngwaf.sh`; rule configuration |
| `ngwaf account-rules` | `--list` or `--json` | flag (summary JSON by default) | C paginated `/ngwaf/v1/rules` | `lib/ngwaf.sh`; account rule configuration |
| `ngwaf thresholds` | workspace ID/exact name; `--json` | flag (summary JSON by default) | W plus E workspace thresholds | `lib/ngwaf.sh`; threshold configuration |
| `ngwaf lists` | workspace ID/exact name; `--json` | flag (summary JSON by default) | W plus paginated workspace and account lists | `lib/ngwaf.sh`; list configuration |
| `ngwaf bot-rules` | workspace ID/exact name; `--json` | flag | W plus paginated workspace rules | `lib/bots.sh`; heuristic bot-control configuration |
| `ngwaf count` | workspace ID/exact name, quoted search query; optional days | default | W plus bounded `/ngwaf/v1/workspaces/{id}/requests` search | `lib/request_search.sh`; retained-match observation |
| `ngwaf requests` | workspace ID/exact name, quoted query; optional days, `--limit N`, `--format auto\|json\|csv`, `--output FILE` | format/auto | W plus bounded request search | `lib/request_search.sh`; retained request records |
| `ngwaf rule-audit` | workspace, one or more rule IDs; `--days N`, `--signals CSV`, `--json` | flag | W plus rule details and request-search counts per rule/signal | `lib/rule_audit.sh`; configuration and retained observations |
| `ngwaf template-audit` | workspace, template; optional days, `--json` or `--format human\|json` | flag/format | W plus paginated rules, thresholds, and request-search counts | `lib/template_audit.sh`; derived control review |
| `ngwaf signal-count` | workspace, signal; optional days | default | W plus bounded tag request search | `lib/request_search.sh`; retained-match observation |
| `ngwaf overview` | optional days; `--json` | flag | C account `/ngwaf/v1/timeseries` | `lib/metrics.sh`; aggregate observation |
| `ngwaf timeseries` | workspace; optional days or `--start UTC [--end UTC]`; `--json` | flag | W plus E workspace timeseries | `lib/metrics.sh`; daily observation |
| `ngwaf metrics` | comma-separated metrics; optional days or `--start UTC --end UTC`; `--json`, `--diagnose-intervals` | flag | C account `/ngwaf/v1/timeseries` | `lib/metrics.sh`; aggregate observation |
| `ngwaf attack-profile` | optional days or `FROM TO`; `--json` | flag | C workspace inventory, account timeseries, signals report | `lib/attack_analysis.sh`; derived observation |
| `ngwaf attack-origins` | optional days or `FROM TO`; `--json` | flag | C workspace inventory and timeseries; top-attacks GET per selected workspace | `lib/attack_analysis.sh`; derived observation, fan-out |
| `ngwaf snapshot` | workspace; `--output FILE`, `--include-list-entries`, `--json` | flag | W plus workspace detail, rules, thresholds, lists | `lib/snapshots.sh`; local protected configuration snapshot |

### DDoS, Bot Management, and local comparison

| Command path | Required arguments; verified options | JSON | Scope and API dependency | Implementation / evidence |
| --- | --- | --- | --- | --- |
| `ddos link` | exact customer event URL | no | E `/ddos-protection/v1/events/{event_id}` | `lib/links.sh`; verified URL association |
| `ddos export-event` | event ID; required `--output FILE\|-`, optional `--customer ID`, `--service ID` | stdout with `--output -` | E event, paginated event rules, rule detail/traffic stats per rule | `lib/ddos.sh`; protected evidence export |
| `bot workspaces` | optional `--service-id` exact CDN ID; `--json` | flag | C cursor-paginated `/bot-management/v1/workspaces`; E service validation when selected | `lib/bots.sh`; ContentGuard configuration |
| `bot stats` | exact service ID; optional days or `FROM TO`; `--json` | flag | E service detail and `/stats/service/{id}` | `lib/bots.sh`; historical observation |
| `bot rules` | workspace ID/exact name; `--json` | flag | W plus paginated NGWAF workspace rules | `lib/bots.sh`; heuristic bot-control configuration |
| `bot intl-stats` | optional days or `FROM TO`; `--json` | flag | C `/service` and stats per fixed matching service; customer-specific extension | `customer/costco.sh`; historical observation, **not general purpose** |
| `bot intl-types` | optional days or `FROM TO`; `--json` | flag | C `/service` and stats per fixed matching service; customer-specific extension | `customer/costco.sh`; historical observation, **not general purpose** |
| `snapshot ngwaf` | workspace; `--output FILE`, `--include-list-entries`, `--json` | flag | same as `ngwaf snapshot` | `lib/snapshots.sh`; native alias |
| `diff` | before and after snapshot files; `--json`, `--check` | flag | L, no API | `lib/snapshots.sh`; local semantic comparison |
<!-- CLI_INVENTORY_END -->

## Compatibility routes and request cost

`lib/dispatch.sh` still accepts flat legacy routes such as `services`,
`products`, `workspaces`, `workspace-services`, `rules`, `count`, `requests`,
`bot-stats`, and `snapshot`. They dispatch to the same `cmd_*` functions as
the namespaced routes; see `fa help legacy` for the complete flat syntax.
`ngwaf` is the compatibility launcher. New user guidance should use the
namespaced `fa` forms above. The two `bot intl-*` routes are existing
customer-specific extensions in `customer/costco.sh` and should not be used
as generic account inspection commands.

The base customer scope check may add a request before those listed in the
table. High-cost paths include service/product customer inventory (cursor
pages, token-visible fallback, per-service probes/config), `customer
vcl-size` (generated VCL per CDN service), `customer security` (Agents per
workspace, optional Cloud WAF association details), broad `legacy-map` and
`workspace-services`, `attack-origins` (top-attacks per workspace), and
`rule-audit`/`template-audit` (request counts per target). Even exact
`workspace-services --service-id` may inspect many legacy site `serviceID`
values after seeing an in-band hostname. `lib/core.sh` rejects incomplete
NGWAF list pagination; `lib/services.sh` checks cursor traversal and reports
token-visible rather than proven account-wide service coverage. Expensive
inventory commands expose phases and idle heartbeats on stderr. See
[known limitations](known-limitations.md) for request fan-out and evidence
boundaries.

For the evidence model and historical integrations, see
[deployment architecture](ngwaf-deployment-architecture.md) and
[Agents API scope](ngwaf-agent-api.md). The [README](../README.md) remains
the onboarding and task-guide document.

## Updating this reference

Change this index when `lib/dispatch.sh`, `lib/help.sh`, or a command's
arguments, API dependencies, request scope, or evidence meaning changes.
Run `bash tests/cli-reference.sh` to compare command paths in this table with
the CLI's offline help, then run `./scripts/check`. This check detects missing
or stale command paths; flags and semantics still require source review.
