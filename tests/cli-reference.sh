#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
doc="$ROOT/docs/cli-reference.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The command-path column is the sole maintained inventory in the document.
# Help is the implementation-owned inventory; this check does not duplicate
# command names or attempt to infer flags from prose.
awk '
  /^<!-- CLI_INVENTORY_START -->/ { inside=1; next }
  /^<!-- CLI_INVENTORY_END -->/ { inside=0; next }
  inside && /^\| `[a-z]/ {
    split($0, fields, "`")
    print fields[2]
  }
' "$doc" >"$tmp/documented"

if [[ ! -s "$tmp/documented" ]]; then
  printf 'cli-reference: no command inventory found\n' >&2
  exit 1
fi
if [[ -n "$(sort "$tmp/documented" | uniq -d)" ]]; then
  printf 'cli-reference: duplicate documented command path\n' >&2
  sort "$tmp/documented" | uniq -d >&2
  exit 1
fi
sort -u "$tmp/documented" >"$tmp/documented.sorted"

"$ROOT/fastly-audit" --help | awk '
  /^  fastly-audit [a-z]/ {
    line=$0
    sub(/^  fastly-audit /, "", line)
    split(line, field, / +/)
    if (field[1] ~ /^(customer|service|security|ngwaf|ddos|bot|snapshot)$/) {
      if (field[2] ~ /^\[/) print field[1]
      else print field[1] " " field[2]
    } else print field[1]
  }
' >"$tmp/help"
"$ROOT/fastly-audit" ngwaf --help |
  awk '/^  [a-z][a-z-]*( |$)/ {print "ngwaf " $1}' >>"$tmp/help"
"$ROOT/fastly-audit" bot --help |
  awk '/^  intl-(stats|types) / {print "bot " $1}' >>"$tmp/help"
sort -u "$tmp/help" >"$tmp/help.sorted"

if ! diff -u "$tmp/help.sorted" "$tmp/documented.sorted"; then
  printf 'cli-reference: update the command table to match current offline help\n' >&2
  exit 1
fi
printf 'cli-reference: OK (%s command paths)\n' "$(wc -l <"$tmp/help.sorted" | tr -d ' ')"
