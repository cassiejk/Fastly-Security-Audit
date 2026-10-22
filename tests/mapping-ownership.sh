#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/helpers.sh"
test_init
# shellcheck source=lib/security.sh
source "$ROOT/lib/security.sh"

customer='customer-a'
site='{"status":"COMPLETE","data":[{"id":"workspace-a","name":"Workspace A","customer_id":"customer-a","serviceID":"inspection-a"}]}'
mixed='{"status":"COMPLETE","data":[{"id":"workspace-a","name":"Workspace A","customer_id":"customer-a","serviceID":"inspection-a"},{"id":"workspace-b","name":"Workspace B","serviceID":"inspection-b"}]}'
service='{"id":"cdn-a","name":"CDN A","type":"vcl"}'
vcl='{"status":"COMPLETE","hosts":["inspection-name.edgecompute.app"]}'
foreign='[{"service_id":"inspection-a","status":"COMPLETE","service":{"id":"inspection-a","name":"inspection-name","type":"wasm","customer_id":"customer-b"},"lookup_http_status":200,"lookup_response_format":"json_object"}]'

validated="$(legacy_map_validate_sites_customer_json "$mixed" "$customer" 'Customer A' corp-a cli)"
jq -e '.corp_validation_status != "VALID" and .site_ownership_counts.verified == 1 and .site_ownership_counts.unverified == 1' <<<"$validated" >/dev/null

validated_site="$(legacy_map_validate_sites_customer_json "$site" "$customer" 'Customer A' corp-a cli)"
rows="$(legacy_map_rows_for_service_json "$service" "$vcl" "$validated_site" "$foreign")"
jq -e '.[0].status != "CONFIRMED"' <<<"$rows" >/dev/null

for owner in '"customer-a"' '"customer-b"' 'null' '""'; do
  inspection="$(jq --argjson owner "$owner" 'map(.service.customer_id = $owner)' <<<"$foreign")"
  checked="$(legacy_map_validate_inspection_services_json "$inspection" "$customer")"
  rows="$(legacy_map_rows_for_service_json "$service" "$vcl" "$validated_site" "$checked")"
  if [[ "$owner" == '"customer-a"' ]]; then
    jq -e '.[0].status == "CONFIRMED" and .[0].workspace_id == "workspace-a"' <<<"$rows" >/dev/null
  else
    jq -e '.[0].status != "CONFIRMED" and .[0].candidates == []' <<<"$rows" >/dev/null
    jq -e '.[0].failure.failure_kind == "ownership_mismatch" or .[0].failure.failure_kind == "ownership_unverified"' <<<"$checked" >/dev/null
  fi
done

mixed_checked="$(legacy_map_validate_sites_customer_json "$mixed" "$customer" 'Customer A' corp-a cli)"
jq -e '.status == "PARTIAL" and .data[0].ownership_validation_status == "verified" and .data[1].ownership_validation_status == "ownership_unverified"' <<<"$mixed_checked" >/dev/null
matching="$(jq 'map(.service.customer_id = "customer-a")' <<<"$foreign")"
matching="$(legacy_map_validate_inspection_services_json "$matching" "$customer")"
unrelated='[{"service_id":"inspection-b","status":"COMPLETE","service":{"id":"inspection-b","name":"other-inspection","type":"wasm","customer_id":"customer-a"},"ownership_validation_status":"verified"}]'
rows="$(legacy_map_rows_for_service_json "$service" "$vcl" "$mixed_checked" "$(jq -n --argjson a "$matching" --argjson b "$unrelated" '$a + $b')")"
jq -e '.[0].status == "CONFIRMED" and .[0].workspace_id == "workspace-a"' <<<"$rows" >/dev/null
rows="$(legacy_map_rows_for_service_json "$service" "$vcl" "$mixed_checked" "$matching")"
jq -e '.[0].status == "UNKNOWN" and (.[0].candidates | length) == 1' <<<"$rows" >/dev/null
no_reference="$(jq 'del(.data[1].serviceID)' <<<"$mixed")"
no_reference="$(legacy_map_validate_sites_customer_json "$no_reference" "$customer" 'Customer A' corp-a cli)"
rows="$(legacy_map_rows_for_service_json "$service" "$vcl" "$no_reference" "$matching")"
jq -e '.[0].status == "CONFIRMED" and .[0].workspace_id == "workspace-a"' <<<"$rows" >/dev/null

conflicting='{"status":"COMPLETE","data":[{"id":"workspace-a","customer_id":"customer-a"},{"id":"workspace-b","customer_id":"customer-b"}]}'
if legacy_map_validate_sites_customer_json "$conflicting" "$customer" 'Customer A' corp-a cli >/dev/null 2>&1; then
  printf 'conflicting site ownership was accepted\n' >&2; exit 1
fi
conflicting_fields='{"status":"COMPLETE","data":[{"id":"workspace-a","customer_id":"customer-a","customer":{"id":"customer-b"}}]}'
if legacy_map_validate_sites_customer_json "$conflicting_fields" "$customer" 'Customer A' corp-a cli >/dev/null 2>&1; then
  printf 'conflicting ownership fields on one site were accepted\n' >&2; exit 1
fi
printf 'mapping ownership regressions passed\n'
