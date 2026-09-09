#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
test_init

ngwaf_bash_version_at_least 5 2
ngwaf_bash_version_at_least 5 3
ngwaf_bash_version_at_least 6 0

if ngwaf_bash_version_at_least 5 1; then
  printf 'runtime test: Bash 5.1 was accepted\n' >&2
  exit 1
fi

if ngwaf_bash_version_at_least 3 2; then
  printf 'runtime test: Bash 3.2 was accepted\n' >&2
  exit 1
fi

if ngwaf_print_bash_runtime_error fastly-audit 3.2.57 Darwin 2>"$TEST_TMP/err"; then
  :
fi
grep -F 'fastly-audit: Bash 5.2 or newer is required; found 3.2.57.' "$TEST_TMP/err" >/dev/null
grep -F 'fastly-audit: macOS: brew install bash' "$TEST_TMP/err" >/dev/null
grep -F "fastly-audit: Ensure Homebrew's bin directory precedes /bin in PATH." "$TEST_TMP/err" >/dev/null

if ngwaf_print_bash_runtime_error ngwaf 5.1.16 Linux 2>"$TEST_TMP/err"; then
  :
fi
grep -F 'ngwaf: Bash 5.2 or newer is required; found 5.1.16.' "$TEST_TMP/err" >/dev/null
grep -F 'ngwaf: Install Bash 5.2 or newer and ensure it appears first in PATH.' "$TEST_TMP/err" >/dev/null

if [[ "$(uname -s)" == "Darwin" && -x /bin/bash ]]; then
  if /bin/bash "$ROOT/fastly-audit" version >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'runtime test: macOS /bin/bash unexpectedly accepted fastly-audit\n' >&2
    exit 1
  fi
  grep -F 'fastly-audit: Bash 5.2 or newer is required' "$TEST_TMP/err" >/dev/null
  grep -F 'fastly-audit: macOS: brew install bash' "$TEST_TMP/err" >/dev/null

  if /bin/bash "$ROOT/ngwaf" version >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'runtime test: macOS /bin/bash unexpectedly accepted ngwaf\n' >&2
    exit 1
  fi
  grep -F 'ngwaf: Bash 5.2 or newer is required' "$TEST_TMP/err" >/dev/null
  grep -F 'ngwaf: macOS: brew install bash' "$TEST_TMP/err" >/dev/null

  if /bin/bash "$ROOT/ngwaf-update" "$ROOT" >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    printf 'runtime test: macOS /bin/bash unexpectedly accepted ngwaf-update\n' >&2
    exit 1
  fi
  grep -F 'ngwaf-update: Bash 5.2 or newer is required' "$TEST_TMP/err" >/dev/null
  grep -F 'ngwaf-update: macOS: brew install bash' "$TEST_TMP/err" >/dev/null
fi

fastly_version="$("$ROOT/fastly-audit" version)"
ngwaf_version="$("$ROOT/ngwaf" version)"
[[ "${fastly_version#fastly-audit }" == "${ngwaf_version#ngwaf }" ]]

printf 'runtime: OK\n'
