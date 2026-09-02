# ngwaf-helper v21

v21 is a **structural refactor of v20**. The command surface and API logic are intentionally unchanged; the monolithic 3,200-line Bash file is split into focused modules.

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
    └── smoke.sh
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

## Refactor boundary

v21 deliberately does **not** change API semantics. Existing functions were moved intact from v20 into modules. Functional changes should be made in later versions so a behavioral regression can be distinguished from the refactor itself.

### Known scope caveat retained from v20

`customer/costco.sh` contains the customer-specific `intl-bot-stats` and `intl-bot-types` commands. They remain behaviorally unchanged in v21. They should not be generalized to other customers without explicit refactoring and validation.
