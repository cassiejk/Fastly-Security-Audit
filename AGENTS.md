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

## Validation policy

These budgets are automatic repository defaults for every future Codex task,
including tasks that do not mention testing. Silence about validation never
permits extra tests. Codex must apply this policy without requiring the user to
request fewer tests, name a tier, or repeat the limits. "Make sure it works" does
not authorize the full suite. Only the user's explicit authorization for this
specific task permits Tier 3. Report external CI or release protection gates
that require more validation; do not bypass them or treat them as local
authorization.
Budgets are cumulative across the entire task and do not reset after edits,
failures, iterations, or a transition between tiers. Complexity or shared-file
imports alone do not expand them.

### Tier 1 — Fast development and investigation

This is the default while implementing, debugging, or exploring. Make a coherent
change, then check Bash syntax on modified scripts and run at most **one**
directly relevant focused test script when executable behavior changes. Do not
test after every edit. Documentation-only and comment-only changes need no
behavior tests: review the diff and run `git diff --check` only.

Do not run `./scripts/check`, broad integration or customer-security suites,
repository-wide ShellCheck, packaging tests, broad service-inventory tests,
unrelated behavior tests, full CLI smoke tests, or repeated documentation scans
by default.

### Tier 2 — Feature completion

When implementation is ready for review, check Bash syntax on modified scripts,
run targeted ShellCheck on changed scripts when available, and run
`git diff --check`. Run at most **two directly relevant focused test scripts
total across the entire task**, counting Tier 1 tests whose relevant inputs have
not changed. For a localized message, output label, or documentation change,
one focused test may suffice. Check CLI help/reference consistency only when
routing, flags, or help behavior changed; check modified documentation for
consistency. Do not automatically run `./scripts/check`.

Tier 1 and Tier 2 share a cumulative **60-second validation execution budget**
per development task. This does not limit implementation time. Inspect unfamiliar
test scripts before running them; prefer quick, directly relevant checks. Do
not start another test after the budget is exhausted. If a test substantially
exceeds it, terminate cleanly when safe and mark it incomplete; do not restart
it merely to obtain a pass or keep monitoring it in hope of completion. Report
incomplete validation and stop instead of progressively broadening the suite.
An exhausted budget is a stopping condition.

Choose tests for the changed behavior, not for the number of dependents of a
file. Do not run `tests/customer-security.sh` merely because `lib/security.sh`
changed, every authentication test because `lib/core.sh` changed, service
inventory suites for a localized HTTP diagnostic, or unrelated DDoS, Bot
Management, VCL, snapshot, mapping, or deployment tests. Do not run every test
that sources a changed module or a broad suite merely to increase confidence.
Use one focused fake-HTTP authentication test for a 401 message, one Agents
diagnostic test for a count label, and diff review for a Markdown-only edit.
For shared HTTP request construction, use targeted request tests and reserve
broader validation for an identified integration gate. If no narrow test exists,
report the gap instead of substituting a broad suite.

Keep test additions small: reuse existing fixtures and helpers, prefer one
representative success case and one important failure case, and retain critical
negative cases for security-sensitive behavior. Do not add speculative matrices
or weaken, disable, or remove existing assertions to save time. Never make an
authenticated customer API call merely to validate local code.

### Tier 3 — Full repository integration

Preserve the existing `./scripts/check` suite. Codex must not run it or an
equivalent complete regression suite without the user's explicit authorization
for that specific task. Implementing, fixing, committing, pushing, installing,
packaging, or releasing does not authorize Tier 3. Neither a shared-module edit,
perceived foundational or security risk, nor cross-module dependencies grant
an automatic exception. Report any independent CI or release protection that
requires broader testing rather than bypassing it or claiming it passed.

### Validation freeze and stopping rule

Once Tier 2 begins, stop nonessential code changes, speculative edge cases,
unrelated tests, opportunistic refactoring, unrelated documentation, and extra
validation without a specific unresolved failure. If a required defect appears,
make the smallest correction and rerun only the directly affected test when
needed. Expand focused checks only for a directly relevant failure and within
the approved budget; do not restart the full suite automatically. Investigate
relevant failures without making unrelated production changes to fix
pre-existing test failures.

Do not rerun tests that passed against unchanged code, restart a full suite
merely because a release version changed, or run both a broad suite and its
component scripts without a specific reason. Do not select tests solely
because they source a shared Bash module or use exhaustive regression testing
to compensate for unrelated uncertainty. If a focused test fails, investigate
and rerun only that test after the relevant correction.

Stop validating and report when requested behavior is complete, applicable
focused tests and syntax/targeted lint pass, required documentation is updated,
and no directly relevant failure remains. Do not keep testing because time or
tools remain available. If validation is incomplete or the budget is exhausted,
report the gap and stop; never claim an interrupted or unrun test passed.
Reduced validation does not relax ownership, authentication, pagination, JSON,
or fail-closed safeguards, and does not authorize suppressing failures.
Task completion does not authorize staging, committing, or pushing.

Every implementation summary must state the tier, exact focused test scripts
and total script count, approximate validation execution time, syntax and lint
results, deferred tests, remaining failures or gaps, whether full regression
validation ran, and whether authenticated live API requests occurred. Separate
mocked tests and static checks from actual authenticated observations; do not
claim full regression coverage from focused checks.

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
