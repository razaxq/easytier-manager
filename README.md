# EasyTier Manager

[中文说明](README_zh.md) | English

[![ShellCheck](https://github.com/razaxq/easytier-manager/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/razaxq/easytier-manager/actions/workflows/shellcheck.yml)
[![Upstream compatibility](https://github.com/razaxq/easytier-manager/actions/workflows/upstream-compat.yml/badge.svg)](https://github.com/razaxq/easytier-manager/actions/workflows/upstream-compat.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-blue.svg)](#)

An interactive script to **install, configure and manage [EasyTier](https://github.com/EasyTier/EasyTier)** on Linux. Pure POSIX `sh` — no Bash, Python or other runtime dependency.

> A third-party script, not affiliated with the upstream project. EasyTier binaries remain the copyright of their authors.

**Language**: the single script is bilingual and picks its language in this order — `ET_LANG` > system locale (`zh*` → Chinese) > English.

---

## ✨ Features

- **Interactive menu** — install / update / configure / restart / uninstall / status in one place
- **Two configuration modes** — a TOML config file or push from the Web console, both with a wizard
- **Broad coverage** — OpenWrt(procd) / Debian / Ubuntu / RHEL / Arch(systemd) / Alpine(OpenRC); x86_64, ARM soft/hard-float, RISC-V, LoongArch, MIPS
- **Non-interactive mode + subcommands** — preset every parameter through environment variables (Ansible / CI); `status`/`start`/`stop`/`restart` suit cron and return a non-zero exit code on failure
- **Mandatory integrity check** — the SHA-256 is fetched from the official Release API and enforced; mirrors, proxies and a PAT are supported for speed, but a download mirror is never trusted as the source of the digest
- **Safe defaults** — the Web admin UI binds `127.0.0.1` only, the core control port binds loopback, exit-node and other sensitive capabilities are off; systemd units enable `NoNewPrivileges`/`ProtectSystem` sandboxing
- **Transactional installs** — download and verify first, stage the binaries and check their version, then stop services and commit as a set, with rollback on failure; `Ctrl+C` never leaves a half-installed binary or a truncated config
- **Identity preserved across upgrades** — the machine ID survives a Web-mode upgrade or reconfiguration, so the console does not mistake an existing node for a new device
- **Small-flash friendly** — only the required binaries are installed; log and backup defaults tighten automatically under procd; disk space is checked before installing

---

## 🚀 Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/razaxq/easytier-manager/main/easytier.sh -o easytier.sh
sudo sh easytier.sh
```

> Requires `curl` and `unzip`; the script prints the matching install command if either is missing.

Subcommands (run and exit; no argument opens the menu):

```sh
sh easytier.sh status     # service status + network overview (easytier-cli peer/route)
sh easytier.sh start      # start / stop / restart
sh easytier.sh version    # print the script and core versions
sh easytier.sh help       # help
```

---

## ⚙️ Environment variables

### Copy-paste configuration

Edit the values, then run the whole block. `sudo env` is used rather than `sudo VAR=…` because the default sudoers policy refuses variables set on the sudo command line.

**Standalone node (TOML mode)**

```sh
curl -fsSL https://raw.githubusercontent.com/razaxq/easytier-manager/main/easytier.sh -o easytier.sh
sudo env \
  ET_NONINTERACTIVE=1 \
  ET_LANG=en \
  ET_MODE=toml \
  ET_INSTANCE_NAME=mynode \
  ET_VIRTUAL_IP=10.0.0.1/24 \
  ET_NETWORK_NAME=mynet \
  ET_NETWORK_SECRET=change-me \
  ET_PEERS=tcp://public.easytier.cn:11010 \
  ET_LISTEN_PORT=11010 \
  sh easytier.sh
```

**Join a Web console (Web mode)**

```sh
sudo env \
  ET_NONINTERACTIVE=1 \
  ET_MODE=web \
  ET_INSTANCE_NAME=mynode \
  ET_WEB_URL=udp://console.example.com:22020/myuser \
  sh easytier.sh
```

Optional additions to either block — a download mirror, a pinned version, and letting this node act as an exit node:

```sh
  ET_GITHUB_MIRROR=https://ghproxy.com \
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
| `ET_VERSION` | Version to install; setting it explicitly allows an older or pre-release version | latest stable |
| `ET_ARCH` | Override arch detection: `x86_64` `aarch64` `arm` `armhf` `armv7` `armv7hf` `riscv64` `loongarch64` `mips` `mipsel` | auto-detected |
| `ET_ALLOW_PRERELEASE` | `1` = let a pre-release be selected automatically | `0` |
| `ET_ALLOW_VERSION_FALLBACK` / `ET_DEFAULT_VERSION` | Allow falling back to a fixed version when the API fails and nothing is installed | `0` / `v2.6.4` |
| `ET_SHA256` | Set the zip's SHA-256 manually; otherwise the official digest is fetched | automatic |
| `ET_ALLOW_UNVERIFIED` | `1` = continue when the SHA-256 cannot be fetched or computed (not recommended) | `0` |
| `ET_GITHUB_MIRROR` | Download prefix mirror | empty |
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
| `ET_DATA_COMPRESS_ALGO` | Compression algorithm `0`/`1`/`2` | `0` (none) |

### Logging and maintenance

| Variable | Description | Default |
|---|---|---|
| `ET_FILE_LOG_DIR` / `ET_FILE_LOG_LEVEL` | Core log directory / level (`off`…`trace`). Uninstall offers to `rm -rf` this directory, so it must be at least two levels deep and not a system directory | `/var/log/easytier` / `error` |
| `ET_FILE_LOG_SIZE` / `ET_FILE_LOG_COUNT` | Size per file (MB) / files kept | `10` / `5` (procd: `2` / `3`) |
| `ET_BACKUP_KEEP` | Backups kept per binary/config (`0` = no backup) | `3` (procd: `1`) |
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
| `/var/log/easytier/` | Core file logs (size-rotated; on tmpfs under OpenWrt) |
| `/var/log/easytier-manager.log` | The script's own log |

---

## 🧪 Development

Issues and PRs are welcome. Local checks:

```sh
shellcheck -s sh easytier.sh
sh tests/test_machine_id.sh
sh tests/test_manager.sh
sh tests/test_upstream_compat.sh   # needs network; downloads the latest stable release
```

CI runs ShellCheck and the unit tests; a weekly job verifies the upstream official digest, release layout, CLI options and the generated TOML.

> ⚠️ Both languages are inlined in `t "en" "zh"` calls — **change them together**.

---

## ❓ FAQ

**Q: Why `/bin/sh` instead of Bash?**
To stay compatible with OpenWrt (BusyBox ash) and Alpine (no Bash by default), so the script also runs on routers.

**Q: The download or the SHA-256 lookup fails.**
Use `ET_GITHUB_MIRROR` for a download mirror or set `https_proxy`; set `ET_GITHUB_TOKEN` when the API is rate-limited. A mirror is never trusted as the digest source — the script still fetches the SHA-256 from the official GitHub API. You can also set the official `ET_SHA256` by hand. Use `ET_ALLOW_UNVERIFIED=1` only if you explicitly accept the risk.

**Q: Why is the Web console reachable from localhost only?**
Upstream's initial migration seeds two accounts, `admin/admin` (superuser) and `user/user`, and registering a new account does not remove them. Prefer SSH forwarding or a reverse tunnel with TLS and access control; if you really need LAN access, set `ET_WEB_BIND_ADDR=0.0.0.0` and change both passwords immediately.

**Q: Does uninstalling delete my config and node identity?**
Not automatically. The uninstall flow asks **separately** about backups, `/etc/easytier`, the machine identity and the Web database, and keeps everything by default.

**Q: My network configuration disappeared from the Web console after an upgrade.**
The console keys nodes by machine ID, and the default ID algorithm changed between older and newer releases. Since v2.6.1 the script triggers the legacy ID migration before replacing the binary and preserves `--machine-id` on reconfiguration. If the ID has already changed, recover the old one and reconfigure once with `ET_MACHINE_ID=<old-id> sh easytier.sh`.

---

[MIT](LICENSE) © 2026 Ramos
