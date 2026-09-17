#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
fail() { printf '%s\n' "$1" >&2; exit 1; }
# shellcheck source=lib/ngwaf.sh
source "$ROOT/lib/ngwaf.sh"
# shellcheck source=lib/security.sh
source "$ROOT/lib/security.sh"
export FASTLY_DSTOKEN=preflight-dstoken-secret
export FASTLY_VOUCH_COOKIE=preflight-vouch-secret

in_band_evidence='{"customer":{"id":"c","name":"Costco"},"summary":{"sites_inventory_status":"COMPLETE"},"sources":{},"mappings":[{"status":"CONFIRMED","workspace_id":"w","workspace_name":"workspace","source_service_id":"s1","source_service_name":"staging","active_version":111,"inspection_service_id":"i"}]}'
product='{"status":"COMPLETE","result":{},"services":[]}'
workspaces='{"data":[{"id":"w","name":"workspace"},{"id":"empty","name":"empty"}]}'
result="$(workspace_services_payload_json "$in_band_evidence" "$product" "$workspaces" w)"
jq -e '.status == "COMPLETE" and .service_count == 1 and .services[0].active_version == 111 and .services[0].mapping_sources == ["in_band_vcl_evidence"] and (.services[0] | has("architecture_status") | not) and (.provenance | has("legacy_generated_vcl") | not)' <<<"$result" >/dev/null
result="$(workspace_services_payload_json \
  "$(jq '.mappings[0].workspace_id = "internal-site"' <<<"$in_band_evidence")" "$product" "$workspaces" w)"
jq -e '.service_count == 1 and .services[0].mapping_evidence[0].evidence.internal_site_id == "internal-site" and .services[0].mapping_evidence[0].evidence.workspace_resolution == "unique_exact_workspace_name"' <<<"$result" >/dev/null
result="$(workspace_services_payload_json \
  "$(jq '.mappings[0].workspace_id = "internal-site"' <<<"$in_band_evidence")" "$product" \
  "$(jq '.data += [{id:"other",name:"workspace"}]' <<<"$workspaces")" w)"
jq -e '.status == "PARTIAL" and .service_count == 0 and (.unmatched_workspace_relationships | length) == 1' <<<"$result" >/dev/null
in_band_evidence="$(jq '.mappings += [.mappings[0], (.mappings[0] + {source_service_id:"s2"})]' <<<"$in_band_evidence")"
product='{"status":"COMPLETE","result":{},"services":[{"id":"s1","name":"staging","type":"vcl","active_version":111,"configuration_status":"RETRIEVED","configuration":{"workspace_id":"w"}}]}'
result="$(workspace_services_payload_json "$in_band_evidence" "$product" "$workspaces" '')"
jq -e '.workspaces[0].service_count == 2 and .workspaces[0].services[0].mapping_sources == ["enabled_product_api","in_band_vcl_evidence"] and .workspaces[1].service_count == 0 and .summary.in_band_vcl_evidence_relationships == 2 and .summary.enabled_product_relationships == 1 and .summary.workspaces_with_no_observed_mapping == 1' <<<"$result" >/dev/null
in_band_evidence="$(jq '.mappings += [{status:"UNKNOWN",source_service_id:"bad",reason:"VCL unavailable"}]' <<<"$in_band_evidence")"
result="$(workspace_services_payload_json "$in_band_evidence" "$product" "$workspaces" w)"
jq -e '.status == "PARTIAL" and .unresolved_services[0].source_service_id == "bad"' <<<"$result" >/dev/null
product="$(jq '.status = "UNKNOWN"' <<<"$product")"
result="$(workspace_services_payload_json "$in_band_evidence" "$product" "$workspaces" w)"
jq -e '.status == "UNKNOWN"' <<<"$result" >/dev/null
result="$(workspace_services_payload_json \
  "$(jq '.mappings = []' <<<"$in_band_evidence")" \
  '{"status":"COMPLETE","result":{},"services":[]}' "$workspaces" empty)"
jq -e '.status == "COMPLETE" and .service_count == 0' <<<"$result" >/dev/null
result="$(workspace_services_payload_json \
  "$(jq '.mappings = []' <<<"$in_band_evidence")" \
  '{"status":"COMPLETE","result":{},"services":[{"id":"bad","type":"vcl","configuration_status":"UNAVAILABLE"}]}' "$workspaces" w)"
jq -e '.status == "PARTIAL" and .unresolved_product_configurations[0].id == "bad"' <<<"$result" >/dev/null
if workspace_services_payload_json "$in_band_evidence" "$product" '{}' w >/dev/null 2>&1; then
  fail 'malformed inventory accepted'
fi

# Exercise the real command collection path with deterministic mocked sources.
fixture_workspaces="$workspaces"
fixture_in_band_evidence="$in_band_evidence"
fixture_product="$product"
resolve_workspace_json() { printf 'workspace lookup\n' >>"$TEST_TMP/calls"; [[ "$1" == workspace ]] || return 1; printf '{"id":"w"}\n'; }
current_cid() { printf 'c\n'; }
get_all_pages() { printf 'workspace inventory\n' >>"$TEST_TMP/calls"; printf '%s\n' "$fixture_workspaces"; }
cmd_security_legacy_map() { printf 'in-band evidence sites and generated_vcl\n' >>"$TEST_TMP/calls"; printf '%s\n' "$fixture_in_band_evidence"; }
get_token_visible_customer_services() { printf '/service inventory\n' >>"$TEST_TMP/calls"; printf '{"data":[]}\n'; }
discover_product_json() { printf 'enabled product\n' >>"$TEST_TMP/calls"; printf '%s\n' "$fixture_product"; }

for missing in FASTLY_DSTOKEN FASTLY_VOUCH_COOKIE both; do
  rm -f "$TEST_TMP/calls"
  if (
    case "$missing" in
      both) unset FASTLY_DSTOKEN FASTLY_VOUCH_COOKIE ;;
      *) unset "$missing" ;;
    esac
    cmd_workspace_services workspace --json
  ) >"$TEST_TMP/missing.out" 2>"$TEST_TMP/missing.err"; then
    fail 'missing credentials accepted'
  fi
  [[ ! -s "$TEST_TMP/calls" && ! -s "$TEST_TMP/missing.out" ]] || fail 'preflight performed collection work or emitted a result'
  rg -q 'missing required credentials for in-band workspace-service mapping' "$TEST_TMP/missing.err"
  if [[ "$missing" == both ]]; then
    rg -q '^  FASTLY_DSTOKEN$' "$TEST_TMP/missing.err"
    rg -q '^  FASTLY_VOUCH_COOKIE$' "$TEST_TMP/missing.err"
  else
    rg -q "^  $missing$" "$TEST_TMP/missing.err"
  fi
  if rg -q 'preflight-dstoken-secret|preflight-vouch-secret' "$TEST_TMP/missing.out" "$TEST_TMP/missing.err"; then
    fail 'credential value leaked'
  fi
done
if (unset FASTLY_DSTOKEN FASTLY_VOUCH_COOKIE; cmd_workspace_services --all --json) >"$TEST_TMP/missing.out" 2>"$TEST_TMP/missing.err"; then
  fail 'all-workspaces bypassed preflight'
fi
[[ ! -s "$TEST_TMP/calls" ]] || fail 'all-workspaces preflight performed collection work'
if cmd_workspace_services invalid --json >/dev/null 2>&1; then fail 'invalid workspace accepted'; fi
if cmd_workspace_services workspace --json >"$TEST_TMP/partial.json"; then fail 'incomplete mapping succeeded'; fi
jq -e '.status == "UNKNOWN" and .service_count == 2' "$TEST_TMP/partial.json" >/dev/null
in_band_evidence="$(jq 'del(.mappings[-1])' <<<"$in_band_evidence")"
product="$(jq '.status = "COMPLETE"' <<<"$product")"
fixture_in_band_evidence="$in_band_evidence"
fixture_product="$product"
cmd_workspace_services --all --json >"$TEST_TMP/all.json"
rg -q '/service inventory' "$TEST_TMP/calls"
rg -q 'generated_vcl' "$TEST_TMP/calls"
if rg -q 'preflight-dstoken-secret|preflight-vouch-secret' "$TEST_TMP/all.json"; then fail 'success output leaked credentials'; fi
jq -e '.status == "COMPLETE" and (.workspaces | length) == 2' "$TEST_TMP/all.json" >/dev/null
# shellcheck source=lib/dispatch.sh
source "$ROOT/lib/dispatch.sh"
dispatch_preflight() { :; }
PROGRAM_NAME=fastly-audit
dispatch_ngwaf_namespace workspace-services --all --json >"$TEST_TMP/dispatched.json"
cmp "$TEST_TMP/all.json" "$TEST_TMP/dispatched.json" >/dev/null ||
  jq -e '.status == "COMPLETE" and (.workspaces | length) == 2' "$TEST_TMP/dispatched.json" >/dev/null
human_table() { cat; }
cmd_workspace_services --all >"$TEST_TMP/human.txt"
rg -q 'NO OBSERVED CDN SERVICE MAPPING' "$TEST_TMP/human.txt"
rg -q 'Mapping coverage' "$TEST_TMP/human.txt"
rg -q 'in-band VCL evidence' "$TEST_TMP/human.txt"
fixture_in_band_evidence="$(jq '.mappings = []' <<<"$fixture_in_band_evidence")"
cmd_workspace_services workspace --json >"$TEST_TMP/product.json"
jq -e '.service_count == 1 and .services[0].mapping_sources == ["enabled_product_api"]' "$TEST_TMP/product.json" >/dev/null
get_all_pages() { return 1; }
if cmd_workspace_services --all --json >/dev/null 2>&1; then fail 'mapping collection failure accepted'; fi
printf 'workspace-services: OK\n'
