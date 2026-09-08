# fastly-audit v24.1

v24.1 adds a customer-scoped security-product inventory spanning API
Discovery, Bot Management, DDoS Protection, Next-Gen WAF service mappings,
and the complete NGWAF workspace collection. Product-list queries explicitly
carry the selected customer ID and validate the response customer before data
is accepted.

The summary distinguishes configuration enablement from observed traffic or
security efficacy, preserves inconclusive results as unknown, and retains the
audit-window limitation of the observed service inventory. All v24.0
namespaces and the complete `ngwaf` compatibility interface remain supported.

## Layout

```text
ngwaf-helper/
├── fastly-audit          # primary CLI bootstrap
├── ngwaf                 # backward-compatible entry point
├── ngwaf-update          # package-aware installer
├── lib/
│   ├── core.sh            # HTTP, pagination, dates, shared JSON helpers
│   ├── dispatch.sh        # flat compatibility + namespaced routing
│   ├── doctor.sh          # dependency, authentication, and scope diagnostics
│   ├── account.sh         # version, auth identity, customer selection
│   ├── services.sh        # CDN/Compute + product inventory
│   ├── security.sh        # cross-product security coverage summary
│   ├── ngwaf.sh           # workspaces, rules, thresholds, posture, lists
│   ├── bots.sh            # bot rules + Bot Management historical stats
│   ├── metrics.sh         # timeseries and metric summaries
│   ├── request_search.sh  # request-search counts and drill-down rows
│   ├── rule_audit.sh      # rule configuration plus retained-match analysis
│   ├── attack_analysis.sh # attack-profile and request-origin reports
│   ├── snapshots.sh       # protected snapshots + local semantic diffs
│   └── help.sh            # CLI help
├── customer/
│   └── costco.sh          # Costco-specific international QBR commands
├── scripts/
│   └── check              # syntax + optional ShellCheck + smoke tests
└── tests/
    ├── smoke.sh
    ├── count.sh
    ├── requests.sh
    ├── rule-audit.sh
    ├── metrics.sh
    ├── doctor.sh
    └── snapshots.sh
```

## Development

Run directly from the repository:

```bash
./ngwaf version
./ngwaf posture production
```

Before committing:

```bash
./scripts/check
```

API requests show an interactive spinner and elapsed time on stderr, leaving
stdout safe for JSON pipelines. Useful controls:

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
ngwaf doctor
ngwaf doctor --json
```

It checks Bash and command dependencies, HTTP policy values, token presence and
API access, customer selection and identity, complete workspace enumeration,
and case-insensitive workspace-name collisions. It never prints the API token.
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

Retrieve one workspace rule directly by ID without downloading the complete
rule collection:

```bash
ngwaf rule Production 6047e66c33e0b901e666e36a
```

The response preserves the rule object at the top level and adds `context` and
`provenance`. The command verifies that the API response contains the requested
rule ID; missing rules, malformed responses, and mismatched IDs fail closed.

### Security product summary

Inspect selected-customer security-product coverage without querying unrelated
delivery and observability products:

```bash
fastly-audit security summary
fastly-audit security summary --json
```

The summary checks API Discovery, Bot Management, DDoS Protection, and
Next-Gen WAF enablement against the audit-observed service set. Where the
public product API supplies configuration, it also reports fields such as
DDoS mode, Bot Management ContentGuard state, and NGWAF workspace/traffic-ramp
mapping. The complete NGWAF workspace collection is included as separate
context.

An enabled mapping means the product is attached in Fastly configuration. It
does not prove that the service carries current production traffic, that a
specific enforcement path is active, or that the control is effective. A
non-2xx enablement probe other than 404 is reported as unknown rather than
silently counted as disabled.

### Data and output contracts

| Command family | Primary source | Data class | Important interpretation |
|---|---|---|---|
| `workspace`, `rule`, `rules`, `thresholds`, `lists`, `posture` | NGWAF configuration APIs | Point-in-time configuration | Single-rule responses are identity-checked; paginated collections complete or fail; rule summaries do not simulate rule precedence. |
| `overview`, `timeseries`, `metrics`, `attack-profile` | NGWAF timeseries API | Aggregated timeseries | Uses complete UTC days; `to` is exclusive; every requested metric must be present and numeric in every returned row. |
| `count`, `signal-count`, `requests` | NGWAF request-search API | Retained searchable request records | Uses a rolling window ending five minutes before execution; `meta.total` may reflect sampled or mixed-storage records and is not raw traffic. `requests` returns a bounded set of actual rows separately from the total cohort size. |
| `rule-audit` | NGWAF rule API plus request-search API | Rule configuration plus retained-search cohort counts | Retrieves live rule configuration, counts `ruleid:<id>` and selected `ruleid:<id> tag:<signal>` intersections over one shared rolling window, and emits deterministic review indicators without treating overlapping signal cohorts as additive. |
| `bot-stats` | Fastly Historical Stats | Daily service statistics | Bot metrics are sampled and scaled estimates; they are not directly comparable to unsampled `edge_requests`. |
| `services`, `products`, `inventory` | Customer audit events plus service/product APIs | Observed inventory | The service set is audit-window-derived, not a guaranteed all-time inventory. |
| `security summary` | Customer audit events, security-product enablement/configuration APIs, and NGWAF workspaces | Cross-product configuration inventory | Enabled does not prove traffic or enforcement; inconclusive probes remain unknown. |
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
  'ruleid:6047e66c33e0b901e666e368 tag:SQLI' 7 --limit 25
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
  6047e66c33e0b901e666e368 \
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

## Installation

The old `ngwaf-update ./ngwaf` workflow is preserved, but the updater now installs the whole package under `~/.local/share/ngwaf` and symlinks `~/bin/ngwaf` to its entry point.

Install the new updater once:

```bash
install -m 755 ./ngwaf-update ~/bin/ngwaf-update
```

Then future updates remain:

```bash
ngwaf-update ./ngwaf
```

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
fastly-audit snapshot ngwaf Production --output before.json
fastly-audit diff before.json after.json --check --json
```

Use `fastly-audit <namespace> help` for focused help. Existing commands such as
`ngwaf rule`, `ngwaf count`, and `fastly-audit services` remain compatibility
paths; namespacing does not alter API endpoints, scope validation, or JSON data.
