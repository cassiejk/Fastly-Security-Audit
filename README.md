# ngwaf-helper v21.3

v21.3 builds on the v21 structural refactor with shared HTTP progress and error handling, request-count query validation, macOS Bash 3.2 compatibility, and explicit request-search sampling semantics.

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
    └── count.sh
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

v21 deliberately did **not** change API semantics. Existing functions were moved intact from v20 into modules so behavioral regressions could be distinguished from the refactor. v21.1 was the first post-refactor behavioral release, v21.2 fixed the zero-retry test path on macOS Bash 3.2, and v21.3 makes request-search sampling semantics explicit in every count result.

### Known scope caveat retained from v20

`customer/costco.sh` contains the customer-specific `intl-bot-stats` and `intl-bot-types` commands. They remain behaviorally unchanged in v21. They should not be generalized to other customers without explicit refactoring and validation.
