# Changelog

## 1.2.0 - Safe Interrupts and Stable Spinner

- Fixed `Ctrl+C` handling during mirror tests.
- Fixed spinner cleanup when the script is interrupted.
- Removed fragile command substitution around full mirror test functions.
- Added safer child process tracking for mirror probes.
- Added cancellable `apt-get update` execution.
- Added cleanup for running spinner and child processes on `INT` and `TERM`.
- Improved reliability when running via `curl | sudo bash`.
- Updated internal Python probe user agent to `PowerAPTBoost/1.2.0`.

## 1.1.0 - Loading Spinner and Better Mirror Test Output

- Added loading spinner while testing mirror endpoints.
- Added `--no-spinner` option for CI/CD and log-only environments.
- Moved mirror test logs to `stderr` to keep internal output parsing clean.
- Improved mirror test visibility for users.
- Added clearer OK/FAIL status output for repository checks.

## 1.0.0 - Initial Release

- Added automatic Ubuntu codename detection.
- Added mirror speed testing.
- Added fastest mirror selection.
- Added APT source backup.
- Added APT network optimization.
- Added cache cleanup.
- Added branded PowerMatin banner.
