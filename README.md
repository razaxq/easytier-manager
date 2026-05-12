# EasyTier Manager

[![ShellCheck](https://github.com/razaxq/easytier-manager/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/razaxq/easytier-manager/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-blue.svg)](#)

一个用于在 Linux 发行版上**安装、配置与管理 [EasyTier](https://github.com/EasyTier/EasyTier)** 的交互式脚本。纯 POSIX `sh`，无需 Bash、Python 或其他运行时依赖。

> EasyTier 本身是由 [EasyTier/EasyTier](https://github.com/EasyTier/EasyTier) 维护的开源 P2P 异地组网工具。本仓库仅提供第三方安装脚本，与上游项目无隶属关系。

---

## ✨ 功能

- 🎛  **交互式菜单** —— 安装 / 更新 / 配置 / 重启 / 卸载 / 查看状态，一站式完成
- 🧩  **TOML 或 Web 控制台** 两种配置模式，含配置向导
- 🐧  **多发行版 / 多架构** —— OpenWrt、Debian、Ubuntu、RHEL、Alpine、Arch；x86_64 / aarch64 / armv7 / riscv64
- ⚙️  **多 init 系统** —— procd（OpenWrt）/ systemd / OpenRC，服务文件自动生成
- 🔒  **输入校验** —— CIDR、URL、端口格式检查，密钥强度检测
- 🤖  **非交互模式** —— 环境变量预设全部参数，可用于 Ansible / CI
- 📦  **版本备份** —— 更新时可选保留旧二进制（默认不保留；保留时按数量自动轮换，配置备份同步轮转）
- 📋  **日志管理** —— 脚本操作日志写入 `/var/log/easytier-manager.log`；自动配置 core 文件日志大小与轮转，避免日志填满磁盘
- 🪶  **小闪存友好** —— 仅安装必需二进制（默认跳过 `easytier-web` GUI 与未启用的 `easytier-web-embed`）；procd 下日志/备份默认值自动收紧；下载与安装前进行磁盘空间预检

---

## 🚀 快速开始

### 交互式安装（推荐）

```sh
curl -fsSL https://raw.githubusercontent.com/razaxq/easytier-manager/main/easytier.sh -o easytier.sh
sudo sh easytier.sh
```

> 🔔 脚本需要 `curl` 和 `unzip`。若缺失，脚本会提示对应的安装命令。

### 非交互式安装

```sh
curl -fsSL https://raw.githubusercontent.com/razaxq/easytier-manager/main/easytier.sh -o easytier.sh
sudo ET_NONINTERACTIVE=1 \
     ET_VERSION=v2.4.5 \
     ET_MODE=toml \
     ET_INSTANCE_NAME=mynode \
     ET_VIRTUAL_IP=10.0.0.1/24 \
     ET_NETWORK_NAME=mynet \
     ET_PEERS=tcp://public.easytier.cn:11010 \
     sh easytier.sh
```

---

## 🧰 支持的系统

| 发行版族 | init 系统 | 备注 |
|---|---|---|
| OpenWrt | procd | `/etc/init.d/` |
| Debian / Ubuntu / Raspbian | systemd | |
| RHEL / Fedora / Rocky / AlmaLinux | systemd | |
| Arch / Manjaro | systemd | |
| Alpine | OpenRC | |

**支持架构**：`x86_64` · `aarch64` · `armv7` · `riscv64`

---

## 📖 使用

### 主菜单

```
  ──────────────────────────────────────────
    EasyTier 管理脚本  vX.Y.Z
  ──────────────────────────────────────────
  系统  debian        架构  x86_64
  Init  systemd
  版本  2.4.5
  配置  TOML 配置文件
  ──────────────────────────────────────────

  1)  更新 / 重装（选择版本）
  2)  卸载
  3)  重新配置并重启服务
  4)  仅重启服务
  5)  查看服务状态
  6)  Web 控制台管理
  7)  查看已安装文件位置
  0)  退出
```

### 非交互环境变量

| 变量 | 说明 | 示例 |
|---|---|---|
| `ET_NONINTERACTIVE` | 启用非交互模式 | `1` |
| `ET_VERSION` | 安装版本 | `v2.4.5` |
| `ET_MODE` | 配置模式 | `toml` 或 `web` |
| `ET_INSTANCE_NAME` | 节点实例名 | `node-sg-01` |
| `ET_VIRTUAL_IP` | 虚拟 IPv4（含掩码） | `10.0.0.1/24` |
| `ET_NETWORK_NAME` | 虚拟网络名 | `mynet` |
| `ET_NETWORK_SECRET` | 网络密钥（留空自动生成） | `abc...` |
| `ET_PEERS` | 逗号分隔 Peer 列表 | `tcp://a:11010,udp://b:11010` |
| `ET_PROXY_CIDR` | 子网代理 CIDR（可选） | `192.168.1.0/24` |
| `ET_WEB_URL` | Web 模式接入 URL | `udp://host:22020/user` |
| `ET_BACKUP_KEEP` | 每个二进制 / 配置保留的备份份数（非交互下 `0` = 不备份） | `3`（默认；procd 下 `1`） |
| `ET_RELEASES_COUNT` | 版本列表最多条数 | `20`（默认） |
| `ET_INSTALL_WEB_GUI` | `1` 时安装 `easytier-web` GUI 客户端 | `0`（默认不装） |
| `ET_FILE_LOG_DIR` | core 文件日志目录 | `/var/log/easytier`（默认） |
| `ET_FILE_LOG_LEVEL` | core 文件日志级别 | `error`（默认；可选 `off`/`error`/`warn`/`info`/`debug`/`trace`） |
| `ET_FILE_LOG_SIZE` | 每份日志大小 (MB) | `10`（默认；procd 下 `2`） |
| `ET_FILE_LOG_COUNT` | 最多保留日志份数 | `5`（默认；procd 下 `3`） |
| `LOG_FILE` | 脚本日志文件路径 | `/var/log/easytier-manager.log` |

---

## 📁 文件位置

| 路径 | 说明 |
|---|---|
| `/usr/bin/easytier-core` `easytier-cli` | 节点必备二进制（始终安装） |
| `/usr/bin/easytier-web-embed` | Web 控制台守护进程（仅 Web 自建模式按需安装） |
| `/usr/bin/easytier-web` | 独立 GUI 客户端（仅 `ET_INSTALL_WEB_GUI=1` 时安装） |
| `/usr/bin/easytier-*.bak.<ts>` | 旧版本备份（询问保留；轮换数 = `ET_BACKUP_KEEP`） |
| `/etc/easytier/config.toml` | TOML 模式配置 |
| `/etc/easytier/core.args` | core 启动参数 |
| `/etc/easytier/web.args` | web-embed 启动参数 |
| `/etc/systemd/system/easytier.service` 等 | 服务单元（按 init 系统） |
| `/var/log/easytier-manager.log` | 脚本自身日志 |
| `/var/log/easytier/` | easytier-core 文件日志（按大小轮转，OpenWrt 上落在 tmpfs） |

---

## 🧪 开发与贡献

欢迎提 Issue 和 PR！

本地检查：

```sh
shellcheck -s sh easytier.sh
```

CI 会在每次 push / PR 时对所有 `*.sh` 跑 ShellCheck（见 [`.github/workflows/shellcheck.yml`](.github/workflows/shellcheck.yml)）。

---

## ❓ 常见问题

**Q: 为什么是 `/bin/sh` 而不是 Bash？**
A: 兼容 OpenWrt（BusyBox ash）和 Alpine（默认无 Bash），让脚本在路由器上也能跑。

**Q: 下载失败怎么办？**
A: 检查网络；大陆用户可考虑在下载前设置 `https_proxy` 或通过 GitHub 镜像。

**Q: 卸载后还想保留配置？**
A: 卸载流程会**分步**询问是否删除备份和 `/etc/easytier`，默认保留。

**Q: 如何升级到新版？**
A: 主菜单选 `1)`，脚本会拉取最新 Release 列表。「仅更新二进制」保留现有配置。

---

## 📄 License

[MIT](LICENSE) © 2026 Ramos

本脚本与 [EasyTier 上游项目](https://github.com/EasyTier/EasyTier) 无隶属关系。EasyTier 二进制的版权归其作者所有。
