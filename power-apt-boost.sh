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
VERSION="1.0.0"
AUTHOR="Matin Shahabadi"
GITHUB="https://github.com/power0matin"

CODENAME=""
SELECTED_MIRROR=""
SELECTED_TIME=""

DRY_RUN="false"
SKIP_UPDATE="false"
KEEP_RECOMMENDS="false"
FORCE_MIRROR=""

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
  command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
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
    req = urllib.request.Request(url, headers={"User-Agent": "PowerAPTBoost/1.0"})
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

test_single_mirror() {
  local base="$1"
  local main_url
  local updates_url
  local security_url

  local main_result
  local updates_result
  local security_result

  local main_code
  local main_time
  local updates_code
  local updates_time
  local security_code
  local security_time
  local total_time

  base="${base%/}"

  main_url="$base/dists/$CODENAME/InRelease"
  updates_url="$base/dists/$CODENAME-updates/InRelease"
  security_url="$base/dists/$CODENAME-security/InRelease"

  echo "==> $base"

  main_result="$(probe_url "$main_url")"
  updates_result="$(probe_url "$updates_url")"
  security_result="$(probe_url "$security_url")"

  main_code="$(echo "$main_result" | awk '{print $1}')"
  main_time="$(echo "$main_result" | awk '{print $2}')"

  updates_code="$(echo "$updates_result" | awk '{print $1}')"
  updates_time="$(echo "$updates_result" | awk '{print $2}')"

  security_code="$(echo "$security_result" | awk '{print $1}')"
  security_time="$(echo "$security_result" | awk '{print $2}')"

  echo "main:     HTTP $main_code time ${main_time}s"
  echo "updates:  HTTP $updates_code time ${updates_time}s"
  echo "security: HTTP $security_code time ${security_time}s"

  if [ "$main_code" = "200" ] && [ "$updates_code" = "200" ] && [ "$security_code" = "200" ]; then
    total_time="$(awk "BEGIN {print $main_time + $updates_time + $security_time}")"
    echo "OK total ${total_time}s"
    echo
    echo "$base $total_time"
    return 0
  fi

  echo "FAILED"
  echo
  return 1
}

select_forced_mirror() {
  local result
  local mirror
  local total_time

  echo "Testing forced mirror..."
  echo

  result="$(test_single_mirror "$FORCE_MIRROR" | tail -n 1 || true)"

  mirror="$(echo "$result" | awk '{print $1}')"
  total_time="$(echo "$result" | awk '{print $2}')"

  if [ "$mirror" != "$FORCE_MIRROR" ] || [ -z "${total_time:-}" ]; then
    die "Forced mirror is not valid or not reachable: $FORCE_MIRROR"
  fi

  SELECTED_MIRROR="$mirror"
  SELECTED_TIME="$total_time"
}

select_fastest_mirror() {
  local best=""
  local best_time="999999"
  local result
  local mirror
  local total_time

  echo "Detected Ubuntu codename: $CODENAME"
  echo
  echo "Testing Ubuntu mirrors..."
  echo

  for base in "${CANDIDATES[@]}"; do
    result="$(test_single_mirror "$base" | tail -n 1 || true)"

    mirror="$(echo "$result" | awk '{print $1}')"
    total_time="$(echo "$result" | awk '{print $2}')"

    if [ -n "${mirror:-}" ] && [ -n "${total_time:-}" ]; then
      if awk "BEGIN {exit !($total_time < $best_time)}"; then
        best="$mirror"
        best_time="$total_time"
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

  if ! apt-get update; then
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