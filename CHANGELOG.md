# Changelog

All notable changes to Power APT Boost will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.0.0] — 2025-07-10

### Added

- `--restore` / `--restore-path` for automatic backup restoration
- `--list` to test and display all available mirrors
- `--json` for machine-readable output (CI/CD friendly)
- `--verbose` / `--quiet` modes for output control
- `--timeout` to configure probe timeout
- `--country` to filter mirrors by country code
- `--ipv6` for IPv6 mirror testing
- `--log-file` for persistent logging
- Automatic rollback on `apt-get update` failure
- Global mirror list (not Iran-specific)
- Proper deb822 format with `Signed-By` keyring validation
- Third-party source detection (won't delete `sources.list` with third-party repos)
- Colored terminal output with auto-detection
- Structured exit codes (0-8)
- Backup directory in `/var/backups/power-apt-boost/`
- Comprehensive ShellCheck-clean codebase
- GitHub Actions CI (ShellCheck, shfmt, Ubuntu matrix)
- GitHub Actions release workflow
- Issue and PR templates
- CONTRIBUTING.md, SECURITY.md, SUPPORT.md, CODE_OF_CONDUCT.md, ROADMAP.md
- .editorconfig, .shellcheckrc, .markdownlint.json
- Integration test suite

### Changed

- `APT::Install-Recommends` is no longer set by default (was opt-out, now not set)
- Mirror list is now global (removed regional bias)
- Backups stored in `/var/backups/power-apt-boost/` instead of `/root/`
- Spinner no longer inherits EXIT trap in subshells
- All functions use local variables (no more global return values)
- `--no-spinner` is the default in `--json` and `--quiet` modes

### Fixed

- EXIT trap firing in spinner subshell, killing parent process
- `rm -f /etc/apt/sources.list` no longer unconditional (checks for third-party repos)
- Missing keyring file now produces a warning instead of silent failure
- `mktemp` usage now uses `$TMPDIR` with proper fallback
- Floating-point comparison no longer spawns unnecessary subprocesses

### Removed

- `--keep-recommends` flag (use `--keep-recommends` equivalent in apt config directly)
- Unnecessary coreutils dependency checks (awk, date, mkdir, etc.)
- Iran-specific mirror bias from default mirror list

## [1.2.0] — Safe Interrupts and Stable Spinner

- Fixed `Ctrl+C` handling during mirror tests
- Fixed spinner cleanup when the script is interrupted
- Removed fragile command substitution around full mirror test functions
- Added safer child process tracking for mirror probes
- Added cancellable `apt-get update` execution
- Added cleanup for running spinner and child processes on `INT` and `TERM`
- Improved reliability when running via `curl | sudo bash`

## [1.1.0] — Loading Spinner and Better Mirror Test Output

- Added loading spinner while testing mirror endpoints
- Added `--no-spinner` option for CI/CD and log-only environments
- Moved mirror test logs to `stderr` to keep internal output parsing clean
- Improved mirror test visibility for users
- Added clearer OK/FAIL status output for repository checks

## [1.0.0] — Initial Release

- Added automatic Ubuntu codename detection
- Added mirror speed testing
- Added fastest mirror selection
- Added APT source backup
- Added APT network optimization
- Added cache cleanup
- Added branded banner

[Unreleased]: https://github.com/power0matin/power-apt-boost/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/power0matin/power-apt-boost/compare/v1.2.0...v2.0.0
[1.2.0]: https://github.com/power0matin/power-apt-boost/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/power0matin/power-apt-boost/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/power0matin/power-apt-boost/releases/tag/v1.0.0
