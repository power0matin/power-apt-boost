# Power APT Boost

[![CI](https://github.com/power0matin/power-apt-boost/actions/workflows/ci.yml/badge.svg)](https://github.com/power0matin/power-apt-boost/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen.svg)](https://www.shellcheck.net/)
[![Version](https://img.shields.io/badge/version-2.0.0-orange.svg)](https://github.com/power0matin/power-apt-boost/releases)

Fast Ubuntu APT mirror selector and network optimizer.

Power APT Boost tests multiple Ubuntu mirrors, selects the fastest working mirror for your server, rewrites APT sources safely, applies network optimizations, and runs `apt-get update`.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/power-apt-boost/main/power-apt-boost.sh | sudo bash
```

Or test first without changes:

```bash
sudo bash power-apt-boost.sh --dry-run
```

## Features

- Auto-detects Ubuntu codename
- Tests 20+ global Ubuntu mirrors
- Selects the fastest working mirror
- Automatic rollback on failure
- Backs up APT configuration before changes
- Writes modern deb822-format APT sources
- Configures APT network optimizations
- Machine-readable JSON output for CI/CD
- Country-based mirror filtering
- IPv6 mirror testing support
- Persistent logging to file
- Safe `Ctrl+C` interruption
- Comprehensive test suite

## Installation

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/power-apt-boost/main/power-apt-boost.sh | sudo bash
```

### Manual

```bash
git clone https://github.com/power0matin/power-apt-boost.git
cd power-apt-boost
sudo bash power-apt-boost.sh
```

### Verify before running

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/power-apt-boost/main/power-apt-boost.sh | less
# Review the script, then:
curl -fsSL https://raw.githubusercontent.com/power0matin/power-apt-boost/main/power-apt-boost.sh | sudo bash
```

## Usage

### Auto-select fastest mirror

```bash
sudo bash power-apt-boost.sh
```

### Test without changing anything

```bash
sudo bash power-apt-boost.sh --dry-run
```

### Use a specific mirror

```bash
sudo bash power-apt-boost.sh --mirror https://mirror.example.com/ubuntu
```

### Restore from backup

```bash
sudo bash power-apt-boost.sh --restore
```

### List and test all mirrors

```bash
sudo bash power-apt-boost.sh --list
```

### Machine-readable output (CI/CD)

```bash
sudo bash power-apt-boost.sh --json --quiet
```

### Filter mirrors by country

```bash
sudo bash power-apt-boost.sh --country us
```

### Verbose output for debugging

```bash
sudo bash power-apt-boost.sh --verbose
```

## Options

| Option | Description |
|--------|-------------|
| `-h`, `--help` | Show help message |
| `-v`, `--version` | Show version |
| `-m`, `--mirror URL` | Use a specific mirror |
| `-r`, `--restore` | Restore APT config from latest backup |
| `--restore-path PATH` | Restore from a specific backup |
| `--dry-run` | Test mirrors without changing config |
| `--skip-update` | Write config but skip `apt-get update` |
| `--list` | List available mirrors and test them |
| `--json` | Output as JSON (sets `--quiet --no-spinner`) |
| `--verbose` | Show detailed output |
| `--quiet` | Suppress non-essential output |
| `--no-spinner` | Disable spinner (for CI/CD) |
| `--timeout SECS` | Probe timeout in seconds (default: 20) |
| `--country CODE` | Filter mirrors by country code |
| `--ipv6` | Use IPv6 for mirror testing |
| `--log-file PATH` | Write log to file |

## What It Does

1. **Detects** Ubuntu version codename
2. **Tests** multiple Ubuntu mirrors for reachability and speed
3. **Selects** the fastest working mirror
4. **Backs up** current APT configuration to `/var/backups/power-apt-boost/`
5. **Writes** modern deb822-format APT sources to `/etc/apt/sources.list.d/ubuntu.sources`
6. **Configures** APT network optimizations (IPv4, retries, timeouts)
7. **Cleans** stale package lists
8. **Runs** `apt-get update`

## What It Changes

| File | Action |
|------|--------|
| `/etc/apt/sources.list.d/ubuntu.sources` | Created/overwritten |
| `/etc/apt/apt.conf.d/99-power-apt-boost` | Created/overwritten |
| `/etc/apt/sources.list` | Removed (if no third-party repos) |
| `/var/lib/apt/lists/*` | Cleaned |

## Backup & Restore

### Automatic backups

Backups are created at:

```
/var/backups/power-apt-boost/YYYY-MM-DD_HH-MM-SS/
```

Each backup contains copies of:
- `ubuntu.sources` (deb822 format)
- `sources.list` (legacy format)
- `sources.list.d/`
- `apt.conf.d/`

### Restore from latest backup

```bash
sudo bash power-apt-boost.sh --restore
```

### Restore from specific backup

```bash
sudo bash power-apt-boost.sh --restore-path /var/backups/power-apt-boost/2025-01-01_12-00-00
```

### Manual restore

```bash
# List available backups
ls -la /var/backups/power-apt-boost/

# Restore manually
sudo cp -a /var/backups/power-apt-boost/BACKUP/sources.list.d /etc/apt/
sudo cp -a /var/backups/power-apt-boost/BACKUP/apt.conf.d /etc/apt/
sudo rm -f /etc/apt/sources.list.d/ubuntu.sources
sudo apt-get update
```

## What It Does NOT Change

- Package installation behavior
- System security settings
- Network configuration
- Firewall rules
- Any files outside `/etc/apt/`

## Mirror Testing

Power APT Boost tests each mirror against three endpoints:

```
/dists/<codename>/InRelease
/dists/<codename>-updates/InRelease
/dists/<codename>-security/InRelease
```

Only mirrors that return HTTP 200 for all three are considered. The fastest mirror (lowest combined response time) is selected.

### Default mirrors

| Region | Mirrors |
|--------|---------|
| Global | `archive.ubuntu.com`, `mirrors.kernel.org` |
| US | `us.archive.ubuntu.com`, `mirror.math.princeton.edu`, `mirror.cs.uchicago.edu`, `mirror.rit.edu`, `mirror.arizona.edu` |
| UK | `uk.archive.ubuntu.com` |
| Europe | `de.archive.ubuntu.com`, `fr.archive.ubuntu.com`, `it.archive.ubuntu.com`, `nl.archive.ubuntu.com` |
| Asia-Pacific | `au.archive.ubuntu.com`, `jp.archive.ubuntu.com`, `kr.archive.ubuntu.com`, `in.archive.ubuntu.com` |
| Americas | `br.archive.ubuntu.com` |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Usage error (invalid arguments) |
| 3 | Network error |
| 4 | Not running as root |
| 5 | Not Ubuntu |
| 6 | No working mirror found |
| 7 | Backup failed |
| 8 | Restore failed |

## Troubleshooting

### "This script must be run as root"

```bash
sudo bash power-apt-boost.sh
```

### "curl or wget is required"

```bash
apt-get install -y curl
```

### "No working mirror found"

- Check your network connection
- Try with a longer timeout: `--timeout 60`
- Try a specific mirror: `--mirror https://archive.ubuntu.com/ubuntu`

### "apt-get update failed after applying mirror"

The script automatically restores the previous configuration. To restore manually:

```bash
sudo bash power-apt-boost.sh --restore
```

### Third-party sources warning

If you have third-party APT sources in `/etc/apt/sources.list`, Power APT Boost preserves them and only removes the file if it contains only Ubuntu sources.

## Compatibility

| Ubuntu Version | Status |
|---------------|--------|
| 24.04 LTS Noble | Tested |
| 22.04 LTS Jammy | Tested |
| 20.04 LTS Focal | Tested |

Requires Bash 4.0+ and one of: curl, wget.

## Security

- See [SECURITY.md](SECURITY.md) for reporting vulnerabilities
- Review the script before running from a URL
- Use `--dry-run` to preview changes
- All changes are backed up automatically

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

```bash
# Development setup
git clone https://github.com/power0matin/power-apt-boost.git
cd power-apt-boost
chmod +x power-apt-boost.sh

# Lint
shellcheck -x power-apt-boost.sh
shfmt -d power-apt-boost.sh

# Test
bash tests/run_tests.sh
```

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned features.

## License

[MIT](LICENSE)

## Author

**Matin Shahabadi** — [@power0matin](https://github.com/power0matin)
