#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../lib/runtime.sh
source "$ROOT/lib/runtime.sh"
ngwaf_require_bash_runtime smoke.sh

[[ "$($ROOT/fastly-audit version)" == 'fastly-audit 24.2.3' ]]
[[ "$($ROOT/ngwaf version)" == 'ngwaf 24.2.3' ]]
$ROOT/fastly-audit help >/dev/null
$ROOT/ngwaf help >/dev/null
printf 'smoke: OK\n'
