#!/usr/bin/env bash
#
# Power APT Boost — Fast Ubuntu APT mirror selector and network optimizer
#
# Author  : Matin Shahabadi
# GitHub  : https://github.com/power0matin/power-apt-boost
# License : MIT
# Version : 3.0.0
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
readonly APP_VERSION="3.0.0"
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

readonly PROBE_TIMEOUT_CONNECT=5
readonly PROBE_TIMEOUT_TOTAL=15
readonly MAX_WORKERS=8

readonly EXIT_OK=0
readonly EXIT_GENERAL=1
readonly EXIT_USAGE=2

# ─── Global State ─────────────────────────────────────────────────────────────

# Detect script invocation name for restore command
set +u
_SCRIPT_NAME="${BASH_SOURCE[0]}"
set -u
if [[ "$_SCRIPT_NAME" == "bash" ]] || [[ "$_SCRIPT_NAME" == "/usr/bin/bash" ]]; then
  _SCRIPT_NAME="power-apt-boost.sh"
elif [[ "$_SCRIPT_NAME" == *"power-apt-boost"* ]]; then
  _SCRIPT_NAME="$(basename "$_SCRIPT_NAME")"
fi

CODENAME=""
SELECTED_MIRROR=""
SELECTED_TIME=""
DRY_RUN=false
SKIP_UPDATE=false
FORCE_MIRROR=""
# shellcheck disable=SC2034  # NO_SPINNER kept for --no-spinner backward compat
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

_tmp_dirs=()
_bg_pids=()

# ─── Color ────────────────────────────────────────────────────────────────────

_setup_colors() {
  if [[ -t 2 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    readonly COLOR_RED=$'\033[0;31m'
    readonly COLOR_GREEN=$'\033[0;32m'
    readonly COLOR_YELLOW=$'\033[0;33m'
    readonly COLOR_BLUE=$'\033[0;34m'
    readonly COLOR_CYAN=$'\033[0;36m'
    readonly COLOR_BOLD=$'\033[1m'
    readonly COLOR_DIM=$'\033[2m'
    readonly COLOR_RESET=$'\033[0m'
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
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

msg() {
  [[ "$QUIET" == true ]] && return
  printf '%b\n' "$*" >&2
  _log_to_file "$*"
}

msg_color() {
  [[ "$QUIET" == true ]] && return
  local color="$1" text="$2"
  printf '%b%b%b\n' "$color" "$text" "$COLOR_RESET" >&2
  _log_to_file "$text"
}

msg_verbose() {
  [[ "$VERBOSE" == true ]] && msg "$@"
}

info() { msg_color "$COLOR_GREEN" "[OK] $*"; }
warn() {
  msg_color "$COLOR_YELLOW" "[WARN] $*"
  _log_to_file "WARN: $*"
}
error() {
  msg_color "$COLOR_RED" "[ERROR] $*"
  _log_to_file "ERROR: $*"
}

die() {
  error "$1"
  exit "${2:-$EXIT_GENERAL}"
}

# ─── Cleanup & Signals ────────────────────────────────────────────────────────

_cleanup() {
  local exit_code=$?

  # Kill all tracked background jobs
  local pid
  for pid in "${_bg_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  _bg_pids=()

  # Note: kill 0 is intentionally omitted — it would kill the script itself

  # Clean temp dirs
  local d
  for d in "${_tmp_dirs[@]}"; do
    if [[ -d "$d" ]]; then rm -rf "$d" 2>/dev/null || true; fi
  done
  _tmp_dirs=()

  if [[ -t 2 ]]; then printf "\r\033[K" >&2 2>/dev/null || true; fi

  [[ "$LOG_ENABLED" == true ]] && [[ -n "$LOG_FILE" ]] &&
    _log_to_file "Session ended with exit code $exit_code"

  exit "$exit_code"
}

_handle_interrupt() {
  msg ""
  msg_color "$COLOR_YELLOW" "Interrupted by user. Cleaning up..."
  exit 130
}

trap _cleanup EXIT
trap _handle_interrupt INT TERM HUP

# ─── Root Check ───────────────────────────────────────────────────────────────

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root. Use: sudo bash ${_SCRIPT_NAME}"
  fi

  local _hostname_output
  if _hostname_output=$(hostname 2>&1); then
    :
  elif [[ "$_hostname_output" == *"unable to resolve host"* ]]; then
    warn "Hostname resolution issue detected — this is a system config problem"
    warn "  (inconsistent hostname in /etc/hosts), not a Power APT Boost issue."
    warn "  The script will continue safely."
    warn "  Fix: add your hostname to /etc/hosts (e.g. '127.0.0.1 $(hostname 2>/dev/null || echo localhost)')"
  fi
}

# ─── Dependency Check ─────────────────────────────────────────────────────────

_check_commands() {
  local missing=() cmd
  for cmd in apt-get awk date grep mkdir cp id mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -gt 0 ]] && die "Missing required commands: ${missing[*]}"
}

_check_probe_tool() {
  command -v curl >/dev/null 2>&1 && return 0
  command -v wget >/dev/null 2>&1 && return 0
  die "curl or wget is required for mirror testing. Install one:\n  apt-get install -y curl"
}

# ─── Ubuntu Detection ────────────────────────────────────────────────────────

detect_ubuntu() {
  [[ -f /etc/os-release ]] || die "/etc/os-release not found. This script requires Ubuntu."

  # shellcheck disable=SC1091
  source /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu only. Detected: ${PRETTY_NAME:-${ID:-unknown}} (${ID:-unknown})"
  [[ -n "${VERSION_CODENAME:-}" ]] || die "Could not detect Ubuntu version codename from /etc/os-release."

  CODENAME="$VERSION_CODENAME"
  msg_verbose "Detected Ubuntu ${VERSION_ID:-} (${CODENAME})"
}

# ─── Mirror List ──────────────────────────────────────────────────────────────

_DEFAULT_MIRRORS=(
  # ── Iran (tested, low-latency for Iranian users) ─────────
  "https://ir.archive.ubuntu.com/ubuntu"
  "https://mirror.arvancloud.ir/ubuntu"
  "https://mirror.iranserver.com/ubuntu"
  "https://ubuntu.hostiran.ir/ubuntu"
  "https://mirror.hostbaran.com/ubuntu"
  "https://mirror.aminidc.com/ubuntu"
  "https://archive.ito.gov.ir/ubuntu"
  "https://archive.ubuntu.petiak.ir/ubuntu"
  "https://mirror.mobinhost.com/ubuntu"
  "https://linuxmirrors.ir/ubuntu"
  "https://mirror.kubarcloud.com/ubuntu"

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
)

_get_mirrors() {
  local mirrors=()

  if [[ -n "$COUNTRY_FILTER" ]]; then
    local country_lower mirror_url
    country_lower="$(echo "$COUNTRY_FILTER" | tr '[:upper:]' '[:lower:]')"
    for mirror_url in "${_DEFAULT_MIRRORS[@]}"; do
      [[ "$mirror_url" == *"//${country_lower}."* ]] && mirrors+=("$mirror_url")
    done
    [[ ${#mirrors[@]} -eq 0 ]] && mirrors=("${_DEFAULT_MIRRORS[@]}")
  else
    mirrors=("${_DEFAULT_MIRRORS[@]}")
  fi

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
  printf '%-50s  %-8s  %s\n' "MIRROR" "STATUS" "DETAIL"
  printf '%-50s  %-8s  %s\n' "$(printf '%0.s-' {1..50})" "--------" "$(printf '%0.s-' {1..30})"

  local mirror_url probe_result http_code reason
  while IFS= read -r mirror_url; do
    probe_result=$(_probe_url_code "${mirror_url}/dists/${CODENAME}/InRelease")
    http_code="${probe_result%% *}"
    reason="${probe_result#* }"
    [[ "$reason" == "$http_code" ]] && reason=""
    if [[ "$http_code" == "200" ]]; then
      printf '%-50s  %-8s  %s\n' "$mirror_url" "OK" ""
    else
      printf '%-50s  %-8s  %s\n' "$mirror_url" "FAIL" "HTTP $http_code${reason:+ — $reason}"
    fi
  done < <(_get_mirrors)
}

# ─── HTTP Probing ─────────────────────────────────────────────────────────────

# Curl-specific error classification
_classify_curl_error() {
  local content
  content=$(cat "$1" 2>/dev/null || true)
  case "$content" in
  *"Could not resolve host"* | *"resolve"*) echo "DNS resolution failed" ;;
  *"Connection refused"*) echo "Connection refused" ;;
  *"Connection timed out"* | *"timed out"*) echo "Connection timed out" ;;
  *"SSL"* | *"TLS"* | *"certificate"*) echo "TLS handshake failed" ;;
  *"Network is unreachable"*) echo "Network unreachable" ;;
  *"No route to host"*) echo "No route to host" ;;
  *"Empty reply from server"*) echo "Empty reply from server" ;;
  *) echo "Connection failed" ;;
  esac
}

# Wget-specific error classification
_classify_wget_error() {
  local output="$1"
  case "$output" in
  *"Failed to resolve"* | *"Unknown host"*) echo "DNS resolution failed" ;;
  *"Connection refused"*) echo "Connection refused" ;;
  *"timed out"* | *"timed-out"*) echo "Connection timed out" ;;
  *"SSL"* | *"certificate"*) echo "TLS handshake failed" ;;
  *"Network is unreachable"*) echo "Network unreachable" ;;
  *) echo "Connection failed" ;;
  esac
}

# Probe a single URL. Writes "http_code reason" to stdout.
_probe_url_code() {
  local url="$1"
  local ip_flag="-4"
  local reason="" http_code

  [[ "$USE_IPV6" == true ]] && ip_flag="-6"

  if command -v curl >/dev/null 2>&1; then
    local curl_stderr
    curl_stderr=$(mktemp "${TMPDIR:-/tmp}/${APP_SLUG}.curlerr.XXXXXX")

    http_code=$(curl "$ip_flag" -L -sS \
      --connect-timeout "$PROBE_TIMEOUT_CONNECT" \
      --max-time "$PROBE_TIMEOUT_TOTAL" \
      -o /dev/null -w '%{http_code}' "$url" 2>"$curl_stderr") || true

    if [[ "$http_code" == "000" ]] || [[ -z "$http_code" ]]; then
      reason=$(_classify_curl_error "$curl_stderr")
      http_code="000"
    fi
    rm -f "$curl_stderr" 2>/dev/null || true
    echo "${http_code} ${reason}"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    local wget_output
    wget_output=$(wget "$ip_flag" --server-response --spider \
      --timeout="$TIMEOUT_TOTAL" --tries=1 -q "$url" 2>&1) || true
    http_code=$(echo "$wget_output" | awk '/HTTP\// {print $2}')
    http_code="${http_code:-000}"
    [[ "$http_code" == "000" ]] && reason=$(_classify_wget_error "$wget_output")
    echo "${http_code} ${reason}"
    return
  fi

  echo "000 no_http_client"
}

# ─── Mirror Testing ──────────────────────────────────────────────────────────

# Test a single mirror: probes main/updates/security in parallel.
# Writes "total_time pass|fail" to result_file (arg $2).
# Prints per-component status lines to stderr.
_test_mirror() {
  local base_url="${1%/}"
  local result_file="$2"
  local codename="$3"
  local main_url="${base_url}/dists/${codename}/InRelease"
  local updates_url="${base_url}/dists/${codename}-updates/InRelease"
  local security_url="${base_url}/dists/${codename}-security/InRelease"

  # Create temp dir for probe stderr files
  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/${APP_SLUG}.mirror.XXXXXX")

  # ── Launch three probes in parallel ──────────────────────────
  local start end elapsed
  start=$(date +%s%N 2>/dev/null || date +%s)

  _probe_url_code "$main_url" >"${tmpdir}/main" 2>"${tmpdir}/main.err" &
  local pid_main=$!
  _probe_url_code "$updates_url" >"${tmpdir}/upd" 2>"${tmpdir}/upd.err" &
  local pid_updates=$!
  _probe_url_code "$security_url" >"${tmpdir}/sec" 2>"${tmpdir}/sec.err" &
  local pid_security=$!

  # ── Wait for all three probes ────────────────────────────────
  wait "$pid_main" 2>/dev/null || true
  wait "$pid_updates" 2>/dev/null || true
  wait "$pid_security" 2>/dev/null || true

  end=$(date +%s%N 2>/dev/null || date +%s)

  # Elapsed time (wall-clock of the parallel batch)
  if [[ ${#start} -gt 10 ]]; then
    elapsed=$(awk "BEGIN {printf \"%.6f\", ($end - $start) / 1000000000}")
  else
    elapsed="$((end - start)).000000"
  fi

  # ── Parse results ────────────────────────────────────────────
  local main_result updates_result security_result
  main_result=$(cat "${tmpdir}/main" 2>/dev/null)
  updates_result=$(cat "${tmpdir}/upd" 2>/dev/null)
  security_result=$(cat "${tmpdir}/sec" 2>/dev/null)

  rm -rf "$tmpdir" 2>/dev/null || true

  local main_code="${main_result%% *}"
  local main_time="${main_result#* }"
  main_time="${main_time%% *}"
  local main_reason="${main_result#* }"
  main_reason="${main_reason#* }"
  [[ "$main_reason" == "$main_time" ]] && main_reason=""

  local updates_code="${updates_result%% *}"
  local updates_time="${updates_result#* }"
  updates_time="${updates_time%% *}"
  local updates_reason="${updates_result#* }"
  updates_reason="${updates_reason#* }"
  [[ "$updates_reason" == "$updates_time" ]] && updates_reason=""

  local security_code="${security_result%% *}"
  local security_time="${security_result#* }"
  security_time="${security_time%% *}"
  local security_reason="${security_result#* }"
  security_reason="${security_reason#* }"
  [[ "$security_reason" == "$security_time" ]] && security_reason=""

  # ── Print results to stderr (preserves original format) ──────
  msg_color "$COLOR_BLUE" "==> $base_url"

  local fail_msg
  if [[ "$main_code" == "200" ]]; then
    info "[OK] main: HTTP $main_code in ${main_time}s"
  else
    fail_msg="main: HTTP $main_code in ${main_time}s"
    [[ -n "$main_reason" ]] && fail_msg="${fail_msg} — ${main_reason}"
    error "[FAIL] $fail_msg"
  fi

  if [[ "$updates_code" == "200" ]]; then
    info "[OK] updates: HTTP $updates_code in ${updates_time}s"
  else
    fail_msg="updates: HTTP $updates_code in ${updates_time}s"
    [[ -n "$updates_reason" ]] && fail_msg="${fail_msg} — ${updates_reason}"
    error "[FAIL] $fail_msg"
  fi

  if [[ "$security_code" == "200" ]]; then
    info "[OK] security: HTTP $security_code in ${security_time}s"
  else
    fail_msg="security: HTTP $security_code in ${security_time}s"
    [[ -n "$security_reason" ]] && fail_msg="${fail_msg} — ${security_reason}"
    error "[FAIL] $fail_msg"
  fi

  # ── Write result to file ─────────────────────────────────────
  if [[ "$main_code" == "200" ]] && [[ "$updates_code" == "200" ]] && [[ "$security_code" == "200" ]]; then
    echo "${elapsed} pass" >"$result_file"
  else
    echo "${elapsed} fail" >"$result_file"
  fi
}

# ─── Parallel Benchmark ──────────────────────────────────────────────────────

_select_mirror() {
  local mirror_list total_mirrors bench_start bench_end bench_duration

  msg_color "$COLOR_BOLD" "Ubuntu codename: $CODENAME"
  echo ""

  mirror_list=$(_get_mirrors)
  total_mirrors=$(echo "$mirror_list" | wc -l)
  msg_color "$COLOR_BOLD" "Testing $total_mirrors mirrors (up to $MAX_WORKERS in parallel)..."
  echo ""

  bench_start=$(date +%s)

  # ── Create temp dir for result files ─────────────────────────
  local bench_tmpdir
  bench_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/${APP_SLUG}.bench.XXXXXX")

  # ── Read mirror list into array for indexed access ───────────
  local -a mirrors
  mapfile -t mirrors <<<"$mirror_list"
  local total=${#mirrors[@]}

  # ── Worker: test one mirror, write result to file ────────────
  _bench_worker() {
    local idx="$1" url="$2" codename="$3" result_file="$4"
    _test_mirror "$url" "$result_file" "$codename"
  }

  # ── Dispatch mirrors to worker pool ──────────────────────────
  local idx=0
  while ((idx < total)); do
    # Fill up to MAX_WORKERS slots
    while ((${#_bg_pids[@]} < MAX_WORKERS)) && ((idx < total)); do
      _bench_worker "$idx" "${mirrors[$idx]}" "$CODENAME" \
        "${bench_tmpdir}/${idx}.result" &
      _bg_pids+=($!)
      ((idx++))
    done

    # Wait for at least one worker to finish
    local new_pids=()
    local pid
    for pid in "${_bg_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        new_pids+=("$pid")
      else
        wait "$pid" 2>/dev/null || true
      fi
    done
    _bg_pids=("${new_pids[@]+"${new_pids[@]}"}")
  done

  # ── Wait for remaining workers ───────────────────────────────
  for pid in "${_bg_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  _bg_pids=()

  bench_end=$(date +%s)
  bench_duration=$((bench_end - bench_start))

  # ── Collect results and find best ────────────────────────────
  local best="" best_time="999999" tested=0 passed=0 failed=0
  local i result_line rtime rstatus
  for ((i = 0; i < total; i++)); do
    result_line=$(cat "${bench_tmpdir}/${i}.result" 2>/dev/null) || continue
    ((tested++)) || true
    rtime="${result_line%% *}"
    rstatus="${result_line#* }"
    if [[ "$rstatus" == "pass" ]]; then
      ((passed++)) || true
      if awk "BEGIN {exit !($rtime < $best_time)}"; then
        best="${mirrors[$i]}"
        best_time="$rtime"
      fi
    else
      ((failed++)) || true
    fi
  done

  rm -rf "$bench_tmpdir" 2>/dev/null || true

  # ── Print summary (matches original format exactly) ──────────
  echo ""
  msg_color "$COLOR_BOLD" "─── Benchmark Summary ───"
  msg "  Total mirrors tested:  $tested"
  msg "  Successful mirrors:    $passed"
  msg "  Failed mirrors:        $failed"
  msg "  Total duration:        ${bench_duration}s"

  if [[ -n "$best" ]]; then
    msg_color "$COLOR_GREEN" "  Selected mirror:       $best"
    msg "  Selection reason:      Fastest response (${best_time}s total)"
  fi
  echo ""

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

  if [[ -f "$APT_DEB822_FILE" ]]; then
    cp -a "$APT_DEB822_FILE" "$backup_dir/ubuntu.sources" 2>/dev/null || true
    ((backed_up++)) || true
  fi
  if [[ -f "$APT_SOURCES_FILE" ]]; then
    cp -a "$APT_SOURCES_FILE" "$backup_dir/sources.list" 2>/dev/null || true
    ((backed_up++)) || true
  fi
  if [[ -d "$APT_SOURCES_DIR" ]]; then
    cp -a "$APT_SOURCES_DIR" "$backup_dir/sources.list.d" 2>/dev/null || true
    ((backed_up++)) || true
  fi
  if [[ -d "$APT_CONF_DIR" ]]; then
    cp -a "$APT_CONF_DIR" "$backup_dir/apt.conf.d" 2>/dev/null || true
    ((backed_up++)) || true
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

  if [[ ! -f "$KEYRING_PATH" ]]; then
    warn "Keyring not found at $KEYRING_PATH — apt may fail signature verification"
  fi

  local has_third_party=false
  if [[ -f "$APT_SOURCES_FILE" ]]; then
    if grep -v '^\s*$' "$APT_SOURCES_FILE" 2>/dev/null |
      grep -v '^\s*#' |
      grep -v 'archive.ubuntu.com' |
      grep -v 'security.ubuntu.com' |
      grep -q . 2>/dev/null; then
      has_third_party=true
    fi
  fi

  cat >"$APT_DEB822_FILE" <<SOURCES
# Power APT Boost — Ubuntu mirror configuration
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Mirror: ${mirror_url}

Types: deb
URIs: ${mirror_url}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports ${CODENAME}-security
Components: main restricted universe multiverse
Signed-By: ${KEYRING_PATH}
SOURCES

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
  cat >"$APT_CONF_FILE" <<APTCONF
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
    if [[ -d "$BACKUP_BASE" ]]; then
      backup_path=$(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' 2>/dev/null |
        sort -rn | head -1 | cut -f2)
    fi
  fi

  if [[ -z "$backup_path" ]] || [[ ! -d "$backup_path" ]]; then
    if [[ -d "/root" ]]; then
      backup_path=$(find /root -maxdepth 1 -name 'apt-backup-*' -type d -printf '%T@\t%p\n' 2>/dev/null |
        sort -rn | head -1 | cut -f2)
    fi
  fi

  if [[ -z "$backup_path" ]] || [[ ! -d "$backup_path" ]]; then
    die "No backup found to restore.\n  Searched:\n    ${BACKUP_BASE}/\n    /root/apt-backup-*/"
  fi

  msg_color "$COLOR_BOLD" "Restoring from: $backup_path"
  echo ""

  if [[ -f "${backup_path}/ubuntu.sources" ]]; then
    cp -a "${backup_path}/ubuntu.sources" "$APT_DEB822_FILE"
    info "Restored ubuntu.sources"
  elif [[ -d "${backup_path}/sources.list.d" ]]; then
    cp -a "${backup_path}/sources.list.d/." "$APT_SOURCES_DIR/"
    info "Restored sources.list.d"
  fi

  if [[ -f "${backup_path}/sources.list" ]]; then
    cp -a "${backup_path}/sources.list" "$APT_SOURCES_FILE"
    info "Restored sources.list"
  fi

  if [[ -d "${backup_path}/apt.conf.d" ]]; then
    cp -a "${backup_path}/apt.conf.d/." "$APT_CONF_DIR/"
    info "Restored apt.conf.d"
  fi

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

  local backup_dir
  backup_dir="$(_create_backup)"

  _write_apt_sources "$SELECTED_MIRROR"
  _write_apt_config

  msg_verbose "Cleaning APT cache..."
  rm -rf /var/lib/apt/lists/*
  apt-get clean 2>/dev/null || true

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
  local status="success" action="mirror_selected"
  [[ "$DRY_RUN" == true ]] && action="dry_run"
  [[ "$RESTORE" == true ]] && action="backup_restored"

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
    sudo bash ${_SCRIPT_NAME} --restore

${COLOR_BOLD}════════════════════════════════════════════════════════════${COLOR_RESET}

EOF
}

_print_banner() {
  [[ "$QUIET" == true || "$JSON_OUTPUT" == true ]] && return
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
  sudo bash ${_SCRIPT_NAME} [OPTIONS]
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
  sudo bash ${_SCRIPT_NAME}

  ${COLOR_DIM}# Test without changes${COLOR_RESET}
  sudo bash ${_SCRIPT_NAME} --dry-run

  ${COLOR_DIM}# Use a specific mirror${COLOR_RESET}
  sudo bash ${_SCRIPT_NAME} --mirror https://mirror.example.com/ubuntu

  ${COLOR_DIM}# Restore from latest backup${COLOR_RESET}
  sudo bash ${_SCRIPT_NAME} --restore

  ${COLOR_DIM}# Machine-readable output for CI/CD${COLOR_RESET}
  sudo bash ${_SCRIPT_NAME} --json --quiet

  ${COLOR_DIM}# List and test all mirrors${COLOR_RESET}
  sudo bash ${_SCRIPT_NAME} --list

  ${COLOR_DIM}# Filter by country${COLOR_RESET}
  sudo bash ${_SCRIPT_NAME} --country us

  ${COLOR_DIM}# Pipe install${COLOR_RESET}
  curl -fsSL ${APP_GITHUB}/raw/main/power-apt-boost.sh | sudo bash

${COLOR_BOLD}WHAT IT DOES${COLOR_RESET}
  1. Detects Ubuntu codename
  2. Tests multiple Ubuntu mirrors concurrently for reachability and speed
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
    sudo bash ${_SCRIPT_NAME} --restore
    sudo bash ${_SCRIPT_NAME} --restore-path /var/backups/${APP_SLUG}/2025-01-01_12-00-00

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
  [[ $# -eq 0 ]] && return

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      _print_help
      exit "$EXIT_OK"
      ;;
    -v | --version)
      echo "$APP_NAME v$APP_VERSION"
      exit "$EXIT_OK"
      ;;
    -m | --mirror)
      [[ ! "${2:-}" ]] && die "Option $1 requires a URL argument" "$EXIT_USAGE"
      FORCE_MIRROR="${2%/}"
      shift 2
      ;;
    -r | --restore)
      RESTORE=true
      shift
      ;;
    --restore-path)
      [[ ! "${2:-}" ]] && die "Option $1 requires a path argument" "$EXIT_USAGE"
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
      # shellcheck disable=SC2034
      NO_SPINNER=true
      shift
      ;;
    --timeout)
      [[ ! "${2:-}" ]] && die "Option $1 requires a number" "$EXIT_USAGE"
      [[ ! "$2" =~ ^[0-9]+$ ]] && die "Option $1 requires a positive integer" "$EXIT_USAGE"
      TIMEOUT_TOTAL="$2"
      shift 2
      ;;
    --country)
      [[ ! "${2:-}" ]] && die "Option $1 requires a country code" "$EXIT_USAGE"
      COUNTRY_FILTER="$2"
      shift 2
      ;;
    --ipv6)
      USE_IPV6=true
      shift
      ;;
    --log-file)
      [[ ! "${2:-}" ]] && die "Option $1 requires a file path" "$EXIT_USAGE"
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

  if [[ "$LOG_ENABLED" == true ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    : >"$LOG_FILE"
    _log_to_file "Session started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi

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

  if [[ -n "$FORCE_MIRROR" ]]; then
    msg_color "$COLOR_BOLD" "Testing forced mirror: $FORCE_MIRROR"
    echo ""
    local result_file
    result_file=$(mktemp "${TMPDIR:-/tmp}/${APP_SLUG}.force.XXXXXX")
    _test_mirror "$FORCE_MIRROR" "$result_file" "$CODENAME"
    local rtime rstatus
    rtime=$(awk '{print $1}' "$result_file")
    rstatus=$(awk '{print $2}' "$result_file")
    rm -f "$result_file" 2>/dev/null || true
    if [[ "$rstatus" == "pass" ]]; then
      SELECTED_MIRROR="$FORCE_MIRROR"
      SELECTED_TIME="$rtime"
    else
      die "Forced mirror is not reachable: $FORCE_MIRROR"
    fi
  else
    _select_mirror
  fi

  _apply_changes
  _print_summary

  [[ "$JSON_OUTPUT" == true ]] && _print_json
}

main "$@"
