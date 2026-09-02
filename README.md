# ngwaf-helper v22.0

v22 makes the CLI's scope and data contracts explicit. It confirms the selected
customer, resolves workspace names to IDs, fails closed when requested metrics
are absent, reports exact analytical windows, and labels the source and data
class of structured analytical output.

## Layout

```text
ngwaf-helper/
├── ngwaf                 # CLI bootstrap + command dispatch
├── ngwaf-update          # package-aware installer
├── lib/
│   ├── core.sh            # HTTP, pagination, dates, shared JSON helpers
│   ├── account.sh         # version, auth identity, customer selection
│   ├── services.sh        # CDN/Compute + product inventory
│   ├── ngwaf.sh           # workspaces, rules, thresholds, posture, lists
│   ├── bots.sh            # bot rules + Bot Management historical stats
│   ├── metrics.sh         # timeseries, request counts, attack analysis
│   └── help.sh            # CLI help
├── customer/
│   └── costco.sh          # Costco-specific international QBR commands
├── scripts/
│   └── check              # syntax + optional ShellCheck + smoke tests
└── tests/
    ├── smoke.sh
    ├── count.sh
    └── metrics.sh
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

### Data and output contracts

| Command family | Primary source | Data class | Important interpretation |
|---|---|---|---|
| `workspace`, `rules`, `thresholds`, `lists`, `posture` | NGWAF configuration APIs | Point-in-time configuration | Pagination completes or the command fails; rule summaries do not simulate rule precedence. |
| `overview`, `timeseries`, `metrics`, `attack-profile` | NGWAF timeseries API | Aggregated timeseries | Uses complete UTC days; `to` is exclusive; every requested metric must be present and numeric in every returned row. |
| `count`, `signal-count` | NGWAF request-search API | Retained searchable request records | Uses a rolling window ending five minutes before execution; `meta.total` may reflect sampled or mixed-storage records and is not raw traffic. |
| `bot-stats` | Fastly Historical Stats | Daily service statistics | Bot metrics are sampled and scaled estimates; they are not directly comparable to unsampled `edge_requests`. |
| `services`, `products`, `inventory` | Customer audit events plus service/product APIs | Observed inventory | The service set is audit-window-derived, not a guaranteed all-time inventory. |
| `attack-origins` | Per-workspace top-attacks plus NGWAF timeseries | Ranked/truncated attack dimensions | Production workspaces are selected by a documented name regex and country rows are reconciled to `requests_attack`. |

Analytical JSON includes a `window` object and a `provenance` object. Request
search reports the exact `from` and `until` values sent to the endpoint without
inventing boundary semantics that the response does not state. Workspace
JSON also reports `workspace`, `workspace_id`, and the original
`workspace_input`. These fields make the exact query interval, endpoint family,
aggregation, and missing-data policy inspectable downstream.

Missing requested metrics or non-numeric values are errors. v22 does not silently
replace those values with zero. A literal zero returned by the API remains zero.

### Request-search count semantics

`count` and `signal-count` return Fastly's request-search `meta.total` value.
This is a count of retained searchable request records, which may include
sampled or mixed-storage data depending on the matching signals and storage
category. It is not raw traffic and the helper does not scale it into an
estimated traffic total. Ratios calculated from these values describe shares
of searchable matches, not exact shares of all production traffic.

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

v21 deliberately did **not** change API semantics. Existing functions were moved intact from v20 into modules so behavioral regressions could be distinguished from the refactor. v21.1 was the first post-refactor behavioral release, v21.2 fixed the zero-retry test path on macOS Bash 3.2, and v21.3 made request-search sampling semantics explicit in every count result. v22 adds explicit scope resolution and data-quality contracts; consumers of `metrics --json` and `timeseries --json` should account for their new metadata wrappers.

### Known scope caveat retained from v20

`customer/costco.sh` contains the customer-specific `intl-bot-stats` and `intl-bot-types` commands. They remain behaviorally unchanged in v21. They should not be generalized to other customers without explicit refactoring and validation.
