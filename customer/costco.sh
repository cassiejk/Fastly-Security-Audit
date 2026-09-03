# shellcheck shell=bash
# Sourced by the ngwaf entry point; do not execute directly.

cmd_intl_bot_stats() {
  local format=""
  local cid customer services matched tmp summary
  local from_arg="" to_arg=""

  if [[ "${!#:-}" == "--json" ]]; then
    format="--json"
    set -- "${@:1:$(($#-1))}"
  fi

  case "$#" in
    0)
      make_historical_window_days 30
      ;;
    1)
      validate_historical_days "$1"
      make_historical_window_days "$1"
      ;;
    2)
      from_arg="$1"
      to_arg="$2"
      set_historical_window_dates "$from_arg" "$to_arg"
      validate_monthly_historical_window "$from_arg" "$to_arg"
      ;;
    *)
      die 'usage: ngwaf intl-bot-stats [days|FROM TO] [--json]'
      ;;
  esac

  cid="$(current_cid)"
  customer="$(get "/customer/$cid" | jq -r '.name')"

  # This intentionally targets only the international production services
  # represented on the current Costco QBR slide. It excludes staging/stg,
  # perf/prf, preprod, tst, sbx, domestic cab*/usb*, and unrelated prod/prd
  # services by using an exact service-name allowlist.
  services="$(
    get "/service" |
      jq --arg cid "$cid" '
        [
          .[]
          | select(.customer_id == $cid)
          | select(
              .name
              | test("^prod-(au|es|fr|is|jp|kr|mx|nz|se|tw|uk)$")
            )
          | {name, id}
        ]
        | sort_by(.name)
      '
  )"

  matched="$(jq 'length' <<<"$services")"
  (( matched > 0 )) ||
    die 'no matching international production services found'

  tmp="$(mktemp)"
  printf '[]' > "$tmp"

  while IFS=$'\t' read -r service_name service_id; do
    [[ -n "$service_name" && -n "$service_id" ]] || continue

    summary="$(historical_bot_summary_known_service_json "$service_id" "$service_name")"

    json_stream "$summary" "$(cat "$tmp")" |
      jq -s '.[0] as $item | .[1] + [$item]' > "${tmp}.new"
    mv "${tmp}.new" "$tmp"
  done < <(
    jq -r '.[] | [.name, .id] | @tsv' <<<"$services"
  )

  if [[ "$format" == "--json" ]]; then
    jq \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$HIST_FROM" \
      --arg to "$HIST_TO" \
      '{
        customer: $customer,
        customer_id: $customer_id,
        from: $from,
        to: $to,
        scope: "international production services only",
        services: (
          map(
            . + {
              market: (
                .service_name
                | capture("^prod-(?<code>[a-z]{2})$").code
                | {
                    au: "Australia",
                    es: "Spain",
                    fr: "France",
                    is: "Iceland",
                    jp: "Japan",
                    kr: "Korea",
                    mx: "Mexico",
                    nz: "New Zealand",
                    se: "Sweden",
                    tw: "Taiwan",
                    uk: "UK"
                  }[.]
              )
            }
          )
          | sort_by(-(.bot_percentage // -1))
        )
      }' "$tmp"
    rm -f "$tmp"
    return
  fi

  printf '%s — International Production Bot Management\n' "$customer"
  printf '%s → %s UTC (TO is exclusive)\n' "$HIST_FROM" "$HIST_TO"
  printf 'Scope: exact prod-{au,es,fr,is,jp,kr,mx,nz,se,tw,uk} services only\n\n'

  jq -r '
    def human:
      if . >= 1000000000 then (((. / 1000000000) * 100 | round) / 100 | tostring) + "B"
      elif . >= 1000000 then (((. / 1000000) * 100 | round) / 100 | tostring) + "M"
      elif . >= 1000 then (((. / 1000) * 10 | round) / 10 | tostring) + "K"
      else tostring
      end;

    def market:
      .service_name
      | capture("^prod-(?<code>[a-z]{2})$").code
      | {
          au: "Australia",
          es: "Spain",
          fr: "France",
          is: "Iceland",
          jp: "Japan",
          kr: "Korea",
          mx: "Mexico",
          nz: "New Zealand",
          se: "Sweden",
          tw: "Taiwan",
          uk: "UK"
        }[.];

    sort_by(-(.bot_percentage // -1))
    | (
        ["MARKET", "SERVICE", "EDGE REQUESTS", "BOT ANALYZED*", "BOTS DETECTED*", "BOT % OF ANALYZED*"],
        (
          .[]
          | [
              (market),
              .service_name,
              (.edge_requests | human),
              (.analyzed | human),
              (.detected | human),
              (
                if .bot_percentage == null
                then "n/a"
                else (((.bot_percentage * 100) | round) / 100 | tostring) + "%"
                end
              )
            ]
        )
      )
    | @tsv
  ' "$tmp" | human_table

  rm -f "$tmp"

  printf '\nDefinitions:\n'
  printf '  Bot %% of analyzed* = bot-detected / bot-analyzed using Bot Management metrics.\n'
  printf '  * Bot Management metrics are sampled and scaled estimates; do not divide them by edge_requests to calculate coverage.\n'
  printf 'WARNING: Review matched service scope and outliers before using API-derived values in customer-facing material.\n'
  printf 'Excluded by design: staging/stg, perf/prf, preprod, tst, sbx, domestic cab*/usb*, and unrelated services.\n'
}

cmd_intl_bot_types() {
  local format=""
  local cid customer services matched tmp summary
  local from_arg="" to_arg=""

  if [[ "${!#:-}" == "--json" ]]; then
    format="--json"
    set -- "${@:1:$(($#-1))}"
  fi

  case "$#" in
    0)
      make_historical_window_days 30
      ;;
    1)
      validate_historical_days "$1"
      make_historical_window_days "$1"
      ;;
    2)
      from_arg="$1"
      to_arg="$2"
      set_historical_window_dates "$from_arg" "$to_arg"
      validate_monthly_historical_window "$from_arg" "$to_arg"
      ;;
    *)
      die 'usage: ngwaf intl-bot-types [days|FROM TO] [--json]'
      ;;
  esac

  cid="$(current_cid)"
  customer="$(get "/customer/$cid" | jq -r '.name')"

  services="$(
    get "/service" |
      jq --arg cid "$cid" '
        [
          .[]
          | select(.customer_id == $cid)
          | select(.name | test("^prod-(au|es|fr|is|jp|kr|mx|nz|se|tw|uk)$"))
          | {name, id}
        ]
        | sort_by(.name)
      '
  )"

  matched="$(jq 'length' <<<"$services")"
  (( matched > 0 )) || die 'no matching international production services found'

  tmp="$(mktemp)"
  printf '[]' > "$tmp"

  while IFS=$'\t' read -r service_name service_id; do
    [[ -n "$service_name" && -n "$service_id" ]] || continue
    summary="$(historical_bot_summary_known_service_json "$service_id" "$service_name")"
    json_stream "$summary" "$(cat "$tmp")" |
      jq -s '.[0] as $item | .[1] + [$item]' > "${tmp}.new"
    mv "${tmp}.new" "$tmp"
  done < <(jq -r '.[] | [.name, .id] | @tsv' <<<"$services")

  if [[ "$format" == "--json" ]]; then
    jq \
      --arg customer "$customer" \
      --arg customer_id "$cid" \
      --arg from "$HIST_FROM" \
      --arg to "$HIST_TO" \
      '{
        customer: $customer,
        customer_id: $customer_id,
        from: $from,
        to: $to,
        scope: "international production services only",
        note: "Bot type metrics can overlap; they are not a mutually exclusive composition and should not be summed to 100%.",
        services: (
          map(
            . + {
              market: (
                .service_name
                | capture("^prod-(?<code>[a-z]{2})$").code
                | {
                    au: "Australia", es: "Spain", fr: "France", is: "Iceland",
                    jp: "Japan", kr: "Korea", mx: "Mexico", nz: "New Zealand",
                    se: "Sweden", tw: "Taiwan", uk: "UK"
                  }[.]
              )
            }
          )
          | sort_by(-(.detected // 0))
        )
      }' "$tmp"
    rm -f "$tmp"
    return
  fi

  printf '%s — International Bot Type Signals\n' "$customer"
  printf '%s → %s UTC (TO is exclusive)\n' "$HIST_FROM" "$HIST_TO"
  printf 'Scope: exact prod-{au,es,fr,is,jp,kr,mx,nz,se,tw,uk} services only\n\n'

  jq -r '
    def human:
      if . >= 1000000000 then (((. / 1000000000) * 100 | round) / 100 | tostring) + "B"
      elif . >= 1000000 then (((. / 1000000) * 100 | round) / 100 | tostring) + "M"
      elif . >= 1000 then (((. / 1000) * 10 | round) / 10 | tostring) + "K"
      else tostring
      end;

    def market:
      .service_name
      | capture("^prod-(?<code>[a-z]{2})$").code
      | {
          au: "Australia", es: "Spain", fr: "France", is: "Iceland",
          jp: "Japan", kr: "Korea", mx: "Mexico", nz: "New Zealand",
          se: "Sweden", tw: "Taiwan", uk: "UK"
        }[.];

    sort_by(-(.detected // 0))
    | (
        ["MARKET", "DETECTED*", "VERIFIED*", "HEADLESS*", "AI CRAWLER*", "AI FETCHER*", "SEARCH CRAWLER*"],
        (.[] | [
          (market),
          (.detected | human),
          (.verified | human),
          (.headless | human),
          (.ai_crawler | human),
          (.ai_fetcher | human),
          (.search_engine_crawler | human)
        ])
      )
    | @tsv
  ' "$tmp" | human_table

  printf '\nShare of detected bot requests carrying each classification:\n'
  jq -r '
    def pct($n; $d):
      if ($d // 0) > 0 then (((($n // 0) / $d * 100) * 100 | round) / 100 | tostring) + "%" else "n/a" end;
    def market:
      .service_name
      | capture("^prod-(?<code>[a-z]{2})$").code
      | {
          au: "Australia", es: "Spain", fr: "France", is: "Iceland",
          jp: "Japan", kr: "Korea", mx: "Mexico", nz: "New Zealand",
          se: "Sweden", tw: "Taiwan", uk: "UK"
        }[.];
    sort_by(-(.detected // 0))
    | (
        ["MARKET", "VERIFIED / DETECTED", "HEADLESS / DETECTED", "AI CRAWLER / DETECTED", "AI FETCHER / DETECTED", "SEARCH / DETECTED"],
        (.[] | [
          (market),
          pct(.verified; .detected),
          pct(.headless; .detected),
          pct(.ai_crawler; .detected),
          pct(.ai_fetcher; .detected),
          pct(.search_engine_crawler; .detected)
        ])
      )
    | @tsv
  ' "$tmp" | human_table

  rm -f "$tmp"

  printf '\nDefinitions:\n'
  printf '  * Bot Management metrics are statistically sampled and scaled estimates.\n'
  printf '  Verified, headless, AI crawler/fetcher, and search crawler classifications can overlap.\n'
  printf '  Do NOT add these columns together or treat them as a 100%% stacked composition.\n'
  printf 'WARNING: Use this command to inspect classification patterns; validate semantics before building a customer-facing composition chart.\n'
}

