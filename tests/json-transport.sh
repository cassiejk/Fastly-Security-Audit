#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../lib/core.sh
source "$ROOT/lib/core.sh"

# This document intentionally exceeds the commonly encountered macOS
# per-process argument ceiling. It must reach jq through stdin.
large_document="$(
  jq -cn '{
    kind: "large",
    payload: ("x" * 3000000)
  }'
)"

result="$(
  json_stream \
    '{"kind":"small"}' \
    "$large_document" |
  jq -s '.'
)"

jq -e '
  length == 2
  and .[0].kind == "small"
  and .[1].kind == "large"
  and (.[1].payload | length) == 3000000
' >/dev/null <<<"$result"

# Structured API responses and result collections may not use --argjson.
# Bounded scalar values and small selector arrays remain permitted.
prohibited_names=(
  body
  response
  rows
  data
  rules
  account_rules
  thresholds
  workspace_lists
  account_lists
  workspaces
  products
  configs
  configuration
  observed_ids
  unknown_checks
  selected
  matched_rules
  production_workspaces
  selected_workspaces
  attack_signals
  countries
  item
  ws
)

for name in "${prohibited_names[@]}"; do
  if rg -n \
    --glob '*.sh' \
    --glob 'ngwaf' \
    -- "--argjson[[:space:]]+${name}([[:space:]]|$)" \
    "$ROOT/lib" \
    "$ROOT/customer" \
    "$ROOT/ngwaf"; then
    printf '%s\n' \
      "json-transport: structured --argjson payload detected: $name" \
      >&2
    exit 1
  fi
done

printf 'json-transport: OK\n'
