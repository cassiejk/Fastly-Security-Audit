#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "$($ROOT/fastly-audit version)" == 'fastly-audit 24.1' ]]
[[ "$($ROOT/ngwaf version)" == 'ngwaf 24.1' ]]
$ROOT/fastly-audit help >/dev/null
$ROOT/ngwaf help >/dev/null
printf 'smoke: OK\n'
