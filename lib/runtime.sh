# shellcheck shell=bash
# Sourced before the rest of the project; keep this file Bash 3.2-compatible.

NGWAF_MIN_BASH_MAJOR=5
NGWAF_MIN_BASH_MINOR=2
NGWAF_MIN_BASH_VERSION="${NGWAF_MIN_BASH_MAJOR}.${NGWAF_MIN_BASH_MINOR}"

# Compare a detected Bash major/minor pair against the project's minimum.
# Tests call this directly so runtime policy can be validated without requiring
# several real Bash installations on every machine.
ngwaf_bash_version_at_least() {
  local have_major="$1"
  local have_minor="$2"
  local need_major="${3:-$NGWAF_MIN_BASH_MAJOR}"
  local need_minor="${4:-$NGWAF_MIN_BASH_MINOR}"

  [[ "$have_major" =~ ^[0-9]+$ ]] || return 1
  [[ "$have_minor" =~ ^[0-9]+$ ]] || return 1
  [[ "$need_major" =~ ^[0-9]+$ ]] || return 1
  [[ "$need_minor" =~ ^[0-9]+$ ]] || return 1

  if (( have_major > need_major )); then
    return 0
  fi
  if (( have_major < need_major )); then
    return 1
  fi
  (( have_minor >= need_minor ))
}

# Return the current interpreter's version as a compact x.y.z-style string.
# BASH_VERSION contains suffixes such as "(1)-release"; those are useful in
# doctor, but the bootstrap error is easier to read without them.
ngwaf_current_bash_version_short() {
  local version="${BASH_VERSION:-unknown}"
  version="${version%%(*}"
  [[ -n "$version" ]] || version="unknown"
  printf '%s\n' "$version"
}

# Prefer the actual running interpreter over PATH lookup. PATH matters for the
# shebang, but $BASH tells doctor which executable is running this process.
ngwaf_current_bash_executable() {
  if [[ -n "${BASH:-}" ]]; then
    printf '%s\n' "$BASH"
  else
    command -v bash 2>/dev/null || printf 'unknown\n'
  fi
}

ngwaf_runtime_os_name() {
  uname -s 2>/dev/null || printf 'unknown\n'
}

ngwaf_print_bash_runtime_error() {
  local program="$1"
  local found="$2"
  local os_name="${3:-}"

  [[ -n "$os_name" ]] || os_name="$(ngwaf_runtime_os_name)"

  printf '%s: Bash %s or newer is required; found %s.\n' \
    "$program" "$NGWAF_MIN_BASH_VERSION" "$found" >&2

  if [[ "$os_name" == "Darwin" ]]; then
    printf '%s: macOS: brew install bash\n' "$program" >&2
    printf '%s: Ensure Homebrew'\''s bin directory precedes /bin in PATH.\n' \
      "$program" >&2
  else
    printf '%s: Install Bash %s or newer and ensure it appears first in PATH.\n' \
      "$program" "$NGWAF_MIN_BASH_VERSION" >&2
  fi
}

ngwaf_require_bash_runtime() {
  local program="${1:-fastly-audit}"
  local major="${BASH_VERSINFO[0]:-0}"
  local minor="${BASH_VERSINFO[1]:-0}"

  if ngwaf_bash_version_at_least "$major" "$minor"; then
    return 0
  fi

  ngwaf_print_bash_runtime_error "$program" "$(ngwaf_current_bash_version_short)"
  return 1
}
