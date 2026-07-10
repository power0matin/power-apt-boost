# Roadmap

## v2.1.0 — Parallel Mirror Testing

- [ ] Test mirrors concurrently with configurable parallelism
- [ ] Add `--concurrency N` flag
- [ ] Progress indicator showing mirrors tested/available

## v2.2.0 — Mirror Intelligence

- [ ] Mirror freshness checking (compare InRelease timestamps)
- [ ] Mirror reliability scoring (track success rate over time)
- [ ] Latency + bandwidth benchmark mode
- [ ] Country-aware mirror selection using GeoIP

## v2.3.0 — Enterprise Features

- [ ] Config file support (`/etc/power-apt-boost.conf`)
- [ ] Mirror whitelist/blacklist files
- [ ] Custom mirror lists
- [ ] Proxy support (`--proxy`)
- [ ] Corporate mirror priority

## v3.0.0 — Multi-Distribution

- [ ] Debian support
- [ ] Linux Mint support
- [ ] Pop!_OS support
- [ ] Generic APT-based distribution support

## Future Ideas

- [ ] APT mirror health dashboard
- [ ] Automatic periodic mirror re-evaluation
- [ ] Integration with cloud provider metadata
- [ ] Docker/OCI container support
- [ ] Bash completion script
- [ ] Zsh completion script

---

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).
