#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for shell-based behavior tests.

TEST_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=../lib/runtime.sh
source "$TEST_HELPERS_DIR/../lib/runtime.sh"

_test_entry="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
ngwaf_require_bash_runtime "$(basename "$_test_entry")"
unset _test_entry

test_cleanup() {
  local rc=$?

  if [[ -n "${TEST_TMP:-}" ]]; then
    rm -rf "$TEST_TMP"
  fi
  exit "$rc"
}

test_init() {
  # shellcheck disable=SC2034
  ROOT="$(cd "$TEST_HELPERS_DIR/.." && pwd -P)"
  # shellcheck disable=SC2034
  TEST_TMP="$(mktemp -d)"

  trap test_cleanup EXIT
}

test_file_mode() {
  [[ $# -eq 1 ]] || {
    printf 'test_file_mode requires <path>\n' >&2
    exit 1
  }

  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
