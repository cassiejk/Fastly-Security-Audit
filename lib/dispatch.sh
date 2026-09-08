# shellcheck shell=bash
# USAGE_PROGRAM is consumed dynamically by die() in lib/core.sh.
# shellcheck disable=SC2034
# Sourced by the fastly-audit entry point; do not execute directly.

dispatch_preflight() {
  local command="${1:-help}"

  case "$command" in
    help|-h|--help|version|doctor)
      ;;
    diff)
      require jq
      ;;
    *)
      require curl
      require jq
      ;;
  esac

  case "$command" in
    help|-h|--help|version|doctor|diff)
      ;;
    *)
      [[ -n "${FASTLY_API_TOKEN:-}" ]] || die 'FASTLY_API_TOKEN is not set'
      ;;
  esac

  case "$command" in
    help|-h|--help|version|whoami|use|doctor|diff)
      ;;
    *)
      confirm_customer_scope
      ;;
  esac
}

dispatch_flat() {
  local command="${1:-help}"
  (( $# == 0 )) || shift

  dispatch_preflight "$command"

  case "$command" in
    version) cmd_version "$@" ;;
    doctor) cmd_doctor "$@" ;;
    whoami) cmd_whoami "$@" ;;
    use) cmd_use "$@" ;;
    customer) cmd_customer "$@" ;;
    services) cmd_services "$@" ;;
    products) cmd_products "$@" ;;
    inventory) cmd_inventory "$@" ;;
    workspaces) cmd_workspaces "$@" ;;
    overview) cmd_overview "$@" ;;
    timeseries) cmd_timeseries "$@" ;;
    metrics) cmd_metrics "$@" ;;
    attack-profile) cmd_attack_profile "$@" ;;
    attack-origins) cmd_attack_origins "$@" ;;
    bot-stats) cmd_bot_stats "$@" ;;
    intl-bot-stats) cmd_intl_bot_stats "$@" ;;
    intl-bot-types) cmd_intl_bot_types "$@" ;;
    account-rules) cmd_account_rules "$@" ;;
    workspace) cmd_workspace "$@" ;;
    posture) cmd_posture "$@" ;;
    rule) cmd_rule "$@" ;;
    rules) cmd_rules "$@" ;;
    thresholds) cmd_thresholds "$@" ;;
    lists) cmd_lists "$@" ;;
    bot-rules) cmd_bot_rules "$@" ;;
    count) cmd_count "$@" ;;
    requests) cmd_requests "$@" ;;
    signal-count) cmd_signal_count "$@" ;;
    snapshot) cmd_snapshot "$@" ;;
    diff) cmd_diff "$@" ;;
    help|-h|--help)
      if [[ "${1:-}" == "legacy" ]]; then
        legacy_usage
      else
        usage
      fi
      ;;
    *) die "unknown command: $command; run: $PROGRAM_NAME help" ;;
  esac
}

dispatch_ngwaf_namespace() {
  local subcommand="${1:-help}"
  (( $# == 0 )) || shift
  USAGE_PROGRAM="$PROGRAM_NAME ngwaf"

  case "$subcommand" in
    help|-h|--help) ngwaf_namespace_usage ;;
    workspaces|workspace|posture|rule|rules|account-rules|thresholds|lists|bot-rules|count|requests|signal-count|overview|timeseries|metrics|attack-profile|attack-origins)
      dispatch_flat "$subcommand" "$@"
      ;;
    snapshot) dispatch_flat snapshot "$@" ;;
    *) die "unknown NGWAF command: $subcommand; run: $PROGRAM_NAME ngwaf help" ;;
  esac
}

dispatch_service_namespace() {
  local subcommand="${1:-help}"
  (( $# == 0 )) || shift
  USAGE_PROGRAM="$PROGRAM_NAME service"

  case "$subcommand" in
    help|-h|--help) service_namespace_usage ;;
    list) dispatch_flat services "$@" ;;
    products) dispatch_flat products "$@" ;;
    inventory) dispatch_flat inventory "$@" ;;
    *) die "unknown service command: $subcommand; run: $PROGRAM_NAME service help" ;;
  esac
}

dispatch_security_namespace() {
  local subcommand="${1:-help}"
  (( $# == 0 )) || shift
  USAGE_PROGRAM="$PROGRAM_NAME security"

  case "$subcommand" in
    help|-h|--help) security_namespace_usage ;;
    summary)
      dispatch_preflight security-summary
      cmd_security_summary "$@"
      ;;
    *) die "unknown security command: $subcommand; run: $PROGRAM_NAME security help" ;;
  esac
}

dispatch_bot_namespace() {
  local subcommand="${1:-help}"
  (( $# == 0 )) || shift
  USAGE_PROGRAM="$PROGRAM_NAME bot"

  case "$subcommand" in
    help|-h|--help) bot_namespace_usage ;;
    stats) dispatch_flat bot-stats "$@" ;;
    rules) dispatch_flat bot-rules "$@" ;;
    intl-stats) dispatch_flat intl-bot-stats "$@" ;;
    intl-types) dispatch_flat intl-bot-types "$@" ;;
    *) die "unknown bot command: $subcommand; run: $PROGRAM_NAME bot help" ;;
  esac
}

dispatch_customer_namespace() {
  local subcommand="${1:-show}"
  (( $# == 0 )) || shift
  USAGE_PROGRAM="$PROGRAM_NAME customer"

  case "$subcommand" in
    show) dispatch_flat customer "$@" ;;
    use) dispatch_flat use "$@" ;;
    whoami) dispatch_flat whoami "$@" ;;
    help|-h|--help) customer_namespace_usage ;;
    *) die "unknown customer command: $subcommand; run: $PROGRAM_NAME customer help" ;;
  esac
}

dispatch_snapshot_namespace() {
  local resource="${1:-help}"
  (( $# == 0 )) || shift
  USAGE_PROGRAM="$PROGRAM_NAME snapshot"

  case "$resource" in
    ngwaf) dispatch_flat snapshot "$@" ;;
    help|-h|--help) snapshot_namespace_usage ;;
    *) dispatch_flat snapshot "$resource" "$@" ;;
  esac
}

dispatch_cli() {
  local command="${1:-help}"
  (( $# == 0 )) || shift

  case "$command" in
    ngwaf) dispatch_ngwaf_namespace "$@" ;;
    service) dispatch_service_namespace "$@" ;;
    security) dispatch_security_namespace "$@" ;;
    bot) dispatch_bot_namespace "$@" ;;
    customer)
      if [[ "$PROGRAM_NAME" == "fastly-audit" && $# -gt 0 ]]; then
        dispatch_customer_namespace "$@"
      else
        dispatch_flat customer "$@"
      fi
      ;;
    snapshot)
      if [[ "$PROGRAM_NAME" == "fastly-audit" ]]; then
        dispatch_snapshot_namespace "$@"
      else
        dispatch_flat snapshot "$@"
      fi
      ;;
    *)
      USAGE_PROGRAM="$PROGRAM_NAME"
      dispatch_flat "$command" "$@"
      ;;
  esac
}
