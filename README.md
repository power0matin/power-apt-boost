# Power APT Boost

Fast Ubuntu APT mirror selector and network optimizer.

**Power APT Boost** tests multiple Ubuntu mirrors, selects the fastest working mirror for your server, rewrites APT sources safely, applies basic APT network optimizations, cleans old package indexes, and runs `apt-get update`.

Built by **Matin Shahabadi**.

GitHub: [power0matin](https://github.com/power0matin)

## Features

- Auto-detects Ubuntu codename
- Tests multiple Ubuntu mirrors
- Shows live loading spinner while testing mirrors
- Selects the fastest working mirror
- Creates APT source backups before changes
- Forces IPv4 for better VPS compatibility
- Sets APT retry and timeout options
- Disables recommended packages by default for lighter installs
- Cleans old APT indexes
- Runs `apt-get update`
- Supports safe `Ctrl+C` interruption
- Supports dry-run mode
- Supports custom mirror selection
- Supports CI-friendly no-spinner mode

## Supported Mirrors

Power APT Boost currently tests and supports the following Ubuntu mirrors:

| Mirror                                | Protocol | Status    |
| ------------------------------------- | -------- | --------- |
| `https://repo.abrha.net/ubuntu`       | HTTPS    | Supported |
| `http://repo.abrha.net/ubuntu`        | HTTP     | Supported |
| `https://mirror.arvancloud.ir/ubuntu` | HTTPS    | Supported |
| `http://mirror.arvancloud.ir/ubuntu`  | HTTP     | Supported |
| `http://ir.archive.ubuntu.com/ubuntu` | HTTP     | Supported |
| `http://archive.ubuntu.com/ubuntu`    | HTTP     | Supported |

Power APT Boost checks each mirror by testing these Ubuntu repository endpoints:

```text
/dists/<codename>/InRelease
/dists/<codename>-updates/InRelease
/dists/<codename>-security/InRelease
```

For example, on Ubuntu 24.04 LTS Noble, it tests:

```text
/dists/noble/InRelease
/dists/noble-updates/InRelease
/dists/noble-security/InRelease
```

The fastest mirror that returns successful HTTP `200` responses for all required endpoints will be selected automatically.

You can also force a specific mirror manually:

```bash
sudo bash power-apt-boost.sh --mirror http://mirror.arvancloud.ir/ubuntu
```

To test mirrors without changing your APT configuration:

```bash
sudo bash power-apt-boost.sh --dry-run
```

## Supported OS

Ubuntu only.

Tested on:

- Ubuntu 24.04 LTS Noble
- Should also work on recent Ubuntu releases with deb822 APT source format

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/power-apt-boost/main/power-apt-boost.sh | sudo bash
```

## Quick Dry Run

Test mirrors without changing your system:

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/power-apt-boost/main/power-apt-boost.sh | sudo bash -s -- --dry-run
```

## Manual Install

```bash
git clone https://github.com/power0matin/power-apt-boost.git
cd power-apt-boost
sudo bash power-apt-boost.sh
```

## Usage

Run normally:

```bash
sudo bash power-apt-boost.sh
```

Run without changing APT config:

```bash
sudo bash power-apt-boost.sh --dry-run
```

Use a specific mirror:

```bash
sudo bash power-apt-boost.sh --mirror http://mirror.arvancloud.ir/ubuntu
```

Disable spinner output:

```bash
sudo bash power-apt-boost.sh --no-spinner
```

Write config but skip `apt-get update`:

```bash
sudo bash power-apt-boost.sh --skip-update
```

Keep recommended packages enabled:

```bash
sudo bash power-apt-boost.sh --keep-recommends
```

Show help:

```bash
sudo bash power-apt-boost.sh --help
```

Show version:

```bash
sudo bash power-apt-boost.sh --version
```

## Options

| Option               | Description                                              |
| -------------------- | -------------------------------------------------------- |
| `-h`, `--help`       | Show help message                                        |
| `-v`, `--version`    | Show version                                             |
| `-m`, `--mirror URL` | Use a specific Ubuntu mirror instead of auto-selecting   |
| `--dry-run`          | Test mirrors and show result without changing APT config |
| `--skip-update`      | Write config but do not run `apt-get update`             |
| `--keep-recommends`  | Keep APT recommended packages enabled                    |
| `--no-spinner`       | Disable loading spinner output                           |

## After Optimization

After successful optimization, install packages normally:

```bash
sudo apt-get install -y nginx
```

Because Power APT Boost sets:

```text
APT::Install-Recommends "false";
```

APT will avoid installing recommended extra packages by default, making installs lighter and faster.

If you do not want this behavior, run Power APT Boost with:

```bash
sudo bash power-apt-boost.sh --keep-recommends
```

## What It Changes

Power APT Boost creates backups under:

```text
/root/apt-backup-YYYY-MM-DD-HHMMSS
```

It writes the selected mirror to:

```text
/etc/apt/sources.list.d/ubuntu.sources
```

It writes APT network optimization config to:

```text
/etc/apt/apt.conf.d/99-power-apt-boost
```

It removes the old legacy file if present:

```text
/etc/apt/sources.list
```

## Safe Interrupts

Power APT Boost supports safe interruption with:

```text
Ctrl+C
```

When interrupted, it cleans up running spinner and child processes before exiting.

This is especially useful during slow mirror tests or `apt-get update`.

## Example Output

```text
============================================================
  Power APT Boost v1.2.0
  Fast Ubuntu APT Mirror Selector

  Author : Matin Shahabadi
  GitHub : https://github.com/power0matin
============================================================

Detected Ubuntu codename: noble

Testing Ubuntu mirrors...

==> https://repo.abrha.net/ubuntu
[OK] Testing main repository - HTTP 200 in 0.184418s
[OK] Testing updates repository - HTTP 200 in 0.184033s
[OK] Testing security repository - HTTP 200 in 0.144216s
main:     HTTP 200 time 0.184418s
updates:  HTTP 200 time 0.184033s
security: HTTP 200 time 0.144216s
OK total 0.512667s

Selected mirror: http://mirror.arvancloud.ir/ubuntu
APT mirror optimized successfully.
```

## Restore Backup

Check available backups:

```bash
ls -lah /root/apt-backup-*
```

To restore manually, copy the backup files back to `/etc/apt/`.

Example:

```bash
sudo cp -a /root/apt-backup-YYYY-MM-DD-HHMMSS/sources.list.d /etc/apt/
sudo cp -a /root/apt-backup-YYYY-MM-DD-HHMMSS/apt.conf.d /etc/apt/
sudo apt-get update
```

## Repository Structure

```text
power-apt-boost/
├── power-apt-boost.sh
├── README.md
├── LICENSE
├── CHANGELOG.md
├── .gitattributes
└── .gitignore
```

## Author

**Matin Shahabadi**

GitHub: [@power0matin](https://github.com/power0matin)

## License

MIT
