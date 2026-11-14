# EasyTier Manager

[中文说明](README.md) | English

[![ShellCheck](https://github.com/razaxq/easytier-manager/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/razaxq/easytier-manager/actions/workflows/shellcheck.yml)
[![Upstream compatibility](https://github.com/razaxq/easytier-manager/actions/workflows/upstream-compat.yml/badge.svg)](https://github.com/razaxq/easytier-manager/actions/workflows/upstream-compat.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Install, configure and manage [EasyTier](https://github.com/EasyTier/EasyTier) on Linux through an interactive menu.

> A third-party script, not affiliated with the upstream project. EasyTier binaries remain the copyright of their authors.

**Language**: the single script is bilingual and picks its language in this order — `ET_LANG` > system locale (`zh*` → Chinese) > English.

---

## ✨ Features

- **Interactive menu** — install / update / configure / restart / uninstall / status in one place
- **Two configuration modes** — a TOML config file or push from the Web console, both with a wizard
- **Broad coverage** — OpenWrt(procd) / Debian / Ubuntu / RHEL / Arch(systemd) / Alpine(OpenRC); x86_64, ARM soft/hard-float, RISC-V, LoongArch, MIPS, ppc64le (when the selected release provides an asset)
- **Non-interactive mode + subcommands** — preset every parameter through environment variables (Ansible / CI); `status`/`start`/`stop`/`restart` suit cron and return a non-zero exit code on failure
- **Mandatory integrity check** — the SHA-256 is fetched from the official Release API and enforced; mirrors, proxies and a PAT are supported for speed, but a download mirror is never trusted as the source of the digest
- **Safe defaults** — the Web admin UI binds `127.0.0.1` only, the core control port binds loopback, exit-node and other sensitive capabilities are off; systemd units enable `NoNewPrivileges`/`ProtectSystem` sandboxing
- **Transactional installs** — download and verify first, stage the binaries and check their version, then stop services and commit as a set, with rollback on failure; `Ctrl+C` never leaves a half-installed binary or a truncated config
- **Web upgrade snapshots** — stop services and save the database, SQLite sidecars, matching binaries and configuration together; `rollback` restores the complete set after a schema-changing upgrade
- **Identity preserved across upgrades** — the machine ID survives a Web-mode upgrade or reconfiguration, so the console does not mistake an existing node for a new device
- **Small-flash friendly** — only the required binaries are installed; log and backup defaults tighten automatically under procd; disk space is checked before installing

---

## 🚀 Quick start

On OpenWrt, log in as root and run this command to open the menu. You need `curl` and `unzip`. The command runs without `sudo` or a local script file.

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/easytier-manager@main/easytier.sh | sh
```

The same command works in a root shell on other Linux systems. If your account has sudo access, you can run `sudo -i` before installing, managing services or restoring a snapshot.

To run a single command, set the script URL in your current shell, then choose one of the commands below.

```sh
ET_SCRIPT_URL=https://cdn.jsdelivr.net/gh/razaxq/easytier-manager@main/easytier.sh
curl -fsSL "$ET_SCRIPT_URL" | sh -s -- status   # service status and network overview
curl -fsSL "$ET_SCRIPT_URL" | sh -s -- start    # also accepts stop or restart
curl -fsSL "$ET_SCRIPT_URL" | sh -s -- version  # script and core versions
curl -fsSL "$ET_SCRIPT_URL" | sh -s -- help     # command help
curl -fsSL "$ET_SCRIPT_URL" | sh -s -- rollback /var/lib/easytier-manager/backups/upgrade-SNAPSHOT
```

---

## ⚙️ Environment variables

### Copy-paste configuration

Edit the values, then run the block for your configuration in a root shell.

**Standalone node (TOML mode)**

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/easytier-manager@main/easytier.sh | \
  ET_NONINTERACTIVE=1 \
  ET_MODE=toml \
  ET_INSTANCE_NAME=mynode \
  ET_VIRTUAL_IP=10.0.0.1/24 \
  ET_NETWORK_NAME=mynet \
  ET_NETWORK_SECRET=change-me \
  ET_PEERS=tcp://public.easytier.cn:11010 \
  ET_LISTEN_PORT=11010 \
  sh
```

**Join a Web console (Web mode)**

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/easytier-manager@main/easytier.sh | \
  ET_NONINTERACTIVE=1 \
  ET_MODE=web \
  ET_INSTANCE_NAME=mynode \
  ET_WEB_URL=udp://console.example.com:22020/myuser \
  sh
```

Optional additions to either block — a download mirror, a pinned version, and letting this node act as an exit node:

```sh
  ET_GITHUB_MIRROR=https://ghfast.top \
  ET_VERSION=v2.6.4 \
  ET_ENABLE_EXIT_NODE=1 \
```

### Basic configuration

| Variable | Description | Example |
|---|---|---|
| `ET_LANG` | Force the interface language | `en` / `zh` |
| `ET_NONINTERACTIVE` | Enable non-interactive mode | `1` |
| `ET_MODE` | Configuration mode | `toml` / `web` |
| `ET_INSTANCE_NAME` | Node instance name | `node-sg-01` |
| `ET_VIRTUAL_IP` | Virtual IPv4 with mask (omit when `ET_DHCP=1`) | `10.0.0.1/24` |
| `ET_DHCP` | `1` = assign the virtual IP via DHCP | `0` (default) |
| `ET_LISTEN_PORT` | Base listen port, range 1-65533 (ws/wss use +1/+2) | `11010` (default) |
| `ET_DEV_NAME` | TUN device name | `easytier0` (default) |
| `ET_NETWORK_NAME` / `ET_NETWORK_SECRET` | Network name / secret (auto-generated when empty) | `mynet` |
| `ET_PEERS` | Comma-separated peer list | `tcp://a:11010,udp://b:11010` |
| `ET_PROXY_CIDR` | Subnet proxy CIDRs, comma-separated | `192.168.1.0/24,10.9.0.0/24` |
| `ET_WEB_URL` | Join URL for Web mode | `udp://host:22020/user` |
| `ET_MACHINE_ID` | Pin the machine ID; rarely needed — the script migrates and preserves it | `cad9ff67-...` |

### Version and download

| Variable | Description | Default |
|---|---|---|
| `ET_VERSION` | Version to install, e.g. `v2.6.4`, `v2.7.0` or `nightly`; explicit selection also allows older releases | latest stable |
| `ET_ARCH` | Override arch detection: `x86_64` `aarch64` `arm` `armhf` `armv7` `armv7hf` `riscv64` `loongarch64` `mips` `mipsel` `ppc64le` | auto-detected |
| `ET_ALLOW_PRERELEASE` | `1` = allow automatic selection of versioned pre-releases; excludes nightly | `0` |
| `ET_ALLOW_VERSION_FALLBACK` / `ET_DEFAULT_VERSION` | Allow falling back to a fixed version when the API fails and nothing is installed | `0` / `v2.6.4` |
| `ET_SHA256` | Set the zip's SHA-256 manually; otherwise the official digest is fetched | automatic |
| `ET_ALLOW_UNVERIFIED` | `1` = continue when the SHA-256 cannot be fetched or computed (not recommended) | `0` |
| `ET_GITHUB_MIRROR` | Download prefix mirror; tried first, with github.com as the last resort | empty |
| `ET_GITHUB_MIRRORS` | Fallback prefixes tried in order after a direct attempt fails; empty disables the fallback | `https://ghfast.top https://gh-proxy.com` |
| `ET_GITHUB_API` / `ET_GITHUB_TOKEN` | API base / PAT (lifts the 60-per-hour anonymous limit) | official / empty |
| `ET_CACHE_TTL` | Seconds to cache the release list (`0` disables) | `600` |
| `ET_MIN_TMP_MB` | Minimum free space in `/tmp` for download + extract (MB) | `120` |

### Network and security

| Variable | Description | Default |
|---|---|---|
| `ET_WEB_BIND_ADDR` | Web admin UI bind address; exposing it requires setting `0.0.0.0` explicitly | `127.0.0.1` |
| `ET_WEB_DB_PATH` | Web console database path | `/var/lib/easytier-web/et.db` |
| `ET_RPC_PORTAL` | Core's local control port (what `easytier-cli` dials); empty = upstream default | `127.0.0.1:15888` |
| `ET_ENABLE_EXIT_NODE` | `1` = let this node act as an exit node | `0` |
| `ET_PRIVATE_MODE` | `1` = reject foreign networks | `1` |
| `ET_USE_SMOLTCP` | `1` = use smoltcp for TCP proxying | `0` |
| `ET_DATA_COMPRESS_ALGO` | Compression: `0` (legacy none), `1` (none), `2` (Zstd), `3` (LZO, requires a supporting core) | `0` (none) |

### Logging and maintenance

| Variable | Description | Default |
|---|---|---|
| `ET_FILE_LOG_DIR` / `ET_FILE_LOG_LEVEL` | Core log directory / level (`off`…`trace`). Uninstall offers to `rm -rf` this directory, so it must be at least two levels deep and not a system directory | `/var/log/easytier` / `error` |
| `ET_FILE_LOG_SIZE` / `ET_FILE_LOG_COUNT` | Size per file (MB) / files kept | `10` / `5` (procd: `2` / `3`) |
| `ET_BACKUP_KEEP` | Backups kept per binary/config (`0` = no backup) | `3` (procd: `1`) |
| `ET_UPGRADE_BACKUP_DIR` | Private directory for complete Web upgrade snapshots; use persistent storage on OpenWrt | `/var/lib/easytier-manager/backups` |
| `ET_UPGRADE_BACKUP_KEEP` | Complete snapshots retained after a successful upgrade (minimum `1`); independent of `ET_BACKUP_KEEP` | `2` (`1` on OpenWrt) |
| `ET_RELEASES_COUNT` | Maximum entries in the release list | `20` |
| `ET_INSTALL_WEB_GUI` | `1` = also install the `easytier-web` GUI client | `0` |
| `LOG_FILE` | Path of the script's own log | `/var/log/easytier-manager.log` |

---

## 📁 File locations

| Path | Description |
|---|---|
| `/usr/bin/easytier-core` `easytier-cli` | Node essentials (always installed) |
| `/usr/bin/easytier-web-embed` | Web console daemon (installed on demand in self-hosted mode) |
| `/usr/bin/easytier-web` | Standalone GUI client (only with `ET_INSTALL_WEB_GUI=1`) |
| `/usr/bin/easytier-*.bak.<ts>` | Old-version backups (rotated by `ET_BACKUP_KEEP`) |
| `/etc/easytier/config.toml` | TOML-mode configuration |
| `/etc/easytier/core.args` · `web.args` | Startup arguments for core / web-embed |
| `/var/lib/easytier/machine_id` | Persistent machine ID (in the matching data directory when the service keeps `HOME`/`XDG_DATA_HOME`) |
| `/var/lib/easytier-web/et.db` | Web console accounts and network configuration |
| `/var/lib/easytier-manager/backups/upgrade-*` | Complete Web upgrade snapshots, including secrets; directory mode `700`, payload mode `600` |
| `/var/log/easytier/` | Core file logs (size-rotated; on tmpfs under OpenWrt) |
| `/var/log/easytier-manager.log` | The script's own log |

---

## Upgrade channels and recovery

Pressing Enter in version selection installs the latest stable release by default. `ET_ALLOW_PRERELEASE=1` also allows versioned pre-releases. Select nightly explicitly in the menu or set `ET_VERSION=nightly`. The script resolves the real archive name and SHA-256 from the same official release response; it supports dated core version strings and refuses a missing architecture asset before stopping services. LZO (`ET_DATA_COMPRESS_ALGO=3`) is rejected before replacing the configuration when the core does not advertise support.

Before upgrading an existing local Web console, the script stops core/web-embed and creates a cold snapshot of all managed binaries, the database and its `-wal`/`-shm`/`-journal` files, arguments, TOML, machine ID and service definitions. A backup failure aborts the upgrade and attempts to resume previously running services. `ET_BACKUP_KEEP=0` only disables ordinary binary/config backups; it does not disable these snapshots. Reserve storage for the installed programs and database for each retained snapshot. On OpenWrt, `/var` is commonly temporary: set `ET_UPGRADE_BACKUP_DIR` to a persistent mounted directory to retain recovery data across reboots.

The upgrade prints the snapshot path and the command to restore the matching programs and database together. Rollback first saves the current state in a rescue snapshot and restores it if the requested recovery fails. It restores the snapshot's service running states. Database writes made after the selected snapshot are no longer present in the restored database; they remain in the rescue snapshot. Recovery requires the same managed file paths and database path; custom service/database layouts need separate handling. Uninstall leaves the default upgrade snapshot directory in place. They contain credentials and should stay private.

## 🧪 Development

Issues and PRs are welcome. Local checks:

```sh
shellcheck -s sh easytier.sh
sh tests/test_machine_id.sh
sh tests/test_manager.sh
sh tests/test_releases.sh
sh tests/test_options.sh
sh tests/test_download.sh
sh tests/test_upgrade.sh         # test-only dependencies: python3 and sqlite3
sh tests/test_busybox.sh         # busybox
ET_TEST_CHANNEL=stable sh tests/test_upstream_compat.sh
ET_TEST_CHANNEL=prerelease sh tests/test_upstream_compat.sh
ET_TEST_CHANNEL=nightly sh tests/test_upstream_compat.sh
```

CI runs ShellCheck and the unit tests; a weekly matrix downloads stable, versioned pre-release and nightly packages to verify official digests, release layout, service arguments, generated TOML and LZO handling. Network checks execute Linux x86_64 binaries. Architecture selection tests do not replace testing on the target hardware.

> ⚠️ Both languages are inlined in `t "en" "zh"` calls — **change them together**.

---

## ❓ FAQ

**Q: The download or the SHA-256 lookup fails.**
Use `ET_GITHUB_MIRROR` for a download mirror or set `https_proxy`; set `ET_GITHUB_TOKEN` when the API is rate-limited. A mirror is never trusted as the digest source — the script still fetches the SHA-256 from the official GitHub API. When the official API is unreachable, a versioned tag is still downloaded by its standard asset name, but no official digest is available, so `ET_SHA256` must be set by hand (or `ET_ALLOW_UNVERIFIED=1` accepted explicitly); `nightly` has no fixed filename and always needs the official API. Use `ET_ALLOW_UNVERIFIED=1` only if you explicitly accept the risk.

**Q: Why is the Web console reachable from localhost only?**
Upstream's initial migration seeds two accounts, `admin/admin` (superuser) and `user/user`, and registering a new account does not remove them. Prefer SSH forwarding or a reverse tunnel with TLS and access control; if you really need LAN access, set `ET_WEB_BIND_ADDR=0.0.0.0` and change both passwords immediately.

**Q: Does uninstalling delete my config and node identity?**
Not automatically. The uninstall flow asks **separately** about backups, `/etc/easytier`, the machine identity and the Web database, and keeps everything by default.

**Q: My network configuration disappeared from the Web console after an upgrade.**
The console keys nodes by machine ID, and the default ID algorithm changed between older and newer releases. Since v2.6.1 the script triggers the legacy ID migration before replacing the binary and preserves `--machine-id` on reconfiguration. If the ID has already changed, recover the old ID. In the quick-start command, insert `ET_MACHINE_ID=your-old-id` between the pipe and `sh`, using the recovered value, then reconfigure once from the menu.

---

[MIT](LICENSE) © 2026 Ramos
