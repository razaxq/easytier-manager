# EasyTier Manager

[中文说明](README_zh.md) | [English](README.md)

[![ShellCheck](https://github.com/razaxq/easytier-manager/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/razaxq/easytier-manager/actions/workflows/shellcheck.yml)
[![Upstream compatibility](https://github.com/razaxq/easytier-manager/actions/workflows/upstream-compat.yml/badge.svg)](https://github.com/razaxq/easytier-manager/actions/workflows/upstream-compat.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-blue.svg)](#)

在 Linux 上**安装、配置与管理 [EasyTier](https://github.com/EasyTier/EasyTier)** 的交互式脚本。纯 POSIX `sh`，无 Bash / Python 依赖。

> 第三方脚本，与上游项目无隶属关系。EasyTier 二进制的版权归其作者所有。

**语言**：单脚本内置中英双语，按 `ET_LANG` > 系统 locale（`zh*` → 中文）> 英文 的顺序选择。

---

## ✨ 功能

- **交互式菜单** —— 安装 / 更新 / 配置 / 重启 / 卸载 / 状态一站式完成
- **两种配置模式** —— TOML 配置文件或 Web 控制台下发，均含向导
- **广覆盖** —— OpenWrt(procd) / Debian / Ubuntu / RHEL / Arch(systemd) / Alpine(OpenRC)；x86_64、ARM soft/hard-float、RISC-V、LoongArch、MIPS
- **非交互模式 + 子命令** —— 环境变量预设全部参数（Ansible / CI）；`status`/`start`/`stop`/`restart` 便于 cron，失败返回非零退出码
- **强制完整性校验** —— 默认从官方 Release API 取 SHA-256 强制比对；支持镜像 / 代理 / PAT 加速，但镜像不被信任为摘要来源
- **安全默认值** —— Web 管理界面仅监听 `127.0.0.1`，core 控制端口绑定回环，出口节点等敏感能力默认关闭；systemd 单元启用 `NoNewPrivileges`/`ProtectSystem` 等沙箱项
- **稳健的安装事务** —— 先下载校验、暂存并验证版本，再停服务整体提交，失败可回滚；`Ctrl+C` 不会留下半装的二进制或截断的配置
- **升级身份兼容** —— Web 模式升级/重配保留机器 ID，避免控制台把原节点误识别为新设备
- **小闪存友好** —— 只装必需二进制；procd 下日志/备份默认值自动收紧；安装前做空间预检

---

## 🚀 快速开始

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/easytier-manager@main/easytier.sh -o easytier.sh
sudo env ET_LANG=zh sh easytier.sh
```

> 需要 `curl` 与 `unzip`；缺失时脚本会提示对应安装命令。
> 中文环境下 `sudo sh easytier.sh` 也会自动显示中文，`ET_LANG=zh` 用于在英文 / `C` locale 的主机上强制中文。
> jsDelivr 对 `@main` 的 CDN 缓存为 12 小时，刚发布的修复可能有延迟。要拿最新版可改用
> `https://raw.githubusercontent.com/razaxq/easytier-manager/main/easytier.sh`，或访问
> `https://purge.jsdelivr.net/gh/razaxq/easytier-manager@main/easytier.sh` 刷新缓存。

子命令（执行后即退出，无参数则进入菜单）：

```sh
sh easytier.sh status     # 服务状态 + 网络概览（easytier-cli peer/route）
sh easytier.sh start      # 启动 / stop 停止 / restart 重启
sh easytier.sh version    # 打印脚本与 core 版本
sh easytier.sh help       # 帮助
```

---

## ⚙️ 环境变量

### 直接复制粘贴的配置

改好取值后整段执行即可。这里用 `sudo env` 而不是 `sudo VAR=…`，因为默认的 sudoers 策略会拒绝在 sudo 命令行上设置环境变量。

**独立节点（TOML 模式）**

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/razaxq/easytier-manager@main/easytier.sh -o easytier.sh
sudo env \
  ET_NONINTERACTIVE=1 \
  ET_LANG=zh \
  ET_MODE=toml \
  ET_INSTANCE_NAME=mynode \
  ET_VIRTUAL_IP=10.0.0.1/24 \
  ET_NETWORK_NAME=mynet \
  ET_NETWORK_SECRET=change-me \
  ET_PEERS=tcp://public.easytier.cn:11010 \
  ET_LISTEN_PORT=11010 \
  sh easytier.sh
```

**接入 Web 控制台（Web 模式）**

```sh
sudo env \
  ET_NONINTERACTIVE=1 \
  ET_LANG=zh \
  ET_MODE=web \
  ET_INSTANCE_NAME=mynode \
  ET_WEB_URL=udp://console.example.com:22020/myuser \
  sh easytier.sh
```

按需追加到上面任意一段里 —— 下载镜像、锁定版本、允许本节点作为出口节点：

```sh
  ET_GITHUB_MIRROR=https://ghfast.top \
  ET_VERSION=v2.6.4 \
  ET_ENABLE_EXIT_NODE=1 \
```

### 基础配置

| 变量 | 说明 | 示例 |
|---|---|---|
| `ET_LANG` | 强制界面语言 | `en` / `zh` |
| `ET_NONINTERACTIVE` | 启用非交互模式 | `1` |
| `ET_MODE` | 配置模式 | `toml` / `web` |
| `ET_INSTANCE_NAME` | 节点实例名 | `node-sg-01` |
| `ET_VIRTUAL_IP` | 虚拟 IPv4 含掩码（`ET_DHCP=1` 时可省略） | `10.0.0.1/24` |
| `ET_DHCP` | `1` = DHCP 自动分配虚拟 IP | `0`（默认） |
| `ET_LISTEN_PORT` | 监听基准端口，范围 1-65533（ws/wss 用 +1/+2） | `11010`（默认） |
| `ET_DEV_NAME` | TUN 设备名 | `easytier0`（默认） |
| `ET_NETWORK_NAME` / `ET_NETWORK_SECRET` | 虚拟网络名 / 密钥（留空自动生成） | `mynet` |
| `ET_PEERS` | 逗号分隔 Peer 列表 | `tcp://a:11010,udp://b:11010` |
| `ET_PROXY_CIDR` | 子网代理 CIDR，可多个 | `192.168.1.0/24,10.9.0.0/24` |
| `ET_WEB_URL` | Web 模式接入 URL | `udp://host:22020/user` |
| `ET_MACHINE_ID` | 固定机器 ID；通常无需设置，脚本会自动迁移/保留 | `cad9ff67-...` |

### 版本与下载

| 变量 | 说明 | 默认 |
|---|---|---|
| `ET_VERSION` | 安装版本；显式设置时可指定旧版或预发布版 | 最新稳定版 |
| `ET_ARCH` | 覆盖自动探测的架构：`x86_64` `aarch64` `arm` `armhf` `armv7` `armv7hf` `riscv64` `loongarch64` `mips` `mipsel` | 自动探测 |
| `ET_ALLOW_PRERELEASE` | `1` = 允许自动选中预发布版 | `0` |
| `ET_ALLOW_VERSION_FALLBACK` / `ET_DEFAULT_VERSION` | API 失败且未安装时允许回退到指定版本 | `0` / `v2.6.4` |
| `ET_SHA256` | 手动指定 zip 的 SHA-256；未设置时自动读官方 digest | 自动 |
| `ET_ALLOW_UNVERIFIED` | `1` = 无法取得/计算 SHA-256 时仍继续（不推荐） | `0` |
| `ET_GITHUB_MIRROR` | 下载前缀镜像（大陆加速），设置后优先使用，github.com 兜底 | 空 |
| `ET_GITHUB_MIRRORS` | 直连失败后依次尝试的备用前缀，留空则关闭自动回退 | `https://ghfast.top https://gh-proxy.com` |
| `ET_GITHUB_API` / `ET_GITHUB_TOKEN` | API 基址 / PAT（解除 60 次每小时限流） | 官方 / 空 |
| `ET_CACHE_TTL` | 版本列表缓存秒数（`0` 关闭） | `600` |
| `ET_MIN_TMP_MB` | 下载+解压所需 `/tmp` 最小空间 (MB) | `120` |

### 网络与安全

| 变量 | 说明 | 默认 |
|---|---|---|
| `ET_WEB_BIND_ADDR` | Web 管理界面监听地址；对外暴露需显式设为 `0.0.0.0` | `127.0.0.1` |
| `ET_WEB_DB_PATH` | Web 控制台数据库路径 | `/var/lib/easytier-web/et.db` |
| `ET_RPC_PORTAL` | core 本机控制端口（`easytier-cli` 连接目标），留空用上游默认 | `127.0.0.1:15888` |
| `ET_ENABLE_EXIT_NODE` | `1` = 允许本节点充当出口节点 | `0` |
| `ET_PRIVATE_MODE` | `1` = 拒绝陌生网络 | `1` |
| `ET_USE_SMOLTCP` | `1` = TCP 代理启用 smoltcp | `0` |
| `ET_DATA_COMPRESS_ALGO` | 压缩算法 `0`/`1`/`2` | `0`（不压缩） |

### 日志与维护

| 变量 | 说明 | 默认 |
|---|---|---|
| `ET_FILE_LOG_DIR` / `ET_FILE_LOG_LEVEL` | core 日志目录 / 级别（`off`…`trace`）。卸载时会询问是否 `rm -rf` 此目录，因此必须是至少两级的路径且不能是系统目录 | `/var/log/easytier` / `error` |
| `ET_FILE_LOG_SIZE` / `ET_FILE_LOG_COUNT` | 每份大小 (MB) / 保留份数 | `10` / `5`（procd 下 `2` / `3`） |
| `ET_BACKUP_KEEP` | 每个二进制/配置保留的备份份数（`0` = 不备份） | `3`（procd 下 `1`） |
| `ET_RELEASES_COUNT` | 版本列表最多条数 | `20` |
| `ET_INSTALL_WEB_GUI` | `1` = 安装 `easytier-web` GUI 客户端 | `0` |
| `LOG_FILE` | 脚本自身日志路径 | `/var/log/easytier-manager.log` |

---

## 📁 文件位置

| 路径 | 说明 |
|---|---|
| `/usr/bin/easytier-core` `easytier-cli` | 节点必备二进制（始终安装） |
| `/usr/bin/easytier-web-embed` | Web 控制台守护进程（自建模式按需安装） |
| `/usr/bin/easytier-web` | 独立 GUI 客户端（仅 `ET_INSTALL_WEB_GUI=1`） |
| `/usr/bin/easytier-*.bak.<ts>` | 旧版本备份（按 `ET_BACKUP_KEEP` 轮换） |
| `/etc/easytier/config.toml` | TOML 模式配置 |
| `/etc/easytier/core.args` · `web.args` | core / web-embed 启动参数 |
| `/var/lib/easytier/machine_id` | 持久化机器 ID（若服务保留 `HOME`/`XDG_DATA_HOME` 则在对应数据目录） |
| `/var/lib/easytier-web/et.db` | Web 控制台账号与网络配置 |
| `/var/log/easytier/` | core 文件日志（按大小轮转，OpenWrt 上落在 tmpfs） |
| `/var/log/easytier-manager.log` | 脚本自身日志 |

---

## 🧪 开发

欢迎提 Issue 和 PR。本地检查：

```sh
shellcheck -s sh easytier.sh
sh tests/test_machine_id.sh
sh tests/test_manager.sh
sh tests/test_upstream_compat.sh   # 需联网，会下载最新稳定版
```

CI 跑 ShellCheck 与单元测试；另有每周任务核验上游官方摘要、Release 结构、CLI 参数与生成的 TOML。

> ⚠️ 中英文案内联在 `t "en" "zh"` 调用里，改文案时**两种语言一起改**。

---

## ❓ 常见问题

**Q: 为什么是 `/bin/sh` 而不是 Bash？**
兼容 OpenWrt（BusyBox ash）和 Alpine（默认无 Bash），让脚本在路由器上也能跑。

**Q: 下载或 SHA-256 查询失败？**
大陆用户可用 `ET_GITHUB_MIRROR` 走下载镜像或设 `https_proxy`；API 限流时设 `ET_GITHUB_TOKEN`。镜像不被信任为摘要来源，脚本仍从官方 GitHub API 取 SHA-256；也可手动设置官方 `ET_SHA256`。仅在明确接受风险时使用 `ET_ALLOW_UNVERIFIED=1`。

**Q: 为什么 Web 控制台只能本机访问？**
上游初始化数据库时预置了 `admin/admin`（超级用户）与 `user/user` 两个账号，注册新账号并不会移除它们。建议通过 SSH 转发或带 TLS/访问控制的反向隧道访问；确需局域网监听时设 `ET_WEB_BIND_ADDR=0.0.0.0`，并立即改掉这两个账号的密码。

**Q: 卸载会删掉配置和节点身份吗？**
不会自动删。卸载流程**分步**询问是否删除备份、`/etc/easytier`、机器身份和 Web 数据库，默认全部保留。

**Q: 升级后 Web 控制台里原网络配置不见了？**
控制台按机器 ID 关联节点。旧版到新版的默认 ID 算法曾发生迁移；脚本自 v2.6.1 起会在替换二进制前触发旧 ID 迁移，并在重配时保留 `--machine-id`。若 ID 已变化，需先找回旧 ID 再执行 `ET_MACHINE_ID=<旧ID> sh easytier.sh` 重配一次。

---

[MIT](LICENSE) © 2026 Ramos
