# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 2.0.x   | :white_check_mark: |
| 1.2.x   | :x:                |
| < 1.2   | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability in Power APT Boost, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

### How to Report

Send an email to the maintainer with:

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### What to Expect

- **Acknowledgment**: Within 48 hours
- **Assessment**: Within 1 week
- **Fix or mitigation**: Depending on severity, within 1-2 weeks
- **Disclosure**: After a fix is available, a security advisory will be published

### Scope

This policy covers the `power-apt-boost.sh` script and its direct behavior. The following are out of scope:

- Bugs in third-party tools (curl, wget, apt)
- Issues in Ubuntu itself
- Network-level attacks beyond the script's control

## Security Considerations

### What Power APT Boost Does

- Writes to `/etc/apt/sources.list.d/` and `/etc/apt/apt.conf.d/`
- Requires root privileges
- Tests network endpoints (mirrors)
- Creates backups in `/var/backups/power-apt-boost/`

### What Power APT Boost Does NOT Do

- Exfiltrates data
- Downloads or executes remote code
- Modifies system files outside APT configuration
- Communicates with any servers other than Ubuntu mirrors

### Integrity

- The script uses `set -euo pipefail` for safety
- All file operations are atomic (write to temp, move into place)
- Backups are created before any changes
- The `--dry-run` flag allows testing without changes

## Best Practices for Users

1. **Review the script** before running from a URL:

   ```bash
   curl -fsSL URL | less
   ```

2. **Use `--dry-run` first** to see what would change:

   ```bash
   curl -fsSL URL | sudo bash -s -- --dry-run
   ```

3. **Check backups** after running:

   ```bash
   ls -la /var/backups/power-apt-boost/
   ```

4. **Verify the script** matches the repository:

   ```bash
   sha256sum power-apt-boost.sh
   ```
