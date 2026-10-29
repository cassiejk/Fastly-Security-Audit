# shellcheck shell=bash
# USAGE_PROGRAM is consumed dynamically by die() in lib/core.sh.
# shellcheck disable=SC2034
# Sourced by the fastly-audit entry point; do not execute directly.

dispatch_preflight() {
  local command="${1:-help}"

  case "$command" in
    help|-h|--help|version|doctor|setup)
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
    help|-h|--help|version|doctor|setup|diff)
      ;;
    *)
      [[ -n "${FASTLY_API_TOKEN:-}" ]] || die 'FASTLY_API_TOKEN is not set'
      ;;
  esac

  case "$command" in
    help|-h|--help|version|whoami|use|doctor|setup|diff)
      ;;
    *)
      confirm_customer_scope
      ;;
  esac
}

dispatch_require_no_args() {
  local command_path="$1" help_path="$2" argument
  shift 2
  (( $# == 0 )) && return 0
  argument="$1"
  if [[ "$argument" == -* ]]; then
    printf "Error: unsupported option '%s' for '%s'\n" "$argument" "$command_path" >&2
  else
    printf "Error: unexpected argument '%s' for '%s'\n" "$argument" "$command_path" >&2
  fi
  printf "Run '%s -h' for usage.\n" "$help_path" >&2
  return 1
}

dispatch_flat() {
  local command="${1:-help}"
  (( $# == 0 )) || shift

  if [[ "$command" == "inventory" && $# -eq 1 ]]; then
    case "$1" in
      help|-h|--help) inventory_usage; return ;;
    esac
  fi

  if [[ "$command" == "template-audit" && ( "${1:-}" == "--help" || "${1:-}" == "-h" ) ]]; then
    cmd_template_audit "$@"
    return
  fi
  if [[ "$command" == "timeseries" ]]; then
    timeseries_parse_args "$@"
    if [[ "${TIMESERIES_HELP:-0}" == 1 ]]; then
      timeseries_usage
      return
    fi
  fi
  if [[ "$command" == "timeseries" || "$command" == "overview" ]]; then
    # Keep NGWAF_DEBUG schema diagnostics free of customer and workspace IDs.
    NGWAF_TIMESERIES_DEBUG=scope
  fi

  if [[ "$command" == "help" && "${1:-}" == "ngwaf" && "${2:-}" == "timeseries" && $# -eq 2 ]]; then
    timeseries_usage
    return
  fi

  # Commands without operands must reject extras before customer preflight or API calls.
  case "$command" in
    workspaces)
      if (( $# == 1 )) && [[ "$1" == -h || "$1" == --help ]]; then
        workspaces_usage
        return
      fi
      dispatch_require_no_args "$USAGE_PROGRAM workspaces" "$USAGE_PROGRAM workspaces" "$@" || return 1
      ;;
    version|whoami|customer)
      if (( $# == 1 )) && [[ "$1" == -h || "$1" == --help ]]; then
        usage
        return
      fi
      local command_path="$USAGE_PROGRAM $command"
      if [[ "$command" == customer && "$USAGE_PROGRAM" == "$PROGRAM_NAME customer" ]]; then
        command_path="$USAGE_PROGRAM show"
      fi
      dispatch_require_no_args "$command_path" "$USAGE_PROGRAM" "$@" || return 1
      ;;
    rules|thresholds)
      if (( $# >= 1 )) && [[ "$1" == -* ]]; then
        dispatch_require_no_args "$USAGE_PROGRAM $command" "$USAGE_PROGRAM" "$1" || return 1
      fi
      if (( $# >= 2 )); then
        case "$command:$2" in
          rules:--json|rules:--list|thresholds:--json) ;;
          *) dispatch_require_no_args "$USAGE_PROGRAM $command" "$USAGE_PROGRAM" "$2" || return 1 ;;
        esac
      fi
      if (( $# > 2 )); then
        dispatch_require_no_args "$USAGE_PROGRAM $command" "$USAGE_PROGRAM" "${@:3}" || return 1
      fi
      ;;
    overview)
      if (( $# > 2 )); then
        dispatch_require_no_args "$USAGE_PROGRAM overview" "$USAGE_PROGRAM" "${@:3}" || return 1
      fi
      if (( $# >= 1 )) && [[ "$1" == -* && "$1" != --json ]]; then
        dispatch_require_no_args "$USAGE_PROGRAM overview" "$USAGE_PROGRAM" "$1" || return 1
      fi
      if (( $# >= 2 )) && [[ "$2" == -* && "$2" != --json ]]; then
        dispatch_require_no_args "$USAGE_PROGRAM overview" "$USAGE_PROGRAM" "$2" || return 1
      fi
      ;;
  esac

  dispatch_preflight "$command"

  case "$command" in
    version) cmd_version "$@" ;;
    doctor) cmd_doctor "$@" ;;
    setup) cmd_setup "$@" ;;
    whoami) cmd_whoami "$@" ;;
    use) cmd_use "$@" ;;
    customer) cmd_customer "$@" ;;
    services) progress_run 'service list' cmd_services "$@" ;;
    products) progress_run 'service products' cmd_products "$@" ;;
    inventory) progress_run 'inventory' cmd_inventory "$@" ;;
    workspaces) progress_run 'NGWAF workspaces' cmd_workspaces "$@" ;;
    link) cmd_ngwaf_link "$@" ;;
    workspace-services) cmd_workspace_services "$@" ;;
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
    rule-audit) cmd_rule_audit "$@" ;;
    template-audit) cmd_template_audit "$@" ;;
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
    agent-diagnostic)
      agent_diagnostic_parse_args "$@"
      if [[ "$AGENT_DIAGNOSTIC_HELP" == 1 ]]; then
        agent_diagnostic_usage
        return
      fi
      dispatch_preflight agent-diagnostic
      cmd_ngwaf_agent_diagnostic
      ;;
    platform-metrics-diagnostic)
      platform_metrics_diagnostic_parse_args "$@"
      if [[ "$PLATFORM_METRICS_DIAGNOSTIC_HELP" == 1 ]]; then
        platform_metrics_diagnostic_usage
        return
      fi
      dispatch_preflight platform-metrics-diagnostic
      cmd_platform_metrics_diagnostic
      ;;
    workspaces|link|workspace-services|workspace|posture|rule|rules|account-rules|thresholds|lists|bot-rules|count|requests|rule-audit|template-audit|signal-count|overview|timeseries|metrics|attack-profile|attack-origins)
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
    domains)
      dispatch_preflight services
      cmd_service_domains "$@"
      ;;
    vcl-size)
      dispatch_preflight services
      cmd_service_vcl_size "$@"
      ;;
    ngwaf-architecture)
      dispatch_preflight services
      cmd_service_ngwaf_architecture "$@"
      ;;
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
    legacy-map)
      dispatch_preflight security-summary
      cmd_security_legacy_map "$@"
      ;;
    *) die "unknown security command: $subcommand; run: $PROGRAM_NAME security help" ;;
  esac
}

dispatch_ddos_namespace() {
  local subcommand="${1:-help}"
  (( $# == 0 )) || shift
  USAGE_PROGRAM="$PROGRAM_NAME ddos"

  case "$subcommand" in
    help|-h|--help) ddos_namespace_usage ;;
    link)
      dispatch_preflight ddos-link
      cmd_ddos_link "$@"
      ;;
    export-event)
      dispatch_preflight ddos-export-event
      cmd_ddos_export_event "$@"
      ;;
    *) die "unknown DDoS command: $subcommand; run: $PROGRAM_NAME ddos help" ;;
  esac
}

dispatch_bot_namespace() {
  local subcommand="${1:-help}"
  (( $# == 0 )) || shift
  USAGE_PROGRAM="$PROGRAM_NAME bot"

  case "$subcommand" in
    help|-h|--help) bot_namespace_usage ;;
    workspaces) cmd_bot_workspaces "$@" ;;
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
    setup) dispatch_flat setup "$@" ;;
    use) dispatch_flat use "$@" ;;
    whoami) dispatch_flat whoami "$@" ;;
    security)
      customer_security_parse_args "$@"
      if [[ "$CUSTOMER_SECURITY_MODE" == help ]]; then
        customer_security_usage
        return
      fi
      dispatch_preflight customer-security
      NGWAF_PROGRESS_PHASE_TOTAL=5
      export NGWAF_PROGRESS_PHASE_TOTAL
      progress_run 'customer security audit' cmd_customer_security
      ;;
    vcl-size)
      dispatch_preflight services
      cmd_customer_vcl_size "$@"
      ;;
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
    ddos) dispatch_ddos_namespace "$@" ;;
    service) dispatch_service_namespace "$@" ;;
    security) dispatch_security_namespace "$@" ;;
    bot) dispatch_bot_namespace "$@" ;;
    customer)
      if [[ $# -gt 0 && ( "$PROGRAM_NAME" == "fastly-audit" || "${1:-}" == security ) ]]; then
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
