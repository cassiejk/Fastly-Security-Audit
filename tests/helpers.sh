#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for shell-based behavior tests.

test_cleanup() {
  local rc=$?

  if [[ -n "${TEST_TMP:-}" ]]; then
    rm -rf "$TEST_TMP"
  fi
  exit "$rc"
}

test_init() {
  # shellcheck disable=SC2034
  ROOT="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd -P)"
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
