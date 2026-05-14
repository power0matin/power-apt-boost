#!/usr/bin/env bash
#
# Power APT Boost
# Fast Ubuntu APT mirror selector and network optimizer
#
# Author : Matin
# GitHub : https://github.com/power0matin
# Brand  : PowerMatin
#

set -u

APP_NAME="Power APT Boost"
AUTHOR="Matin"
GITHUB="https://github.com/power0matin"

print_banner() {
  cat <<EOF

============================================================
  $APP_NAME
  Fast Ubuntu APT Mirror Selector

  Author : $AUTHOR
  GitHub : $GITHUB
  Brand  : PowerMatin
============================================================

EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Please run this script as root."
  fi
}

detect_ubuntu() {
  if [ ! -f /etc/os-release ]; then
    die "/etc/os-release not found."
  fi

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
  url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -4 -L -sS --connect-timeout 8 --max-time 20 \
      -o /dev/null -w '%{http_code} %{time_total}' "$url" 2>/dev/null || echo "000 999999"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
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
import sys, time, urllib.request
url = sys.argv[1]
start = time.time()
try:
    req = urllib.request.Request(url, headers={"User-Agent": "PowerAPTBoost/1.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        code = r.getcode()
    print(f"{code} {time.time() - start:.6f}")
except Exception:
    print("000 999999")
PY
    return
  fi

  echo "000 999999"
}

backup_apt_sources() {
  backup_dir="/root/apt-backup-$(date +%F-%H%M%S)"
  mkdir -p "$backup_dir"

  cp -a /etc/apt/sources.list "$backup_dir/sources.list" 2>/dev/null || true
  cp -a /etc/apt/sources.list.d "$backup_dir/sources.list.d" 2>/dev/null || true
  cp -a /etc/apt/apt.conf.d "$backup_dir/apt.conf.d" 2>/dev/null || true

  echo "Backup created at: $backup_dir"
}

write_apt_config() {
  selected_mirror="$1"

  cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $selected_mirror
Suites: $CODENAME $CODENAME-updates $CODENAME-backports $CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

  cat > /etc/apt/apt.conf.d/99-power-apt-boost <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "2";
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
Acquire::Languages "none";
APT::Install-Recommends "false";
EOF

  rm -f /etc/apt/sources.list
}

clean_apt_cache() {
  rm -rf /var/lib/apt/lists/*
  apt-get clean
}

test_mirrors() {
  CANDIDATES=(
    "https://repo.abrha.net/ubuntu"
    "http://repo.abrha.net/ubuntu"
    "https://mirror.arvancloud.ir/ubuntu"
    "http://mirror.arvancloud.ir/ubuntu"
    "http://ir.archive.ubuntu.com/ubuntu"
    "http://archive.ubuntu.com/ubuntu"
  )

  best=""
  best_time="999999"

  echo "Detected Ubuntu codename: $CODENAME"
  echo
  echo "Testing Ubuntu mirrors..."
  echo

  for base in "${CANDIDATES[@]}"; do
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

      if awk "BEGIN {exit !($total_time < $best_time)}"; then
        best="$base"
        best_time="$total_time"
      fi
    else
      echo "FAILED"
    fi

    echo
  done

  if [ -z "$best" ]; then
    die "No working mirror found. Your server network may be blocking or resetting Ubuntu repository connections."
  fi

  SELECTED_MIRROR="$best"
  SELECTED_TIME="$best_time"
}

run_update() {
  echo
  echo "Selected mirror: $SELECTED_MIRROR"
  echo "Mirror test time: ${SELECTED_TIME}s"
  echo

  backup_apt_sources
  write_apt_config "$SELECTED_MIRROR"
  clean_apt_cache

  echo
  echo "Running apt-get update..."
  echo

  apt-get update
}

print_final_message() {
  cat <<EOF

============================================================
  Done.

  APT mirror optimized successfully.
  Selected mirror: $SELECTED_MIRROR

  Recommended install command:
    apt-get install -y PACKAGE_NAME

  Example:
    apt-get install -y nginx

  Powered by PowerMatin
  GitHub: $GITHUB
============================================================

EOF
}

main() {
  print_banner
  need_root
  detect_ubuntu
  test_mirrors
  run_update
  print_final_message
}

main "$@"
BASH

chmod +x /root/power-apt-boost.sh
bash /root/power-apt-boost.sh