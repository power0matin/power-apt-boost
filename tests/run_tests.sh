#!/usr/bin/env bash
#
# Power APT Boost — Test Suite Runner
#
# Run: bash tests/run_tests.sh
# Requires: Ubuntu, bash 4.0+

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly SCRIPT="${PROJECT_DIR}/power-apt-boost.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

_tests_run=0
_tests_passed=0
_tests_failed=0

# ─── Test Helpers ─────────────────────────────────────────────────────────────

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local test_name="$3"

  _tests_run=$((_tests_run + 1))

  if [[ "$actual" -eq "$expected" ]]; then
    _tests_passed=$((_tests_passed + 1))
    printf "${GREEN}  PASS${RESET}  %s\n" "$test_name"
  else
    _tests_failed=$((_tests_failed + 1))
    printf "${RED}  FAIL${RESET}  %s (expected exit %d, got %d)\n" "$test_name" "$expected" "$actual"
  fi
}

assert_contains() {
  local expected="$1"
  local actual="$2"
  local test_name="$3"

  _tests_run=$((_tests_run + 1))

  if [[ "$actual" == *"$expected"* ]]; then
    _tests_passed=$((_tests_passed + 1))
    printf "${GREEN}  PASS${RESET}  %s\n" "$test_name"
  else
    _tests_failed=$((_tests_failed + 1))
    printf "${RED}  FAIL${RESET}  %s (output does not contain: %s)\n" "$test_name" "$expected"
  fi
}

assert_not_contains() {
  local unexpected="$1"
  local actual="$2"
  local test_name="$3"

  _tests_run=$((_tests_run + 1))

  if [[ "$actual" != *"$unexpected"* ]]; then
    _tests_passed=$((_tests_passed + 1))
    printf "${GREEN}  PASS${RESET}  %s\n" "$test_name"
  else
    _tests_failed=$((_tests_failed + 1))
    printf "${RED}  FAIL${RESET}  %s (output should not contain: %s)\n" "$test_name" "$unexpected"
  fi
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_help_flag() {
  local output exit_code=0
  output=$(bash "$SCRIPT" --help 2>&1) || exit_code=$?
  assert_exit_code 0 "$exit_code" "help flag exits 0"
  assert_contains "Power APT Boost" "$output" "help shows app name"
  assert_contains "OPTIONS" "$output" "help shows options section"
  assert_contains "--restore" "$output" "help shows restore option"
}

test_version_flag() {
  local output exit_code=0
  output=$(bash "$SCRIPT" --version 2>&1) || exit_code=$?
  assert_exit_code 0 "$exit_code" "version flag exits 0"
  assert_contains "Power APT Boost" "$output" "version shows app name"
  assert_contains "2.0.0" "$output" "version shows version number"
}

test_unknown_flag() {
  local output exit_code=0
  output=$(bash "$SCRIPT" --nonexistent 2>&1) || exit_code=$?
  assert_exit_code 2 "$exit_code" "unknown flag exits with code 2"
  assert_contains "Unknown option" "$output" "unknown flag shows error"
}

test_mirror_requires_url() {
  local output exit_code=0
  output=$(bash "$SCRIPT" --mirror 2>&1) || exit_code=$?
  assert_exit_code 2 "$exit_code" "mirror without URL exits with code 2"
}

test_timeout_requires_number() {
  local output exit_code=0
  output=$(bash "$SCRIPT" --timeout abc 2>&1) || exit_code=$?
  assert_exit_code 2 "$exit_code" "timeout with non-number exits with code 2"
}

test_country_requires_code() {
  local output exit_code=0
  output=$(bash "$SCRIPT" --country 2>&1) || exit_code=$?
  assert_exit_code 2 "$exit_code" "country without code exits with code 2"
}

test_dry_run_no_root() {
  # Should fail because we're not root (in CI) or succeed with dry-run
  local output exit_code=0
  output=$(bash "$SCRIPT" --dry-run --no-spinner 2>&1) || exit_code=$?

  # Should either succeed (if root) or fail with "must be run as root"
  if [[ "$(id -u)" -eq 0 ]]; then
    assert_exit_code 0 "$exit_code" "dry-run as root exits 0"
  else
    assert_exit_code 4 "$exit_code" "dry-run without root exits 4"
  fi
}

test_list_flag() {
  # --list requires root and network, so just check it parses correctly
  local output exit_code=0
  output=$(bash "$SCRIPT" --list 2>&1) || exit_code=$?

  # Should either succeed or fail with "must be run as root"
  if [[ "$(id -u)" -eq 0 ]]; then
    assert_exit_code 0 "$exit_code" "list flag exits 0"
  else
    assert_exit_code 4 "$exit_code" "list flag without root exits 4"
  fi
}

test_json_output() {
  local output exit_code=0
  output=$(bash "$SCRIPT" --json --dry-run --no-spinner 2>&1) || exit_code=$?

  if [[ "$(id -u)" -eq 0 ]]; then
    assert_exit_code 0 "$exit_code" "json output exits 0"
    assert_contains '"version"' "$output" "json output contains version key"
    assert_contains '"action"' "$output" "json output contains action key"
    assert_contains '"dry_run": true' "$output" "json output shows dry_run true"
  else
    assert_exit_code 4 "$exit_code" "json output without root exits 4"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo "Power APT Boost — Test Suite"
  echo "============================"
  echo ""

  if [[ ! -f "$SCRIPT" ]]; then
    echo -e "${RED}Script not found: $SCRIPT${RESET}"
    exit 1
  fi

  echo "Running unit tests..."
  echo ""
  test_help_flag
  test_version_flag
  test_unknown_flag
  test_mirror_requires_url
  test_timeout_requires_number
  test_country_requires_code

  echo ""
  echo "Running integration tests (require root)..."
  echo ""
  test_dry_run_no_root
  test_list_flag
  test_json_output

  echo ""
  echo "============================"
  printf "Results: %d passed, %d failed, %d total\n" \
    "$_tests_passed" "$_tests_failed" "$_tests_run"
  echo ""

  if [[ $_tests_failed -gt 0 ]]; then
    exit 1
  fi

  exit 0
}

main "$@"
