# Power APT Boost

Fast Ubuntu APT mirror selector and network optimizer.

**Power APT Boost** tests multiple Ubuntu mirrors, selects the fastest working mirror for your server, rewrites APT sources safely, applies basic APT network optimizations, cleans old package indexes, and runs `apt-get update`.

Built by **Matin Shahabadi**.

GitHub: [power0matin](https://github.com/power0matin)

## Features

- Auto-detects Ubuntu codename
- Tests multiple Ubuntu mirrors
- Selects the fastest working mirror
- Creates APT source backups before changes
- Forces IPv4 for better VPS compatibility
- Sets APT retry and timeout options
- Disables recommended packages by default for lighter installs
- Cleans old APT indexes
- Runs `apt-get update`

## Supported OS

Ubuntu only.

Tested on:

- Ubuntu 24.04 LTS Noble
- Should also work on recent Ubuntu releases with deb822 APT source format

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/power-apt-boost/main/power-apt-boost.sh | sudo bash
```

## Manual Install

```bash
git clone https://github.com/power0matin/power-apt-boost.git
cd power-apt-boost
sudo bash power-apt-boost.sh
```

## Usage

Run:

```bash
sudo bash power-apt-boost.sh
```

After successful optimization, install packages normally:

```bash
sudo apt-get install -y nginx
```

Because Power APT Boost sets:

```text
APT::Install-Recommends "false";
```

APT will avoid installing recommended extra packages by default, making installs lighter and faster.

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

## Example Output

```text
Power APT Boost
Fast Ubuntu APT Mirror Selector

Author : Matin Shahabadi
GitHub : https://github.com/power0matin

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

## Author

**Matin Shahabadi**

GitHub: [@power0matin](https://github.com/power0matin)

## License

MIT
