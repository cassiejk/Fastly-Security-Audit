#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init

DIST="$TEST_TMP/dist"
"$ROOT/scripts/package-release" --dist "$DIST" --tag v24.2.3 >"$TEST_TMP/package-output"

[[ -f "$DIST/fastly-audit.tar.gz" ]]
[[ -f "$DIST/fastly-audit.tar.gz.sha256" ]]
[[ -x "$DIST/fastly-audit-installer.sh" ]]

grep -F 'Release assets written to' "$TEST_TMP/package-output" >/dev/null
grep -F 'fastly-audit.tar.gz' "$TEST_TMP/package-output" >/dev/null
grep -F 'fastly-audit-installer.sh' "$TEST_TMP/package-output" >/dev/null

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$DIST" && sha256sum -c fastly-audit.tar.gz.sha256) >/dev/null
else
  (cd "$DIST" && shasum -a 256 -c fastly-audit.tar.gz.sha256) >/dev/null
fi

tar -tzf "$DIST/fastly-audit.tar.gz" >"$TEST_TMP/archive-list"
grep -F 'fastly-audit/fastly-audit' "$TEST_TMP/archive-list" >/dev/null
grep -F 'fastly-audit/ngwaf' "$TEST_TMP/archive-list" >/dev/null
grep -F 'fastly-audit/ngwaf-update' "$TEST_TMP/archive-list" >/dev/null
grep -F 'fastly-audit/lib/runtime.sh' "$TEST_TMP/archive-list" >/dev/null
grep -F 'fastly-audit/lib/setup.sh' "$TEST_TMP/archive-list" >/dev/null
grep -F 'fastly-audit/customer/costco.sh' "$TEST_TMP/archive-list" >/dev/null

mkdir -p "$TEST_TMP/extract"
tar -xzf "$DIST/fastly-audit.tar.gz" -C "$TEST_TMP/extract"
[[ "$("$TEST_TMP/extract/fastly-audit/fastly-audit" version)" == "fastly-audit 24.2.3" ]]
[[ "$("$TEST_TMP/extract/fastly-audit/ngwaf" version)" == "ngwaf 24.2.3" ]]

if "$ROOT/scripts/package-release" --dist "$TEST_TMP/bad-dist" --tag v99.0 >"$TEST_TMP/bad-out" 2>"$TEST_TMP/bad-err"; then
  printf 'package-release test: mismatched tag unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'release tag v99.0 does not match fastly-audit version 24.2.3' "$TEST_TMP/bad-err" >/dev/null

printf 'package-release: OK\n'
