#!/usr/bin/env bash
set -euo pipefail

PROGRAM_NAME="fastly-audit-installer"
MIN_BASH_MAJOR=5
MIN_BASH_MINOR=2
MIN_BASH_VERSION="${MIN_BASH_MAJOR}.${MIN_BASH_MINOR}"

bash_version_at_least() {
  local have_major="$1"
  local have_minor="$2"

  [[ "$have_major" =~ ^[0-9]+$ ]] || return 1
  [[ "$have_minor" =~ ^[0-9]+$ ]] || return 1

  if (( have_major > MIN_BASH_MAJOR )); then
    return 0
  fi
  if (( have_major < MIN_BASH_MAJOR )); then
    return 1
  fi
  (( have_minor >= MIN_BASH_MINOR ))
}

bash_version_short() {
  local version="${BASH_VERSION:-unknown}"
  version="${version%%(*}"
  [[ -n "$version" ]] || version="unknown"
  printf '%s\n' "$version"
}

runtime_error() {
  local found="$1"
  local os_name
  os_name="$(uname -s 2>/dev/null || printf 'unknown\n')"

  printf '%s: Bash %s or newer is required; found %s.\n' \
    "$PROGRAM_NAME" "$MIN_BASH_VERSION" "$found" >&2

  if [[ "$os_name" == "Darwin" ]]; then
    printf '%s: macOS: brew install bash\n' "$PROGRAM_NAME" >&2
    printf '%s: Ensure Homebrew'\''s bin directory precedes /bin in PATH.\n' \
      "$PROGRAM_NAME" >&2
  else
    printf '%s: Install Bash %s or newer and ensure it appears first in PATH.\n' \
      "$PROGRAM_NAME" "$MIN_BASH_VERSION" >&2
  fi
}

if ! bash_version_at_least "${BASH_VERSINFO[0]:-0}" "${BASH_VERSINFO[1]:-0}"; then
  runtime_error "$(bash_version_short)"
  exit 1
fi

usage() {
  cat <<'HELP'
fastly-audit GitHub Release installer

Usage:
  bash fastly-audit-installer.sh [--version TAG] [--repo OWNER/REPO] [--bin-dir DIR] [--customer-id CUSTOMER_ID] [--configure-shell] [--skip-setup]

Defaults:
  --repo cassiejk/Fastly-Security-Audit
  --version latest
  --bin-dir ~/bin

Environment overrides:
  FASTLY_AUDIT_RELEASE_BASE_URL  Base URL containing release assets
  FASTLY_AUDIT_ARCHIVE_URL       Direct fastly-audit.tar.gz URL
  FASTLY_AUDIT_CHECKSUM_URL      Direct fastly-audit.tar.gz.sha256 URL
  FASTLY_AUDIT_INSTALL_ROOT      Override package install directory
HELP
}

fail() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing dependency: $1"
}

download_file() {
  local url="$1"
  local output="$2"

  printf 'Downloading %s\n' "${output##*/}"
  if ! curl -fsSL "$url" -o "$output"; then
    fail 'download failed; confirm that the Release and all installer assets are published and accessible'
  fi
}

verify_checksum() {
  local archive="$1"
  local checksum="$2"
  local dir

  dir="$(cd "$(dirname "$archive")" && pwd -P)"

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dir" && sha256sum -c "$(basename "$checksum")")
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$dir" && shasum -a 256 -c "$(basename "$checksum")")
  else
    fail "missing dependency: sha256sum or shasum"
  fi
}

repo="${FASTLY_AUDIT_REPO:-cassiejk/Fastly-Security-Audit}"
version="${FASTLY_AUDIT_VERSION:-latest}"
bin_dir="${FASTLY_AUDIT_BIN_DIR:-$HOME/bin}"
customer_id=""
skip_setup=false
configure_shell=false

while (( $# > 0 )); do
  case "$1" in
    --repo)
      [[ $# -ge 2 && -n "${2:-}" ]] || fail 'usage: --repo OWNER/REPO'
      repo="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 && -n "${2:-}" ]] || fail 'usage: --version TAG'
      version="$2"
      shift 2
      ;;
    --bin-dir)
      [[ $# -ge 2 && -n "${2:-}" ]] || fail 'usage: --bin-dir DIR'
      bin_dir="$2"
      shift 2
      ;;
    --customer-id)
      [[ $# -ge 2 && -n "${2:-}" ]] || fail 'usage: --customer-id CUSTOMER_ID'
      customer_id="$2"
      shift 2
      ;;
    --skip-setup)
      skip_setup=true
      shift
      ;;
    --configure-shell)
      configure_shell=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

case "$repo" in
  */*) ;;
  *) fail 'repo must be OWNER/REPO' ;;
esac

if [[ "$configure_shell" == true ]]; then
  [[ "$bin_dir" == "$HOME/bin" ]] ||
    fail '--configure-shell supports the default ~/bin only; use the printed PATH command for a custom --bin-dir'
  case "${SHELL##*/}" in
    zsh) profile="$HOME/.zprofile" ;;
    bash) profile="$HOME/.bash_profile" ;;
    *) fail '--configure-shell supports zsh or bash; use the printed PATH command for this shell' ;;
  esac
fi

require_command curl
require_command tar

if [[ -n "${FASTLY_AUDIT_RELEASE_BASE_URL:-}" ]]; then
  release_base="${FASTLY_AUDIT_RELEASE_BASE_URL%/}"
elif [[ "$version" == "latest" ]]; then
  release_base="https://github.com/$repo/releases/latest/download"
else
  release_base="https://github.com/$repo/releases/download/$version"
fi

archive_url="${FASTLY_AUDIT_ARCHIVE_URL:-$release_base/fastly-audit.tar.gz}"
checksum_url="${FASTLY_AUDIT_CHECKSUM_URL:-$release_base/fastly-audit.tar.gz.sha256}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/fastly-audit-release-install.XXXXXX")"

cleanup() {
  rm -rf "$workdir"
}

trap cleanup EXIT

archive="$workdir/fastly-audit.tar.gz"
checksum="$workdir/fastly-audit.tar.gz.sha256"
extract_dir="$workdir/extract"

download_file "$archive_url" "$archive"
download_file "$checksum_url" "$checksum"
verify_checksum "$archive" "$checksum"

mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir"

package_root="$extract_dir/fastly-audit"
[[ -x "$package_root/ngwaf-update" ]] ||
  fail "release archive did not contain fastly-audit/ngwaf-update"

export FASTLY_AUDIT_BIN_DIR="$bin_dir"
"$package_root/ngwaf-update" "$package_root"

if [[ "$configure_shell" == true ]]; then
  # The profile must expand HOME and PATH when a future shell starts.
  # shellcheck disable=SC2016
  path_line='export PATH="$HOME/bin:$PATH"'
  if [[ -f "$profile" ]] && grep -Fqx "$path_line" "$profile"; then
    printf 'PATH already configured in %s\n' "$profile"
  else
    if [[ -e "$profile" ]]; then
      profile_backup="${profile}.backup-$(date +%Y%m%d-%H%M%S)-$$"
      cp -p "$profile" "$profile_backup"
      printf 'Shell profile backup: %s\n' "$profile_backup"
    fi
    printf '\n%s\n' "$path_line" >>"$profile"
    printf 'Added ~/bin to PATH for future terminals in %s\n' "$profile"
  fi
fi
printf '\nInstall complete.\n'
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *)
    printf "For this terminal, run: export PATH=\"%s:\$PATH\"\n" "$bin_dir"
    ;;
esac

if [[ "$skip_setup" == "true" ]]; then
  printf 'Setup skipped. Run later with: %s/fa setup --customer-id CUSTOMER_ID\n' \
    "$bin_dir"
elif [[ -n "$customer_id" && -n "${FASTLY_API_TOKEN:-}" ]]; then
  "$bin_dir/fa" setup --customer-id "$customer_id"
elif [[ -n "$customer_id" ]]; then
  printf 'Load FASTLY_API_TOKEN through your approved credential workflow, then run: %s/fa setup --customer-id %s\n' \
    "$bin_dir" "$customer_id"
else
  printf 'Next: load FASTLY_API_TOKEN through your approved credential workflow, then run: %s/fa setup --customer-id CUSTOMER_ID\n' \
    "$bin_dir"
fi
printf 'Once setup succeeds, map a CDN service with: %s/fa ngwaf workspace-services --service-id EXACT_CDN_SERVICE_ID --json\n' "$bin_dir"
