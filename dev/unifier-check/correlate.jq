def normalize:
  if type == "string" then gsub("^[[:space:]]+|[[:space:]]+$"; "") | ascii_downcase
  else "" end;

def fastly_role($definitions):
  (.role | if type == "string" then ascii_downcase else null end) as $legacy
  | (.roles | if type == "array" then . else null end) as $assigned
  | if .deleted_at != null then
      {state: "other", reason: "deleted_fastly_user"}
    elif .locked == true then
      {state: "unresolved", reason: "locked_fastly_user"}
    elif $legacy == null or $assigned == null or ($assigned | length) == 0 then
      {state: "unresolved", reason: "missing_legacy_or_iam_role"}
    elif any($assigned[]; ($definitions[.] // null) == null) then
      {state: "unresolved", reason: "unresolved_iam_role_id"}
    else
      (any($assigned[]; ($definitions[.] | ascii_downcase) == "superuser")) as $iam_super
      | ($legacy == "superuser") as $legacy_super
      | if $iam_super != $legacy_super then
          {state: "unresolved", reason: "legacy_iam_role_conflict"}
        elif $iam_super then {state: "superuser", reason: null}
        else {state: "other", reason: null} end
    end;

def ngwaf_role:
  if (.role | type) != "string" or (.status | type) != "string"
     or (.apiUser | type) != "boolean" then
    {state: "unresolved", reason: "missing_role_status_or_apiUser"}
  elif (.status == "inactive" or .status == "disabled"
        or .status == "deactivated" or .status == "deleted") then
    {state: "other", reason: "inactive_or_unknown_status"}
  elif .status != "active" then
    {state: "unresolved", reason: "unknown_status"}
  elif .apiUser == true then
    {state: "other", reason: "api_only_user"}
  elif .role == "owner" then {state: "owner", reason: null}
  else {state: "other", reason: null} end;

($ngwaf_report[0].outcome == "retrieved" or $ngwaf_report[0].outcome == "empty") as $ngok
| ($fastly_report[0].outcome == "retrieved" or $fastly_report[0].outcome == "empty") as $fok
| ($roles_report[0].outcome == "retrieved" or $roles_report[0].outcome == "not_required") as $rok
| (reduce $roles_report[0].roles[]? as $r ({}; .[$r.id] = $r.name)) as $definitions
| [if $ngok then $ngwaf_raw[0].data[] else empty end
   | {key: (.email | normalize), decision: ngwaf_role}] as $ng
| [if $fok then $fastly_raw[0][] else empty end
   | {key: (.login | normalize), decision: fastly_role($definitions)}] as $fast
| ([$ng[].key, $fast[].key] | unique | map(select(. != ""))) as $keys
| [range(0; $keys | length) as $i
   | $keys[$i] as $key
   | ([$ng[] | select(.key == $key)]) as $ns
   | ([$fast[] | select(.key == $key)]) as $fs
   | (if ($ns | length) > 1 or ($fs | length) > 1 then
        {category: "unresolved", reason: "duplicate_normalized_identifier"}
      elif any($ns[]; .decision.state == "unresolved")
           or any($fs[]; .decision.state == "unresolved") then
        {category: "unresolved", reason: "role_or_status_unresolved"}
      elif any($ns[]; .decision.state == "owner")
           and any($fs[]; .decision.state == "superuser") then
        {category: "matching_records", reason: null}
      elif any($ns[]; .decision.state == "owner") then
        {category: "ngwaf_owner_only", reason: null}
      elif any($fs[]; .decision.state == "superuser") then
        {category: "fastly_superuser_only", reason: null}
      else {category: "neither", reason: null} end)
   | . + {local_id: ("U" + (($i + 1) | tostring)),
          normalized_email: $key,
          ngwaf_record_count: ($ns | length), fastly_record_count: ($fs | length)}
  ] as $identities
| ([ $ng[] | select(.key == "") ] | length) as $ng_missing
| ([ $fast[] | select(.key == "") ] | length) as $fast_missing
| ($identities | map(select(.category == "matching_records")) | length) as $matches
| ($identities | map(select(.category == "unresolved")) | length) as $unresolved
| ($identities | map(select(.category == "unresolved")
                     | .ngwaf_record_count + .fastly_record_count) | add // 0) as $unresolved_records
| (($ngwaf_report[0].pagination.next_present == true)
   or ($ngwaf_report[0].pagination.meta.next_cursor_present == true)
   or (($ngwaf_report[0].pagination.totalCount | type) == "number"
       and $ngwaf_report[0].pagination.totalCount > $ngwaf_report[0].record_count)) as $ng_more
| {
    selected_customer_id: $customer_id,
    selected_corp: $corp,
    api_status: {ngwaf: $ngwaf_report[0].outcome,
                 fastly: $fastly_report[0].outcome,
                 iam_roles: $roles_report[0].outcome},
    user_counts: {ngwaf: $ngwaf_report[0].record_count,
                  fastly: $fastly_report[0].record_count},
    ngwaf_owner_count: ([ $ng[] | select(.decision.state == "owner") ] | length),
    fastly_superuser_count: ([ $fast[] | select(.decision.state == "superuser") ] | length),
    confirmed_matching_record_count: $matches,
    ngwaf_owner_only_count: ($identities | map(select(.category == "ngwaf_owner_only")) | length),
    fastly_superuser_only_count: ($identities | map(select(.category == "fastly_superuser_only")) | length),
    unresolved_identity_count: $unresolved,
    unresolved_record_count: ($unresolved_records + $ng_missing + $fast_missing),
    missing_identifier_counts: {ngwaf: $ng_missing, fastly: $fast_missing},
    completeness: {ngwaf: "not_demonstrated", fastly: "not_demonstrated"},
    pagination_indicates_more_ngwaf_records: $ng_more,
    corp_customer_mapping: "unverified",
    identity_claim: "matching_account_records_only",
    result: (if ($ngok and $fok and $rok) == false then "inconclusive"
             elif $matches > 0 then "matches_found"
             elif ($unresolved + $ng_missing + $fast_missing) > 0 or $ng_more then "inconclusive"
             else "no_matches_observed" end),
    reasons: ([
      if $ngok == false then "ngwaf_user_list_unavailable" else empty end,
      if $fok == false then "fastly_user_list_unavailable" else empty end,
      if $rok == false then "iam_roles_unavailable_or_unresolved" else empty end,
      if ($unresolved + $ng_missing + $fast_missing) > 0 then "unresolved_identity_or_role_records" else empty end,
      if $ng_more then "ngwaf_pagination_indicates_more_records" else empty end,
      "user_list_completeness_not_demonstrated",
      "corp_customer_mapping_not_independently_verified",
      "email_match_does_not_prove_same_authenticated_human"
    ]),
    identities: ($identities | map(select(.category != "neither")))
  }
| if $show_identities then
    {
      warning: "Matching email addresses do not prove shared authenticated identity.",
      missing_identifier_counts,
      identities: [.identities[] | {local_id, category, normalized_email}]
    }
  else
    .identities |= map(del(.normalized_email))
  end
