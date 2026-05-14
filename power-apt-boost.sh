#!/usr/bin/env bash
#
# Power APT Boost
# Fast Ubuntu APT mirror selector and network optimizer
#
# Author : Matin Shahabadi
# GitHub : https://github.com/power0matin
# License: MIT
#

set -Eeuo pipefail

APP_NAME="Power APT Boost"
VERSION="1.2.0"
AUTHOR="Matin Shahabadi"
GITHUB="https://github.com/power0matin"

CODENAME=""
SELECTED_MIRROR=""
SELECTED_TIME=""

LAST_HTTP_CODE=""
LAST_TIME_TOTAL=""
TEST_MIRROR=""
TEST_TIME=""

SPINNER_PID=""
CHILD_PID=""

DRY_RUN="false"
SKIP_UPDATE="false"
KEEP_RECOMMENDS="false"
FORCE_MIRROR=""
NO_SPINNER="false"

CANDIDATES=(
  "https://repo.abrha.net/ubuntu"
  "http://repo.abrha.net/ubuntu"
  "https://mirror.arvancloud.ir/ubuntu"
  "http://mirror.arvancloud.ir/ubuntu"
  "http://ir.archive.ubuntu.com/ubuntu"
  "http://archive.ubuntu.com/ubuntu"
)

print_banner() {
  cat <<EOF

============================================================
  $APP_NAME v$VERSION
  Fast Ubuntu APT Mirror Selector

  Author : $AUTHOR
  GitHub : $GITHUB
============================================================

EOF
}

print_help() {
  cat <<EOF
$APP_NAME v$VERSION

Usage:
  sudo bash power-apt-boost.sh [options]

Options:
  -h, --help                 Show this help message
  -v, --version              Show version
  -m, --mirror URL           Use a specific Ubuntu mirror instead of auto-selecting
      --dry-run              Test mirrors and show result without changing APT config
      --skip-update          Write config but do not run apt-get update
      --keep-recommends      Keep APT recommended packages enabled
      --no-spinner           Disable loading spinner output

Examples:
  sudo bash power-apt-boost.sh

  sudo bash power-apt-boost.sh --dry-run

  sudo bash power-apt-boost.sh --mirror http://mirror.arvancloud.ir/ubuntu

  curl -fsSL https://raw.githubusercontent.com/power0matin/power-apt-boost/main/power-apt-boost.sh | sudo bash

What this script does:
  - Detects Ubuntu codename
  - Tests multiple Ubuntu mirrors
  - Selects the fastest working mirror
  - Backs up current APT sources and config
  - Rewrites Ubuntu APT sources
  - Forces IPv4 for better VPS compatibility
  - Sets APT retry and timeout options
  - Cleans old APT package lists
  - Runs apt-get update unless --skip-update is used
  - Supports safe Ctrl+C interruption

Author:
  $AUTHOR
  $GITHUB
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "INFO: $*"
}

log() {
  echo "$*" >&2
}

supports_spinner() {
  [ "$NO_SPINNER" = "false" ] && [ -t 2 ]
}

cleanup_processes() {
  if [ -n "${SPINNER_PID:-}" ]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi

  if [ -n "${CHILD_PID:-}" ]; then
    kill "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
    CHILD_PID=""
  fi

  if [ -t 2 ]; then
    printf "\r\033[K" >&2 || true
  fi
}

handle_interrupt() {
  log ""
  log "Interrupted by user. Cleaning up..."
  cleanup_processes
  exit 130
}

start_spinner() {
  local message="$1"

  if ! supports_spinner; then
    log "... $message"
    SPINNER_PID=""
    return
  fi

  (
    local frames=("|" "/" "-" "\\")
    local i=0

    while true; do
      printf "\r[%s] %s" "${frames[$i]}" "$message" >&2
      i=$(( (i + 1) % 4 ))
      sleep 0.12
    done
  ) &

  SPINNER_PID="$!"
}

stop_spinner() {
  local status="$1"
  local message="$2"

  if [ -n "${SPINNER_PID:-}" ]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi

  if supports_spinner; then
    printf "\r\033[K[%s] %s\n" "$status" "$message" >&2
  else
    log "[$status] $message"
  fi
}

trap cleanup_processes EXIT
trap handle_interrupt INT TERM

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Please run this script as root. Example: sudo bash power-apt-boost.sh"
  fi
}

require_basic_commands() {
  command -v awk >/dev/null 2>&1 || die "awk is required."
  command -v date >/dev/null 2>&1 || die "date is required."
  command -v mkdir >/dev/null 2>&1 || die "mkdir is required."
  command -v cp >/dev/null 2>&1 || die "cp is required."
  command -v rm >/dev/null 2>&1 || die "rm is required."
  command -v id >/dev/null 2>&1 || die "id is required."
  command -v cat >/dev/null 2>&1 || die "cat is required."
  command -v mktemp >/dev/null 2>&1 || die "mktemp is required."
  command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
}

require_probe_tool() {
  if command -v curl >/dev/null 2>&1; then
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    return
  fi

  die "curl, wget, or python3 is required to test mirrors."
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        print_help
        exit 0
        ;;
      -v|--version)
        echo "$APP_NAME v$VERSION"
        exit 0
        ;;
      -m|--mirror)
        [ "${2:-}" ] || die "--mirror requires a URL."
        FORCE_MIRROR="${2%/}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --skip-update)
        SKIP_UPDATE="true"
        shift
        ;;
      --keep-recommends)
        KEEP_RECOMMENDS="true"
        shift
        ;;
      --no-spinner)
        NO_SPINNER="true"
        shift
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

detect_ubuntu() {
  if [ ! -f /etc/os-release ]; then
    die "/etc/os-release not found."
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  if [ "${ID:-}" != "ubuntu" ]; then
    die "This script is designed for Ubuntu only. Detected: ${ID:-unknown}"
  fi

  if [ -z "${VERSION_CODENAME:-}" ]; then
    die "Could not detect Ubuntu codename."
  fi

  CODENAME="$VERSION_CODENAME"
}

probe_url() {
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -4 -L -sS --connect-timeout 8 --max-time 20 \
      -o /dev/null -w '%{http_code} %{time_total}' "$url" 2>/dev/null || echo "000 999999"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    local start
    local end

    start="$(date +%s)"

    if wget -4 --spider --timeout=20 --tries=1 -q "$url"; then
      end="$(date +%s)"
      echo "200 $((end - start))"
    else
      echo "000 999999"
    fi

    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" <<'PY'
import sys
import time
import urllib.request

url = sys.argv[1]
start = time.time()

try:
    req = urllib.request.Request(url, headers={"User-Agent": "PowerAPTBoost/1.2.0"})
    with urllib.request.urlopen(req, timeout=20) as response:
        code = response.getcode()
    print(f"{code} {time.time() - start:.6f}")
except Exception:
    print("000 999999")
PY
    return
  fi

  echo "000 999999"
}

probe_url_with_spinner() {
  local label="$1"
  local url="$2"
  local tmp_file
  local result
  local code
  local time_taken
  local child_status=0

  LAST_HTTP_CODE="000"
  LAST_TIME_TOTAL="999999"

  tmp_file="$(mktemp -t power-apt-boost.XXXXXX)"

  start_spinner "$label"

  (
    probe_url "$url" > "$tmp_file"
  ) &

  CHILD_PID="$!"

  if wait "$CHILD_PID"; then
    child_status=0
  else
    child_status="$?"
  fi

  CHILD_PID=""

  result="$(cat "$tmp_file" 2>/dev/null || true)"
  rm -f "$tmp_file"

  if [ "$child_status" -ne 0 ] || [ -z "${result:-}" ]; then
    result="000 999999"
  fi

  code="$(echo "$result" | awk '{print $1}')"
  time_taken="$(echo "$result" | awk '{print $2}')"

  if [ -z "${code:-}" ]; then
    code="000"
  fi

  if [ -z "${time_taken:-}" ]; then
    time_taken="999999"
  fi

  LAST_HTTP_CODE="$code"
  LAST_TIME_TOTAL="$time_taken"

  if [ "$code" = "200" ]; then
    stop_spinner "OK" "$label - HTTP $code in ${time_taken}s"
  else
    stop_spinner "FAIL" "$label - HTTP $code in ${time_taken}s"
  fi
}

test_single_mirror() {
  local base="$1"
  local main_url
  local updates_url
  local security_url

  local main_code
  local main_time
  local updates_code
  local updates_time
  local security_code
  local security_time
  local total_time

  TEST_MIRROR=""
  TEST_TIME=""

  base="${base%/}"

  main_url="$base/dists/$CODENAME/InRelease"
  updates_url="$base/dists/$CODENAME-updates/InRelease"
  security_url="$base/dists/$CODENAME-security/InRelease"

  log "==> $base"

  probe_url_with_spinner "Testing main repository" "$main_url"
  main_code="$LAST_HTTP_CODE"
  main_time="$LAST_TIME_TOTAL"

  probe_url_with_spinner "Testing updates repository" "$updates_url"
  updates_code="$LAST_HTTP_CODE"
  updates_time="$LAST_TIME_TOTAL"

  probe_url_with_spinner "Testing security repository" "$security_url"
  security_code="$LAST_HTTP_CODE"
  security_time="$LAST_TIME_TOTAL"

  log "main:     HTTP $main_code time ${main_time}s"
  log "updates:  HTTP $updates_code time ${updates_time}s"
  log "security: HTTP $security_code time ${security_time}s"

  if [ "$main_code" = "200" ] && [ "$updates_code" = "200" ] && [ "$security_code" = "200" ]; then
    total_time="$(awk "BEGIN {print $main_time + $updates_time + $security_time}")"

    TEST_MIRROR="$base"
    TEST_TIME="$total_time"

    log "OK total ${total_time}s"
    log ""
    return 0
  fi

  log "FAILED"
  log ""
  return 1
}

select_forced_mirror() {
  log "Testing forced mirror..."
  log ""

  if ! test_single_mirror "$FORCE_MIRROR"; then
    die "Forced mirror is not valid or not reachable: $FORCE_MIRROR"
  fi

  SELECTED_MIRROR="$TEST_MIRROR"
  SELECTED_TIME="$TEST_TIME"
}

select_fastest_mirror() {
  local best=""
  local best_time="999999"

  echo "Detected Ubuntu codename: $CODENAME"
  echo
  echo "Testing Ubuntu mirrors..."
  echo

  for base in "${CANDIDATES[@]}"; do
    if test_single_mirror "$base"; then
      if awk "BEGIN {exit !($TEST_TIME < $best_time)}"; then
        best="$TEST_MIRROR"
        best_time="$TEST_TIME"
      fi
    fi
  done

  if [ -z "$best" ]; then
    die "No working mirror found. Your server network may be blocking or resetting Ubuntu repository connections."
  fi

  SELECTED_MIRROR="$best"
  SELECTED_TIME="$best_time"
}

backup_apt_sources() {
  local backup_dir

  backup_dir="/root/apt-backup-$(date +%F-%H%M%S)"
  mkdir -p "$backup_dir"

  cp -a /etc/apt/sources.list "$backup_dir/sources.list" 2>/dev/null || true
  cp -a /etc/apt/sources.list.d "$backup_dir/sources.list.d" 2>/dev/null || true
  cp -a /etc/apt/apt.conf.d "$backup_dir/apt.conf.d" 2>/dev/null || true

  echo "Backup created at: $backup_dir"
}

write_apt_sources() {
  local selected_mirror="$1"

  cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $selected_mirror
Suites: $CODENAME $CODENAME-updates $CODENAME-backports $CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

  rm -f /etc/apt/sources.list
}

write_apt_network_config() {
  cat > /etc/apt/apt.conf.d/99-power-apt-boost <<EOF
Acquire::ForceIPv4 "true";
Acquire::Retries "2";
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
Acquire::Languages "none";
EOF

  if [ "$KEEP_RECOMMENDS" = "false" ]; then
    cat >> /etc/apt/apt.conf.d/99-power-apt-boost <<EOF
APT::Install-Recommends "false";
EOF
  fi
}

clean_apt_cache() {
  rm -rf /var/lib/apt/lists/*
  apt-get clean
}

run_apt_update() {
  local child_status=0

  apt-get update &

  CHILD_PID="$!"

  if wait "$CHILD_PID"; then
    child_status=0
  else
    child_status="$?"
  fi

  CHILD_PID=""

  return "$child_status"
}

apply_changes() {
  echo
  echo "Selected mirror: $SELECTED_MIRROR"
  echo "Mirror test time: ${SELECTED_TIME}s"
  echo

  if [ "$DRY_RUN" = "true" ]; then
    cat <<EOF
Dry run mode is enabled.

No changes were applied.

Would write:
  /etc/apt/sources.list.d/ubuntu.sources
  /etc/apt/apt.conf.d/99-power-apt-boost

Would select:
  $SELECTED_MIRROR

EOF
    return
  fi

  backup_apt_sources
  write_apt_sources "$SELECTED_MIRROR"
  write_apt_network_config
  clean_apt_cache

  if [ "$SKIP_UPDATE" = "true" ]; then
    echo "Skipped apt-get update because --skip-update was used."
    return
  fi

  echo
  echo "Running apt-get update..."
  echo

  if ! run_apt_update; then
    die "apt-get update failed after applying mirror configuration."
  fi
}

print_final_message() {
  if [ "$DRY_RUN" = "true" ]; then
    cat <<EOF
============================================================
  Dry run completed.

  Fastest working mirror:
  $SELECTED_MIRROR

  No system changes were made.

  Powered by $AUTHOR
  GitHub: $GITHUB
============================================================
EOF
    return
  fi

  cat <<EOF

============================================================
  Done.

  APT mirror optimized successfully.
  Selected mirror: $SELECTED_MIRROR

  Recommended install command:
    apt-get install -y PACKAGE_NAME

  Example:
    apt-get install -y nginx

  Powered by $AUTHOR
  GitHub: $GITHUB
============================================================

EOF
}

main() {
  parse_args "$@"
  print_banner
  need_root
  require_basic_commands
  require_probe_tool
  detect_ubuntu

  if [ -n "$FORCE_MIRROR" ]; then
    select_forced_mirror
  else
    select_fastest_mirror
  fi

  apply_changes
  print_final_message
}

main "$@"