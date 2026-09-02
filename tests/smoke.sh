#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "$($ROOT/ngwaf version)" == 'ngwaf 21.0' ]]
$ROOT/ngwaf help >/dev/null
printf 'smoke: OK\n'
