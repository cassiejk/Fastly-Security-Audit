# Changelog

All notable changes to `fastly-audit` and its `ngwaf` compatibility command are
documented here.


## [24.0] - 2026-09-04

- Promotes `fastly-audit` as the primary modular CLI while preserving `ngwaf`
  as a complete compatibility launcher.
- Adds `customer`, `service`, `ngwaf`, `bot`, and `snapshot` command namespaces
  with focused help for each namespace.
- Extracts command routing and preflight behavior into `lib/dispatch.sh`.
- Preserves all original flat commands and verifies that legacy and namespaced
  Weedmaps rule retrieval return identical output.
- Makes `doctor` report and validate the launcher that actually invoked it.
- Adds namespace and dual-launcher diagnostic regression coverage.

## [23.2] - 2026-09-04

### Added

- Isolated package-installer regression coverage for both launchers.
- Multi-megabyte JSON transport regression coverage.
- Direct version and help validation for `fastly-audit` and `ngwaf`.

### Changed

- Structured API responses, rule collections, service inventories, snapshots,
  bot statistics, and metrics summaries are streamed to `jq` through standard
  input instead of being passed as process arguments.
- Terminal progress and error prefixes reflect the command used to invoke the
  application.
- `ngwaf-update` installs `fastly-audit` as the primary command and `ngwaf` as
  its compatibility launcher under one package directory.

### Fixed

- Prevented `Argument list too long` failures for customers with large service
  inventories or configuration datasets.
- Preserved customer scope, data provenance, pagination, and output contracts
  while converting large JSON payload transport.

[24.0]: https://github.com/cassiejk/ngwaf-helper/releases/tag/v24.0
[23.2]: https://github.com/cassiejk/ngwaf-helper/releases/tag/v23.2
