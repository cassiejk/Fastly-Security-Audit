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
  local os_name interpreter brew_command='' brew_prefix='' homebrew_bash=''
  local major minor selected_bash
  os_name="$(uname -s 2>/dev/null || printf 'unknown\n')"
  interpreter="${BASH:-$(command -v bash 2>/dev/null || printf 'unknown')}"

  printf '%s: Bash %s or newer is required; found %s at %s.\n' \
    "$PROGRAM_NAME" "$MIN_BASH_VERSION" "$found" "$interpreter" >&2

  if [[ "$os_name" == "Darwin" ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew_command="$(command -v brew)"
    elif [[ -x /opt/homebrew/bin/brew ]]; then
      brew_command=/opt/homebrew/bin/brew
    elif [[ -x /usr/local/bin/brew ]]; then
      brew_command=/usr/local/bin/brew
    fi
    if [[ -z "$brew_command" ]]; then
      printf '%s: Install Homebrew and Bash %s or newer, then rerun this installer.\n' \
        "$PROGRAM_NAME" "$MIN_BASH_VERSION" >&2
      return
    fi
    brew_prefix="$("$brew_command" --prefix 2>/dev/null || true)"
    if [[ -n "$brew_prefix" ]]; then
      homebrew_bash="$brew_prefix/bin/bash"
    fi
    if [[ -n "$homebrew_bash" && -x "$homebrew_bash" ]]; then
      major="$("$homebrew_bash" -c 'printf "%s" "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
      minor="$("$homebrew_bash" -c 'printf "%s" "${BASH_VERSINFO[1]}"' 2>/dev/null || true)"
      if bash_version_at_least "$major" "$minor"; then
        selected_bash="$(command -v bash 2>/dev/null || true)"
        if [[ "$selected_bash" != "$homebrew_bash" ]]; then
          printf '%s: Compatible Homebrew Bash is installed at %s but is not first on PATH.\n' \
            "$PROGRAM_NAME" "$homebrew_bash" >&2
        else
          printf '%s: Compatible Homebrew Bash is on PATH, but this installer was started with %s.\n' \
            "$PROGRAM_NAME" "$interpreter" >&2
        fi
        printf '%s: Rerun with: ' "$PROGRAM_NAME" >&2
        if [[ "$selected_bash" != "$homebrew_bash" ]]; then
          printf 'PATH=%q:"$PATH" ' "${homebrew_bash%/bash}" >&2
        fi
        printf '%q' "$homebrew_bash" >&2
        printf ' %q' "$0" "$@" >&2
        printf '\n' >&2
        return
      fi
    fi
    printf '%s: Install or update Bash with: %s install bash\n' \
      "$PROGRAM_NAME" "$brew_command" >&2
    printf '%s: Then rerun this installer with Homebrew Bash %s or newer.\n' \
      "$PROGRAM_NAME" "$MIN_BASH_VERSION" >&2
  else
    printf '%s: Install Bash %s or newer with your system package manager and rerun using that interpreter.\n' \
      "$PROGRAM_NAME" "$MIN_BASH_VERSION" >&2
  fi
}

if ! bash_version_at_least "${BASH_VERSINFO[0]:-0}" "${BASH_VERSINFO[1]:-0}"; then
  runtime_error "$(bash_version_short)" "$@"
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
  local name="$1" action='install it with your system package manager'
  command -v "$name" >/dev/null 2>&1 && return 0
  case "$name" in
    jq) action='install jq (macOS: brew install jq), then rerun the installer' ;;
    curl) action='install curl (macOS: brew install curl), then rerun the installer' ;;
    tar) action='install tar or restore the system tar command, then rerun the installer' ;;
  esac
  fail "missing dependency: $name; $action"
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
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  fail 'missing dependency: sha256sum or shasum; install a SHA-256 checksum tool before downloading the Release'
fi
if [[ "$skip_setup" != true && -n "$customer_id" && -n "${FASTLY_API_TOKEN:-}" ]]; then
  require_command jq
fi

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
if ! updater_output="$("$package_root/ngwaf-update" "$package_root" 2>&1)"; then
  printf '%s\n' "$updater_output" >&2
  fail 'package installation failed'
fi

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
installed_bin_dir="$(cd "$bin_dir" && pwd -P)"
installed_fa="$installed_bin_dir/fa"
installed_version="$("$installed_fa" version)"
selected_fa="$(command -v fa 2>/dev/null || true)"
printf '\nFastly-Audit installed successfully!\n'
printf 'Version: %s\n' "$installed_version"
printf 'Installed command: %s\n' "$installed_fa"
printf 'Bash: %s (supported)\n' "$(bash_version_short)"
if [[ "$selected_fa" == "$installed_fa" || "$selected_fa" == "$bin_dir/fa" ]]; then
  printf 'Shell command: fa is ready to run in this terminal.\n'
elif [[ -n "$selected_fa" ]]; then
  printf 'Shell command: another fa takes precedence (%s).\n' "$selected_fa"
else
  printf 'Shell command: fa is not on PATH in this terminal.\n'
fi
if [[ "$selected_fa" != "$installed_fa" && "$selected_fa" != "$bin_dir/fa" ]]; then
  printf 'For this terminal, run: export PATH='
  printf '%q' "$installed_bin_dir"
  printf ':"$PATH"\n'
  printf 'Or run the installed command directly: %s\n' "$installed_fa"
fi
if [[ "$configure_shell" == true ]]; then
  printf 'Shell profile: PATH change takes effect in new terminals only.\n'
fi

if [[ "$skip_setup" == true ]]; then
  printf 'Customer setup: skipped; Fastly API access was not checked.\n'
elif [[ -z "${FASTLY_API_TOKEN:-}" ]]; then
  printf 'Credential status: FASTLY_API_TOKEN is not loaded; Fastly API access was not checked.\n'
  printf 'Customer setup: incomplete.\n'
elif [[ -z "$customer_id" ]]; then
  printf 'Credential status: FASTLY_API_TOKEN is loaded; Fastly API access was not checked.\n'
  printf 'Customer setup: incomplete; select a Fastly Customer ID with fa setup.\n'
else
  if "$installed_fa" setup --customer-id "$customer_id"; then
    printf 'Customer setup: completed. Run %s doctor for operational verification.\n' "$installed_fa"
  else
    printf 'Customer setup: incomplete; the software is installed. Review the setup checks above.\n'
  fi
fi
if [[ "$skip_setup" == true || -z "${FASTLY_API_TOKEN:-}" || -z "$customer_id" ]]; then
  printf '\nNext steps:\n'
  if [[ -z "${FASTLY_API_TOKEN:-}" ]]; then
    printf '  1. Load an authorized Fastly API token into FASTLY_API_TOKEN using your approved local credential workflow.\n'
  else
    printf '  1. Confirm FASTLY_API_TOKEN is authorized to read your selected customer.\n'
  fi
  printf '  2. Run: %s setup' "$installed_fa"
  if [[ -n "$customer_id" ]]; then printf ' --customer-id %q' "$customer_id"; fi
  printf '\n  3. Run: %s doctor\n' "$installed_fa"
fi
printf 'Need help? Run: %s setup --help\n' "$installed_fa"
