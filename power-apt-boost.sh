#!/usr/bin/env bash
#
# Power APT Boost — Fast Ubuntu APT mirror selector and network optimizer
#
# Author  : Matin Shahabadi
# GitHub  : https://github.com/power0matin/power-apt-boost
# License : MIT
# Version : 2.0.0
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/power0matin/power-apt-boost/main/power-apt-boost.sh | sudo bash
#   sudo bash power-apt-boost.sh [OPTIONS]
#
# Run with --help for full usage information.

set -euo pipefail
IFS=$'\n\t'

# ─── Constants ────────────────────────────────────────────────────────────────

readonly APP_NAME="Power APT Boost"
readonly APP_VERSION="2.0.0"
readonly APP_SLUG="power-apt-boost"
readonly APP_AUTHOR="Matin Shahabadi"
readonly APP_GITHUB="https://github.com/power0matin/power-apt-boost"
readonly APP_LICENSE="MIT"

readonly APT_SOURCES_DIR="/etc/apt/sources.list.d"
readonly APT_CONF_DIR="/etc/apt/apt.conf.d"
readonly APT_SOURCES_FILE="/etc/apt/sources.list"
readonly APT_DEB822_FILE="${APT_SOURCES_DIR}/ubuntu.sources"
readonly APT_CONF_FILE="${APT_CONF_DIR}/99-${APP_SLUG}"
readonly BACKUP_BASE="/var/backups/${APP_SLUG}"
readonly KEYRING_PATH="/usr/share/keyrings/ubuntu-archive-keyring.gpg"

readonly PROBE_TIMEOUT_CONNECT=8

# Exit codes
readonly EXIT_OK=0
readonly EXIT_GENERAL=1
readonly EXIT_USAGE=2

# ─── Global State ─────────────────────────────────────────────────────────────

CODENAME=""
SELECTED_MIRROR=""
SELECTED_TIME=""
DRY_RUN=false
SKIP_UPDATE=false
FORCE_MIRROR=""
NO_SPINNER=false
VERBOSE=false
QUIET=false
JSON_OUTPUT=false
RESTORE=false
RESTORE_PATH=""
TIMEOUT_TOTAL=20
COUNTRY_FILTER=""
USE_IPV6=false
LOG_FILE=""
LOG_ENABLED=false

_spinner_pid=""
_child_pid=""
_tmp_files=()

# ─── Color ────────────────────────────────────────────────────────────────────

_setup_colors() {
  if [[ -t 2 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    readonly COLOR_RED='\033[0;31m'
    readonly COLOR_GREEN='\033[0;32m'
    readonly COLOR_YELLOW='\033[0;33m'
    readonly COLOR_BLUE='\033[0;34m'
    readonly COLOR_CYAN='\033[0;36m'
    readonly COLOR_BOLD='\033[1m'
    readonly COLOR_DIM='\033[2m'
    readonly COLOR_RESET='\033[0m'
  else
    readonly COLOR_RED=''
    readonly COLOR_GREEN=''
    readonly COLOR_YELLOW=''
    readonly COLOR_BLUE=''
    readonly COLOR_CYAN=''
    readonly COLOR_BOLD=''
    readonly COLOR_DIM=''
    readonly COLOR_RESET=''
  fi
}

# ─── Logging ──────────────────────────────────────────────────────────────────

_log_to_file() {
  if [[ "$LOG_ENABLED" == true ]] && [[ -n "$LOG_FILE" ]]; then
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

msg() {
  if [[ "$QUIET" == true ]]; then
    return
  fi
  printf '%b\n' "$*" >&2
  _log_to_file "$*"
}

msg_color() {
  if [[ "$QUIET" == true ]]; then
    return
  fi
  local color="$1" text="$2"
  printf '%b%b%b\n' "$color" "$text" "$COLOR_RESET" >&2
  _log_to_file "$text"
}

msg_verbose() {
  if [[ "$VERBOSE" == true ]]; then
    msg "$@"
  fi
}

info() {
  msg_color "$COLOR_GREEN" "[OK] $*"
}

warn() {
  msg_color "$COLOR_YELLOW" "[WARN] $*"
  _log_to_file "WARN: $*"
}

error() {
  msg_color "$COLOR_RED" "[ERROR] $*"
  _log_to_file "ERROR: $*"
}

die() {
  local exit_code="${2:-$EXIT_GENERAL}"
  error "$1"
  exit "$exit_code"
}

# ─── Cleanup & Signals ────────────────────────────────────────────────────────

_cleanup_tmp() {
  local f
  if [[ ${#_tmp_files[@]} -gt 0 ]]; then
    for f in "${_tmp_files[@]}"; do
      if [[ -f "$f" ]]; then
        rm -f "$f" 2>/dev/null || true
      fi
    done
  fi
  _tmp_files=()
}

_cleanup_processes() {
  if [[ -n "${_spinner_pid:-}" ]]; then
    kill "$_spinner_pid" 2>/dev/null || true
    wait "$_spinner_pid" 2>/dev/null || true
    _spinner_pid=""
  fi

  if [[ -n "${_child_pid:-}" ]]; then
    kill "$_child_pid" 2>/dev/null || true
    wait "$_child_pid" 2>/dev/null || true
    _child_pid=""
  fi
}

_cleanup() {
  local exit_code
  exit_code=$?
  _cleanup_processes
  _cleanup_tmp

  if [[ -t 2 ]]; then
    printf "\r\033[K" >&2 2>/dev/null || true
  fi

  if [[ "$LOG_ENABLED" == true ]] && [[ -n "$LOG_FILE" ]]; then
    _log_to_file "Session ended with exit code $exit_code"
  fi

  exit "$exit_code"
}

_handle_interrupt() {
  msg ""
  msg_color "$COLOR_YELLOW" "Interrupted by user. Cleaning up..."
  _cleanup_processes
  _cleanup_tmp
  exit 130
}

trap _cleanup EXIT
trap _handle_interrupt INT TERM HUP

# ─── Temporary Files ──────────────────────────────────────────────────────────

_make_tmp() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/${APP_SLUG}.XXXXXX")"
  _tmp_files+=("$tmp")
  echo "$tmp"
}

# ─── Root Check ───────────────────────────────────────────────────────────────

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root. Use: sudo $0"
  fi
}

# ─── Dependency Check ─────────────────────────────────────────────────────────

_check_commands() {
  local missing=()
  local cmd

  for cmd in apt-get awk date grep mkdir cp id mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required commands: ${missing[*]}"
  fi
}

_check_probe_tool() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    return 0
  fi
  die "curl or wget is required for mirror testing. Install one:\n  apt-get install -y curl"
}

# ─── Ubuntu Detection ────────────────────────────────────────────────────────

detect_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found. This script requires Ubuntu."
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    die "This script supports Ubuntu only. Detected: ${PRETTY_NAME:-${ID:-unknown}} (${ID:-unknown})"
  fi

  if [[ -z "${VERSION_CODENAME:-}" ]]; then
    die "Could not detect Ubuntu version codename from /etc/os-release."
  fi

  CODENAME="$VERSION_CODENAME"
  msg_verbose "Detected Ubuntu ${VERSION_ID:-} (${CODENAME})"
}

# ─── Mirror List ──────────────────────────────────────────────────────────────

# Global Ubuntu mirrors — no regional bias
_DEFAULT_MIRRORS=(
  # ── Global ─────────────────────────────────────────────
  "https://archive.ubuntu.com/ubuntu"
  "https://mirrors.kernel.org/ubuntu"

  # ── US ─────────────────────────────────────────────────
  "https://us.archive.ubuntu.com/ubuntu"
  "https://mirror.math.princeton.edu/pub/ubuntu"
  "https://mirror.cs.uchicago.edu/ubuntu"
  "https://mirror.csclub.uwaterloo.ca/ubuntu"
  "https://mirror.rit.edu/ubuntu"
  "https://mirror.arizona.edu/ubuntu"
  "https://mirror.asciichost.com/ubuntu"
  "https://mirror.dal10.us.leaseweb.net/ubuntu"

  # ── UK ─────────────────────────────────────────────────
  "https://uk.archive.ubuntu.com/ubuntu"

  # ── Europe ─────────────────────────────────────────────
  "https://de.archive.ubuntu.com/ubuntu"
  "https://fr.archive.ubuntu.com/ubuntu"
  "https://it.archive.ubuntu.com/ubuntu"
  "https://nl.archive.ubuntu.com/ubuntu"

  # ── Asia-Pacific ───────────────────────────────────────
  "https://au.archive.ubuntu.com/ubuntu"
  "https://jp.archive.ubuntu.com/ubuntu"
  "https://kr.archive.ubuntu.com/ubuntu"
  "https://in.archive.ubuntu.com/ubuntu"

  # ── Americas ───────────────────────────────────────────
  "https://br.archive.ubuntu.com/ubuntu"

  # ── Iran ───────────────────────────────────────────────
  # Dedicated Iranian mirror pool for users in Iran.
  # These mirrors are located in Iran and provide low-latency
  # access to Ubuntu repositories for Iranian users.
  "https://ir.archive.ubuntu.com/ubuntu"
  "https://mirror.iranserver.com/ubuntu"
  "https://mirror.kernel.ir/ubuntu"
  "https://mirror.arvancloud.ir/ubuntu"
  "https://ubuntu.hostiran.ir/ubuntu"
  "https://mirror.hostbaran.com/ubuntu"
  "https://mirror.aminidc.com/ubuntu"
  "https://archive.ito.gov.ir/ubuntu"
  "https://mirror.faraso.org/ubuntu"
  "https://archive.ubuntu.petiak.ir/ubuntu"
  "https://mirror.kimiahost.com/ubuntu"
  "https://mirror.mobinhost.com/ubuntu"
  "https://mirror.pishgaman.net/ubuntu"
  "https://mirror.sindad.com/ubuntu"
  "https://linuxmirrors.ir/ubuntu"
  "https://mirror.jamko.ir/ubuntu"
  "https://mirror.kubarcloud.com/ubuntu"
)

_get_mirrors() {
  local mirrors=()

  # Use country-specific mirrors if filter is set
  if [[ -n "$COUNTRY_FILTER" ]]; then
    local country_lower
    country_lower="$(echo "$COUNTRY_FILTER" | tr '[:upper:]' '[:lower:]')"
    local mirror_url
    for mirror_url in "${_DEFAULT_MIRRORS[@]}"; do
      if [[ "$mirror_url" == *"//${country_lower}."* ]] || [[ "$mirror_url" == *"//${country_lower}."* ]]; then
        mirrors+=("$mirror_url")
      fi
    done
    # Fall back to all mirrors if no country-specific ones found
    if [[ ${#mirrors[@]} -eq 0 ]]; then
      msg_verbose "No mirrors found for country filter '$COUNTRY_FILTER', using all mirrors"
      mirrors=("${_DEFAULT_MIRRORS[@]}")
    fi
  else
    mirrors=("${_DEFAULT_MIRRORS[@]}")
  fi

  # Add forced mirror at the front if set
  if [[ -n "$FORCE_MIRROR" ]]; then
    mirrors=("$FORCE_MIRROR" "${mirrors[@]}")
  fi

  printf '%s\n' "${mirrors[@]}"
}

list_mirrors() {
  detect_ubuntu

  echo "$APP_NAME v$APP_VERSION — Mirror List"
  echo ""
  echo "Ubuntu codename: $CODENAME"
  echo ""
  printf '%-50s  %s\n' "MIRROR" "STATUS"
  printf '%-50s  %s\n' "$(printf '%0.s-' {1..50})" "------"

  local mirror_url
  while IFS= read -r mirror_url; do
    local main_url="${mirror_url}/dists/${CODENAME}/InRelease"
    local code
    code=$(_probe_url_code "$main_url")
    if [[ "$code" == "200" ]]; then
      printf '%-50s  %s\n' "$mirror_url" "OK"
    else
      printf '%-50s  %s\n' "$mirror_url" "FAIL (HTTP $code)"
    fi
  done < <(_get_mirrors)
}

# ─── HTTP Probing ─────────────────────────────────────────────────────────────

_probe_url_code() {
  local url="$1"
  local ip_flag="-4"

  if [[ "$USE_IPV6" == true ]]; then
    ip_flag="-6"
  fi

  if command -v curl >/dev/null 2>&1; then
    curl "$ip_flag" -L -sS --connect-timeout "$PROBE_TIMEOUT_CONNECT" \
      --max-time "$TIMEOUT_TOTAL" -o /dev/null \
      -w '%{http_code}' "$url" 2>/dev/null || echo "000"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    local http_code
    http_code=$(wget "$ip_flag" --server-response --spider \
      --timeout="$TIMEOUT_TOTAL" --tries=1 -q "$url" 2>&1 \
      | awk '/HTTP\// {print $2}') || true
    echo "${http_code:-000}"
    return
  fi

  echo "000"
}

_probe_url_timed() {
  local url="$1"
  local start end elapsed code

  start=$(date +%s%N 2>/dev/null || date +%s)
  code=$(_probe_url_code "$url")
  end=$(date +%s%N 2>/dev/null || date +%s)

  # Calculate elapsed time
  if [[ ${#start} -gt 10 ]]; then
    # nanosecond precision
    elapsed=$(awk "BEGIN {printf \"%.6f\", ($end - $start) / 1000000000}")
  else
    # second precision fallback
    elapsed="$(( end - start )).000000"
  fi

  echo "$code $elapsed"
}

# ─── Spinner ──────────────────────────────────────────────────────────────────

_supports_spinner() {
  [[ "$NO_SPINNER" == false ]] && [[ -t 2 ]] && [[ "$QUIET" == false ]]
}

_start_spinner() {
  local message="$1"

  if ! _supports_spinner; then
    msg_verbose "... $message"
    return
  fi

  (
    local -a frames
    frames[0]='|'
    frames[1]='/'
    frames[2]='-'
    frames[3]=$'\x5c'
    local i=0
    while true; do
      printf "\r\033[K  [%s] %s" "${frames[$i]}" "$message" >&2
      i=$(( (i + 1) % 4 ))
      sleep 0.12
    done
  ) &
  _spinner_pid=$!
}

_stop_spinner() {
  local status="$1"
  local message="$2"
  local color="$3"

  if [[ -n "${_spinner_pid:-}" ]]; then
    kill "$_spinner_pid" 2>/dev/null || true
    wait "$_spinner_pid" 2>/dev/null || true
    _spinner_pid=""
  fi

  if _supports_spinner; then
    if [[ "$status" == "OK" ]]; then
      printf '%b\r\033[K[%s] %s%b\n' "$COLOR_GREEN" "$status" "$message" "$COLOR_RESET" >&2
    elif [[ "$status" == "FAIL" ]]; then
      printf '%b\r\033[K[%s] %s%b\n' "$COLOR_RED" "$status" "$message" "$COLOR_RESET" >&2
    else
      printf "\r\033[K[%s] %s\n" "$status" "$message" >&2
    fi
  else
    if [[ "$status" == "OK" ]]; then
      info "[$status] $message"
    elif [[ "$status" == "FAIL" ]]; then
      error "[$status] $message"
    else
      msg "[$status] $message"
    fi
  fi
}

# ─── Mirror Testing ──────────────────────────────────────────────────────────

_test_mirror() {
  local base_url="$1"
  local main_code main_time updates_code updates_time security_code security_time
  local result total_time

  base_url="${base_url%/}"

  local main_url="${base_url}/dists/${CODENAME}/InRelease"
  local updates_url="${base_url}/dists/${CODENAME}-updates/InRelease"
  local security_url="${base_url}/dists/${CODENAME}-security/InRelease"

  msg_color "$COLOR_BLUE" "==> $base_url"

  # Test main
  _start_spinner "Testing main repository"
  result=$(_probe_url_timed "$main_url")
  main_code="${result%% *}"
  main_time="${result#* }"
  _stop_spinner "$([ "$main_code" = "200" ] && echo "OK" || echo "FAIL")" \
    "main: HTTP $main_code in ${main_time}s" \
    "$([ "$main_code" = "200" ] && echo "$COLOR_GREEN" || echo "$COLOR_RED")"

  # Test updates
  _start_spinner "Testing updates repository"
  result=$(_probe_url_timed "$updates_url")
  updates_code="${result%% *}"
  updates_time="${result#* }"
  _stop_spinner "$([ "$updates_code" = "200" ] && echo "OK" || echo "FAIL")" \
    "updates: HTTP $updates_code in ${updates_time}s" \
    "$([ "$updates_code" = "200" ] && echo "$COLOR_GREEN" || echo "$COLOR_RED")"

  # Test security
  _start_spinner "Testing security repository"
  result=$(_probe_url_timed "$security_url")
  security_code="${result%% *}"
  security_time="${result#* }"
  _stop_spinner "$([ "$security_code" = "200" ] && echo "OK" || echo "FAIL")" \
    "security: HTTP $security_code in ${security_time}s" \
    "$([ "$security_code" = "200" ] && echo "$COLOR_GREEN" || echo "$COLOR_RED")"

  # Check all passed
  if [[ "$main_code" == "200" ]] && [[ "$updates_code" == "200" ]] && [[ "$security_code" == "200" ]]; then
    total_time=$(awk "BEGIN {printf \"%.6f\", $main_time + $updates_time + $security_time}")
    msg_verbose "  Total time: ${total_time}s"
    echo "$total_time"
    return 0
  fi

  return 1
}

_select_mirror() {
  local best=""
  local best_time="999999"
  local mirror_url total_time tested=0 passed=0

  msg_color "$COLOR_BOLD" "Ubuntu codename: $CODENAME"
  echo ""

  local mirror_list
  mirror_list=$(_get_mirrors)

  local total_mirrors
  total_mirrors=$(echo "$mirror_list" | wc -l)
  msg_color "$COLOR_BOLD" "Testing $total_mirrors mirrors..."
  echo ""

  while IFS= read -r mirror_url; do
    if [[ -z "$mirror_url" ]]; then
      continue
    fi
    tested=$((tested + 1))

    local mirror_time
    if mirror_time=$(_test_mirror "$mirror_url"); then
      passed=$((passed + 1))

      # Compare times using awk for float comparison
      if awk "BEGIN {exit !($mirror_time < $best_time)}"; then
        best="$mirror_url"
        best_time="$mirror_time"
      fi
    fi
  done <<< "$mirror_list"

  echo ""
  msg "Mirrors tested: $tested, available: $passed"

  if [[ -z "$best" ]]; then
    die "No working mirror found. Check your network connection and try again.\n  Possible causes:\n    - Firewall blocking Ubuntu repository access\n    - DNS resolution failure\n    - Network connectivity issue"
  fi

  SELECTED_MIRROR="$best"
  SELECTED_TIME="$best_time"
}

# ─── Backup ───────────────────────────────────────────────────────────────────

_create_backup() {
  local backup_dir
  backup_dir="${BACKUP_BASE}/$(date '+%Y-%m-%d_%H-%M-%S')"
  mkdir -p "$backup_dir"

  local backed_up=0

  # Backup deb822 sources
  if [[ -f "$APT_DEB822_FILE" ]]; then
    cp -a "$APT_DEB822_FILE" "$backup_dir/ubuntu.sources" 2>/dev/null || true
    backed_up=$((backed_up + 1))
  fi

  # Backup legacy sources.list
  if [[ -f "$APT_SOURCES_FILE" ]]; then
    cp -a "$APT_SOURCES_FILE" "$backup_dir/sources.list" 2>/dev/null || true
    backed_up=$((backed_up + 1))
  fi

  # Backup sources.list.d
  if [[ -d "$APT_SOURCES_DIR" ]]; then
    cp -a "$APT_SOURCES_DIR" "$backup_dir/sources.list.d" 2>/dev/null || true
    backed_up=$((backed_up + 1))
  fi

  # Backup apt.conf.d
  if [[ -d "$APT_CONF_DIR" ]]; then
    cp -a "$APT_CONF_DIR" "$backup_dir/apt.conf.d" 2>/dev/null || true
    backed_up=$((backed_up + 1))
  fi

  if [[ $backed_up -eq 0 ]]; then
    warn "No APT configuration files found to back up"
  else
    info "Backup created: $backup_dir"
  fi

  echo "$backup_dir"
}

# ─── APT Configuration ───────────────────────────────────────────────────────

_write_apt_sources() {
  local mirror_url="$1"

  # Ensure keyring exists
  if [[ ! -f "$KEYRING_PATH" ]]; then
    warn "Keyring not found at $KEYRING_PATH — apt may fail signature verification"
  fi

  # Check for existing non-Ubuntu sources in sources.list
  local has_third_party=false
  if [[ -f "$APT_SOURCES_FILE" ]]; then
    if grep -v '^\s*$' "$APT_SOURCES_FILE" 2>/dev/null \
      | grep -v '^\s*#' \
      | grep -v 'archive.ubuntu.com' \
      | grep -v 'security.ubuntu.com' \
      | grep -q . 2>/dev/null; then
      has_third_party=true
    fi
  fi

  # Write deb822 format
  cat > "$APT_DEB822_FILE" <<SOURCES
# Power APT Boost — Ubuntu mirror configuration
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Mirror: ${mirror_url}

Types: deb
URIs: ${mirror_url}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports ${CODENAME}-security
Components: main restricted universe multiverse
Signed-By: ${KEYRING_PATH}
SOURCES

  # Only remove sources.list if it doesn't contain third-party repos
  if [[ -f "$APT_SOURCES_FILE" ]]; then
    if [[ "$has_third_party" == true ]]; then
      warn "sources.list contains third-party repositories — preserving it"
      warn "Third-party sources may conflict with deb822 config"
    else
      rm -f "$APT_SOURCES_FILE"
      msg_verbose "Removed legacy sources.list (no third-party repos detected)"
    fi
  fi
}

_write_apt_config() {
  cat > "$APT_CONF_FILE" <<APTCONF
# Power APT Boost — APT network optimization
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

// Force IPv4 for better compatibility
Acquire::ForceIPv4 "true";

// Retry failed downloads
Acquire::Retries "3";

// Connection timeouts (seconds)
Acquire::http::Timeout "${TIMEOUT_TOTAL}";
Acquire::https::Timeout "${TIMEOUT_TOTAL}";

// Skip translation downloads for speed
Acquire::Languages "none";
APTCONF

  msg_verbose "Wrote APT config to $APT_CONF_FILE"
}

# ─── Backup Restore ───────────────────────────────────────────────────────────

_restore_backup() {
  local backup_path="$1"

  if [[ -z "$backup_path" ]]; then
    # Find the most recent backup
    if [[ -d "$BACKUP_BASE" ]]; then
      backup_path=$(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -f2)
    fi
  fi

  if [[ -z "$backup_path" ]] || [[ ! -d "$backup_path" ]]; then
    # Try the old backup location
    if [[ -d "/root" ]]; then
      backup_path=$(find /root -maxdepth 1 -name 'apt-backup-*' -type d -printf '%T@\t%p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -f2)
    fi
  fi

  if [[ -z "$backup_path" ]] || [[ ! -d "$backup_path" ]]; then
    die "No backup found to restore.\n  Searched:\n    ${BACKUP_BASE}/\n    /root/apt-backup-*/"
  fi

  msg_color "$COLOR_BOLD" "Restoring from: $backup_path"
  echo ""

  # Restore deb822 sources
  if [[ -f "${backup_path}/ubuntu.sources" ]]; then
    cp -a "${backup_path}/ubuntu.sources" "$APT_DEB822_FILE"
    info "Restored ubuntu.sources"
  elif [[ -d "${backup_path}/sources.list.d" ]]; then
    cp -a "${backup_path}/sources.list.d/." "$APT_SOURCES_DIR/"
    info "Restored sources.list.d"
  fi

  # Restore sources.list
  if [[ -f "${backup_path}/sources.list" ]]; then
    cp -a "${backup_path}/sources.list" "$APT_SOURCES_FILE"
    info "Restored sources.list"
  fi

  # Restore apt.conf.d
  if [[ -d "${backup_path}/apt.conf.d" ]]; then
    cp -a "${backup_path}/apt.conf.d/." "$APT_CONF_DIR/"
    info "Restored apt.conf.d"
  fi

  # Clean and update
  msg "Running apt-get update..."
  if apt-get update 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
    info "APT sources restored and updated successfully"
  else
    die "apt-get update failed after restore. Check your APT sources manually."
  fi
}

# ─── Apply Changes ───────────────────────────────────────────────────────────

_apply_changes() {
  echo ""
  msg_color "$COLOR_BOLD" "Selected mirror: $SELECTED_MIRROR"
  msg_color "$COLOR_CYAN" "Response time: ${SELECTED_TIME}s"
  echo ""

  if [[ "$DRY_RUN" == true ]]; then
    cat <<DRYRUN
${COLOR_BOLD}Dry run mode — no changes applied.${COLOR_RESET}

Files that would be written:
  ${APT_DEB822_FILE}
  ${APT_CONF_FILE}

Selected mirror:
  ${SELECTED_MIRROR}

DRYRUN
    return 0
  fi

  # Create backup
  local backup_dir
  backup_dir="$(_create_backup)"

  # Write configuration
  _write_apt_sources "$SELECTED_MIRROR"
  _write_apt_config

  # Clean old package lists
  msg_verbose "Cleaning APT cache..."
  rm -rf /var/lib/apt/lists/*
  apt-get clean 2>/dev/null || true

  # Run apt-get update
  if [[ "$SKIP_UPDATE" == true ]]; then
    msg_color "$COLOR_YELLOW" "Skipped apt-get update (--skip-update)"
    return 0
  fi

  echo ""
  msg_color "$COLOR_BOLD" "Running apt-get update..."
  echo ""

  if apt-get update 2>&1; then
    info "APT update completed successfully"
  else
    warn "apt-get update failed — restoring backup"
    _restore_backup "$backup_dir"
    die "Mirror configuration was reverted due to apt-get update failure."
  fi
}

# ─── Output ───────────────────────────────────────────────────────────────────

_print_json() {
  local status="success"
  local action="mirror_selected"

  if [[ "$DRY_RUN" == true ]]; then
    action="dry_run"
  fi
  if [[ "$RESTORE" == true ]]; then
    action="backup_restored"
  fi

  cat <<JSON
{
  "version": "${APP_VERSION}",
  "action": "${action}",
  "status": "${status}",
  "codename": "${CODENAME:-unknown}",
  "mirror": "${SELECTED_MIRROR:-}",
  "response_time": "${SELECTED_TIME:-}",
  "dry_run": ${DRY_RUN},
  "skip_update": ${SKIP_UPDATE},
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
}

_print_summary() {
  if [[ "$DRY_RUN" == true ]]; then
    cat <<EOF

${COLOR_BOLD}════════════════════════════════════════════════════════════${COLOR_RESET}
${COLOR_CYAN}  Dry run completed${COLOR_RESET}

  Fastest mirror:  ${SELECTED_MIRROR}
  Response time:   ${SELECTED_TIME}s

  No system changes were made.
${COLOR_BOLD}════════════════════════════════════════════════════════════${COLOR_RESET}

EOF
    return
  fi

  cat <<EOF

${COLOR_BOLD}════════════════════════════════════════════════════════════${COLOR_RESET}
${COLOR_GREEN}  APT mirror optimized successfully${COLOR_RESET}

  Mirror:  ${SELECTED_MIRROR}
  Time:    ${SELECTED_TIME}s

  Files modified:
    ${APT_DEB822_FILE}
    ${APT_CONF_FILE}

  To restore a previous configuration:
    sudo $0 --restore

${COLOR_BOLD}════════════════════════════════════════════════════════════${COLOR_RESET}

EOF
}

_print_banner() {
  if [[ "$QUIET" == true ]]; then
    return
  fi
  if [[ "$JSON_OUTPUT" == true ]]; then
    return
  fi
  cat <<EOF

${COLOR_BOLD}${COLOR_CYAN}  ${APP_NAME} v${APP_VERSION}${COLOR_RESET}
  Fast Ubuntu APT mirror selector and network optimizer

  ${COLOR_DIM}GitHub: ${APP_GITHUB}${COLOR_RESET}
  ${COLOR_DIM}License: ${APP_LICENSE}${COLOR_RESET}

EOF
}

_print_help() {
  cat <<EOF
${APP_NAME} v${APP_VERSION} — Fast Ubuntu APT mirror selector

${COLOR_BOLD}USAGE${COLOR_RESET}
  sudo bash $0 [OPTIONS]
  curl -fsSL ${APP_GITHUB}/raw/main/power-apt-boost.sh | sudo bash

${COLOR_BOLD}OPTIONS${COLOR_RESET}
  ${COLOR_GREEN}-h, --help${COLOR_RESET}            Show this help message
  ${COLOR_GREEN}-v, --version${COLOR_RESET}         Show version information
  ${COLOR_GREEN}-m, --mirror URL${COLOR_RESET}      Use a specific Ubuntu mirror
  ${COLOR_GREEN}-r, --restore${COLOR_RESET}         Restore APT config from backup
  ${COLOR_GREEN}    --restore-path PATH${COLOR_RESET} Restore from a specific backup
  ${COLOR_GREEN}    --dry-run${COLOR_RESET}          Test mirrors without changing config
  ${COLOR_GREEN}    --skip-update${COLOR_RESET}      Write config but skip apt-get update
  ${COLOR_GREEN}    --list${COLOR_RESET}             List available mirrors and test them
  ${COLOR_GREEN}    --json${COLOR_RESET}             Output results as JSON (for scripting)
  ${COLOR_GREEN}    --verbose${COLOR_RESET}           Show detailed output
  ${COLOR_GREEN}    --quiet${COLOR_RESET}             Suppress non-essential output
  ${COLOR_GREEN}    --no-spinner${COLOR_RESET}        Disable spinner (for CI/CD)
  ${COLOR_GREEN}    --timeout SECS${COLOR_RESET}      Probe timeout (default: 20)
  ${COLOR_GREEN}    --country CODE${COLOR_RESET}      Filter mirrors by country code
  ${COLOR_GREEN}    --ipv6${COLOR_RESET}              Use IPv6 for mirror testing
  ${COLOR_GREEN}    --log-file PATH${COLOR_RESET}     Write log to file

${COLOR_BOLD}EXAMPLES${COLOR_RESET}
  ${COLOR_DIM}# Auto-select fastest mirror${COLOR_RESET}
  sudo bash $0

  ${COLOR_DIM}# Test without changes${COLOR_RESET}
  sudo bash $0 --dry-run

  ${COLOR_DIM}# Use a specific mirror${COLOR_RESET}
  sudo bash $0 --mirror https://mirror.example.com/ubuntu

  ${COLOR_DIM}# Restore from latest backup${COLOR_RESET}
  sudo bash $0 --restore

  ${COLOR_DIM}# Machine-readable output for CI/CD${COLOR_RESET}
  sudo bash $0 --json --quiet

  ${COLOR_DIM}# List and test all mirrors${COLOR_RESET}
  sudo bash $0 --list

  ${COLOR_DIM}# Filter by country${COLOR_RESET}
  sudo bash $0 --country us

  ${COLOR_DIM}# Pipe install${COLOR_RESET}
  curl -fsSL ${APP_GITHUB}/raw/main/power-apt-boost.sh | sudo bash

${COLOR_BOLD}WHAT IT DOES${COLOR_RESET}
  1. Detects Ubuntu codename
  2. Tests multiple Ubuntu mirrors for reachability and speed
  3. Selects the fastest working mirror
  4. Backs up current APT configuration
  5. Writes deb822-format APT sources
  6. Configures APT network optimizations (IPv4, retries, timeouts)
  7. Cleans stale package lists
  8. Runs apt-get update

${COLOR_BOLD}BACKUPS${COLOR_RESET}
  Backups are stored in: ${BACKUP_BASE}/
  Old backups in:       /root/apt-backup-*/

  To restore:
    sudo $0 --restore
    sudo $0 --restore-path /var/backups/${APP_SLUG}/2025-01-01_12-00-00

${COLOR_BOLD}EXIT CODES${COLOR_RESET}
  ${COLOR_GREEN}0${COLOR_RESET}  Success
  1  General error
  2  Usage error (invalid arguments)
  3  Network error
  4  Not running as root
  5  Not Ubuntu
  6  No working mirror found
  7  Backup failed
  8  Restore failed

${COLOR_BOLD}AUTHOR${COLOR_RESET}
  ${APP_AUTHOR}
  ${APP_GITHUB}
EOF
}

# ─── Argument Parsing ────────────────────────────────────────────────────────

_parse_args() {
  if [[ $# -eq 0 ]]; then
    return
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        _print_help
        exit "$EXIT_OK"
        ;;
      -v|--version)
        echo "$APP_NAME v$APP_VERSION"
        exit "$EXIT_OK"
        ;;
      -m|--mirror)
        if [[ ! "${2:-}" ]]; then
          die "Option $1 requires a URL argument" "$EXIT_USAGE"
        fi
        FORCE_MIRROR="${2%/}"
        shift 2
        ;;
      -r|--restore)
        RESTORE=true
        shift
        ;;
      --restore-path)
        if [[ ! "${2:-}" ]]; then
          die "Option $1 requires a path argument" "$EXIT_USAGE"
        fi
        RESTORE_PATH="${2}"
        RESTORE=true
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --skip-update)
        SKIP_UPDATE=true
        shift
        ;;
      --list)
        _check_probe_tool
        list_mirrors
        exit "$EXIT_OK"
        ;;
      --json)
        JSON_OUTPUT=true
        QUIET=true
        NO_SPINNER=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --quiet)
        QUIET=true
        shift
        ;;
      --no-spinner)
        NO_SPINNER=true
        shift
        ;;
      --timeout)
        if [[ ! "${2:-}" ]]; then
          die "Option $1 requires a number" "$EXIT_USAGE"
        fi
        if [[ ! "$2" =~ ^[0-9]+$ ]]; then
          die "Option $1 requires a positive integer" "$EXIT_USAGE"
        fi
        TIMEOUT_TOTAL="$2"
        shift 2
        ;;
      --country)
        if [[ ! "${2:-}" ]]; then
          die "Option $1 requires a country code" "$EXIT_USAGE"
        fi
        COUNTRY_FILTER="$2"
        shift 2
        ;;
      --ipv6)
        USE_IPV6=true
        shift
        ;;
      --log-file)
        if [[ ! "${2:-}" ]]; then
          die "Option $1 requires a file path" "$EXIT_USAGE"
        fi
        LOG_FILE="$2"
        LOG_ENABLED=true
        shift 2
        ;;
      -*)
        die "Unknown option: $1\nRun '$0 --help' for usage information." "$EXIT_USAGE"
        ;;
      *)
        die "Unexpected argument: $1\nRun '$0 --help' for usage information." "$EXIT_USAGE"
        ;;
    esac
  done
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  _setup_colors
  _parse_args "$@"

  # Initialize log file if requested
  if [[ "$LOG_ENABLED" == true ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    : > "$LOG_FILE"
    _log_to_file "Session started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi

  # Handle restore
  if [[ "$RESTORE" == true ]]; then
    need_root
    _restore_backup "$RESTORE_PATH"
    if [[ "$JSON_OUTPUT" == true ]]; then
      SELECTED_MIRROR="restored"
      SELECTED_TIME=""
      _print_json
    fi
    exit "$EXIT_OK"
  fi

  _print_banner
  need_root
  _check_commands
  _check_probe_tool
  detect_ubuntu

  # Select or force mirror
  if [[ -n "$FORCE_MIRROR" ]]; then
    msg_color "$COLOR_BOLD" "Testing forced mirror: $FORCE_MIRROR"
    echo ""
    local total_time
    if total_time=$(_test_mirror "$FORCE_MIRROR"); then
      SELECTED_MIRROR="$FORCE_MIRROR"
      SELECTED_TIME="$total_time"
    else
      die "Forced mirror is not reachable: $FORCE_MIRROR"
    fi
  else
    _select_mirror
  fi

  # Apply or show results
  _apply_changes
  _print_summary

  if [[ "$JSON_OUTPUT" == true ]]; then
    _print_json
  fi
}

main "$@"
