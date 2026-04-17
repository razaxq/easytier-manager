#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` — not POSIX strict, but widely supported (dash/busybox)
# shellcheck disable=SC2059  # printf format with color vars — intentional for ANSI codes
# shellcheck disable=SC2155  # declare-and-assign — readable for local scalar capture
# ==============================================================================
#  easytier-manager.sh — EasyTier 安装与管理脚本
#  版本: 2.0.0
#  仓库: https://github.com/razaxq/easytier-manager
#  上游: https://github.com/EasyTier/EasyTier
#  License: MIT (c) 2026 razaxq
# ==============================================================================
#  支持系统
#    OpenWrt   (procd)
#    Debian / Ubuntu / Raspbian  (systemd)
#    RHEL / Fedora / Rocky / AlmaLinux  (systemd)
#    Arch Linux / Manjaro  (systemd)
#    Alpine Linux  (openrc)
#  支持架构: x86_64 / aarch64 / armv7 / riscv64
# ------------------------------------------------------------------------------
#  非交互式安装（通过环境变量预设所有参数）:
#    ET_NONINTERACTIVE=1         — 跳过所有确认，使用默认值或下列变量
#    ET_VERSION=v2.4.5           — 指定安装版本
#    ET_MODE=toml|web            — 配置模式
#    ET_INSTANCE_NAME=mynode     — 节点实例名
#    ET_VIRTUAL_IP=10.0.0.1/24  — 虚拟 IPv4（含掩码）
#    ET_NETWORK_NAME=mynet       — 虚拟网络名称
#    ET_NETWORK_SECRET=xxx       — 网络密钥（留空则自动生成）
#    ET_PEERS=tcp://a:11010,tcp://b:11010  — 逗号分隔的 Peer 列表
#    ET_PROXY_CIDR=192.168.1.0/24          — 子网代理 CIDR（可选）
#    ET_WEB_URL=udp://host:22020/user      — Web 模式接入 URL
# ==============================================================================

SCRIPT_VERSION="2.0.0"

# ── 可调参数 ──────────────────────────────────────────
ET_BACKUP_KEEP="${ET_BACKUP_KEEP:-3}"           # 每个二进制保留的备份份数
ET_RELEASES_COUNT="${ET_RELEASES_COUNT:-20}"    # 版本列表最多拉取条数
LOG_FILE="${LOG_FILE:-/var/log/easytier-manager.log}"
TMP_DIR="/tmp/et_mgr_$$"

# ── 运行时状态（检测填充，不要手动修改） ──────────────
OS_TYPE=""      # openwrt | debian | rhel | arch | alpine | unknown
INIT_SYS=""     # procd | systemd | openrc | unknown
ARCH_NAME=""    # x86_64 | aarch64 | armv7 | riscv64 | unknown
VER=""          # 选定版本，如 v2.4.5
EXTRACT_DIR=""  # 解压目录（do_download 写入）

# TOML 向导临时变量
_TOML_INSTANCE=""
_TOML_IP=""
_TOML_NET_NAME=""
_TOML_NET_SECRET=""
_TOML_PEERS=""          # 空格分隔
_TOML_PROXY_CIDR=""

# ==============================================================================
#  颜色 & 输出（tty 检测，非终端时降级为无色）
# ==============================================================================
_init_colors() {
    if [ -t 1 ]; then
        # printf 命令替换生成真正的 ESC 字节（0x1b），而非字面字符串 \033
        # 颜色变量既能在 printf 格式串中使用，也可嵌入普通变量后通过 %s 正确输出
        C_RED=$(printf '\033[0;31m')
        C_GRN=$(printf '\033[0;32m')
        C_YLW=$(printf '\033[1;33m')
        C_CYN=$(printf '\033[0;36m')
        C_BLD=$(printf '\033[1m')
        C_DIM=$(printf '\033[2m')
        C_RST=$(printf '\033[0m')
    else
        C_RED=''; C_GRN=''; C_YLW=''; C_CYN=''; C_BLD=''; C_DIM=''; C_RST=''
    fi
}

msg_ok()   { printf "${C_GRN}  ✓${C_RST}  %s\n"  "$*"; _log "OK"   "$*"; }
msg_warn() { printf "${C_YLW}  ⚠${C_RST}  %s\n"  "$*"; _log "WARN" "$*"; }
msg_err()  { printf "${C_RED}  ✗${C_RST}  %s\n"  "$*" >&2; _log "ERR" "$*"; }
msg_info() { printf "${C_CYN}  ›${C_RST}  %s\n"  "$*"; }
die()      { msg_err "$*"; exit 1; }

# 章节标题
section() {
    local title="$1"
    local len="${#title}"
    printf "\n${C_BLD}  %s${C_RST}\n" "$title"
    printf "  "
    i=0; while [ $i -lt $((len + 2)) ]; do printf "─"; i=$((i+1)); done
    printf "\n\n"
}

# ==============================================================================
#  日志（追加到文件，失败静默忽略）
# ==============================================================================
_log() {
    local level="$1"; shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        >> "$LOG_FILE" 2>/dev/null || true
}

# ==============================================================================
#  清理（trap 注册）
# ==============================================================================
_cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap '_cleanup' EXIT INT TERM HUP

# ==============================================================================
#  依赖检查
# ==============================================================================
check_deps() {
    local missing=''
    for cmd in curl unzip; do
        command -v "$cmd" > /dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] && return 0

    msg_err "缺少依赖:${missing}"
    case "$OS_TYPE" in
        openwrt) msg_info "opkg update && opkg install${missing}" ;;
        alpine)  msg_info "apk add${missing}" ;;
        debian)  msg_info "apt-get install -y${missing}" ;;
        rhel)    msg_info "dnf install -y${missing}" ;;
        arch)    msg_info "pacman -S${missing}" ;;
        *)       msg_info "请通过系统包管理器安装:${missing}" ;;
    esac
    die "请先安装缺少的依赖后重新运行"
}

# ==============================================================================
#  系统与架构检测
# ==============================================================================
detect_system() {
    # ── Init 系统 / OS 类型 ──────────────────────────
    if [ -f /etc/openwrt_release ]; then
        OS_TYPE="openwrt"; INIT_SYS="procd"
    elif [ -f /etc/alpine-release ] || \
         (command -v openrc > /dev/null 2>&1 && [ ! -f /etc/debian_version ]); then
        OS_TYPE="alpine"; INIT_SYS="openrc"
    elif [ -f /etc/os-release ]; then
        _id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        _id_like=$(grep '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')
        case "$_id $_id_like" in
            *debian*|*ubuntu*|*raspbian*) OS_TYPE="debian"; INIT_SYS="systemd" ;;
            *fedora*|*rhel*|*centos*|*rocky*|*alma*)
                OS_TYPE="rhel"; INIT_SYS="systemd" ;;
            *arch*|*manjaro*)   OS_TYPE="arch";  INIT_SYS="systemd" ;;
            *alpine*)           OS_TYPE="alpine"; INIT_SYS="openrc"  ;;
            *)                  OS_TYPE="unknown"; INIT_SYS="systemd" ;;
        esac
    else
        OS_TYPE="unknown"; INIT_SYS="unknown"
    fi

    # ── CPU 架构 ─────────────────────────────────────
    case "$(uname -m)" in
        x86_64|amd64)   ARCH_NAME="x86_64"  ;;
        aarch64|arm64)  ARCH_NAME="aarch64" ;;
        armv7l|armv7)   ARCH_NAME="armv7"   ;;
        riscv64)        ARCH_NAME="riscv64" ;;
        *)
            ARCH_NAME="unknown"
            msg_warn "未识别架构: $(uname -m)，EasyTier 可能不支持此平台"
            ;;
    esac

    _log "INFO" "检测: OS=${OS_TYPE} INIT=${INIT_SYS} ARCH=${ARCH_NAME}"
}

# ==============================================================================
#  进程 & 端口工具
# ==============================================================================
# 用 -f 匹配完整路径，避免进程名超过 15 字符被截断
_proc_running() { pgrep -f "/usr/bin/${1}" > /dev/null 2>&1; }
_proc_pid()     { pgrep -f "/usr/bin/${1}" 2>/dev/null | head -1; }

check_proc() {
    local bin="$1" label="${2:-$1}"
    sleep 2
    if _proc_running "$bin"; then
        msg_ok "${label} 运行中 (PID: $(_proc_pid "$bin"))"
        return 0
    fi
    msg_warn "${label} 未检测到进程，请查看日志"
    return 1
}

# 轮询端口就绪：优先 nc，回退 /proc/net/tcp
wait_for_port() {
    local port="$1" timeout="${2:-12}" i=0
    printf "    等待端口 %s 就绪" "$port"
    while [ "$i" -lt "$timeout" ]; do
        if command -v nc > /dev/null 2>&1; then
            nc -z 127.0.0.1 "$port" 2>/dev/null && \
                printf " ${C_GRN}✓${C_RST}\n" && return 0
        else
            local hex; hex=$(printf '%04X' "$port")
            grep -qi ":${hex} " /proc/net/tcp /proc/net/tcp6 2>/dev/null && \
                printf " ${C_GRN}✓${C_RST}\n" && return 0
        fi
        printf '.'
        sleep 1
        i=$((i + 1))
    done
    printf " ${C_YLW}(超时)${C_RST}\n"
    msg_warn "端口 ${port} 未就绪，请检查日志"
    return 1
}

# ==============================================================================
#  输入验证
# ==============================================================================
is_valid_port() {
    printf '%s' "$1" | grep -qE '^[0-9]+$' || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_cidr() {
    printf '%s' "$1" | grep -qE \
        '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$'
}

is_valid_url() {
    printf '%s' "$1" | grep -qE '^(tcp|udp|ws|wss)://'
}

# 生成 URL 安全随机密钥（64 hex 字符）
gen_secret() {
    if command -v openssl > /dev/null 2>&1; then
        openssl rand -hex 32
    elif [ -r /dev/urandom ]; then
        dd if=/dev/urandom bs=32 count=1 2>/dev/null | \
            od -An -tx1 | tr -d ' \n' | head -c 64
    else
        # 最后备选（强度低，仅应急）。$RANDOM 在 busybox ash 可用；POSIX 未定义时回退为 0。
        # shellcheck disable=SC3028
        printf '%s%s%s' "$(date +%s)" "$$" "${RANDOM:-0}" | \
            od -An -tx1 | tr -d ' \n' | head -c 32
        msg_warn "无法读取 /dev/urandom，密钥强度较低，建议上线前手动替换"
    fi
}

# ==============================================================================
#  服务管理 — 统一入口，按 INIT_SYS 分支
# ==============================================================================
svc_stop() {
    case "$INIT_SYS" in
        procd)   [ -f /etc/init.d/easytier ]  && /etc/init.d/easytier stop 2>/dev/null || true ;;
        systemd) systemctl stop easytier  2>/dev/null || true ;;
        openrc)  rc-service easytier stop 2>/dev/null || true ;;
    esac
}

svc_start() {
    case "$INIT_SYS" in
        procd)   /etc/init.d/easytier enable && /etc/init.d/easytier start ;;
        systemd) systemctl daemon-reload && systemctl enable easytier && systemctl start easytier ;;
        openrc)  rc-update add easytier default 2>/dev/null; rc-service easytier start ;;
    esac
}

svc_restart() {
    case "$INIT_SYS" in
        procd)   /etc/init.d/easytier restart  2>/dev/null || true ;;
        systemd) systemctl restart easytier    2>/dev/null || true ;;
        openrc)  rc-service easytier restart   2>/dev/null || true ;;
    esac
}

svc_remove() {
    case "$INIT_SYS" in
        procd)
            [ -f /etc/init.d/easytier ] && {
                /etc/init.d/easytier disable 2>/dev/null || true
                rm -f /etc/init.d/easytier
            } ;;
        systemd)
            systemctl disable easytier 2>/dev/null || true
            rm -f /etc/systemd/system/easytier.service
            systemctl daemon-reload 2>/dev/null || true ;;
        openrc)
            rc-update del easytier default 2>/dev/null || true
            rm -f /etc/init.d/easytier ;;
    esac
}

svc_stop_web() {
    case "$INIT_SYS" in
        procd)   [ -f /etc/init.d/easytier-web ] && /etc/init.d/easytier-web stop 2>/dev/null || true ;;
        systemd) systemctl stop easytier-web  2>/dev/null || true ;;
        openrc)  rc-service easytier-web stop 2>/dev/null || true ;;
    esac
}

svc_start_web() {
    case "$INIT_SYS" in
        procd)   /etc/init.d/easytier-web enable && /etc/init.d/easytier-web start ;;
        systemd) systemctl daemon-reload && systemctl enable easytier-web && systemctl start easytier-web ;;
        openrc)  rc-update add easytier-web default 2>/dev/null; rc-service easytier-web start ;;
    esac
}

svc_restart_web() {
    case "$INIT_SYS" in
        procd)   /etc/init.d/easytier-web restart  2>/dev/null || true ;;
        systemd) systemctl restart easytier-web    2>/dev/null || true ;;
        openrc)  rc-service easytier-web restart   2>/dev/null || true ;;
    esac
}

svc_remove_web() {
    case "$INIT_SYS" in
        procd)
            [ -f /etc/init.d/easytier-web ] && {
                /etc/init.d/easytier-web disable 2>/dev/null || true
                rm -f /etc/init.d/easytier-web
            } ;;
        systemd)
            systemctl disable easytier-web 2>/dev/null || true
            rm -f /etc/systemd/system/easytier-web.service
            systemctl daemon-reload 2>/dev/null || true ;;
        openrc)
            rc-update del easytier-web default 2>/dev/null || true
            rm -f /etc/init.d/easytier-web ;;
    esac
}

# ==============================================================================
#  服务文件写入 — core
# 
# ==============================================================================
svc_write_core() {
    [ -f /etc/easytier/core.args ] || { msg_err "core.args 不存在"; return 1; }

    # systemd / openrc 需要把多行 args 合并为单行
    local args_line
    args_line=$(tr '\n' ' ' < /etc/easytier/core.args | sed 's/[[:space:]]*$//')

    case "$INIT_SYS" in

        procd)
            # 第一段：含变量展开的部分
            cat > /etc/init.d/easytier << EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
    [ -f /etc/easytier/core.args ] || return 1
    procd_open_instance
    procd_set_param command /usr/bin/easytier-core
    while IFS= read -r _arg; do
        [ -n "\$_arg" ] && procd_append_param command "\$_arg"
    done < /etc/easytier/core.args
    procd_set_param respawn 60 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param netdev wan
    procd_set_param limits nofile="65535 65535"
    procd_close_instance
}
service_triggers() {
    procd_add_reload_trigger "easytier"
    procd_add_interface_trigger "interface.*" "wan" /etc/init.d/easytier restart
}
EOF
            chmod +x /etc/init.d/easytier
            ;;

        systemd)
            cat > /etc/systemd/system/easytier.service << EOF
[Unit]
Description=EasyTier Network Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/easytier-core ${args_line}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
            ;;

        openrc)
            cat > /etc/init.d/easytier << EOF
#!/sbin/openrc-run
description="EasyTier Network Node"
command="/usr/bin/easytier-core"
command_args="${args_line}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/easytier.log"
error_log="/var/log/easytier.log"
depend() { need net; after firewall; }
EOF
            chmod +x /etc/init.d/easytier
            ;;

        *)
            msg_warn "未知 init 系统，写入 systemd 格式，请手动调整"
            INIT_SYS="systemd"; svc_write_core; return
            ;;
    esac
    msg_ok "easytier-core 服务文件已写入"
}

# ==============================================================================
#  服务文件写入 — web-embed
# ==============================================================================
svc_write_web() {
    [ -f /etc/easytier/web.args ] || { msg_err "web.args 不存在"; return 1; }

    local args_line
    args_line=$(tr '\n' ' ' < /etc/easytier/web.args | sed 's/[[:space:]]*$//')

    case "$INIT_SYS" in

        procd)
            cat > /etc/init.d/easytier-web << EOF
#!/bin/sh /etc/rc.common
START=98
STOP=11
USE_PROCD=1
start_service() {
    [ -f /etc/easytier/web.args ] || return 1
    procd_open_instance
    procd_set_param command /usr/bin/easytier-web-embed
    while IFS= read -r _arg; do
        [ -n "\$_arg" ] && procd_append_param command "\$_arg"
    done < /etc/easytier/web.args
    procd_set_param respawn 60 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param limits nofile="65535 65535"
    procd_close_instance
}
EOF
            chmod +x /etc/init.d/easytier-web
            ;;

        systemd)
            cat > /etc/systemd/system/easytier-web.service << EOF
[Unit]
Description=EasyTier Web Console
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/easytier-web-embed ${args_line}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
            ;;

        openrc)
            cat > /etc/init.d/easytier-web << EOF
#!/sbin/openrc-run
description="EasyTier Web Console"
command="/usr/bin/easytier-web-embed"
command_args="${args_line}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/easytier-web.log"
error_log="/var/log/easytier-web.log"
depend() { need net; }
EOF
            chmod +x /etc/init.d/easytier-web
            ;;

        *)
            msg_warn "未知 init 系统，写入 systemd 格式"
            INIT_SYS="systemd"; svc_write_web; return
            ;;
    esac
    msg_ok "easytier-web-embed 服务文件已写入"
}

# ==============================================================================
#  版本选择
# 
#  新增: 显示发布日期（GitHub published_at）
#  返回 0 = 已选定（$VER）   1 = 按 0 返回
# ==============================================================================
select_version() {
    # 非交互模式：直接使用环境变量
    if [ -n "${ET_VERSION:-}" ]; then
        VER="$ET_VERSION"
        msg_ok "使用预设版本: $VER"
        return 0
    fi

    section "选择安装版本"
    msg_info "正在从 GitHub 获取版本列表..."

    local json
    json=$(curl -sf --connect-timeout 10 \
        "https://api.github.com/repos/EasyTier/EasyTier/releases?per_page=${ET_RELEASES_COUNT}") || true

    mkdir -p "$TMP_DIR"
    local rel_file="${TMP_DIR}/releases.txt"

    if [ -z "$json" ]; then
        msg_warn "获取失败，回退到内置默认版本 v2.4.5"
        VER="v2.4.5"; return 0
    fi

    # 解析逻辑：
    #   遇到 tag_name  → 重置，开始收集新条目
    #   遇到 published_at → 截取日期部分（YYYY-MM-DD）
    #   遇到 prerelease → 三字段齐全后输出一行，然后重置
    # 不依赖三个字段在 JSON 中的出现顺序
    printf '%s\n' "$json" | awk '
        function trimstr(s,   r) {
            r = s
            gsub(/^[[:space:]"]+/, "", r)
            gsub(/"[[:space:]]*,?[[:space:]]*$/, "", r)
            gsub(/[[:space:]]+$/, "", r)
            return r
        }
        {
            if (index($0, "\"tag_name\"") > 0) {
                # 新条目开始，重置三个字段
                if (tag != "" && date != "" && pre != "")
                    print tag, pre, date
                tag = ""; date = ""; pre = ""
                val = $0
                gsub(/.*"tag_name"[[:space:]]*:[[:space:]]*/, "", val)
                tag = trimstr(val)
            }
            else if (index($0, "\"published_at\"") > 0) {
                val = $0
                gsub(/.*"published_at"[[:space:]]*:[[:space:]]*/, "", val)
                val = trimstr(val)
                gsub(/T.*$/, "", val)   # 只保留 YYYY-MM-DD
                date = val
            }
            else if (index($0, "\"prerelease\"") > 0) {
                pre = (index($0, "true") > 0) ? "pre" : "stable"
                # prerelease 通常是对象的最后几个字段之一，尝试在此输出
                if (tag != "" && date != "" && pre != "") {
                    print tag, pre, date
                    tag = ""; date = ""; pre = ""
                }
            }
        }
        END {
            # 输出最后一条（若未因 tag_name 重置而触发）
            if (tag != "" && date != "" && pre != "")
                print tag, pre, date
        }
    ' > "$rel_file"

    local count
    count=$(wc -l < "$rel_file" | tr -d ' \t')

    if [ "$count" -eq 0 ]; then
        msg_warn "解析失败，回退到内置默认版本 v2.4.5"
        VER="v2.4.5"; return 0
    fi

    while true; do
        # 表头（全 ASCII，与下方数据行的 %-16s %-14s 列宽严格对齐）
        printf "  ${C_BLD}%4s  %-16s  %-14s  %s${C_RST}\n" \
            "No." "Version" "Type" "Date"
        printf "  %s\n" \
            "────────────────────────────────────────────────────"

        local i=1
        while [ "$i" -le "$count" ]; do
            local line tag pre date label clr
            line=$(sed -n "${i}p" "$rel_file")
            tag=$(printf '%s' "$line" | awk '{print $1}')
            pre=$(printf '%s' "$line" | awk '{print $2}')
            date=$(printf '%s' "$line" | awk '{print $3}')

            if [ "$pre" = "stable" ]; then
                label="[stable]    "; clr="$C_GRN"
            else
                label="[pre-release]"; clr="$C_YLW"
            fi

            printf "  ${C_BLD}%3d)${C_RST}  %-16s  ${clr}%-14s${C_RST}  ${C_DIM}%s${C_RST}\n" \
                "$i" "$tag" "$label" "$date"
            i=$((i + 1))
        done

        printf "  ${C_BLD}%3s)${C_RST}  返回\n" "0"
        printf "  %s\n" \
            "────────────────────────────────────────────────────"
        printf "  选择 [0-%d，默认 1]: " "$count"
        read -r vc

        [ "$vc" = "0" ] && return 1
        [ -z "$vc"  ] && vc=1

        local valid=false
        printf '%s' "$vc" | grep -qE '^[0-9]+$' && \
            [ "$vc" -ge 1 ] && [ "$vc" -le "$count" ] && valid=true

        if [ "$valid" = true ]; then
            local chosen_line
            chosen_line=$(sed -n "${vc}p" "$rel_file")
            VER=$(printf '%s' "$chosen_line" | awk '{print $1}')
            local chosen_date
            chosen_date=$(printf '%s' "$chosen_line" | awk '{print $3}')
            msg_ok "已选择: ${VER}  (发布于 ${chosen_date})"
            return 0
        fi
        msg_warn "无效输入，请重新选择"
    done
}

# ==============================================================================
#  下载（先验证，成功后再停服务）
# ==============================================================================
do_download() {
    local ver="$1" arch="$2"

    [ "$arch" = "unknown" ] && \
        die "无法识别架构 $(uname -m)，请访问 https://github.com/EasyTier/EasyTier/releases 手动下载"

    local zip_name="easytier-linux-${arch}-${ver}.zip"
    local url="https://github.com/EasyTier/EasyTier/releases/download/${ver}/${zip_name}"

    section "下载 EasyTier"
    msg_info "版本: ${ver}  架构: ${arch}"
    msg_info "URL:  ${url}"

    mkdir -p "$TMP_DIR"
    if ! curl -L --progress-bar --retry 3 --retry-delay 3 --connect-timeout 15 \
            -o "${TMP_DIR}/${zip_name}" "$url"; then
        msg_err "下载失败，请检查网络连接或版本号"
        return 1
    fi

    msg_info "解压中..."
    if ! unzip -o "${TMP_DIR}/${zip_name}" -d "${TMP_DIR}/"; then
        msg_err "解压失败"
        case "$OS_TYPE" in
            openwrt) msg_info "请先: opkg install unzip" ;;
            alpine)  msg_info "请先: apk add unzip" ;;
            debian)  msg_info "请先: apt-get install -y unzip" ;;
            rhel)    msg_info "请先: dnf install -y unzip" ;;
            arch)    msg_info "请先: pacman -S unzip" ;;
        esac
        return 1
    fi

    local core_path
    core_path=$(find "$TMP_DIR" -maxdepth 2 -name "easytier-core" -type f 2>/dev/null | head -1)
    [ -z "$core_path" ] && { msg_err "解压后未找到 easytier-core（版本号是否正确？）"; return 1; }

    EXTRACT_DIR=$(dirname "$core_path")
    msg_ok "下载并解压完成"
    return 0
}

# ==============================================================================
#  安装二进制（下载验证成功后才停服务）
# ==============================================================================
do_install_bins() {
    local extract_dir="$1"

    msg_info "停止运行中的服务..."
    svc_stop; svc_stop_web

    local ts; ts=$(date +%s)
    local installed=0

    section "安装二进制文件 → /usr/bin/"
    for bin in easytier-core easytier-cli easytier-web easytier-web-embed; do
        if [ -f "${extract_dir}/${bin}" ]; then
            [ -f "/usr/bin/$bin" ] && mv "/usr/bin/$bin" "/usr/bin/${bin}.bak.${ts}"
            mv "${extract_dir}/${bin}" /usr/bin/
            chmod +x "/usr/bin/${bin}"
            local size; size=$(du -sh "/usr/bin/${bin}" 2>/dev/null | awk '{print $1}')
            printf "  ${C_GRN}✓${C_RST}  %-30s  %s\n" "$bin" "$size"
            installed=$((installed + 1))
        else
            printf "  ${C_DIM}-  %-30s  (此版本未包含)${C_RST}\n" "$bin"
        fi
    done

    [ "$installed" -eq 0 ] && { msg_err "未找到任何可安装文件"; return 1; }

    if ! /usr/bin/easytier-core --version > /dev/null 2>&1; then
        msg_err "easytier-core 执行验证失败（架构不兼容？）"
        return 1
    fi

    printf "\n"
    msg_ok "安装完成: $(/usr/bin/easytier-core --version)"
    _prune_backups
    return 0
}

# ==============================================================================
#  备份清理（每个二进制只保留最近 N 份）
# ==============================================================================
_prune_backups() {
    for bin in easytier-core easytier-cli easytier-web easytier-web-embed; do
        local count
        count=$(ls /usr/bin/${bin}.bak.* 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -gt "$ET_BACKUP_KEEP" ]; then
            local del=$(( count - ET_BACKUP_KEEP ))
            ls -t /usr/bin/${bin}.bak.* 2>/dev/null | tail -n "$del" | \
                while read -r f; do
                    rm -f "$f"
                    msg_info "清理旧备份: $(basename "$f")"
                done
        fi
    done
}

# ==============================================================================
#  TOML 配置向导
# 
# ==============================================================================
_toml_wizard() {
    section "TOML 配置向导"

    # ── 节点实例名 ────────────────────────────────────
    local def_name
    def_name="${ET_INSTANCE_NAME:-$(hostname 2>/dev/null || echo "easytier-node")}"
    printf "  节点实例名  [默认: %s]: " "$def_name"
    [ "${ET_NONINTERACTIVE:-0}" = "1" ] && printf '\n' && _TOML_INSTANCE="$def_name" || {
        read -r _TOML_INSTANCE
        [ -z "$_TOML_INSTANCE" ] && _TOML_INSTANCE="$def_name"
    }

    # ── 虚拟 IP ───────────────────────────────────────
    local def_ip="${ET_VIRTUAL_IP:-}"
    while true; do
        printf "  虚拟 IPv4   [例: 10.0.0.1/24]: "
        if [ "${ET_NONINTERACTIVE:-0}" = "1" ] && [ -n "$def_ip" ]; then
            printf '%s\n' "$def_ip"; _TOML_IP="$def_ip"; break
        fi
        read -r _TOML_IP
        [ -z "$_TOML_IP" ] && { msg_warn "虚拟 IP 不能为空"; continue; }
        is_valid_cidr "$_TOML_IP" && break
        msg_warn "格式无效，请输入 a.b.c.d/n 格式（如 10.0.0.1/24）"
    done

    # ── 网络名称 ──────────────────────────────────────
    local def_net="${ET_NETWORK_NAME:-}"
    while true; do
        printf "  网络名称    [自定义字符串]: "
        if [ "${ET_NONINTERACTIVE:-0}" = "1" ] && [ -n "$def_net" ]; then
            printf '%s\n' "$def_net"; _TOML_NET_NAME="$def_net"; break
        fi
        read -r _TOML_NET_NAME
        [ -n "$_TOML_NET_NAME" ] && break
        msg_warn "网络名称不能为空"
    done

    # ── 网络密钥 ──────────────────────────────────────
    printf "  网络密钥    [留空=自动生成]: "
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        printf '\n'
        _TOML_NET_SECRET="${ET_NETWORK_SECRET:-}"
    else
        read -r _TOML_NET_SECRET
    fi
    if [ -z "$_TOML_NET_SECRET" ]; then
        _TOML_NET_SECRET=$(gen_secret)
        msg_ok "已生成随机密钥"
        printf "    ${C_DIM}%s${C_RST}\n" "$_TOML_NET_SECRET"
        msg_info "请记录此密钥——同一网络中所有节点需使用相同密钥"
    fi

    # ── Peer 列表 ─────────────────────────────────────
    _TOML_PEERS=""
    if [ -n "${ET_PEERS:-}" ]; then
        # 环境变量逗号分隔 → 空格分隔
        _TOML_PEERS=$(printf '%s' "$ET_PEERS" | tr ',' ' ')
    else
        msg_info "输入 Peer 地址（可选，空行结束）"
        msg_info "格式: tcp://host:11010  或  udp://host:11010"
        while true; do
            printf "  Peer URL（空行完成）: "
            local peer; read -r peer
            [ -z "$peer" ] && break
            if ! is_valid_url "$peer"; then
                msg_warn "协议须为 tcp/udp/ws/wss，请重新输入"
                continue
            fi
            _TOML_PEERS="${_TOML_PEERS}${_TOML_PEERS:+ }${peer}"
        done
    fi

    # ── 子网代理 ──────────────────────────────────────
    _TOML_PROXY_CIDR="${ET_PROXY_CIDR:-}"
    if [ -z "$_TOML_PROXY_CIDR" ] && [ "${ET_NONINTERACTIVE:-0}" != "1" ]; then
        printf "  子网代理 CIDR [可选，例: 192.168.1.0/24]: "
        read -r _TOML_PROXY_CIDR
        if [ -n "$_TOML_PROXY_CIDR" ] && ! is_valid_cidr "$_TOML_PROXY_CIDR"; then
            msg_warn "CIDR 格式无效，已忽略子网代理"
            _TOML_PROXY_CIDR=""
        fi
    fi
}

_toml_write_config() {
    local cfg="/etc/easytier/config.toml"

    {
        printf 'instance_name = "%s"\n'  "$_TOML_INSTANCE"
        printf 'hostname = "%s"\n'       "$_TOML_INSTANCE"
        printf 'dhcp = false\n'
        printf 'ipv4 = "%s"\n'           "$_TOML_IP"
        printf 'listeners = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010", '
        printf '"wg://0.0.0.0:11011", "ws://0.0.0.0:11011/", "wss://0.0.0.0:11012/"]\n'
        printf 'exit_nodes = []\n'
        printf 'rpc_portal = "0.0.0.0:0"\n'
        printf '\n'

        for peer in $_TOML_PEERS; do
            printf '[[peer]]\n'
            printf 'uri = "%s"\n' "$peer"
            printf '\n'
        done

        if [ -n "$_TOML_PROXY_CIDR" ]; then
            printf '[[proxy_network]]\n'
            printf 'cidr = "%s"\n' "$_TOML_PROXY_CIDR"
            printf '\n'
        fi

        printf '[network_identity]\n'
        printf 'network_name = "%s"\n'   "$_TOML_NET_NAME"
        printf 'network_secret = "%s"\n' "$_TOML_NET_SECRET"
        printf '\n'

        printf '[flags]\n'
        printf 'default_protocol = "tcp"\n'
        printf 'dev_name = "easytier0"\n'
        printf 'enable_ipv6 = true\n'
        printf 'enable_encryption = true\n'
        printf 'enable_exit_node = true\n'
        printf 'data_compress_algo = 2\n'
        printf 'use_smoltcp = true\n'
        printf 'private_mode = true\n'
        printf 'foreign_network_whitelist = "*"\n'
    } > "$cfg"
    chmod 600 "$cfg"
    msg_ok "TOML 配置文件已写入: $cfg"
}

setup_toml_config() {
    mkdir -p /etc/easytier

    if [ -f /etc/easytier/config.toml ]; then
        if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
            msg_info "非交互模式：自动备份并覆盖配置"
            cp /etc/easytier/config.toml "/etc/easytier/config.toml.bak.$(date +%s)"
        else
            printf "  配置文件已存在，覆盖? [y/N/0=返回]: "
            read -r a
            case "$a" in
                0)    return 1 ;;
                y|Y)  cp /etc/easytier/config.toml "/etc/easytier/config.toml.bak.$(date +%s)" ;;
                *)    msg_info "已保留原配置文件"
                      # 保留原文件，仍更新 core.args 指向它
                      printf '%s\n' "--config-file" "/etc/easytier/config.toml" \
                          > /etc/easytier/core.args
                      chmod 600 /etc/easytier/core.args
                      return 0 ;;
            esac
        fi
    fi

    _toml_wizard
    _toml_write_config

    printf '%s\n' "--config-file" "/etc/easytier/config.toml" \
        > /etc/easytier/core.args
    chmod 600 /etc/easytier/core.args
    return 0
}

# ==============================================================================
#  Web 控制台配置
# 
# ==============================================================================
setup_web_console() {
    section "配置 easytier-web-embed"

    # ── API 端口 ──────────────────────────────────────
    local api_port
    while true; do
        printf "  Web API/前端 端口   [默认 11211]: "
        read -r api_port
        [ -z "$api_port" ] && api_port=11211
        is_valid_port "$api_port" && break
        msg_warn "端口范围: 1-65535"
    done

    # ── 配置下发端口 ──────────────────────────────────
    local cfg_port
    while true; do
        printf "  配置下发端口        [默认 22020]: "
        read -r cfg_port
        [ -z "$cfg_port" ] && cfg_port=22020
        is_valid_port "$cfg_port" && break
        msg_warn "端口范围: 1-65535"
    done

    # ── 协议 ────────────────────────────────
    printf '\n'
    msg_info "配置下发协议说明:"
    msg_info "  udp — 推荐，延迟最低"
    msg_info "  tcp — 穿透性更好"
    msg_info "  ws  — 适合 HTTP 反向代理；若 Cloudflare Tunnel 将 ws 升级为 wss，"
    msg_info "        则 easytier-core 接入时协议应填 wss（而非 ws）"
    printf "  协议 (tcp/udp/ws) [默认 udp]: "
    local cfg_proto; read -r cfg_proto
    case "$cfg_proto" in tcp|udp|ws) ;; *) cfg_proto=udp ;; esac

    # ── API Host ────────────────────────────
    printf '\n'
    msg_info "--api-host 决定 Web 前端调用 API 后端的地址:"
    msg_info "  · 仅本地访问:           http://127.0.0.1:${api_port}"
    msg_info "  · Cloudflare Tunnel:  https://your-domain.example.com"
    msg_info "  （Tunnel 配置完成后可通过「Web 控制台管理」重新配置此项）"
    printf "  API Host [默认 http://127.0.0.1:%s]: " "$api_port"
    local api_host; read -r api_host
    [ -z "$api_host" ] && api_host="http://127.0.0.1:${api_port}"

    mkdir -p /etc/easytier
    printf '%s\n' \
        "--api-server-port" "${api_port}" \
        "--api-host"        "${api_host}" \
        "--config-server-port"     "${cfg_port}" \
        "--config-server-protocol" "${cfg_proto}" \
        > /etc/easytier/web.args
    chmod 600 /etc/easytier/web.args

    svc_write_web || return 1
    svc_stop_web  2>/dev/null || true
    svc_start_web
    wait_for_port "$api_port" 12

    printf '\n'
    printf "  ${C_GRN}┌─ easytier-web-embed 已启动 ────────────────────────┐${C_RST}\n"
    printf "  ${C_GRN}│${C_RST}  Web 控制台:  http://0.0.0.0:%-6s                 ${C_GRN}│${C_RST}\n" "$api_port"
    printf "  ${C_GRN}│${C_RST}  配置下发:    %-3s://0.0.0.0:%-6s                 ${C_GRN}│${C_RST}\n" "$cfg_proto" "$cfg_port"
    printf "  ${C_GRN}│${C_RST}  默认账户:    admin / user  ${C_YLW}← 请立即修改密码${C_RST}   ${C_GRN}│${C_RST}\n"
    printf "  ${C_GRN}└─────────────────────────────────────────────────────┘${C_RST}\n\n"
    msg_info "请先在浏览器访问控制台并注册账户，再继续填写接入 URL"
    return 0
}

ask_core_web_url() {
    local started_web="${1:-false}"
    section "easytier-core 接入 Web 控制台"
    msg_info "格式: <protocol>://<host>:<port>/<username>"
    msg_info "示例: udp://127.0.0.1:22020/myuser"
    msg_info "      wss://easytier-web.example.com/22020/myuser"
    msg_info "注意: 若通过 Cloudflare Tunnel 反代且下发协议为 ws，接入协议请填 wss"

    # 非交互模式
    if [ -n "${ET_WEB_URL:-}" ]; then
        mkdir -p /etc/easytier
        printf '%s\n' "-w" "$ET_WEB_URL" > /etc/easytier/core.args
        chmod 600 /etc/easytier/core.args
        msg_ok "接入 URL 已保存（非交互）: $ET_WEB_URL"
        return 0
    fi

    while true; do
        local hint=""
        [ "$started_web" = "true" ] && hint="/撤销 web-embed"
        printf "\n  接入 URL [0=返回%s]: " "$hint"
        read -r w_url

        case "$w_url" in
            0)
                if [ "$started_web" = "true" ]; then
                    msg_info "正在撤销 web-embed 配置..."
                    svc_stop_web; svc_remove_web
                    rm -f /etc/easytier/web.args
                    msg_ok "已撤销 web-embed 服务"
                fi
                return 1
                ;;
            "")
                msg_warn "URL 不能为空"
                ;;
            *)
                if ! is_valid_url "$w_url"; then
                    msg_warn "URL 须以 tcp:// udp:// ws:// wss:// 开头"
                    continue
                fi
                mkdir -p /etc/easytier
                printf '%s\n' "-w" "$w_url" > /etc/easytier/core.args
                chmod 600 /etc/easytier/core.args
                msg_ok "接入 URL 已保存: $w_url"
                return 0
                ;;
        esac
    done
}

do_setup_mode() {
    # 非交互模式
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        case "${ET_MODE:-toml}" in
            web)
                ask_core_web_url "false"; return $?
                ;;
            *)
                setup_toml_config; return $?
                ;;
        esac
    fi

    mkdir -p /etc/easytier
    while true; do
        section "选择配置方式"
        printf "  ${C_BLD}1)${C_RST}  TOML 配置文件  —  独立节点，本地管理\n"
        printf "  ${C_BLD}2)${C_RST}  Web 控制台下发 —  集中管理多节点\n"
        printf "  ${C_BLD}0)${C_RST}  返回\n\n"
        printf "  请选择 [0-2]: "
        read -r mode

        case "$mode" in
            0) return 1 ;;
            1) setup_toml_config && return 0 ;;
            2)
                printf '\n'
                printf "  是否在本机运行 easytier-web-embed？\n"
                printf "  ${C_BLD}1)${C_RST}  是，本机部署 Web 控制台\n"
                printf "  ${C_BLD}2)${C_RST}  否，连接至已有外部控制台\n"
                printf "  ${C_BLD}0)${C_RST}  返回\n"
                printf "  请选择 [0-2]: "
                read -r rw
                case "$rw" in
                    0) continue ;;
                    1)
                        if [ ! -f /usr/bin/easytier-web-embed ]; then
                            msg_warn "easytier-web-embed 未安装，此版本可能不包含"
                            continue
                        fi
                        setup_web_console || continue
                        ask_core_web_url "true" && return 0 || continue
                        ;;
                    2) ask_core_web_url "false" && return 0 || continue ;;
                    *) msg_warn "无效输入" ;;
                esac
                ;;
            *) msg_warn "无效输入" ;;
        esac
    done
}

# ==============================================================================
#  服务状态查看
# ==============================================================================
do_view_status() {
    section "服务状态"

    _print_svc_block() {
        local label="$1" bin="$2" args_file="$3"
        printf "  ${C_BLD}[ %s ]${C_RST}\n" "$label"
        if _proc_running "$bin"; then
            printf "    状态: ${C_GRN}✓ 运行中${C_RST} (PID: $(_proc_pid "$bin"))\n"
        else
            printf "    状态: ${C_RED}✗ 未运行${C_RST}\n"
        fi
        [ -f "$args_file" ] && \
            printf "    参数: ${C_DIM}%s${C_RST}\n" "$(tr '\n' ' ' < "$args_file")"
        # 附加 systemd 状态摘要（3行）
        if [ "$INIT_SYS" = "systemd" ]; then
            local svc_name
            [ "$bin" = "easytier-core" ] && svc_name="easytier" || svc_name="easytier-web"
            systemctl status "$svc_name" --no-pager -l 2>/dev/null | \
                sed -n '3,6p' | sed 's/^/         /' || true
        fi
        printf '\n'
    }

    _print_svc_block "easytier-core"      "easytier-core"      "/etc/easytier/core.args"
    _print_svc_block "easytier-web-embed" "easytier-web-embed" "/etc/easytier/web.args"

    printf "  ${C_BLD}[ 日志命令 ]${C_RST}\n"
    case "$INIT_SYS" in
        procd)
            printf "    easytier-core : logread -f | grep easytier\n"
            printf "    easytier-web  : logread -f | grep easytier-web\n"
            ;;
        systemd)
            printf "    easytier-core : journalctl -u easytier -f\n"
            [ -f /etc/systemd/system/easytier-web.service ] && \
                printf "    easytier-web  : journalctl -u easytier-web -f\n"
            ;;
        openrc)
            printf "    easytier-core : tail -f /var/log/easytier.log\n"
            [ -f /etc/init.d/easytier-web ] && \
                printf "    easytier-web  : tail -f /var/log/easytier-web.log\n"
            ;;
    esac
    printf "    安装日志      : %s\n" "$LOG_FILE"
}

# ==============================================================================
#  Web 控制台独立管理
# ==============================================================================
do_manage_web() {
    while true; do
        section "Web 控制台管理"

        if _proc_running "easytier-web-embed"; then
            local port=""
            [ -f /etc/easytier/web.args ] && \
                port=$(grep -A1 '^--api-server-port$' /etc/easytier/web.args 2>/dev/null \
                       | tail -1 | tr -d ' \t')
            printf "  状态: ${C_GRN}✓ 运行中${C_RST}${port:+  (端口 ${port})}\n"
        else
            printf "  状态: ${C_RED}✗ 未运行${C_RST}\n"
        fi
        [ -f /etc/easytier/web.args ] && \
            printf "  参数: ${C_DIM}%s${C_RST}\n" "$(tr '\n' ' ' < /etc/easytier/web.args)"

        printf '\n'
        printf "  ${C_BLD}1)${C_RST}  启动 / 重启\n"
        printf "  ${C_BLD}2)${C_RST}  停止\n"
        printf "  ${C_BLD}3)${C_RST}  重新配置（端口 / api-host 等）\n"
        printf "  ${C_BLD}4)${C_RST}  移除服务及配置\n"
        printf "  ${C_BLD}0)${C_RST}  返回主菜单\n\n"
        printf "  请选择 [0-4]: "
        read -r wc

        case "$wc" in
            0) return 0 ;;
            1)
                if [ ! -f /etc/easytier/web.args ]; then
                    msg_warn "未找到 web.args，请先执行「重新配置（3）」"
                    continue
                fi
                svc_stop_web 2>/dev/null || true
                svc_start_web
                local p=""
                [ -f /etc/easytier/web.args ] && \
                    p=$(grep -A1 '^--api-server-port$' /etc/easytier/web.args 2>/dev/null \
                        | tail -1 | tr -d ' \t')
                [ -n "$p" ] && wait_for_port "$p" 12
                check_proc easytier-web-embed "easytier-web-embed"
                ;;
            2) svc_stop_web && msg_ok "已停止" ;;
            3) setup_web_console ;;
            4)
                printf "  确认移除 web-embed 服务及配置文件? [y/N]: "
                read -r a
                case "$a" in
                    y|Y)
                        svc_stop_web; svc_remove_web
                        rm -f /etc/easytier/web.args
                        msg_ok "已移除"
                        ;;
                    *) msg_info "已取消" ;;
                esac
                ;;
            *) msg_warn "无效输入" ;;
        esac
    done
}

# ==============================================================================
#  文件位置展示
# ==============================================================================
show_file_locations() {
    section "已安装文件位置"

    printf "  ${C_BLD}[ 二进制 ]${C_RST}  /usr/bin/\n"
    for bin in easytier-core easytier-cli easytier-web easytier-web-embed; do
        if [ -f "/usr/bin/$bin" ]; then
            local size; size=$(du -sh "/usr/bin/$bin" 2>/dev/null | awk '{print $1}')
            printf "  ${C_GRN}✓${C_RST}  %-30s  %s\n" "$bin" "$size"
        else
            printf "  ${C_DIM}-  %-30s  (此版本未包含)${C_RST}\n" "$bin"
        fi
    done

    printf '\n'
    printf "  ${C_BLD}[ 配置 ]${C_RST}  /etc/easytier/\n"
    local cfg_found=false
    for f in config.toml core.args web.args; do
        if [ -f "/etc/easytier/$f" ]; then
            if [ "$f" = "config.toml" ]; then
                printf "  ${C_GRN}✓${C_RST}  %s\n" "$f"
            else
                printf "  ${C_GRN}✓${C_RST}  %-14s  ${C_DIM}%s${C_RST}\n" \
                    "$f" "$(tr '\n' ' ' < "/etc/easytier/$f")"
            fi
            cfg_found=true
        fi
    done
    [ "$cfg_found" = false ] && printf "  ${C_DIM}(无配置文件)${C_RST}\n"

    printf '\n'
    printf "  ${C_BLD}[ 服务文件 ]${C_RST}\n"
    local svc_found=false
    case "$INIT_SYS" in
        procd)
            for f in /etc/init.d/easytier /etc/init.d/easytier-web; do
                [ -f "$f" ] && printf "  ${C_GRN}✓${C_RST}  %s\n" "$f" && svc_found=true
            done ;;
        systemd)
            for f in /etc/systemd/system/easytier.service \
                     /etc/systemd/system/easytier-web.service; do
                [ -f "$f" ] && printf "  ${C_GRN}✓${C_RST}  %s\n" "$f" && svc_found=true
            done ;;
        openrc)
            for f in /etc/init.d/easytier /etc/init.d/easytier-web; do
                [ -f "$f" ] && printf "  ${C_GRN}✓${C_RST}  %s\n" "$f" && svc_found=true
            done ;;
    esac
    [ "$svc_found" = false ] && printf "  ${C_DIM}(无服务文件)${C_RST}\n"

    printf '\n'
    printf "  ${C_BLD}[ 历史备份 ]${C_RST}  /usr/bin/  ${C_DIM}(每个二进制保留最近 %d 份)${C_RST}\n" \
        "$ET_BACKUP_KEEP"
    local bak_list
    bak_list=$(ls /usr/bin/easytier-*.bak.* 2>/dev/null) || true
    if [ -n "$bak_list" ]; then
        printf '%s\n' "$bak_list" | while read -r f; do
            local size; size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
            printf "  ${C_DIM}*  %-44s  %s${C_RST}\n" "$(basename "$f")" "$size"
        done
    else
        printf "  ${C_DIM}(无备份文件)${C_RST}\n"
    fi

    printf '\n'
    printf "  ${C_BLD}[ 日志 ]${C_RST}\n"
    printf "  安装日志: %s\n" "$LOG_FILE"
    case "$INIT_SYS" in
        procd)   printf "  运行日志: logread -f | grep easytier\n" ;;
        systemd) printf "  运行日志: journalctl -u easytier -f\n"
                 [ -f /etc/systemd/system/easytier-web.service ] && \
                     printf "            journalctl -u easytier-web -f\n" ;;
        openrc)  printf "  运行日志: tail -f /var/log/easytier.log\n" ;;
    esac
}

# ==============================================================================
#  卸载
# ==============================================================================
do_uninstall() {
    section "卸载 EasyTier"
    printf "  ${C_YLW}⚠  此操作将移除所有 EasyTier 相关服务和二进制${C_RST}\n\n"
    printf "  确认卸载? [y/N/0=返回]: "
    read -r a
    case "$a" in
        0)    return 1 ;;
        y|Y)  ;;
        *)    msg_info "已取消"; return 1 ;;
    esac

    msg_info "停止并移除服务..."
    svc_stop; svc_stop_web
    svc_remove; svc_remove_web
    killall easytier-core      2>/dev/null || true
    killall easytier-web-embed 2>/dev/null || true
    for bin in easytier-core easytier-cli easytier-web easytier-web-embed; do
        rm -f "/usr/bin/$bin"
    done
    ip link del easytier0 2>/dev/null || true
    msg_ok "二进制及服务已移除"

    local bak_list
    bak_list=$(ls /usr/bin/easytier-*.bak.* 2>/dev/null) || true
    if [ -n "$bak_list" ]; then
        local bak_count
        bak_count=$(printf '%s\n' "$bak_list" | wc -l | tr -d ' ')
        printf "  删除 %d 个历史备份文件? [y/N]: " "$bak_count"
        read -r a
        case "$a" in
            y|Y) printf '%s\n' "$bak_list" | while read -r f; do rm -f "$f"; done
                 msg_ok "备份文件已清理" ;;
            *)   msg_info "备份文件已保留于 /usr/bin/" ;;
        esac
    fi

    printf "  删除配置目录 /etc/easytier? [y/N]: "
    read -r a
    case "$a" in
        y|Y) rm -rf /etc/easytier && msg_ok "配置目录已删除" ;;
        *)   msg_info "配置目录已保留: /etc/easytier" ;;
    esac
    msg_ok "卸载完成"
    return 0
}

# ==============================================================================
#  主菜单
# ==============================================================================
_print_header() {
    local cur="" mode_str="未配置" web_str=""

    [ -f /usr/bin/easytier-core ] && \
        cur=$(/usr/bin/easytier-core --version 2>&1 | awk '{print $2}' | cut -d'-' -f1)

    if [ -f /etc/easytier/core.args ]; then
        local first; first=$(head -1 /etc/easytier/core.args)
        case "$first" in
            --config-file) mode_str="TOML 配置文件" ;;
            -w)
                local wurl; wurl=$(sed -n '2p' /etc/easytier/core.args 2>/dev/null)
                mode_str="Web 控制台 (${wurl})"
                ;;
        esac
    fi

    if _proc_running "easytier-web-embed"; then
        local port=""
        [ -f /etc/easytier/web.args ] && \
            port=$(grep -A1 '^--api-server-port$' /etc/easytier/web.args 2>/dev/null \
                   | tail -1 | tr -d ' ')
        web_str="${C_GRN}✓ 运行中${C_RST}${port:+  (端口 ${port})}"
    elif [ -f /etc/easytier/web.args ]; then
        web_str="${C_YLW}✗ 已配置但未运行${C_RST}"
    fi

    # 分隔线不依赖内容宽度，彻底规避 CJK 双列字符的对齐问题
    local SEP="${C_BLD}  ──────────────────────────────────────────${C_RST}"
    printf "\n%s\n" "$SEP"
    printf "  ${C_BLD}  EasyTier 管理脚本${C_RST}  v%s\n" "$SCRIPT_VERSION"
    printf "%s\n" "$SEP"
    # 标签列（系统/架构/版本/配置）均为 CJK，视觉宽度 = 4 列
    # 值直接跟在标签后，无需右边框对齐
    printf "  系统  %-12s  架构  %s\n" "$OS_TYPE" "$ARCH_NAME"
    printf "  Init  %s\n" "$INIT_SYS"
    if [ -n "$cur" ]; then
        printf "  版本  %s\n" "$cur"
        printf "  配置  %s\n" "$mode_str"
        [ -n "$web_str" ] && printf "  Web   %s\n" "$web_str"
    else
        printf "  ${C_YLW}状态  未安装${C_RST}\n"
    fi
    printf "%s\n" "$SEP"
}

main() {
    _init_colors
    detect_system
    check_deps

    _log "INFO" "脚本启动 v${SCRIPT_VERSION} OS=${OS_TYPE} INIT=${INIT_SYS} ARCH=${ARCH_NAME}"

    while true; do
        _print_header

        printf '\n'
        if [ -f /usr/bin/easytier-core ]; then
            printf "  ${C_BLD}1)${C_RST}  更新 / 重装（选择版本）\n"
            printf "  ${C_BLD}2)${C_RST}  卸载\n"
            printf "  ${C_BLD}3)${C_RST}  重新配置并重启服务\n"
            printf "  ${C_BLD}4)${C_RST}  仅重启服务\n"
            printf "  ${C_BLD}5)${C_RST}  查看服务状态\n"
            printf "  ${C_BLD}6)${C_RST}  Web 控制台管理\n"
            printf "  ${C_BLD}7)${C_RST}  查看已安装文件位置\n"
            printf "  ${C_BLD}0)${C_RST}  退出\n"
        else
            printf "  ${C_BLD}1)${C_RST}  安装\n"
            printf "  ${C_BLD}0)${C_RST}  退出\n"
        fi
        printf "  ─────────────────────────────────────────────────\n"
        printf "  请选择: "
        read -r choice

        case "$choice" in

            # ── 退出 ────────────────────────────────────────────────
            0) printf "\n  再见\n\n"; _log "INFO" "脚本退出"; exit 0 ;;

            # ── 安装 / 更新 ─────────────────────────────────────────
            1)
                select_version || continue

                if [ -f /usr/bin/easytier-core ]; then
                    local cur latest
                    cur=$(/usr/bin/easytier-core --version 2>&1 | \
                          awk '{print $2}' | cut -d'-' -f1)
                    latest=$(printf '%s' "$VER" | sed 's/^v//')

                    section "更新方式"
                    printf "  ${C_BLD}1)${C_RST}  仅更新二进制（保留现有配置）\n"
                    printf "  ${C_BLD}2)${C_RST}  更新二进制并重新配置\n"
                    [ "$cur" = "$latest" ] && \
                        msg_warn "当前已是 ${VER}，选 1 将重装相同版本"
                    printf "  ${C_BLD}0)${C_RST}  返回\n\n"
                    printf "  请选择 [0-2，默认 1]: "
                    read -r up
                    [ -z "$up" ] && up=1

                    case "$up" in
                        0) continue ;;
                        1)
                            do_download "$VER" "$ARCH_NAME"  || continue
                            do_install_bins "$EXTRACT_DIR"   || continue
                            # 重写服务文件（systemd ExecStart 含版本路径，需更新）
                            [ -f /etc/easytier/core.args ] && svc_write_core || true
                            svc_start
                            check_proc easytier-core "easytier-core"
                            if [ -f /etc/easytier/web.args ]; then
                                svc_write_web; svc_start_web
                                check_proc easytier-web-embed "easytier-web-embed"
                            fi
                            ;;
                        2)
                            do_download "$VER" "$ARCH_NAME"  || continue
                            do_install_bins "$EXTRACT_DIR"   || continue
                            if do_setup_mode; then
                                svc_write_core; svc_stop 2>/dev/null || true
                                svc_start
                                check_proc easytier-core "easytier-core"
                            else
                                msg_warn "已跳过配置，二进制已更新但服务未重启"
                            fi
                            ;;
                        *) msg_warn "无效输入"; continue ;;
                    esac
                else
                    # 全新安装
                    do_download "$VER" "$ARCH_NAME"  || continue
                    do_install_bins "$EXTRACT_DIR"   || continue
                    if do_setup_mode; then
                        svc_write_core
                        svc_start
                        check_proc easytier-core "easytier-core"
                    else
                        msg_warn "二进制已安装，请稍后通过选项 3 完成配置"
                    fi
                fi
                show_file_locations
                ;;

            # ── 卸载 ────────────────────────────────────────────────
            2)
                [ -f /usr/bin/easytier-core ] || { msg_warn "EasyTier 未安装"; continue; }
                do_uninstall || true
                ;;

            # ── 重新配置 ─────────────────────────────────────────────
            3)
                [ -f /usr/bin/easytier-core ] || { msg_warn "EasyTier 未安装"; continue; }
                if do_setup_mode; then
                    svc_write_core
                    svc_stop 2>/dev/null || true
                    svc_start
                    check_proc easytier-core "easytier-core"
                fi
                ;;

            # ── 仅重启 ─────────────────────────────────────
            4)
                [ -f /usr/bin/easytier-core ] || { msg_warn "EasyTier 未安装"; continue; }
                msg_info "重启 easytier-core..."
                svc_restart
                check_proc easytier-core "easytier-core"
                if [ -f /etc/easytier/web.args ]; then
                    printf "  同时重启 easytier-web-embed? [Y/n]: "
                    read -r a
                    case "$a" in
                        n|N) ;;
                        *)  svc_restart_web
                            check_proc easytier-web-embed "easytier-web-embed" ;;
                    esac
                fi
                ;;

            # ── 状态 ───────────────────────────────────────
            5) do_view_status ;;

            # ── Web 管理 ───────────────────────────────────
            6)
                [ -f /usr/bin/easytier-web-embed ] || {
                    msg_warn "easytier-web-embed 未安装（此版本可能不包含）"
                    continue
                }
                do_manage_web
                ;;

            # ── 文件位置 ─────────────────────────────────────────────
            7) show_file_locations ;;

            *) msg_warn "无效输入" ;;
        esac

        printf "\n  按 Enter 返回主菜单..."
        read -r _
    done
}

main