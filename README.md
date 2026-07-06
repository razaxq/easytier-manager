# EasyTier Manager

[![ShellCheck](https://github.com/razaxq/easytier-manager/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/razaxq/easytier-manager/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-blue.svg)](#)

一个用于在 Linux 发行版上**安装、配置与管理 [EasyTier](https://github.com/EasyTier/EasyTier)** 的交互式脚本。纯 POSIX `sh`，无需 Bash、Python 或其他运行时依赖。

> EasyTier 本身是由 [EasyTier/EasyTier](https://github.com/EasyTier/EasyTier) 维护的开源 P2P 异地组网工具。本仓库仅提供第三方安装脚本，与上游项目无隶属关系。

---

## 🌐 语言 / Language

脚本**内置中英双语**，语言选择顺序为：`ET_LANG` 环境变量 > 系统 locale 自动识别（`zh*` → 中文）> 默认英文。

| 文件 | 默认界面语言 | 说明 | Raw URL |
|---|---|---|---|
| **`easytier.sh`**（单一真源） | 跟随 locale（默认 English） | 双语脚本，`zh_CN` 等中文环境自动显示中文 | `.../main/easytier.sh` |
| `easytier.zh.sh` | 简体中文（强制） | 由 `easytier.sh` **自动生成**，即使英文 locale 也显示中文 | `.../main/easytier.zh.sh` |

强制指定语言（对两个文件都生效）：

```sh
ET_LANG=zh sh easytier.sh    # 强制中文
ET_LANG=en sh easytier.zh.sh # 强制英文
```

> **`easytier.sh` is a single bilingual script.** It auto-detects the language from your locale (`zh*` → Chinese, otherwise English) and honors `ET_LANG=en|zh`. `easytier.zh.sh` is **generated** from it (identical code, just defaulting to Chinese) so Chinese users on an English-locale host can still `curl … easytier.zh.sh | sh`.

---

## ✨ 功能

- 🎛  **交互式菜单** —— 安装 / 更新 / 配置 / 重启 / 卸载 / 查看状态，一站式完成
- 🧩  **TOML 或 Web 控制台** 两种配置模式，含配置向导
- 🐧  **多发行版 / 多架构** —— OpenWrt、Debian、Ubuntu、RHEL、Alpine、Arch；x86_64 / aarch64 / armv7 / riscv64
- ⚙️  **多 init 系统** —— procd（OpenWrt）/ systemd / OpenRC，服务文件自动生成
- 🔒  **输入校验** —— CIDR、URL、端口格式检查，密钥强度检测
- 🤖  **非交互模式 + 子命令** —— 环境变量预设全部参数（Ansible / CI）；`status`/`start`/`stop`/`restart` 一次性子命令便于 cron
- 🌏  **下载加速与校验** —— 支持 `ET_GITHUB_MIRROR` 前缀镜像 / `https_proxy` 代理 / `ET_GITHUB_TOKEN` 解除 API 限流；版本列表缓存；下载做 zip 魔数与可选 `ET_SHA256` 完整性校验
- 📡  **网络概览** —— 状态页调用 `easytier-cli` 展示已连接节点与路由
- 🛡  **服务加固** —— systemd 单元默认启用 `NoNewPrivileges`/`ProtectSystem` 等沙箱项（保证 TUN/转发不受影响）
- 📦  **版本备份** —— 更新时可选保留旧二进制（默认不保留；保留时按数量自动轮换，配置备份同步轮转）
- 📋  **日志管理** —— 脚本操作日志写入 `/var/log/easytier-manager.log`；自动配置 core 文件日志大小与轮转，避免日志填满磁盘
- 🪶  **小闪存友好** —— 仅安装必需二进制（默认跳过 `easytier-web` GUI 与未启用的 `easytier-web-embed`）；procd 下日志/备份默认值自动收紧；下载与安装前进行磁盘空间预检

---

## 🚀 快速开始

### 交互式安装（推荐）

英文版（默认）：

```sh
curl -fsSL https://raw.githubusercontent.com/razaxq/easytier-manager/main/easytier.sh -o easytier.sh
sudo sh easytier.sh
```

中文版（把文件名换成 `easytier.zh.sh` 即可）：

```sh
curl -fsSL https://raw.githubusercontent.com/razaxq/easytier-manager/main/easytier.zh.sh -o easytier.sh
sudo sh easytier.sh
```

> 🔔 脚本需要 `curl` 和 `unzip`。若缺失，脚本会提示对应的安装命令。
> 💡 随时可按 `Ctrl+C` **安全退出**：安装/写配置等关键步骤会先完成或整体丢弃当前未提交的改动，绝不留下半装的二进制或被截断的配置。

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

  ── 日常 ──
  1)  查看服务状态
  2)  重启服务
  3)  停止服务
  ── 配置 ──
  4)  修改配置（TOML / Web 模式向导）
  5)  Web 控制台管理
  ── 安装维护 ──
  6)  更新 / 重装（选择版本）
  7)  文件位置与日志
  8)  卸载 EasyTier

  0)  退出
```

### 命令行子命令（便于脚本 / cron）

除交互式菜单外，脚本还支持一次性子命令，执行后即退出：

```sh
sh easytier.sh status     # 服务状态 + 网络概览（easytier-cli peer/route）
sh easytier.sh start      # 启动 easytier-core（及已配置的 web-embed）
sh easytier.sh stop       # 停止
sh easytier.sh restart    # 重启
sh easytier.sh version    # 打印脚本与 core 版本
sh easytier.sh help       # 帮助
```

无参数（或 `menu`）进入交互式菜单。

### 非交互环境变量

| 变量 | 说明 | 示例 |
|---|---|---|
| `ET_LANG` | 强制界面语言（覆盖 locale 自动识别） | `en` 或 `zh` |
| `ET_NONINTERACTIVE` | 启用非交互模式 | `1` |
| `ET_VERSION` | 安装版本 | `v2.4.5` |
| `ET_MODE` | 配置模式 | `toml` 或 `web` |
| `ET_INSTANCE_NAME` | 节点实例名 | `node-sg-01` |
| `ET_VIRTUAL_IP` | 虚拟 IPv4（含掩码；`ET_DHCP=1` 时可省略） | `10.0.0.1/24` |
| `ET_DHCP` | `1` 时用 DHCP 自动分配虚拟 IP（跳过 `ET_VIRTUAL_IP`） | `0`（默认） |
| `ET_LISTEN_PORT` | 监听基准端口（ws/wss 用 +1/+2） | `11010`（默认） |
| `ET_DEV_NAME` | TUN 设备名 | `easytier0`（默认） |
| `ET_NETWORK_NAME` | 虚拟网络名 | `mynet` |
| `ET_NETWORK_SECRET` | 网络密钥（留空自动生成） | `abc...` |
| `ET_PEERS` | 逗号分隔 Peer 列表 | `tcp://a:11010,udp://b:11010` |
| `ET_PROXY_CIDR` | 子网代理 CIDR（可多个，逗号分隔） | `192.168.1.0/24,10.9.0.0/24` |
| `ET_WEB_URL` | Web 模式接入 URL | `udp://host:22020/user` |
| `ET_BACKUP_KEEP` | 每个二进制 / 配置保留的备份份数（非交互下 `0` = 不备份） | `3`（默认；procd 下 `1`） |
| `ET_RELEASES_COUNT` | 版本列表最多条数 | `20`（默认） |
| `ET_INSTALL_WEB_GUI` | `1` 时安装 `easytier-web` GUI 客户端 | `0`（默认不装） |
| `ET_GITHUB_MIRROR` | github.com 下载前缀镜像（大陆加速） | `https://ghproxy.com` |
| `ET_GITHUB_API` | GitHub API 基址（用 API 镜像时覆盖） | `https://api.github.com`（默认） |
| `ET_GITHUB_TOKEN` | GitHub PAT，解除 60 次/时匿名 API 限流（或用 `GITHUB_TOKEN`） | `ghp_...` |
| `ET_SHA256` | 期望的发布 zip 的 sha256（完整性校验） | `<hex>` |
| `ET_CACHE_TTL` | 版本列表缓存秒数（`0` 关闭） | `600`（默认） |
| `ET_MIN_TMP_MB` | 下载+解压所需 `/tmp` 最小可用空间 (MB) | `120`（默认） |
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
shellcheck -s sh easytier.sh tools/build-zh.sh
sh tools/build-zh.sh                 # 从 easytier.sh 重新生成 easytier.zh.sh
```

CI 会在每次 push / PR 时对所有 `*.sh` 跑 ShellCheck（见 [`.github/workflows/shellcheck.yml`](.github/workflows/shellcheck.yml)）。

> ⚠️ **只需维护 `easytier.sh` 这一个文件**（中英文案都内联在其 `t "en" "zh"` 调用里）。`easytier.zh.sh` 是生成产物：改完 `easytier.sh` 后运行 `sh tools/build-zh.sh` 重新生成并一并提交，切勿手动编辑中文版。

---

## ❓ 常见问题

**Q: 为什么是 `/bin/sh` 而不是 Bash？**
A: 兼容 OpenWrt（BusyBox ash）和 Alpine（默认无 Bash），让脚本在路由器上也能跑。

**Q: 下载失败怎么办？**
A: 检查网络。大陆用户可设置 `ET_GITHUB_MIRROR=https://ghproxy.com` 走前缀镜像，或设置 `https_proxy` 走代理；若 API 被限流（60 次/时），设置 `ET_GITHUB_TOKEN=<PAT>`。脚本会自动缓存版本列表（`ET_CACHE_TTL` 秒）以减少 API 调用，并对下载文件做 zip 魔数/可选 `ET_SHA256` 完整性校验。

**Q: 卸载后还想保留配置？**
A: 卸载流程会**分步**询问是否删除备份和 `/etc/easytier`，默认保留。

**Q: 如何升级到新版？**
A: 主菜单选 `6) 更新 / 重装`，脚本会拉取最新 Release 列表。「仅更新二进制」保留现有配置。

---

## 📄 License

[MIT](LICENSE) © 2026 Ramos

本脚本与 [EasyTier 上游项目](https://github.com/EasyTier/EasyTier) 无隶属关系。EasyTier 二进制的版权归其作者所有。
