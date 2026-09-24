# Standalone unifier check

`unifier-check` is a read-only audit of account records relevant to Fastly
Next-Gen WAF dashboard unification. It looks for a legacy NGWAF Corp Owner
record and a Fastly account Superuser record with the same normalized email.
It does not link accounts, change permissions, or establish that a person is
eligible to complete unification.

## Credentials and scope

Run `fastly-creds` in the same interactive shell before invoking the probe.
That existing employee workflow exports `FASTLY_API_TOKEN`, `FASTLY_DSTOKEN`,
and `FASTLY_VOUCH_COOKIE`. The Fastly token must be authorized to read the
selected customer, its user list, and IAM role definitions when role IDs need
resolution. The employee console session must be authorized to read the
selected NGWAF corp's users. Credential presence alone does not establish
those permissions; access failures are reported as inconclusive. The probe
does not use `SIGSCI_EMAIL` or `SIGSCI_TOKEN` and has no credential store or
refresh flow.

Supply both identifiers explicitly. Find the Fastly customer ID in the
intended account's Fastly control panel or authenticated customer metadata;
verify it against the account you intend to audit. Find the NGWAF corp
shortname in that customer's NGWAF console URL, such as the `<corp>` in
`/corps/<corp>/sites/<site>`. Do not derive the corp from the Fastly account
name. `fastly-audit customer show` validates the supplied Fastly ID, but the
probe cannot independently prove that the supplied corp belongs to that
customer.

## Run

From the repository checkout:

```bash
fastly-creds
./dev/unifier-check/probe.sh \
  --customer-id CUSTOMER_ID \
  --corp CORP_SHORTNAME
```

For an explicit local identity reveal, add `--show-identities`. The option
requires terminal stdin, stdout, and stderr; redirected or piped output fails
before any API request. Only matching, partial-match, and unresolved entries
are shown on terminal stderr, with run-scoped ID, category, and normalized
email. JSON stdout and saved reports remain sanitized. Records without an
identifier cannot be shown by email; the reveal reports their counts. Terminal
recording or screen sharing can still capture displayed emails.

The probe makes read-only GET requests to the internal NGWAF console users
endpoint (`FASTLY_NGWAF_INTERNAL_API_BASE`, defaulting to
`https://sigsci-console-internal.secretcdn.net/api`), the Fastly customer
endpoint, and the Fastly customer users endpoint. It retrieves IAM role
definitions only when assigned role IDs need resolution. It reuses
`fastly-audit customer show` for Fastly customer validation. It does not send
retrieved user records to another service.

## Results and limits

Stdout is a one-line sanitized JSON summary. Stderr identifies a private
directory under `dev/unifier-check/results/` containing `ngwaf-users.json`,
`fastly-users.json`, `iam-roles.json`, and `correlation.json`. The reports
contain response structure, role values, counts, and run-scoped IDs, without
names or emails. Raw HTTP responses stay in a restricted temporary directory
and are removed on normal exit. The results directory is ignored by Git.

- `matches_found` means matching account records with both required assigned
  roles were observed.
- `ngwaf_owner_only` and `fastly_superuser_only` identify partial matches in
  the correlation report. They are observations from the returned lists.
- `no_matches_observed` is not a definitive absence finding.
- `inconclusive` means retrieval, identity, account status, role resolution,
  or a visible pagination signal prevents a reliable assessment.

User-list completeness has **not** been established. Matching emails do not
independently prove shared authenticated identity. The audit does not verify
SSO access or successful interactive account linking. The corp-to-customer
mapping is marked unverified; the existing legacy mapping validator requires
NGWAF site inventory, which this audit does not collect. General approval for
broader employee use of the internal NGWAF endpoint remains unconfirmed.

## Offline tests

```bash
bash dev/unifier-check/test-probe.sh
```

The test suite uses fake `curl` responses and makes no customer API requests.
