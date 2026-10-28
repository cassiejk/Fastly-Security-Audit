# Project guidance

## Runtime and structure

- This is a Bash 5.2+ CLI. Keep launchers on `#!/usr/bin/env bash` and do not
  add compatibility workarounds for macOS `/bin/bash` 3.2.
- `fastly-audit` is the primary launcher, `ngwaf` is the compatibility
  launcher, `lib/dispatch.sh` owns routing, and `lib/core.sh` owns shared HTTP,
  scope, pagination, and JSON behavior.
- Keep changes tightly scoped. Preserve existing user changes and established
  module boundaries.

## CLI contracts

- Keep stdout pipeline-safe. Machine-readable output and translated URLs go to
  stdout; progress, scope information, and diagnostics go to stderr.
- Do not launch a browser from link helpers.
- Resolve selectors by documented exact precedence. Unknown, partial,
  conflicting, or ambiguous values must fail closed rather than be guessed.
- Use structured JSON processing with `jq`. When an explicit `false` matters,
  test field presence with `has(...)` instead of relying on `//` fallback
  behavior.

## API and evidence boundaries

- Never infer or hardcode customer ownership from identifiers. Validate the
  selected customer and relevant resource ownership with authenticated API
  metadata before emitting a customer-scoped result.
- Treat failed requests, malformed metadata, incomplete pagination, ownership
  mismatches, and uncertainty as failures where a command promises verified
  ownership.
- Describe `GET /service` inventory as token-visible, not proven account-wide.
  Do not substitute audit events for unavailable inventory.
- Distinguish configuration, retained observations, and security efficacy. Do
  not present product attachment, retained request data, or credential-limited
  results as authoritative per-hostname coverage or proof of enforcement.

### NGWAF API surfaces and authentication boundaries

- Identify hostname, endpoint, authentication, and resource IDs before changing
  any NGWAF integration. Public `https://api.fastly.com` uses
  `FASTLY_API_TOKEN`; its customer-accessible NGWAF workspace and Agents APIs
  use public workspace `id`/`workspace_uid` and agent schemas. Agents results
  are observations, not an independent On-Prem/Edge/Cloud classification.
- Legacy `https://dashboard.signalsciences.net/api/v0` uses `SIGSCI_EMAIL`,
  `SIGSCI_TOKEN`, and `SIGSCI_CORP` where implemented; its corporation, site,
  and Cloud WAF instance resources are a separate management domain.
- Internal Fastly-only SigSci/Salt uses
  `https://sigsci-console-internal.secretcdn.net/api` and a corporation/site
  model. An authenticated employee browser session supplies `dstoken` and
  `VouchCookie` through the existing credential workflow as `FASTLY_DSTOKEN`
  and `FASTLY_VOUCH_COOKIE`. These expiring session cookies are not public API
  tokens. Never substitute internal endpoints for public NGWAF Agents endpoints
  or assume their response fields share a contract.
- Keep public workspace `mode`, legacy site `agentLevel`, internal site
  `agentMode`, and individual-agent `agent_enabled`/`agent_active` distinct.
  Before joining corp/site data to public workspaces, verify each source and
  identifier against current code or authoritative documentation, exact
  selected-customer ownership, and unique matches. Never infer a public
  workspace ID from a matching corp/site name or internal agent record.
  Preserve unknown/conflicting identity and keep configuration, architecture,
  observations, and enforcement evidence separate.
- Use `fa` for user-facing inspections; prefer documented public APIs when
  sufficient while retaining distinct internal evidence paths. Never expose
  credential values in logs, progress, fixtures, documentation, or errors.
  See [NGWAF API sources](docs/ngwaf-api-sources.md).

## Validation

- Add or update focused fake-`curl` behavior tests for API, resolver, JSON, or
  link changes, including failure cases.
- Run the focused tests first, then `./scripts/check` and `git diff --check`.
- Report tests that used mocks separately from any live authenticated API or UI
  validation; do not claim live validation unless it actually ran.

## Inspection workflow and documentation

- Use `fastly-audit` (`fa`) as the exclusive user-facing CLI for Fastly
  inspections and troubleshooting. Keep `ngwaf` only as a compatibility
  launcher. Never recommend the official `fastly` CLI or direct `curl` requests
  as user-facing workarounds. Internal Fastly API calls made by `fa` are allowed.
- If an inspection capability is missing, investigate implementing it in `fa`.
  Before recommending a command, verify its syntax and flags against the
  current launcher, dispatcher, help definitions, and implementation. Do not
  invent commands, flags, JSON fields, or API capabilities. Current repository
  code takes precedence over historical docs, prior conversations, and guesses.
- Prefer narrow, read-only service or workspace inspections. Avoid customer-wide
  inventory scans unless explicitly required. Identify and document expected
  API requests and possible fan-out before adding inspection commands. Show
  progress on stderr for expensive operations.
- Keep NGWAF deployment type, inspection architecture, management method,
  ownership, and enforcement behavior distinct. Preserve exact raw evidence
  and provenance for derived security findings. Never promote missing or
  conflicting evidence to confirmed findings. Historical Signal Sciences-managed
  integrations may not appear in current Fastly NGWAF product APIs.
- Treat current CLI help and source code as authoritative. Update relevant
  documentation when commands, API dependencies, evidence classifications, or
  known limitations change. Check or generate CLI docs from actual help
  definitions where possible to prevent drift.
