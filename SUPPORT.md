# Support

## Getting Help

### Documentation

- [README](README.md) — Full usage guide
- [CHANGELOG](CHANGELOG.md) — Version history
- [CONTRIBUTING](CONTRIBUTING.md) — How to contribute

### Common Issues

#### "This script must be run as root"

```bash
sudo bash power-apt-boost.sh
```

#### "curl or wget is required"

Install curl:

```bash
apt-get install -y curl
```

#### "No working mirror found"

- Check your network connection
- Try with a longer timeout: `sudo bash power-apt-boost.sh --timeout 60`
- Try a specific mirror: `sudo bash power-apt-boost.sh --mirror https://archive.ubuntu.com/ubuntu`

#### "apt-get update failed after applying mirror"

The script automatically restores the previous configuration. Check:

```bash
ls -la /var/backups/power-apt-boost/
sudo bash power-apt-boost.sh --restore
```

#### How to restore a previous configuration

```bash
sudo bash power-apt-boost.sh --restore
```

Or restore from a specific backup:

```bash
sudo bash power-apt-boost.sh --restore-path /var/backups/power-apt-boost/2025-01-01_12-00-00
```

## Reporting Issues

- [GitHub Issues](https://github.com/power0matin/power-apt-boost/issues) — Bug reports and feature requests
- [GitHub Discussions](https://github.com/power0matin/power-apt-boost/discussions) — Questions and ideas

When reporting a bug, include:

1. Ubuntu version (`cat /etc/os-release`)
2. Script version (`bash power-apt-boost.sh --version`)
3. Exact command you ran
4. Full error output
5. Network environment (VPS provider, region)

## Security Issues

See [SECURITY.md](SECURITY.md) for how to report security vulnerabilities.
