#!/bin/sh
# ============================================================================
#  GENERATED FILE — do not edit. Source of truth: easytier.sh
#  Regenerate with:  sh tools/build-zh.sh
# ============================================================================
# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` — not POSIX strict, but widely supported (dash/busybox)
# shellcheck disable=SC2059  # printf format with color vars / t() — intentional for ANSI codes & i18n
# shellcheck disable=SC2155  # declare-and-assign — readable for local scalar capture
# ==============================================================================
#  easytier-manager.sh — EasyTier install & management script
#  Version: see SCRIPT_VERSION below (single source; menu title & logs both read it)
#  Repo: https://github.com/razaxq/easytier-manager
#  Upstream: https://github.com/EasyTier/EasyTier
#  License: MIT (c) 2026 razaxq
# ==============================================================================
#  Bilingual: one script, English + Chinese. Language pick order:
#    ET_LANG=en|zh   — explicit override (easytier.zh.sh wrapper sets ET_LANG=zh)
#    otherwise auto-detected from $LC_ALL / $LC_MESSAGES / $LANG (zh* → Chinese)
#    default: English
# ==============================================================================
#  Supported systems
#    OpenWrt   (procd)
#    Debian / Ubuntu / Raspbian  (systemd)
#    RHEL / Fedora / Rocky / AlmaLinux  (systemd)
#    Arch Linux / Manjaro  (systemd)
#    Alpine Linux  (openrc)
#  Supported archs: x86_64 / aarch64 / armv7 / riscv64
# ------------------------------------------------------------------------------
#  Non-interactive install (preset all params via env vars):
#    ET_NONINTERACTIVE=1         — skip all prompts, use defaults or the vars below
#    ET_LANG=en|zh               — force interface language
#    ET_VERSION=v2.4.5           — version to install
#    ET_MODE=toml|web            — config mode
#    ET_INSTANCE_NAME=mynode     — node instance name
#    ET_VIRTUAL_IP=10.0.0.1/24  — virtual IPv4 (with mask); omit when ET_DHCP=1
#    ET_DHCP=1                   — auto-assign the virtual IP via DHCP (skips ET_VIRTUAL_IP)
#    ET_LISTEN_PORT=11010        — base listen port (ws/wss use +1/+2); default 11010
#    ET_DEV_NAME=easytier0       — TUN device name
#    ET_NETWORK_NAME=mynet       — virtual network name
#    ET_NETWORK_SECRET=xxx       — network secret (auto-generated if empty)
#    ET_PEERS=tcp://a:11010,tcp://b:11010  — comma-separated peer list
#    ET_PROXY_CIDR=192.168.1.0/24,10.9.0.0/24  — subnet proxy CIDR(s), comma-separated (optional)
#    ET_WEB_URL=udp://host:22020/user      — Web mode join URL
#    ET_FILE_LOG_DIR=...                   — core log directory
#    ET_FILE_LOG_LEVEL=off|error|warn|info|debug|trace
#    ET_FILE_LOG_SIZE=<MB>                 — size per log file
#    ET_FILE_LOG_COUNT=<N>                 — number of logs to keep
#    ET_INSTALL_WEB_GUI=1                  — install easytier-web GUI client
#    ET_DEFAULT_VERSION=v2.4.5             — fallback version when GitHub API fails
#    ET_GITHUB_MIRROR=https://ghproxy.com  — prefix mirror for github.com downloads (helps in CN)
#    ET_GITHUB_API=https://api.github.com  — GitHub API base override (for an API mirror)
#    ET_GITHUB_TOKEN=<PAT>                 — lift the 60/h anonymous API rate limit (or GITHUB_TOKEN)
#    ET_SHA256=<hex>                       — expected sha256 of the release zip (integrity check)
#    ET_CACHE_TTL=600                      — seconds to reuse the cached release list (0 disables)
#    (curl also honors the standard https_proxy / http_proxy env vars)
# Note: defaults are in the ── Tunables ── section below; on procd (OpenWrt) BACKUP_KEEP/LOG_SIZE/LOG_COUNT
#     are auto-tightened by main() (values you set explicitly still win)
# ==============================================================================

SCRIPT_VERSION="2.6.0"

# ── Tunables ──────────────────────────────────────────
# These sentinels record whether the user set the vars explicitly; after detect_system, on procd we
# use them to decide whether to apply tighter defaults (explicit values win)
_u_backup=${ET_BACKUP_KEEP:+1}
_u_lsize=${ET_FILE_LOG_SIZE:+1}
_u_lcount=${ET_FILE_LOG_COUNT:+1}

ET_BACKUP_KEEP="${ET_BACKUP_KEEP:-3}"           # backups kept per binary
ET_RELEASES_COUNT="${ET_RELEASES_COUNT:-20}"    # max releases to fetch in the list
ET_INSTALL_WEB_GUI="${ET_INSTALL_WEB_GUI:-0}"   # 1=also install easytier-web GUI client
ET_DEFAULT_VERSION="${ET_DEFAULT_VERSION:-v2.4.5}"  # fallback version when GitHub API fails
LOG_FILE="${LOG_FILE:-/var/log/easytier-manager.log}"
TMP_DIR="/tmp/et_mgr_$$"

# GitHub access — mirror/proxy/token/integrity/cache (all optional; empty = plain github.com)
ET_GITHUB_API="${ET_GITHUB_API:-https://api.github.com}"   # API base (override for a mirror)
ET_GITHUB_MIRROR="${ET_GITHUB_MIRROR:-}"                    # ghproxy-style prefix for release downloads
ET_GITHUB_TOKEN="${ET_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"    # PAT to lift the 60/h anonymous rate limit
ET_SHA256="${ET_SHA256:-}"                                 # expected sha256 of the release zip (optional)
ET_CACHE_TTL="${ET_CACHE_TTL:-600}"                        # reuse cached release list within N seconds (0=off)
CACHE_DIR="${ET_CACHE_DIR:-${TMPDIR:-/tmp}/et_mgr_cache}"  # persists across runs (not wiped by _cleanup)

# All managed binaries (install / backup rotation / uninstall / status all iterate this list; add new binaries here only)
ET_ALL_BINS="easytier-core easytier-cli easytier-web easytier-web-embed"

# core file-log params — default avoids EasyTier writing 100MB×10 into the process cwd
# Note: on OpenWrt /var → /tmp (tmpfs), cleared on reboot; persistent on other distros
ET_FILE_LOG_DIR="${ET_FILE_LOG_DIR:-/var/log/easytier}"
ET_FILE_LOG_LEVEL="${ET_FILE_LOG_LEVEL:-error}"  # off|error|warn|info|debug|trace
ET_FILE_LOG_SIZE="${ET_FILE_LOG_SIZE:-10}"       # size per log file (MB)
ET_FILE_LOG_COUNT="${ET_FILE_LOG_COUNT:-5}"      # max log files to keep

# minimum free space in /tmp for download+extract (zip ~30MB + extracted ~80MB)
ET_MIN_TMP_MB="${ET_MIN_TMP_MB:-120}"

# ── Runtime state (filled by detection, do not edit by hand) ──────────────
OS_TYPE=""      # openwrt | debian | rhel | arch | alpine | unknown
INIT_SYS=""     # procd | systemd | openrc | unknown
ARCH_NAME=""    # x86_64 | aarch64 | armv7 | riscv64 | unknown
VER=""          # selected version (set by select_version; falls back to $ET_DEFAULT_VERSION)
EXTRACT_DIR=""  # extraction dir (set by do_download)
KEEP_BACKUP=0   # do_install_bins decides whether to back up; _install_extra_bin reuses it

# TOML wizard temp vars
_TOML_INSTANCE=""
_TOML_DHCP="0"          # 1 = auto-assign virtual IP via DHCP
_TOML_IP=""
_TOML_LISTEN_PORT=""    # base listen port; +1/+2 derive the ws/wss ports
_TOML_NET_NAME=""
_TOML_NET_SECRET=""
_TOML_PEERS=""          # space-separated
_TOML_PROXY_CIDRS=""    # space-separated (multiple subnet-proxy CIDRs)
_TOML_DEV_NAME=""       # TUN device name
_TOML_ENC="true"        # [flags] enable_encryption
_TOML_PRIVATE="true"    # [flags] private_mode
_TOML_EXITNODE="true"   # [flags] enable_exit_node
_TOML_COMPRESS="2"      # [flags] data_compress_algo

# ==============================================================================
#  i18n — one script, two languages. t "<english>" "<chinese>" prints the right one.
#  Rules of thumb used throughout:
#    · plain text line          → printf '%s\n' "$(t "EN" "ZH")"
#    · prompt (no newline)      → printf '%s'   "$(t "EN " "ZH ")"
#    · line with printf args    → printf "$(t "FMT_EN" "FMT_ZH")" args…   (color vars/%-specifiers kept in the format)
#  _log() diagnostic strings intentionally stay English for greppable logs.
# ==============================================================================
# ET_LANG_DEFAULT is the only line that differs between easytier.sh (en) and the
# generated easytier.zh.sh (zh). tools/build-zh.sh flips it. Do not rename the marker.
ET_LANG_DEFAULT="zh"        # et:lang-default
_LANG="en"
_detect_lang() {
    case "${ET_LANG:-}" in
        zh|zh[_-]*|ZH|Zh) _LANG="zh"; return ;;
        en|en[_-]*|EN|En) _LANG="en"; return ;;
        '') ;;                      # unset → decide below
        *)  _LANG="en"; return ;;
    esac
    # ET_LANG unset: the zh build forces zh; the en build auto-detects from locale
    if [ "$ET_LANG_DEFAULT" = "zh" ]; then _LANG="zh"; return; fi
    case "${LC_ALL:-}${LC_MESSAGES:-}${LANG:-}" in
        *zh*|*ZH*) _LANG="zh" ;;
        *)         _LANG="en" ;;
    esac
}
_detect_lang
t() { [ "$_LANG" = "zh" ] && printf '%s' "$2" || printf '%s' "$1"; }

# ==============================================================================
#  Colors & output (tty detection; falls back to no color when not a terminal)
# ==============================================================================
_init_colors() {
    if [ -t 1 ]; then
        # printf command substitution produces real ESC bytes (0x1b), not the literal string \033
        # color vars work both in printf format strings and when embedded in vars printed via %s
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

# Section heading
section() {
    local title="$1"
    local len="${#title}"
    printf "\n${C_BLD}  %s${C_RST}\n" "$title"
    printf "  "
    local i=0; while [ "$i" -lt $((len + 2)) ]; do printf "─"; i=$((i+1)); done
    printf "\n\n"
}

# ==============================================================================
#  Logging (append to file; failures silently ignored)
# ==============================================================================
_log() {
    local level="$1"; shift
    # subshell so a failed redirect (e.g. LOG_FILE dir missing) is swallowed, not printed by the shell
    ( printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE" ) 2>/dev/null || true
}

# ==============================================================================
#  Cleanup & signal handling (Ctrl+C exits safely anywhere; critical sections abort safely too)
#
#  Design:
#   - EXIT trap always cleans the temp dir and any leftover atomic-write temp files.
#   - INT/TERM/HUP → _on_signal: print a notice then exit 130; EXIT trap does cleanup.
#     Covers menus, input, downloads, waits, etc. — safe to interrupt almost anywhere.
#   - Critical operations that mutate system state (moving binaries, writing config/service files) are
#     wrapped by crit_begin/crit_end using a "write temp → checkpoint crit_ck → atomic same-fs rename" transaction:
#       · an interrupt inside the section is only "recorded", not acted on immediately, so code reaches a checkpoint;
#       · a checkpoint / the end finding a pending interrupt → delete the uncommitted temp file, exit safely;
#       · the target file is replaced only via an atomic mv rename — at any instant it is either the old or the new complete version,
#         never truncated or missing — so Ctrl+C inside a section can discard the current op and exit at any time.
# ==============================================================================
_cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
    # fallback cleanup of THIS run's atomic-write temp files only (named *.tmp.$$),
    # so a concurrent instance's in-flight temp files are never clobbered
    rm -f /etc/easytier/*.tmp.$$      /usr/bin/*.tmp.$$ \
          /etc/init.d/*.tmp.$$        /etc/systemd/system/*.tmp.$$ 2>/dev/null || true
}

_on_signal() {
    printf '\n'
    msg_warn "$(t "Interrupt received, exiting safely…" "收到中断信号，正在安全退出…")"
    exit 130     # triggers the EXIT trap for cleanup
}

trap '_cleanup'   EXIT
trap '_on_signal' INT TERM HUP

# ── Critical section (safely-interruptible atomic-write transaction) ──────────────────────────
_SIG_PENDING=0

# Enter critical section: interrupts are only recorded (not exited on) so we can reach a checkpoint and safely discard uncommitted changes
crit_begin() { _SIG_PENDING=0; trap '_SIG_PENDING=1' INT TERM HUP; }

# Checkpoint: if an interrupt was pressed in the section → delete the given uncommitted temp file(s) and exit safely (target untouched)
crit_ck() {
    [ "$_SIG_PENDING" = "1" ] || return 0
    [ "$#" -gt 0 ] && rm -f "$@" 2>/dev/null
    trap '_on_signal' INT TERM HUP
    printf '\n'
    msg_warn "$(t "Interrupted as requested; uncommitted changes discarded, exiting safely" "已按请求中断，未提交的改动已丢弃，安全退出")"
    exit 130
}

# Leave critical section: restore normal signal handling; if interrupted during it (commit already done atomically), exit safely
crit_end() {
    trap '_on_signal' INT TERM HUP
    if [ "$_SIG_PENDING" = "1" ]; then
        printf '\n'
        msg_warn "$(t "Current operation completed; exiting safely as requested" "当前操作已完成，按您的请求安全退出")"
        exit 130
    fi
    return 0
}

# Atomic commit: set perms → checkpoint (interruptible/discardable) → atomic same-fs rename onto target
# Usage: _commit_tmp <tmp> <target> [chmod mode]
_commit_tmp() {
    local tmp="$1" target="$2" mode="${3:-}"
    [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null
    crit_ck "$tmp"
    mv -f "$tmp" "$target"
}

# ==============================================================================
#  Dependency check
# ==============================================================================
check_deps() {
    local missing=''
    for cmd in curl unzip; do
        command -v "$cmd" > /dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] && return 0

    msg_err "$(t "Missing dependencies:${missing}" "缺少依赖:${missing}")"
    case "$OS_TYPE" in
        openwrt) msg_info "opkg update && opkg install${missing}" ;;
        alpine)  msg_info "apk add${missing}" ;;
        debian)  msg_info "apt-get install -y${missing}" ;;
        rhel)    msg_info "dnf install -y${missing}" ;;
        arch)    msg_info "pacman -S${missing}" ;;
        *)       msg_info "$(t "Install via your system package manager:${missing}" "请通过系统包管理器安装:${missing}")" ;;
    esac
    die "$(t "Please install the missing dependencies and re-run" "请先安装缺少的依赖后重新运行")"
}

# ==============================================================================
#  System & architecture detection
# ==============================================================================
detect_system() {
    # ── Init system / OS type ──────────────────────────
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

    # ── CPU architecture ─────────────────────────────────────
    case "$(uname -m)" in
        x86_64|amd64)   ARCH_NAME="x86_64"  ;;
        aarch64|arm64)  ARCH_NAME="aarch64" ;;
        armv7l|armv7)   ARCH_NAME="armv7"   ;;
        riscv64)        ARCH_NAME="riscv64" ;;
        *)
            ARCH_NAME="unknown"
            msg_warn "$(t "Unrecognized arch: $(uname -m); EasyTier may not support this platform" "未识别架构: $(uname -m)，EasyTier 可能不支持此平台")"
            ;;
    esac

    _log "INFO" "Detected: OS=${OS_TYPE} INIT=${INIT_SYS} ARCH=${ARCH_NAME}"
}

# ==============================================================================
#  Process & port helpers
# ==============================================================================
# Return all PIDs whose cmdline contains /usr/bin/<bin>. Prefer pgrep -f (match by full path,
# avoiding the 15-char process-name truncation); if pgrep is missing, fall back to scanning /proc (BusyBox/OpenWrt
# slim firmware often lacks pgrep, and all targets are Linux where /proc always exists, so the fallback is reliable).
_pids_of() {
    if command -v pgrep > /dev/null 2>&1; then
        pgrep -f "/usr/bin/${1}" 2>/dev/null
        return
    fi
    local p cmd
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
        case "$cmd" in *"/usr/bin/${1}"*) printf '%s\n' "${p##*/}" ;; esac
    done
}
_proc_running() { [ -n "$(_pids_of "$1")" ]; }
_proc_pid()     { _pids_of "$1" | head -1; }

# Kill all processes of the given binary (replaces killall, avoiding its 15-char name truncation & absence)
_kill_bin() {
    local pids
    pids=$(_pids_of "$1" | tr '\n' ' ')
    [ -n "$pids" ] && kill $pids 2>/dev/null || true
    return 0
}

# Run easytier-cli <args…> with a short timeout (avoids hanging if the RPC portal is down).
# Prints stdout only; caller decides what to do with empty output.
_cli() {
    [ -x /usr/bin/easytier-cli ] || return 1
    if command -v timeout > /dev/null 2>&1; then
        timeout 5 /usr/bin/easytier-cli "$@" 2>/dev/null
    else
        /usr/bin/easytier-cli "$@" 2>/dev/null
    fi
}

check_proc() {
    local bin="$1" label="${2:-$1}"
    sleep 2
    if _proc_running "$bin"; then
        local pid; pid=$(_proc_pid "$bin")
        msg_ok "$(t "${label} running (PID: ${pid})" "${label} 运行中 (PID: ${pid})")"
        return 0
    fi
    msg_warn "$(t "${label} process not detected; check the logs" "${label} 未检测到进程，请查看日志")"
    return 1
}

# Poll for port readiness: prefer nc, fall back to /proc/net/tcp
wait_for_port() {
    local port="$1" timeout="${2:-12}" i=0
    printf "$(t "    Waiting for port %s" "    等待端口 %s 就绪")" "$port"
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
    printf " ${C_YLW}$(t "(timeout)" "(超时)")${C_RST}\n"
    msg_warn "$(t "Port ${port} not ready; check the logs" "端口 ${port} 未就绪，请检查日志")"
    return 1
}

# ==============================================================================
#  Input validation
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

# Yes/No prompt with a default. $1 prompt  $2 default(y|n) → return 0 = yes, 1 = no
_ask_flag() {
    printf '%s' "$1"
    local a; read -r a
    [ -z "$a" ] && a="$2"
    case "$a" in
        y|Y) return 0 ;;
        n|N) return 1 ;;
        *)   [ "$2" = "y" ] && return 0 || return 1 ;;
    esac
}

# Return free space (MB) of the filesystem holding the path; empty on failure
# Uses POSIX df -kP (supported on OpenWrt busybox / Alpine; -P avoids device-name wrap breaking columns)
_avail_mb() {
    df -kP "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}'
}

# Check whether free space at path >= need_mb; in non-interactive mode die if short, otherwise ask
# $1 path  $2 need_mb  $3 label
_check_space() {
    local path="$1" need="$2" label="$3"
    local have; have=$(_avail_mb "$path")
    [ -z "$have" ] && return 0          # df failed: skip the check rather than block
    [ "$have" -ge "$need" ] && return 0
    msg_warn "$(t "${label} low on space: ${have}MB free / ~${need}MB needed" "${label} 空间不足: 可用 ${have}MB / 需要约 ${need}MB")"
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        die "$(t "${label} out of space; refusing to continue in non-interactive mode" "${label} 空间不足，非交互模式拒绝继续")"
    fi
    printf '%s' "$(t "  Continue anyway? [y/N]: " "  仍要继续? [y/N]: ")"
    local a; read -r a
    case "$a" in y|Y) return 0 ;; *) return 1 ;; esac
}

# Generate a random secret (all three paths output 64 hex chars)
gen_secret() {
    local s=""
    if command -v openssl > /dev/null 2>&1; then
        s=$(openssl rand -hex 32)
    elif [ -r /dev/urandom ]; then
        s=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | \
            od -An -tx1 | tr -d ' \n' | head -c 64)
    else
        # Last resort (low strength, emergency only). $RANDOM works in busybox ash; falls back to 0 when POSIX-undefined.
        # shellcheck disable=SC3028
        while [ "${#s}" -lt 64 ]; do
            s="${s}$(printf '%s%s%s' "$(date +%s 2>/dev/null)" "$$" "${RANDOM:-0}" | \
                od -An -tx1 | tr -d ' \n')"
        done
        s=$(printf '%s' "$s" | head -c 64)
        # send the warning to stderr so it isn't captured with the secret by $(gen_secret)
        msg_warn "$(t "Cannot read /dev/urandom; secret is weak, replace it manually before production" "无法读取 /dev/urandom，密钥强度较低，建议上线前手动替换")" >&2
    fi
    printf '%s\n' "$s"
}

# ==============================================================================
#  Service management — unified entry, branching on INIT_SYS
# ==============================================================================
# ── Internal impl: operate on the given service name, branching on INIT_SYS (core→easytier, web→easytier-web) ──
_svc_stop() {
    local name="$1"
    case "$INIT_SYS" in
        procd)   [ -f "/etc/init.d/$name" ] && "/etc/init.d/$name" stop 2>/dev/null || true ;;
        systemd) systemctl stop "$name"  2>/dev/null || true ;;
        openrc)  rc-service "$name" stop 2>/dev/null || true ;;
    esac
}

_svc_start() {
    local name="$1"
    case "$INIT_SYS" in
        procd)   "/etc/init.d/$name" enable && "/etc/init.d/$name" start ;;
        systemd) systemctl daemon-reload && systemctl enable "$name" && systemctl start "$name" ;;
        openrc)  rc-update add "$name" default 2>/dev/null; rc-service "$name" start ;;
    esac
}

_svc_restart() {
    local name="$1"
    case "$INIT_SYS" in
        procd)   "/etc/init.d/$name" restart 2>/dev/null || true ;;
        systemd) systemctl restart "$name"   2>/dev/null || true ;;
        openrc)  rc-service "$name" restart  2>/dev/null || true ;;
    esac
}

_svc_remove() {
    local name="$1"
    case "$INIT_SYS" in
        procd)
            [ -f "/etc/init.d/$name" ] && {
                "/etc/init.d/$name" disable 2>/dev/null || true
                rm -f "/etc/init.d/$name"
            } ;;
        systemd)
            systemctl disable "$name" 2>/dev/null || true
            rm -f "/etc/systemd/system/${name}.service"
            systemctl daemon-reload 2>/dev/null || true ;;
        openrc)
            rc-update del "$name" default 2>/dev/null || true
            rm -f "/etc/init.d/$name" ;;
    esac
}

# ── Public entries: core and web services, thin wrappers over the generic impl above ──
svc_stop()        { _svc_stop    easytier;     }
svc_start()       { _svc_start   easytier;     }
svc_restart()     { _svc_restart easytier;     }
svc_remove()      { _svc_remove  easytier;     }
svc_stop_web()    { _svc_stop    easytier-web; }
svc_start_web()   { _svc_start   easytier-web; }
svc_restart_web() { _svc_restart easytier-web; }
svc_remove_web()  { _svc_remove  easytier-web; }

# ==============================================================================
#  Service file writer — core
# ==============================================================================
svc_write_core() {
    [ -f /etc/easytier/core.args ] || { msg_err "$(t "core.args not found" "core.args 不存在")"; return 1; }

    # systemd / openrc need the multi-line args merged into a single line
    local args_line
    args_line=$(tr '\n' ' ' < /etc/easytier/core.args | sed 's/[[:space:]]*$//')

    # normalize unknown init to systemd up front, to avoid recursing inside the critical section
    case "$INIT_SYS" in procd|systemd|openrc) ;;
        *) msg_warn "$(t "Unknown init system; writing systemd format, adjust manually" "未知 init 系统，按 systemd 格式写入，请手动调整")"; INIT_SYS="systemd" ;;
    esac

    crit_begin   # critical section: atomic write of the service file (interruptible, never truncated)
    case "$INIT_SYS" in

        procd)
            # first part: the section with variable expansion
            cat > /etc/init.d/easytier.tmp.$$ << EOF
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
            _commit_tmp /etc/init.d/easytier.tmp.$$ /etc/init.d/easytier 755
            ;;

        systemd)
            cat > /etc/systemd/system/easytier.service.tmp.$$ << EOF
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
# Hardening — kept conservative so TUN creation, routing and forwarding still work
# (deliberately NOT setting ProtectKernelTunables/Modules or a CapabilityBoundingSet).
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
RestrictSUIDSGID=true
ReadWritePaths=${ET_FILE_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF
            _commit_tmp /etc/systemd/system/easytier.service.tmp.$$ /etc/systemd/system/easytier.service 644
            ;;

        openrc)
            cat > /etc/init.d/easytier.tmp.$$ << EOF
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
            _commit_tmp /etc/init.d/easytier.tmp.$$ /etc/init.d/easytier 755
            ;;
    esac
    crit_end
    msg_ok "$(t "easytier-core service file written" "easytier-core 服务文件已写入")"
}

# ==============================================================================
#  Service file writer — web-embed
# ==============================================================================
svc_write_web() {
    [ -f /etc/easytier/web.args ] || { msg_err "$(t "web.args not found" "web.args 不存在")"; return 1; }

    local args_line
    args_line=$(tr '\n' ' ' < /etc/easytier/web.args | sed 's/[[:space:]]*$//')

    # normalize unknown init to systemd up front, to avoid recursing inside the critical section
    case "$INIT_SYS" in procd|systemd|openrc) ;;
        *) msg_warn "$(t "Unknown init system; writing systemd format" "未知 init 系统，按 systemd 格式写入")"; INIT_SYS="systemd" ;;
    esac

    crit_begin   # critical section: atomic write of the service file
    case "$INIT_SYS" in

        procd)
            cat > /etc/init.d/easytier-web.tmp.$$ << EOF
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
            _commit_tmp /etc/init.d/easytier-web.tmp.$$ /etc/init.d/easytier-web 755
            ;;

        systemd)
            cat > /etc/systemd/system/easytier-web.service.tmp.$$ << EOF
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
# Minimal hardening — kept light so account/data persistence (storage path unknown) is not broken
NoNewPrivileges=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
            _commit_tmp /etc/systemd/system/easytier-web.service.tmp.$$ /etc/systemd/system/easytier-web.service 644
            ;;

        openrc)
            cat > /etc/init.d/easytier-web.tmp.$$ << EOF
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
            _commit_tmp /etc/init.d/easytier-web.tmp.$$ /etc/init.d/easytier-web 755
            ;;
    esac
    crit_end
    msg_ok "$(t "easytier-web-embed service file written" "easytier-web-embed 服务文件已写入")"
}

# ==============================================================================
#  GitHub access helpers — mirror / token / integrity / mtime
# ==============================================================================
# Portable file mtime in epoch seconds (empty on failure)
_mtime() {
    date -r "$1" +%s 2>/dev/null || stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Apply the ghproxy-style download mirror prefix to a full github.com URL
_mirror_url() {
    if [ -n "$ET_GITHUB_MIRROR" ]; then
        printf '%s/%s' "${ET_GITHUB_MIRROR%/}" "$1"
    else
        printf '%s' "$1"
    fi
}

# Fetch a GitHub API URL; adds an auth header when a token is set. Prints body, returns curl status.
_gh_api() {
    if [ -n "$ET_GITHUB_TOKEN" ]; then
        curl -sf --connect-timeout 10 \
            -H "Authorization: Bearer $ET_GITHUB_TOKEN" \
            -H "X-GitHub-Api-Version: 2022-11-28" "$1"
    else
        curl -sf --connect-timeout 10 "$1"
    fi
}

# Verify a file's sha256 against an expected hex (case-insensitive). Skips gracefully if no tool.
_verify_sha256() {
    local f="$1" want="$2" got=""
    if command -v sha256sum > /dev/null 2>&1; then
        got=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
    elif command -v shasum > /dev/null 2>&1; then
        got=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
    elif command -v openssl > /dev/null 2>&1; then
        got=$(openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}')
    else
        msg_warn "$(t "No sha256 tool available; skipping integrity check" "无 sha256 工具，跳过完整性校验")"
        return 0
    fi
    if [ "$(printf '%s' "$got" | tr 'A-F' 'a-f')" = "$(printf '%s' "$want" | tr 'A-F' 'a-f')" ]; then
        msg_ok "$(t "SHA256 verified" "SHA256 校验通过")"
        return 0
    fi
    msg_err "$(t "SHA256 mismatch — expected ${want}, got ${got}" "SHA256 不匹配 — 期望 ${want}，实际 ${got}")"
    return 1
}

# ==============================================================================
#  Version selection
#
#  Shows release date (GitHub published_at)
#  Returns 0 = selected ($VER)   1 = user chose 0 to go back
# ==============================================================================
select_version() {
    # non-interactive mode: use the env var directly
    if [ -n "${ET_VERSION:-}" ]; then
        VER="$ET_VERSION"
        msg_ok "$(t "Using preset version: $VER" "使用预设版本: $VER")"
        return 0
    fi

    section "$(t "Select version to install" "选择安装版本")"

    local api_url="${ET_GITHUB_API%/}/repos/EasyTier/EasyTier/releases?per_page=${ET_RELEASES_COUNT}"
    local cache_file="${CACHE_DIR}/releases_${ET_RELEASES_COUNT}.json"
    local json=""

    # reuse a fresh cached list to avoid hammering the API (and the 60/h anon limit)
    if [ "$ET_CACHE_TTL" -gt 0 ] && [ -f "$cache_file" ]; then
        local m age; m=$(_mtime "$cache_file")
        if [ -n "$m" ]; then
            age=$(( $(date +%s) - m ))
            if [ "$age" -ge 0 ] && [ "$age" -lt "$ET_CACHE_TTL" ]; then
                json=$(cat "$cache_file" 2>/dev/null)
                [ -n "$json" ] && msg_info "$(t "Using cached release list (${age}s old)" "使用缓存的版本列表（${age}s 前）")"
            fi
        fi
    fi

    if [ -z "$json" ]; then
        msg_info "$(t "Fetching release list from GitHub..." "正在从 GitHub 获取版本列表...")"
        json=$(_gh_api "$api_url") || true
        # cache a successful fetch for next time
        if [ -n "$json" ] && [ "$ET_CACHE_TTL" -gt 0 ]; then
            mkdir -p "$CACHE_DIR" 2>/dev/null && printf '%s' "$json" > "$cache_file" 2>/dev/null || true
        fi
    fi

    mkdir -p "$TMP_DIR"
    local rel_file="${TMP_DIR}/releases.txt"

    if [ -z "$json" ]; then
        msg_warn "$(t "Failed to fetch the release list from GitHub" "从 GitHub 获取版本列表失败")"
        [ -z "$ET_GITHUB_TOKEN" ] && msg_info "$(t "If rate-limited, set ET_GITHUB_TOKEN=<PAT>, or use ET_GITHUB_MIRROR / https_proxy for a mirror" "若被限流，可设置 ET_GITHUB_TOKEN=<PAT>，或用 ET_GITHUB_MIRROR / https_proxy 走镜像/代理")"
        msg_warn "$(t "Falling back to built-in default ${ET_DEFAULT_VERSION}" "回退到内置默认版本 ${ET_DEFAULT_VERSION}")"
        VER="$ET_DEFAULT_VERSION"; return 0
    fi

    # Parsing logic:
    #   on tag_name  → reset and start collecting a new entry
    #   on published_at → take the date part (YYYY-MM-DD)
    #   on prerelease → once all three fields are set, emit a line, then reset
    # does not depend on the field order in the JSON
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
                # new entry starts, reset the three fields
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
                gsub(/T.*$/, "", val)   # keep only YYYY-MM-DD
                if (val == "null") val = ""   # draft releases have no date → blank it to skip the entry
                date = val
            }
            else if (index($0, "\"prerelease\"") > 0) {
                pre = (index($0, "true") > 0) ? "pre" : "stable"
                # prerelease is usually one of the last fields, try emitting here
                if (tag != "" && date != "" && pre != "") {
                    print tag, pre, date
                    tag = ""; date = ""; pre = ""
                }
            }
        }
        END {
            # emit the last entry (if not already flushed by a tag_name reset)
            if (tag != "" && date != "" && pre != "")
                print tag, pre, date
        }
    ' > "$rel_file"

    local count
    count=$(wc -l < "$rel_file" | tr -d ' \t')

    if [ "$count" -eq 0 ]; then
        msg_warn "$(t "Parse failed; falling back to built-in default ${ET_DEFAULT_VERSION}" "解析失败，回退到内置默认版本 ${ET_DEFAULT_VERSION}")"
        VER="$ET_DEFAULT_VERSION"; return 0
    fi

    # non-interactive and no explicit ET_VERSION: take the first (latest) entry, skip interactive selection
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        VER=$(sed -n '1p' "$rel_file" | awk '{print $1}')
        [ -z "$VER" ] && VER="$ET_DEFAULT_VERSION"
        msg_ok "$(t "Non-interactive: using latest version ${VER}" "非交互：使用最新版本 ${VER}")"
        return 0
    fi

    while true; do
        # header (all ASCII, strictly aligned with the %-16s %-14s columns of the data rows below)
        printf "  ${C_BLD}%4s  %-16s  %-14s  %s${C_RST}\n" \
            "No." "Version" "$(t "Type" "类型")" "$(t "Date" "日期")"
        printf "  %s\n" \
            "────────────────────────────────────────────────────"

        # single pass over the file (fields are "tag pre date" per line)
        local i=0 tag pre date label clr
        while read -r tag pre date; do
            i=$((i + 1))
            if [ "$pre" = "stable" ]; then
                label="[stable]    "; clr="$C_GRN"
            else
                label="[pre-release]"; clr="$C_YLW"
            fi
            printf "  ${C_BLD}%3d)${C_RST}  %-16s  ${clr}%-14s${C_RST}  ${C_DIM}%s${C_RST}\n" \
                "$i" "$tag" "$label" "$date"
        done < "$rel_file"

        printf "  ${C_BLD}%3s)${C_RST}  $(t "Back" "返回")\n" "0"
        printf "  %s\n" \
            "────────────────────────────────────────────────────"
        printf "$(t "  Select [0-%d, default 1]: " "  选择 [0-%d，默认 1]: ")" "$count"
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
            msg_ok "$(t "Selected: ${VER}  (released ${chosen_date})" "已选择: ${VER}  (发布于 ${chosen_date})")"
            return 0
        fi
        msg_warn "$(t "Invalid input, please choose again" "无效输入，请重新选择")"
    done
}

# ==============================================================================
#  Download (verify first, stop services only after success)
# ==============================================================================
do_download() {
    local ver="$1" arch="$2"

    [ "$arch" = "unknown" ] && \
        die "$(t "Unrecognized arch $(uname -m); download manually from https://github.com/EasyTier/EasyTier/releases" "无法识别架构 $(uname -m)，请访问 https://github.com/EasyTier/EasyTier/releases 手动下载")"

    local zip_name="easytier-linux-${arch}-${ver}.zip"
    local url="https://github.com/EasyTier/EasyTier/releases/download/${ver}/${zip_name}"
    local dl_url; dl_url=$(_mirror_url "$url")
    local zip_path="${TMP_DIR}/${zip_name}"

    section "$(t "Download EasyTier" "下载 EasyTier")"
    msg_info "$(t "Version: ${ver}  Arch: ${arch}" "版本: ${ver}  架构: ${arch}")"
    msg_info "URL:  ${dl_url}"
    [ -n "$ET_GITHUB_MIRROR" ] && msg_info "$(t "(via mirror ${ET_GITHUB_MIRROR})" "(经镜像 ${ET_GITHUB_MIRROR})")"

    # /tmp must hold at least the zip (~30MB) + extracted contents (~80MB)
    _check_space "/tmp" "$ET_MIN_TMP_MB" "$(t "/tmp (download + extract)" "/tmp (下载 + 解压)")" || return 1

    mkdir -p "$TMP_DIR"
    if ! curl -L --progress-bar --retry 3 --retry-delay 3 --connect-timeout 15 \
            -o "$zip_path" "$dl_url"; then
        msg_err "$(t "Download failed; check your network or the version number" "下载失败，请检查网络连接或版本号")"
        [ -n "$ET_GITHUB_MIRROR" ] && msg_info "$(t "The mirror may be down; try without ET_GITHUB_MIRROR or a different one" "镜像可能不可用；可去掉 ET_GITHUB_MIRROR 或换一个")"
        return 1
    fi

    # sanity: a mirror/proxy error page is HTML, not a zip — real zips start with the "PK" magic
    if [ "$(dd if="$zip_path" bs=2 count=1 2>/dev/null)" != "PK" ]; then
        msg_err "$(t "Downloaded file is not a valid zip (mirror/proxy returned an error page?)" "下载文件不是有效 zip（镜像/代理返回了错误页？）")"
        return 1
    fi

    # optional integrity check against a caller-provided sha256
    if [ -n "$ET_SHA256" ]; then
        _verify_sha256 "$zip_path" "$ET_SHA256" || return 1
    fi

    msg_info "$(t "Extracting..." "解压中...")"
    if ! unzip -o "$zip_path" -d "${TMP_DIR}/"; then
        msg_err "$(t "Extraction failed" "解压失败")"
        case "$OS_TYPE" in
            openwrt) msg_info "$(t "First run: opkg install unzip" "请先: opkg install unzip")" ;;
            alpine)  msg_info "$(t "First run: apk add unzip" "请先: apk add unzip")" ;;
            debian)  msg_info "$(t "First run: apt-get install -y unzip" "请先: apt-get install -y unzip")" ;;
            rhel)    msg_info "$(t "First run: dnf install -y unzip" "请先: dnf install -y unzip")" ;;
            arch)    msg_info "$(t "First run: pacman -S unzip" "请先: pacman -S unzip")" ;;
        esac
        return 1
    fi

    local core_path
    core_path=$(find "$TMP_DIR" -maxdepth 2 -name "easytier-core" -type f 2>/dev/null | head -1)
    [ -z "$core_path" ] && { msg_err "$(t "easytier-core not found after extraction (is the version correct?)" "解压后未找到 easytier-core（版本号是否正确？）")"; return 1; }

    EXTRACT_DIR=$(dirname "$core_path")
    msg_ok "$(t "Download and extraction complete" "下载并解压完成")"
    return 0
}

# ==============================================================================
#  Install binaries (stop services only after download verified)
# ==============================================================================
do_install_bins() {
    local extract_dir="$1"

    msg_info "$(t "Stopping running services..." "停止运行中的服务...")"
    svc_stop; svc_stop_web

    local ts; ts=$(date +%s)
    local installed=0

    # by default install only core+cli (node essentials); others added on demand / if previously installed
    # — easytier-web GUI only when ET_INSTALL_WEB_GUI=1
    # — already-deployed extra binaries always upgrade too, avoiding web-embed version skew after a core upgrade
    local install_list="easytier-core easytier-cli"
    [ "$ET_INSTALL_WEB_GUI" = "1" ] && install_list="$install_list easytier-web"
    for _bin in easytier-web easytier-web-embed; do
        case " $install_list " in
            *" $_bin "*) ;;
            *) [ -f "/usr/bin/$_bin" ] && install_list="$install_list $_bin" ;;
        esac
    done

    # decide whether to back up old binaries (no backup by default; ask when an old version exists)
    KEEP_BACKUP=0
    local has_existing=0
    for bin in $ET_ALL_BINS; do
        [ -f "/usr/bin/$bin" ] && { has_existing=1; break; }
    done
    if [ "$has_existing" = "1" ]; then
        if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
            # non-interactive: ET_BACKUP_KEEP=0 means no backup; >0 backs up and keeps that many
            [ "$ET_BACKUP_KEEP" -gt 0 ] && KEEP_BACKUP=1
        else
            printf '%s' "$(t "  Keep old binaries as backups (.bak.<ts>)? [y/N]: " "  保留旧二进制为备份 (.bak.<ts>)? [y/N]: ")"
            read -r a
            case "$a" in y|Y) KEEP_BACKUP=1 ;; esac
        fi
    fi

    # estimate total size of binaries to install, for a /usr/bin space precheck
    local need_mb=0
    for bin in $install_list; do
        if [ -f "${extract_dir}/${bin}" ]; then
            local kb; kb=$(du -sk "${extract_dir}/${bin}" 2>/dev/null | awk '{print $1}')
            [ -n "$kb" ] && need_mb=$(( need_mb + (kb / 1024) + 1 ))
        fi
    done
    [ "$need_mb" -gt 0 ] && { _check_space "/usr/bin" "$need_mb" "/usr/bin" || return 1; }

    section "$(t "Installing binaries → /usr/bin/" "安装二进制文件 → /usr/bin/")"
    # critical section (transactional): each binary is copied to a temp name on the target fs, an interruptible checkpoint, then an atomic rename.
    # on interrupt: the uncommitted current binary is discarded and the original untouched; already-committed ones stay intact.
    crit_begin
    for bin in $ET_ALL_BINS; do
        local will_install=0
        for w in $install_list; do [ "$w" = "$bin" ] && will_install=1 && break; done
        if [ "$will_install" = "1" ] && [ -f "${extract_dir}/${bin}" ]; then
            local _new="/usr/bin/${bin}.tmp.$$"
            cp "${extract_dir}/${bin}" "$_new"      # slow copy to a temp name on the target fs (interruptible/discardable)
            chmod +x "$_new"
            crit_ck "$_new"                          # checkpoint: delete temp, exit safely (original binary unchanged)
            if [ "$KEEP_BACKUP" = "1" ] && [ -f "/usr/bin/$bin" ]; then
                cp -p "/usr/bin/$bin" "/usr/bin/${bin}.bak.${ts}"
            fi
            mv -f "$_new" "/usr/bin/$bin"            # atomic same-fs replace
            local size; size=$(du -sh "/usr/bin/${bin}" 2>/dev/null | awk '{print $1}')
            printf "  ${C_GRN}✓${C_RST}  %-30s  %s\n" "$bin" "$size"
            installed=$((installed + 1))
        elif [ "$will_install" = "1" ]; then
            printf "  ${C_DIM}-  %-30s  $(t "(not in this release)" "(此版本未包含)")${C_RST}\n" "$bin"
        else
            printf "  ${C_DIM}-  %-30s  $(t "(skipped, installed on demand)" "(跳过，按需安装)")${C_RST}\n" "$bin"
        fi
    done
    crit_end

    [ "$installed" -eq 0 ] && { msg_err "$(t "No installable files found" "未找到任何可安装文件")"; return 1; }

    if ! /usr/bin/easytier-core --version > /dev/null 2>&1; then
        msg_err "$(t "easytier-core failed to run (incompatible architecture?)" "easytier-core 执行验证失败（架构不兼容？）")"
        return 1
    fi

    printf "\n"
    msg_ok "$(t "Installed: $(/usr/bin/easytier-core --version)" "安装完成: $(/usr/bin/easytier-core --version)")"
    # _prune_backups always runs: even without a new backup it trims old ones down to ET_BACKUP_KEEP
    _prune_backups
    return 0
}

# ==============================================================================
#  Install extra binary on demand (web-embed takes this path)
# ==============================================================================
_install_extra_bin() {
    local bin="$1"
    if [ -n "$EXTRACT_DIR" ] && [ -f "${EXTRACT_DIR}/${bin}" ]; then
        local _new="/usr/bin/${bin}.tmp.$$"
        crit_begin
        cp "${EXTRACT_DIR}/${bin}" "$_new"
        chmod +x "$_new"
        crit_ck "$_new"
        if [ "${KEEP_BACKUP:-0}" = "1" ] && [ -f "/usr/bin/$bin" ]; then
            local ts; ts=$(date +%s)
            cp -p "/usr/bin/$bin" "/usr/bin/${bin}.bak.${ts}"
        fi
        mv -f "$_new" "/usr/bin/$bin"
        crit_end
        local size; size=$(du -sh "/usr/bin/${bin}" 2>/dev/null | awk '{print $1}')
        msg_ok "$(t "Installed on demand: ${bin}${size:+ ($size)}" "按需安装 ${bin}${size:+ ($size)}")"
        return 0
    fi
    [ -f "/usr/bin/$bin" ] && return 0
    msg_warn "$(t "${bin} is not in the downloaded archive and is not installed" "${bin} 不在已下载的压缩包中，且未安装")"
    msg_info "$(t "First choose '6) Update / reinstall' in the main menu to fetch the full archive for this version" "请先在主菜单选「6) 更新 / 重装」获取此版本完整压缩包")"
    return 1
}

# ==============================================================================
#  Backup pruning (trim by glob and ET_BACKUP_KEEP)
# ==============================================================================
_prune_glob() {
    local pat="$1" label="$2"
    local count
    count=$(ls $pat 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -le "$ET_BACKUP_KEEP" ] && return 0
    local del=$(( count - ET_BACKUP_KEEP ))
    ls -t $pat 2>/dev/null | tail -n "$del" | \
        while read -r f; do
            rm -f "$f"
            msg_info "$(t "Removing old ${label}: $(basename "$f")" "清理旧${label}: $(basename "$f")")"
        done
}

_prune_backups() {
    for bin in $ET_ALL_BINS; do
        _prune_glob "/usr/bin/${bin}.bak.*" "$(t "binary backup" "二进制备份")"
    done
    _prune_glob "/etc/easytier/config.toml.bak.*" "$(t "config backup" "配置备份")"
}

# ==============================================================================
#  core.args writer — includes log params
#
#  $1: opener flag (--config-file | -w)
#  $2: opener value (toml path or web url)
#
#  EasyTier by default writes 100MB×10 rolling logs into cwd; on procd cwd=/, which can fill the root partition.
#  So we always set --file-log-{dir,level,size,count} explicitly.
# ==============================================================================
_write_core_args() {
    mkdir -p /etc/easytier "$ET_FILE_LOG_DIR" 2>/dev/null || true
    local _tmp="/etc/easytier/core.args.tmp.$$"
    crit_begin
    printf '%s\n' \
        "$1" "$2" \
        "--file-log-dir"   "$ET_FILE_LOG_DIR" \
        "--file-log-level" "$ET_FILE_LOG_LEVEL" \
        "--file-log-size"  "$ET_FILE_LOG_SIZE" \
        "--file-log-count" "$ET_FILE_LOG_COUNT" \
        > "$_tmp"
    _commit_tmp "$_tmp" /etc/easytier/core.args 600
    crit_end
}

# ==============================================================================
#  TOML config wizard
# ==============================================================================
_toml_wizard() {
    section "$(t "TOML config wizard" "TOML 配置向导")"

    # ── Node instance name ────────────────────────────────────
    local def_name
    def_name="${ET_INSTANCE_NAME:-$(hostname 2>/dev/null || echo "easytier-node")}"
    printf "$(t "  Node instance name  [default: %s]: " "  节点实例名  [默认: %s]: ")" "$def_name"
    [ "${ET_NONINTERACTIVE:-0}" = "1" ] && printf '\n' && _TOML_INSTANCE="$def_name" || {
        read -r _TOML_INSTANCE
        [ -z "$_TOML_INSTANCE" ] && _TOML_INSTANCE="$def_name"
    }

    # ── DHCP vs fixed virtual IP ──────────────────────────
    _TOML_DHCP="${ET_DHCP:-0}"
    if [ "${ET_NONINTERACTIVE:-0}" != "1" ]; then
        _ask_flag "$(t "  Auto-assign the virtual IP via DHCP? [y/N]: " "  用 DHCP 自动分配虚拟 IP? [y/N]: ")" n \
            && _TOML_DHCP=1 || _TOML_DHCP=0
    fi

    # ── Fixed virtual IP (only when DHCP is off) ──────────
    if [ "$_TOML_DHCP" != "1" ]; then
        local def_ip="${ET_VIRTUAL_IP:-}"
        while true; do
            printf '%s' "$(t "  Virtual IPv4   [e.g. 10.0.0.1/24]: " "  虚拟 IPv4   [例: 10.0.0.1/24]: ")"
            if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
                [ -n "$def_ip" ] || die "$(t "Non-interactive mode requires ET_VIRTUAL_IP (or ET_DHCP=1)" "非交互模式需设置 ET_VIRTUAL_IP（或 ET_DHCP=1）")"
                is_valid_cidr "$def_ip" || die "$(t "Invalid ET_VIRTUAL_IP format: $def_ip" "ET_VIRTUAL_IP 格式无效: $def_ip")"
                printf '%s\n' "$def_ip"; _TOML_IP="$def_ip"; break
            fi
            read -r _TOML_IP
            [ -z "$_TOML_IP" ] && { msg_warn "$(t "Virtual IP cannot be empty" "虚拟 IP 不能为空")"; continue; }
            is_valid_cidr "$_TOML_IP" && break
            msg_warn "$(t "Invalid format; enter a.b.c.d/n (e.g. 10.0.0.1/24)" "格式无效，请输入 a.b.c.d/n 格式（如 10.0.0.1/24）")"
        done
    else
        _TOML_IP=""
        msg_info "$(t "DHCP enabled; the fixed-IP prompt is skipped" "已启用 DHCP，跳过固定 IP")"
    fi

    # ── Listen port (base; ws/wss use +1/+2) ──────────────
    local def_port="${ET_LISTEN_PORT:-11010}"
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        _TOML_LISTEN_PORT="$def_port"
    else
        while true; do
            printf "$(t "  Listen port    [default %s]: " "  监听端口    [默认 %s]: ")" "$def_port"
            read -r _TOML_LISTEN_PORT
            [ -z "$_TOML_LISTEN_PORT" ] && _TOML_LISTEN_PORT="$def_port"
            is_valid_port "$_TOML_LISTEN_PORT" && break
            msg_warn "$(t "Port range: 1-65535" "端口范围: 1-65535")"
        done
    fi
    is_valid_port "$_TOML_LISTEN_PORT" || _TOML_LISTEN_PORT=11010

    # ── Network name ──────────────────────────────────────
    local def_net="${ET_NETWORK_NAME:-}"
    while true; do
        printf '%s' "$(t "  Network name    [any string]: " "  网络名称    [自定义字符串]: ")"
        if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
            [ -n "$def_net" ] || die "$(t "Non-interactive mode requires ET_NETWORK_NAME" "非交互模式需设置 ET_NETWORK_NAME")"
            printf '%s\n' "$def_net"; _TOML_NET_NAME="$def_net"; break
        fi
        read -r _TOML_NET_NAME
        [ -n "$_TOML_NET_NAME" ] && break
        msg_warn "$(t "Network name cannot be empty" "网络名称不能为空")"
    done

    # ── Network secret ──────────────────────────────────────
    printf '%s' "$(t "  Network secret    [empty = auto-generate]: " "  网络密钥    [留空=自动生成]: ")"
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        printf '\n'
        _TOML_NET_SECRET="${ET_NETWORK_SECRET:-}"
    else
        read -r _TOML_NET_SECRET
    fi
    if [ -z "$_TOML_NET_SECRET" ]; then
        _TOML_NET_SECRET=$(gen_secret)
        msg_ok "$(t "Generated a random secret" "已生成随机密钥")"
        printf "    ${C_DIM}%s${C_RST}\n" "$_TOML_NET_SECRET"
        msg_info "$(t "Record this secret — all nodes in the same network must use the same secret" "请记录此密钥——同一网络中所有节点需使用相同密钥")"
    fi

    # ── Peer list ─────────────────────────────────────
    _TOML_PEERS=""
    if [ -n "${ET_PEERS:-}" ]; then
        # env var is comma-separated → convert to space-separated
        _TOML_PEERS=$(printf '%s' "$ET_PEERS" | tr ',' ' ')
    else
        msg_info "$(t "Enter peer addresses (optional, blank line to finish)" "输入 Peer 地址（可选，空行结束）")"
        msg_info "$(t "Format: tcp://host:11010  or  udp://host:11010" "格式: tcp://host:11010  或  udp://host:11010")"
        while true; do
            printf '%s' "$(t "  Peer URL (blank line to finish): " "  Peer URL（空行完成）: ")"
            local peer; read -r peer
            [ -z "$peer" ] && break
            if ! is_valid_url "$peer"; then
                msg_warn "$(t "Protocol must be tcp/udp/ws/wss, try again" "协议须为 tcp/udp/ws/wss，请重新输入")"
                continue
            fi
            _TOML_PEERS="${_TOML_PEERS}${_TOML_PEERS:+ }${peer}"
        done
    fi

    # ── Subnet proxy (multiple CIDRs allowed) ─────────────
    _TOML_PROXY_CIDRS=""
    if [ -n "${ET_PROXY_CIDR:-}" ]; then
        # env var: comma-separated list → validate each
        local _c
        for _c in $(printf '%s' "$ET_PROXY_CIDR" | tr ',' ' '); do
            if is_valid_cidr "$_c"; then
                _TOML_PROXY_CIDRS="${_TOML_PROXY_CIDRS}${_TOML_PROXY_CIDRS:+ }$_c"
            else
                msg_warn "$(t "Ignoring invalid proxy CIDR: $_c" "忽略无效子网代理 CIDR: $_c")"
            fi
        done
    elif [ "${ET_NONINTERACTIVE:-0}" != "1" ]; then
        msg_info "$(t "Subnet proxy CIDRs (optional, blank line to finish)" "子网代理 CIDR（可选，空行结束）")"
        while true; do
            printf '%s' "$(t "  Subnet proxy CIDR [e.g. 192.168.1.0/24]: " "  子网代理 CIDR [例: 192.168.1.0/24]: ")"
            local _c; read -r _c
            [ -z "$_c" ] && break
            if is_valid_cidr "$_c"; then
                _TOML_PROXY_CIDRS="${_TOML_PROXY_CIDRS}${_TOML_PROXY_CIDRS:+ }$_c"
            else
                msg_warn "$(t "Invalid CIDR format, try again" "CIDR 格式无效，请重试")"
            fi
        done
    fi

    # ── Advanced options (device name + key flags) ────────
    _TOML_DEV_NAME="${ET_DEV_NAME:-easytier0}"
    _TOML_ENC="true"; _TOML_PRIVATE="true"; _TOML_EXITNODE="true"; _TOML_COMPRESS="2"
    if [ "${ET_NONINTERACTIVE:-0}" != "1" ]; then
        if _ask_flag "$(t "  Configure advanced options (device name, encryption…)? [y/N]: " "  配置高级选项（设备名、加密…）? [y/N]: ")" n; then
            printf "$(t "  TUN device name [default %s]: " "  TUN 设备名 [默认 %s]: ")" "$_TOML_DEV_NAME"
            local _dn; read -r _dn; [ -n "$_dn" ] && _TOML_DEV_NAME="$_dn"
            _ask_flag "$(t "  Enable encryption? [Y/n]: " "  启用加密? [Y/n]: ")" y \
                && _TOML_ENC=true || _TOML_ENC=false
            _ask_flag "$(t "  Private mode (reject foreign networks)? [Y/n]: " "  私有模式（拒绝陌生网络）? [Y/n]: ")" y \
                && _TOML_PRIVATE=true || _TOML_PRIVATE=false
            _ask_flag "$(t "  Allow acting as an exit node? [Y/n]: " "  允许作为出口节点? [Y/n]: ")" y \
                && _TOML_EXITNODE=true || _TOML_EXITNODE=false
        fi
    fi
}

_toml_write_config() {
    local cfg="/etc/easytier/config.toml"
    local _tmp="${cfg}.tmp.$$"
    local p="$_TOML_LISTEN_PORT" p1 p2
    p1=$((p + 1)); p2=$((p + 2))

    crit_begin
    {
        printf 'instance_name = "%s"\n'  "$_TOML_INSTANCE"
        printf 'hostname = "%s"\n'       "$_TOML_INSTANCE"
        if [ "$_TOML_DHCP" = "1" ]; then
            printf 'dhcp = true\n'
        else
            printf 'dhcp = false\n'
            printf 'ipv4 = "%s"\n'       "$_TOML_IP"
        fi
        printf 'listeners = ["tcp://0.0.0.0:%s", "udp://0.0.0.0:%s", ' "$p" "$p"
        printf '"wg://0.0.0.0:%s", "ws://0.0.0.0:%s/", "wss://0.0.0.0:%s/"]\n' "$p1" "$p1" "$p2"
        printf 'exit_nodes = []\n'
        # bind the RPC portal to localhost on the CLI default port so `easytier-cli` works
        # (status view uses it); local-only, not exposed to the network
        printf 'rpc_portal = "127.0.0.1:15888"\n'
        printf '\n'

        for peer in $_TOML_PEERS; do
            printf '[[peer]]\n'
            printf 'uri = "%s"\n' "$peer"
            printf '\n'
        done

        for cidr in $_TOML_PROXY_CIDRS; do
            printf '[[proxy_network]]\n'
            printf 'cidr = "%s"\n' "$cidr"
            printf '\n'
        done

        printf '[network_identity]\n'
        printf 'network_name = "%s"\n'   "$_TOML_NET_NAME"
        printf 'network_secret = "%s"\n' "$_TOML_NET_SECRET"
        printf '\n'

        printf '[flags]\n'
        printf 'default_protocol = "tcp"\n'
        printf 'dev_name = "%s"\n'          "$_TOML_DEV_NAME"
        printf 'enable_ipv6 = true\n'
        printf 'enable_encryption = %s\n'   "$_TOML_ENC"
        printf 'enable_exit_node = %s\n'    "$_TOML_EXITNODE"
        printf 'data_compress_algo = %s\n'  "$_TOML_COMPRESS"
        printf 'use_smoltcp = true\n'
        printf 'private_mode = %s\n'        "$_TOML_PRIVATE"
        printf 'foreign_network_whitelist = "*"\n'
    } > "$_tmp"
    _commit_tmp "$_tmp" "$cfg" 600
    crit_end
    msg_ok "$(t "TOML config written: $cfg" "TOML 配置文件已写入: $cfg")"
}

setup_toml_config() {
    mkdir -p /etc/easytier

    if [ -f /etc/easytier/config.toml ]; then
        if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
            msg_info "$(t "Non-interactive mode: auto-backup and overwrite config" "非交互模式：自动备份并覆盖配置")"
            cp /etc/easytier/config.toml "/etc/easytier/config.toml.bak.$(date +%s)"
            _prune_glob "/etc/easytier/config.toml.bak.*" "$(t "config backup" "配置备份")"
        else
            printf '%s' "$(t "  Config already exists, overwrite? [y/N/0=back]: " "  配置文件已存在，覆盖? [y/N/0=返回]: ")"
            read -r a
            case "$a" in
                0)    return 1 ;;
                y|Y)  cp /etc/easytier/config.toml "/etc/easytier/config.toml.bak.$(date +%s)"
                      _prune_glob "/etc/easytier/config.toml.bak.*" "$(t "config backup" "配置备份")" ;;
                *)    msg_info "$(t "Kept the existing config" "已保留原配置文件")"
                      # keep the existing file, but still update core.args to point at it
                      _write_core_args "--config-file" "/etc/easytier/config.toml"
                      return 0 ;;
            esac
        fi
    fi

    _toml_wizard
    _toml_write_config

    # offer to review / hand-edit the generated config before it goes live
    if [ "${ET_NONINTERACTIVE:-0}" != "1" ]; then
        if _ask_flag "$(t "  Review the generated config now? [y/N]: " "  现在查看生成的配置? [y/N]: ")" n; then
            printf '\n'; sed 's/^/    /' /etc/easytier/config.toml; printf '\n'
        fi
        local _ed="${EDITOR:-}"
        [ -z "$_ed" ] && command -v vi > /dev/null 2>&1 && _ed='vi'
        if [ -n "$_ed" ] && _ask_flag "$(t "  Edit it in ${_ed} before starting? [y/N]: " "  启动前用 ${_ed} 编辑? [y/N]: ")" n; then
            "$_ed" /etc/easytier/config.toml || true
        fi
    fi

    _write_core_args "--config-file" "/etc/easytier/config.toml"
    return 0
}

# ==============================================================================
#  Web console configuration
# ==============================================================================
setup_web_console() {
    section "$(t "Configure easytier-web-embed" "配置 easytier-web-embed")"

    # install web-embed on demand (do_install_bins does not install it by default)
    _install_extra_bin easytier-web-embed || return 1

    # ── API port ──────────────────────────────────────
    local api_port
    while true; do
        printf '%s' "$(t "  Web API/frontend port   [default 11211]: " "  Web API/前端 端口   [默认 11211]: ")"
        read -r api_port
        [ -z "$api_port" ] && api_port=11211
        is_valid_port "$api_port" && break
        msg_warn "$(t "Port range: 1-65535" "端口范围: 1-65535")"
    done

    # ── Config-serving port ──────────────────────────────────
    local cfg_port
    while true; do
        printf '%s' "$(t "  Config-serving port        [default 22020]: " "  配置下发端口        [默认 22020]: ")"
        read -r cfg_port
        [ -z "$cfg_port" ] && cfg_port=22020
        is_valid_port "$cfg_port" && break
        msg_warn "$(t "Port range: 1-65535" "端口范围: 1-65535")"
    done

    # ── Protocol ────────────────────────────────
    printf '\n'
    msg_info "$(t "Config-serving protocol notes:" "配置下发协议说明:")"
    msg_info "$(t "  udp — recommended, lowest latency" "  udp — 推荐，延迟最低")"
    msg_info "$(t "  tcp — better NAT traversal" "  tcp — 穿透性更好")"
    msg_info "$(t "  ws  — good behind an HTTP reverse proxy; if Cloudflare Tunnel upgrades ws to wss," "  ws  — 适合 HTTP 反向代理；若 Cloudflare Tunnel 将 ws 升级为 wss，")"
    msg_info "$(t "        then easytier-core should join with wss (not ws)" "        则 easytier-core 接入时协议应填 wss（而非 ws）")"
    printf '%s' "$(t "  Protocol (tcp/udp/ws) [default udp]: " "  协议 (tcp/udp/ws) [默认 udp]: ")"
    local cfg_proto; read -r cfg_proto
    case "$cfg_proto" in tcp|udp|ws) ;; *) cfg_proto=udp ;; esac

    # ── API Host ────────────────────────────
    printf '\n'
    msg_info "$(t "--api-host sets the address the web frontend uses to call the API backend:" "--api-host 决定 Web 前端调用 API 后端的地址:")"
    msg_info "$(t "  · local access only:      http://127.0.0.1:${api_port}" "  · 仅本地访问:           http://127.0.0.1:${api_port}")"
    msg_info "$(t "  · Cloudflare Tunnel:  https://your-domain.example.com" "  · Cloudflare Tunnel:  https://your-domain.example.com")"
    msg_info "$(t "  (after Tunnel setup, reconfigure this via 'Web console management')" "  （Tunnel 配置完成后可通过「Web 控制台管理」重新配置此项）")"
    printf "$(t "  API Host [default http://127.0.0.1:%s]: " "  API Host [默认 http://127.0.0.1:%s]: ")" "$api_port"
    local api_host; read -r api_host
    [ -z "$api_host" ] && api_host="http://127.0.0.1:${api_port}"

    mkdir -p /etc/easytier
    local _tmp="/etc/easytier/web.args.tmp.$$"
    crit_begin
    printf '%s\n' \
        "--api-server-port" "${api_port}" \
        "--api-host"        "${api_host}" \
        "--config-server-port"     "${cfg_port}" \
        "--config-server-protocol" "${cfg_proto}" \
        > "$_tmp"
    _commit_tmp "$_tmp" /etc/easytier/web.args 600
    crit_end

    svc_write_web || return 1
    svc_stop_web  2>/dev/null || true
    svc_start_web
    wait_for_port "$api_port" 12

    printf '\n'
    printf "$(t "  ${C_GRN}┌─ easytier-web-embed started ────────────────────────┐${C_RST}\n" "  ${C_GRN}┌─ easytier-web-embed 已启动 ────────────────────────┐${C_RST}\n")"
    printf "$(t "  ${C_GRN}│${C_RST}  Web console:  http://0.0.0.0:%-6s                ${C_GRN}│${C_RST}\n" "  ${C_GRN}│${C_RST}  Web 控制台:  http://0.0.0.0:%-6s                 ${C_GRN}│${C_RST}\n")" "$api_port"
    printf "$(t "  ${C_GRN}│${C_RST}  Config push:  %-3s://0.0.0.0:%-6s                 ${C_GRN}│${C_RST}\n" "  ${C_GRN}│${C_RST}  配置下发:    %-3s://0.0.0.0:%-6s                 ${C_GRN}│${C_RST}\n")" "$cfg_proto" "$cfg_port"
    printf "$(t "  ${C_GRN}│${C_RST}  Default login:  admin / user  ${C_YLW}← change now${C_RST}         ${C_GRN}│${C_RST}\n" "  ${C_GRN}│${C_RST}  默认账户:    admin / user  ${C_YLW}← 请立即修改密码${C_RST}   ${C_GRN}│${C_RST}\n")"
    printf "  ${C_GRN}└─────────────────────────────────────────────────────┘${C_RST}\n\n"
    msg_info "$(t "First open the console in a browser and register an account, then fill in the join URL" "请先在浏览器访问控制台并注册账户，再继续填写接入 URL")"
    return 0
}

ask_core_web_url() {
    local started_web="${1:-false}"
    section "$(t "easytier-core joining the web console" "easytier-core 接入 Web 控制台")"
    msg_info "$(t "Format: <protocol>://<host>:<port>/<username>" "格式: <protocol>://<host>:<port>/<username>")"
    msg_info "$(t "Example: udp://127.0.0.1:22020/myuser" "示例: udp://127.0.0.1:22020/myuser")"
    msg_info "      wss://easytier-web.example.com/22020/myuser"
    msg_info "$(t "Note: behind a Cloudflare Tunnel with a ws serving protocol, join with wss" "注意: 若通过 Cloudflare Tunnel 反代且下发协议为 ws，接入协议请填 wss")"

    # non-interactive mode
    if [ -n "${ET_WEB_URL:-}" ]; then
        if ! is_valid_url "$ET_WEB_URL"; then
            die "$(t "Invalid ET_WEB_URL protocol (must be tcp/udp/ws/wss://): $ET_WEB_URL" "ET_WEB_URL 协议无效（须 tcp/udp/ws/wss://）: $ET_WEB_URL")"
        fi
        _write_core_args "-w" "$ET_WEB_URL"
        msg_ok "$(t "Join URL saved (non-interactive): $ET_WEB_URL" "接入 URL 已保存（非交互）: $ET_WEB_URL")"
        return 0
    fi
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        die "$(t "Non-interactive web mode requires ET_WEB_URL (e.g. udp://host:22020/user)" "非交互 web 模式需设置 ET_WEB_URL（如 udp://host:22020/user）")"
    fi

    while true; do
        local hint=""
        [ "$started_web" = "true" ] && hint="$(t "/undo web-embed" "/撤销 web-embed")"
        printf "$(t "\n  Join URL [0=back%s]: " "\n  接入 URL [0=返回%s]: ")" "$hint"
        read -r w_url

        case "$w_url" in
            0)
                if [ "$started_web" = "true" ]; then
                    msg_info "$(t "Undoing web-embed configuration..." "正在撤销 web-embed 配置...")"
                    svc_stop_web; svc_remove_web
                    rm -f /etc/easytier/web.args
                    msg_ok "$(t "web-embed service undone" "已撤销 web-embed 服务")"
                fi
                return 1
                ;;
            "")
                msg_warn "$(t "URL cannot be empty" "URL 不能为空")"
                ;;
            *)
                if ! is_valid_url "$w_url"; then
                    msg_warn "$(t "URL must start with tcp:// udp:// ws:// wss://" "URL 须以 tcp:// udp:// ws:// wss:// 开头")"
                    continue
                fi
                _write_core_args "-w" "$w_url"
                msg_ok "$(t "Join URL saved: $w_url" "接入 URL 已保存: $w_url")"
                return 0
                ;;
        esac
    done
}

do_setup_mode() {
    # non-interactive mode
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
        section "$(t "Choose configuration method" "选择配置方式")"
        printf "  ${C_BLD}1)${C_RST}  $(t "TOML config file  —  standalone node, local management" "TOML 配置文件  —  独立节点，本地管理")\n"
        printf "  ${C_BLD}2)${C_RST}  $(t "Web console push —  centrally manage many nodes" "Web 控制台下发 —  集中管理多节点")\n"
        printf "  ${C_BLD}0)${C_RST}  $(t "Back" "返回")\n\n"
        printf '%s' "$(t "  Select [0-2]: " "  请选择 [0-2]: ")"
        read -r mode

        case "$mode" in
            0) return 1 ;;
            1) setup_toml_config && return 0 ;;
            2)
                printf '\n'
                printf "  $(t "Run easytier-web-embed on this machine?" "是否在本机运行 easytier-web-embed？")\n"
                printf "  ${C_BLD}1)${C_RST}  $(t "Yes, deploy the web console here" "是，本机部署 Web 控制台")\n"
                printf "  ${C_BLD}2)${C_RST}  $(t "No, connect to an existing external console" "否，连接至已有外部控制台")\n"
                printf "  ${C_BLD}0)${C_RST}  $(t "Back" "返回")\n"
                printf '%s' "$(t "  Select [0-2]: " "  请选择 [0-2]: ")"
                read -r rw
                case "$rw" in
                    0) continue ;;
                    1)
                        # setup_web_console installs easytier-web-embed on demand itself
                        setup_web_console || continue
                        ask_core_web_url "true" && return 0 || continue
                        ;;
                    2) ask_core_web_url "false" && return 0 || continue ;;
                    *) msg_warn "$(t "Invalid input" "无效输入")" ;;
                esac
                ;;
            *) msg_warn "$(t "Invalid input" "无效输入")" ;;
        esac
    done
}

# ==============================================================================
#  Service status view
# ==============================================================================
do_view_status() {
    section "$(t "Service status" "服务状态")"

    _print_svc_block() {
        local label="$1" bin="$2" args_file="$3"
        printf "  ${C_BLD}[ %s ]${C_RST}\n" "$label"
        if _proc_running "$bin"; then
            local pid; pid=$(_proc_pid "$bin")
            printf "    $(t "Status" "状态"): ${C_GRN}$(t "✓ running" "✓ 运行中")${C_RST} (PID: %s)\n" "$pid"
        else
            printf "    $(t "Status" "状态"): ${C_RED}$(t "✗ stopped" "✗ 未运行")${C_RST}\n"
        fi
        [ -f "$args_file" ] && \
            printf "    $(t "Args" "参数"): ${C_DIM}%s${C_RST}\n" "$(tr '\n' ' ' < "$args_file")"
        # append a short systemd status summary (3 lines)
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

    # ── Network overview via easytier-cli (peers / routes) — best-effort ──
    if [ -x /usr/bin/easytier-cli ] && _proc_running "easytier-core"; then
        printf "  ${C_BLD}[ $(t "Network (easytier-cli)" "网络概览 (easytier-cli)") ]${C_RST}\n"
        local shown=0 sect out
        for sect in peer route; do
            out=$(_cli "$sect")
            if [ -n "$out" ]; then
                case "$sect" in
                    peer)  printf "    ${C_DIM}$(t "peers:" "节点:")${C_RST}\n" ;;
                    route) printf "    ${C_DIM}$(t "routes:" "路由:")${C_RST}\n" ;;
                esac
                printf '%s\n' "$out" | sed 's/^/      /'
                shown=1
            fi
        done
        if [ "$shown" = "0" ]; then
            msg_info "$(t "easytier-cli returned nothing — RPC portal may be off (older config used rpc_portal 0); reconfigure to enable" "easytier-cli 无输出——RPC 端口可能未开（旧配置用了 rpc_portal 0）；重新配置即可启用")"
        fi
        printf '\n'
    fi

    printf "  ${C_BLD}[ $(t "Log commands" "日志命令") ]${C_RST}\n"
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
    printf "    $(t "Install log  " "安装日志     ") : %s\n" "$LOG_FILE"
}

# ==============================================================================
#  Standalone web console management
# ==============================================================================
do_manage_web() {
    while true; do
        section "$(t "Web console management" "Web 控制台管理")"

        if _proc_running "easytier-web-embed"; then
            local port=""
            [ -f /etc/easytier/web.args ] && \
                port=$(grep -A1 '^--api-server-port$' /etc/easytier/web.args 2>/dev/null \
                       | tail -1 | tr -d ' \t')
            printf "  $(t "Status" "状态"): ${C_GRN}$(t "✓ running" "✓ 运行中")${C_RST}${port:+  ($(t "port" "端口") ${port})}\n"
        else
            printf "  $(t "Status" "状态"): ${C_RED}$(t "✗ stopped" "✗ 未运行")${C_RST}\n"
        fi
        [ -f /etc/easytier/web.args ] && \
            printf "  $(t "Args" "参数"): ${C_DIM}%s${C_RST}\n" "$(tr '\n' ' ' < /etc/easytier/web.args)"

        printf '\n'
        printf "  ${C_BLD}1)${C_RST}  $(t "Start / restart" "启动 / 重启")\n"
        printf "  ${C_BLD}2)${C_RST}  $(t "Stop" "停止")\n"
        printf "  ${C_BLD}3)${C_RST}  $(t "Reconfigure (port / api-host, etc.)" "重新配置（端口 / api-host 等）")\n"
        printf "  ${C_BLD}4)${C_RST}  $(t "Remove service and config" "移除服务及配置")\n"
        printf "  ${C_BLD}0)${C_RST}  $(t "Back to main menu" "返回主菜单")\n\n"
        printf '%s' "$(t "  Select [0-4]: " "  请选择 [0-4]: ")"
        read -r wc

        case "$wc" in
            0) return 0 ;;
            1)
                if [ ! -f /etc/easytier/web.args ]; then
                    msg_warn "$(t "web.args not found; run 'Reconfigure (3)' first" "未找到 web.args，请先执行「重新配置（3）」")"
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
            2) svc_stop_web && msg_ok "$(t "Stopped" "已停止")" ;;
            3) setup_web_console ;;
            4)
                printf '%s' "$(t "  Really remove the web-embed service and config files? [y/N]: " "  确认移除 web-embed 服务及配置文件? [y/N]: ")"
                read -r a
                case "$a" in
                    y|Y)
                        svc_stop_web; svc_remove_web
                        rm -f /etc/easytier/web.args
                        msg_ok "$(t "Removed" "已移除")"
                        ;;
                    *) msg_info "$(t "Cancelled" "已取消")" ;;
                esac
                ;;
            *) msg_warn "$(t "Invalid input" "无效输入")" ;;
        esac
    done
}

# ==============================================================================
#  File location display
# ==============================================================================
show_file_locations() {
    section "$(t "Installed file locations" "已安装文件位置")"

    printf "  ${C_BLD}[ $(t "Binaries" "二进制") ]${C_RST}  /usr/bin/\n"
    for bin in $ET_ALL_BINS; do
        if [ -f "/usr/bin/$bin" ]; then
            local size; size=$(du -sh "/usr/bin/$bin" 2>/dev/null | awk '{print $1}')
            printf "  ${C_GRN}✓${C_RST}  %-30s  %s\n" "$bin" "$size"
        else
            printf "  ${C_DIM}-  %-30s  $(t "(not in this release)" "(此版本未包含)")${C_RST}\n" "$bin"
        fi
    done

    printf '\n'
    printf "  ${C_BLD}[ $(t "Config" "配置") ]${C_RST}  /etc/easytier/\n"
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
    [ "$cfg_found" = false ] && printf "  ${C_DIM}$(t "(no config files)" "(无配置文件)")${C_RST}\n"

    printf '\n'
    printf "  ${C_BLD}[ $(t "Service files" "服务文件") ]${C_RST}\n"
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
    [ "$svc_found" = false ] && printf "  ${C_DIM}$(t "(no service files)" "(无服务文件)")${C_RST}\n"

    printf '\n'
    printf "  ${C_BLD}[ $(t "Backups" "历史备份") ]${C_RST}  /usr/bin/  ${C_DIM}$(t "(keep latest %d per binary)" "(每个二进制保留最近 %d 份)")${C_RST}\n" \
        "$ET_BACKUP_KEEP"
    local bak_list
    bak_list=$(ls /usr/bin/easytier-*.bak.* 2>/dev/null) || true
    if [ -n "$bak_list" ]; then
        printf '%s\n' "$bak_list" | while read -r f; do
            local size; size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
            printf "  ${C_DIM}*  %-44s  %s${C_RST}\n" "$(basename "$f")" "$size"
        done
    else
        printf "  ${C_DIM}$(t "(no backup files)" "(无备份文件)")${C_RST}\n"
    fi

    printf '\n'
    printf "  ${C_BLD}[ $(t "Logs" "日志") ]${C_RST}\n"
    printf "  $(t "Install log" "安装日志"): %s\n" "$LOG_FILE"
    if [ -d "$ET_FILE_LOG_DIR" ]; then
        local cur_log_size
        cur_log_size=$(du -sh "$ET_FILE_LOG_DIR" 2>/dev/null | awk '{print $1}')
        printf "$(t "  Core logs: %s/  ${C_DIM}(now %s, cap %dMB×%d, level %s)${C_RST}\n" "  Core 日志: %s/  ${C_DIM}(当前 %s, 上限 %dMB×%d, 级别 %s)${C_RST}\n")" \
            "$ET_FILE_LOG_DIR" "${cur_log_size:-?}" \
            "$ET_FILE_LOG_SIZE" "$ET_FILE_LOG_COUNT" "$ET_FILE_LOG_LEVEL"
    fi
    case "$INIT_SYS" in
        procd)   printf "  $(t "Runtime log" "运行日志"): logread -f | grep easytier\n" ;;
        systemd) printf "  $(t "Runtime log" "运行日志"): journalctl -u easytier -f\n"
                 [ -f /etc/systemd/system/easytier-web.service ] && \
                     printf "            journalctl -u easytier-web -f\n" ;;
        openrc)  printf "  $(t "Runtime log" "运行日志"): tail -f /var/log/easytier.log\n" ;;
    esac

    # old versions (< 2.1.0) without --file-log-dir wrote 100MB×10 logs to cwd
    if ls /easytier.log /easytier.log.[0-9] /easytier.log.[0-9][0-9] >/dev/null 2>&1; then
        local legacy_size
        legacy_size=$(du -ch /easytier.log* 2>/dev/null | tail -1 | awk '{print $1}')
        printf '\n'
        printf "  ${C_YLW}$(t "⚠  Found legacy logs /easytier.log* (%s); remove manually" "⚠  发现遗留日志 /easytier.log*（%s），可手动清理")${C_RST}\n" \
            "${legacy_size:-?}"
        printf "  ${C_DIM}   rm -f /easytier.log /easytier.log.[0-9] /easytier.log.[0-9][0-9]${C_RST}\n"
    fi
}

# ==============================================================================
#  Uninstall — single binary (also removes its service, but leaves config/backups/logs)
# ==============================================================================
_uninstall_one() {
    local bin="$1"
    printf "$(t "  Really remove ${C_BLD}%s${C_RST}? [y/N]: " "  确认移除 ${C_BLD}%s${C_RST}? [y/N]: ")" "$bin"
    local a; read -r a
    case "$a" in y|Y) ;; *) msg_info "$(t "Cancelled" "已取消")"; return 1 ;; esac

    case "$bin" in
        easytier-core)
            msg_info "$(t "Stopping and removing the easytier service..." "停止并移除 easytier 服务...")"
            svc_stop; svc_remove
            _kill_bin easytier-core
            ip link del easytier0 2>/dev/null || true
            ;;
        easytier-web-embed)
            msg_info "$(t "Stopping and removing the easytier-web service..." "停止并移除 easytier-web 服务...")"
            svc_stop_web; svc_remove_web
            _kill_bin easytier-web-embed
            ;;
    esac

    rm -f "/usr/bin/$bin"
    msg_ok "$(t "${bin} removed" "${bin} 已移除")"
    return 0
}

# ==============================================================================
#  Uninstall — everything (services/config/backups/logs/legacy logs)
# ==============================================================================
_uninstall_all() {
    printf "  ${C_YLW}$(t "⚠  This removes all EasyTier services and binaries" "⚠  此操作将移除所有 EasyTier 相关服务和二进制")${C_RST}\n"
    printf '%s' "$(t "  Confirm full uninstall? [y/N]: " "  确认全部卸载? [y/N]: ")"
    local a; read -r a
    case "$a" in y|Y) ;; *) msg_info "$(t "Cancelled" "已取消")"; return 1 ;; esac

    msg_info "$(t "Stopping and removing services..." "停止并移除服务...")"
    svc_stop; svc_stop_web
    svc_remove; svc_remove_web
    _kill_bin easytier-core
    _kill_bin easytier-web-embed
    for bin in $ET_ALL_BINS; do
        rm -f "/usr/bin/$bin"
    done
    ip link del easytier0 2>/dev/null || true
    msg_ok "$(t "Binaries and services removed" "二进制及服务已移除")"

    local bak_list
    bak_list=$(ls /usr/bin/easytier-*.bak.* 2>/dev/null) || true
    if [ -n "$bak_list" ]; then
        local bak_count
        bak_count=$(printf '%s\n' "$bak_list" | wc -l | tr -d ' ')
        printf "$(t "  Delete %d backup file(s)? [y/N]: " "  删除 %d 个历史备份文件? [y/N]: ")" "$bak_count"
        read -r a
        case "$a" in
            y|Y) printf '%s\n' "$bak_list" | while read -r f; do rm -f "$f"; done
                 msg_ok "$(t "Backup files removed" "备份文件已清理")" ;;
            *)   msg_info "$(t "Backup files kept in /usr/bin/" "备份文件已保留于 /usr/bin/")" ;;
        esac
    fi

    printf '%s' "$(t "  Delete config dir /etc/easytier? [y/N]: " "  删除配置目录 /etc/easytier? [y/N]: ")"
    read -r a
    case "$a" in
        y|Y) rm -rf /etc/easytier && msg_ok "$(t "Config dir deleted" "配置目录已删除")" ;;
        *)   msg_info "$(t "Config dir kept: /etc/easytier" "配置目录已保留: /etc/easytier")" ;;
    esac

    if [ -d "$ET_FILE_LOG_DIR" ]; then
        local log_size
        log_size=$(du -sh "$ET_FILE_LOG_DIR" 2>/dev/null | awk '{print $1}')
        printf "$(t "  Delete log dir %s (%s)? [y/N]: " "  删除日志目录 %s (%s)? [y/N]: ")" "$ET_FILE_LOG_DIR" "${log_size:-?}"
        read -r a
        case "$a" in
            y|Y) rm -rf "$ET_FILE_LOG_DIR" && msg_ok "$(t "Log dir deleted" "日志目录已删除")" ;;
            *)   msg_info "$(t "Log dir kept: $ET_FILE_LOG_DIR" "日志目录已保留: $ET_FILE_LOG_DIR")" ;;
        esac
    fi

    # legacy: before v2.0.x without --file-log-dir, core wrote logs to cwd (=/ on procd)
    local legacy
    legacy=$(ls /easytier.log /easytier.log.[0-9] /easytier.log.[0-9][0-9] 2>/dev/null) || true
    if [ -n "$legacy" ]; then
        local n; n=$(printf '%s\n' "$legacy" | wc -l | tr -d ' ')
        printf "$(t "  Found %d legacy log file(s) (/easytier.log*), delete? [y/N]: " "  发现 %d 个遗留日志文件 (/easytier.log*)，删除? [y/N]: ")" "$n"
        read -r a
        case "$a" in
            y|Y) printf '%s\n' "$legacy" | while read -r f; do rm -f "$f"; done
                 msg_ok "$(t "Legacy logs removed" "遗留日志已清理")" ;;
            *)   msg_info "$(t "Legacy logs kept" "遗留日志已保留")" ;;
        esac
    fi

    msg_ok "$(t "Uninstall complete" "卸载完成")"
    return 0
}

# ==============================================================================
#  Uninstall entry — let the user pick a single binary or everything
# ==============================================================================
do_uninstall() {
    section "$(t "Uninstall EasyTier" "卸载 EasyTier")"

    # collect the currently installed binaries
    local installed="" idx=0
    for bin in $ET_ALL_BINS; do
        [ -f "/usr/bin/$bin" ] && installed="${installed}${installed:+ }$bin"
    done
    if [ -z "$installed" ]; then
        msg_warn "$(t "No EasyTier binaries found" "未发现任何 EasyTier 二进制")"
        return 1
    fi

    printf "  $(t "Installed binaries:" "已安装的二进制：")\n\n"
    idx=0
    for bin in $installed; do
        idx=$((idx + 1))
        local size; size=$(du -sh "/usr/bin/$bin" 2>/dev/null | awk '{print $1}')
        local tag=""
        case "$bin" in
            easytier-core)      tag="  ${C_DIM}$(t "(incl. easytier service)" "(含 easytier 服务)")${C_RST}" ;;
            easytier-web-embed) tag="  ${C_DIM}$(t "(incl. easytier-web service)" "(含 easytier-web 服务)")${C_RST}" ;;
        esac
        printf "  ${C_BLD}%d)${C_RST}  %-22s %s%s\n" "$idx" "$bin" "$size" "$tag"
    done
    local all_idx=$((idx + 1))
    printf "  ${C_BLD}%d)${C_RST}  ${C_YLW}$(t "Delete all" "全部删除")${C_RST}  ${C_DIM}$(t "(incl. services/config/backups/logs)" "(含服务/配置/备份/日志)")${C_RST}\n" "$all_idx"
    printf "  ${C_BLD}0)${C_RST}  $(t "Back" "返回")\n\n"
    printf "$(t "  Select [0-%d]: " "  请选择 [0-%d]: ")" "$all_idx"
    local choice; read -r choice

    [ "$choice" = "0" ] && return 1
    [ "$choice" = "$all_idx" ] && { _uninstall_all; return $?; }

    # validate the numeric range
    if ! printf '%s' "$choice" | grep -qE '^[0-9]+$' || \
       [ "$choice" -lt 1 ] || [ "$choice" -gt "$idx" ]; then
        msg_warn "$(t "Invalid choice" "无效选择")"
        return 1
    fi

    # map to the Nth entry in the installed list
    local target="" i=0
    for bin in $installed; do
        i=$((i + 1))
        [ "$i" = "$choice" ] && { target="$bin"; break; }
    done
    _uninstall_one "$target"
    return $?
}

# ==============================================================================
#  Main menu
# ==============================================================================
_print_header() {
    local cur="" mode_str="$(t "not configured" "未配置")" web_str=""

    [ -f /usr/bin/easytier-core ] && \
        cur=$(/usr/bin/easytier-core --version 2>&1 | awk '{print $2}' | cut -d'-' -f1)

    if [ -f /etc/easytier/core.args ]; then
        local first; first=$(head -1 /etc/easytier/core.args)
        case "$first" in
            --config-file) mode_str="$(t "TOML config file" "TOML 配置文件")" ;;
            -w)
                local wurl; wurl=$(sed -n '2p' /etc/easytier/core.args 2>/dev/null)
                mode_str="$(t "Web console (${wurl})" "Web 控制台 (${wurl})")"
                ;;
        esac
    fi

    if _proc_running "easytier-web-embed"; then
        local port=""
        [ -f /etc/easytier/web.args ] && \
            port=$(grep -A1 '^--api-server-port$' /etc/easytier/web.args 2>/dev/null \
                   | tail -1 | tr -d ' ')
        web_str="${C_GRN}$(t "✓ running" "✓ 运行中")${C_RST}${port:+  ($(t "port" "端口") ${port})}"
    elif [ -f /etc/easytier/web.args ]; then
        web_str="${C_YLW}$(t "✗ configured but not running" "✗ 已配置但未运行")${C_RST}"
    fi

    # separator width is content-independent, sidestepping CJK double-width alignment issues
    local SEP="${C_BLD}  ──────────────────────────────────────────${C_RST}"
    printf "\n%s\n" "$SEP"
    printf "  ${C_BLD}  $(t "EasyTier Manager" "EasyTier 管理脚本")${C_RST}  v%s\n" "$SCRIPT_VERSION"
    printf "%s\n" "$SEP"
    printf "  $(t "System" "系统")  %-12s  $(t "Arch" "架构")  %s\n" "$OS_TYPE" "$ARCH_NAME"
    printf "  Init  %s\n" "$INIT_SYS"
    if [ -n "$cur" ]; then
        printf "  $(t "Version" "版本")  %s\n" "$cur"
        printf "  $(t "Config " "配置")  %s\n" "$mode_str"
        [ -n "$web_str" ] && printf "  Web   %s\n" "$web_str"
    else
        printf "  ${C_YLW}$(t "Status  not installed" "状态  未安装")${C_RST}\n"
    fi
    printf "%s\n" "$SEP"
}

# ==============================================================================
#  CLI usage (for the one-shot subcommands handled in main)
# ==============================================================================
_usage() {
    cat <<USAGE
$(t "EasyTier Manager" "EasyTier 管理脚本") v${SCRIPT_VERSION}

$(t "Usage" "用法"): $(basename "$0") [command]

$(t "Commands" "命令"):
  (none) | menu     $(t "interactive menu (default)" "交互式菜单（默认）")
  status            $(t "show service status and network overview" "显示服务状态与网络概览")
  start|stop|restart
                    $(t "control easytier-core (and web-embed if configured)" "控制 easytier-core（及已配置的 web-embed）")
  version           $(t "print script and core version" "打印脚本与 core 版本")
  help              $(t "this help" "本帮助")

$(t "Non-interactive install: set ET_NONINTERACTIVE=1 and ET_* vars (see README)." "非交互安装：设置 ET_NONINTERACTIVE=1 及 ET_* 变量（见 README）。")
$(t "Language: ET_LANG=en|zh (default: auto from locale)." "语言：ET_LANG=en|zh（默认：按 locale 自动识别）。")
USAGE
}

main() {
    _init_colors
    detect_system

    # procd (OpenWrt) tightens defaults: small flash, /var → /tmp (tmpfs, uses RAM)
    # env vars the user set explicitly win (_u_* sentinels recorded by the declarations at the top)
    if [ "$INIT_SYS" = "procd" ]; then
        [ -z "$_u_backup" ] && ET_BACKUP_KEEP=1
        [ -z "$_u_lsize"  ] && ET_FILE_LOG_SIZE=2
        [ -z "$_u_lcount" ] && ET_FILE_LOG_COUNT=3
    fi

    # ── One-shot subcommands (for scripts / cron); these don't need curl/unzip ──
    case "${1:-}" in
        -h|--help|help)
            _usage; exit 0 ;;
        -V|--version|version)
            printf 'easytier-manager %s\n' "$SCRIPT_VERSION"
            [ -x /usr/bin/easytier-core ] && \
                printf 'easytier-core %s\n' "$(/usr/bin/easytier-core --version 2>&1 | awk '{print $2}')"
            exit 0 ;;
        status)
            do_view_status; exit 0 ;;
        start)
            svc_start; check_proc easytier-core "easytier-core" || true
            [ -f /etc/easytier/web.args ] && { svc_start_web; check_proc easytier-web-embed "easytier-web-embed" || true; }
            exit 0 ;;
        stop)
            svc_stop; [ -f /etc/easytier/web.args ] && svc_stop_web
            msg_ok "$(t "Stopped" "已停止")"; exit 0 ;;
        restart)
            svc_restart; check_proc easytier-core "easytier-core" || true
            [ -f /etc/easytier/web.args ] && { svc_restart_web; check_proc easytier-web-embed "easytier-web-embed" || true; }
            exit 0 ;;
        ''|menu) ;;                 # fall through to interactive menu / non-interactive install
        *)
            msg_err "$(t "Unknown command: $1" "未知命令: $1")"
            _usage; exit 2 ;;
    esac

    check_deps

    _log "INFO" "Script start v${SCRIPT_VERSION} OS=${OS_TYPE} INIT=${INIT_SYS} ARCH=${ARCH_NAME} BACKUP=${ET_BACKUP_KEEP} LOG=${ET_FILE_LOG_SIZE}MB×${ET_FILE_LOG_COUNT}"

    # ── Non-interactive mode: do the install / update once, then exit (for CI / Ansible) ────
    # the interactive menu needs a tty; non-interactively stdin is EOF and the menu would spin, so dispatch here directly.
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        select_version                   || die "$(t "Version selection failed" "版本选择失败")"
        do_download "$VER" "$ARCH_NAME"  || die "$(t "Download failed" "下载失败")"
        do_install_bins "$EXTRACT_DIR"   || die "$(t "Install failed" "安装失败")"
        # if web-embed was deployed, upgrade it too to avoid version skew with core
        [ -f /etc/easytier/web.args ] && _install_extra_bin easytier-web-embed
        do_setup_mode                    || die "$(t "Configuration failed (check ET_MODE / ET_VIRTUAL_IP / ET_WEB_URL, etc.)" "配置失败（检查 ET_MODE / ET_VIRTUAL_IP / ET_WEB_URL 等）")"
        svc_write_core
        svc_stop 2>/dev/null || true
        svc_start
        check_proc easytier-core "easytier-core" || true
        if [ -f /etc/easytier/web.args ]; then
            svc_write_web && svc_restart_web
            check_proc easytier-web-embed "easytier-web-embed" || true
        fi
        _log "INFO" "Non-interactive install complete VER=${VER}"
        exit 0
    fi

    # ── Backfill --file-log-* once for old (< 2.1.0) core.args that lacks it ────
    # without this, the old service still writes 100MB×10 rolling logs to cwd (=/ on procd)
    if [ -f /etc/easytier/core.args ] && \
       ! grep -q -- "--file-log-dir" /etc/easytier/core.args; then
        msg_warn "$(t "Detected old core.args missing log params; appending --file-log-*" "检测到旧版 core.args 缺少日志参数，正在追加 --file-log-*")"
        mkdir -p "$ET_FILE_LOG_DIR" 2>/dev/null || true
        _tmp="/etc/easytier/core.args.tmp.$$"
        crit_begin
        { cat /etc/easytier/core.args; printf '%s\n' \
            "--file-log-dir"   "$ET_FILE_LOG_DIR" \
            "--file-log-level" "$ET_FILE_LOG_LEVEL" \
            "--file-log-size"  "$ET_FILE_LOG_SIZE" \
            "--file-log-count" "$ET_FILE_LOG_COUNT"; } > "$_tmp"
        _commit_tmp "$_tmp" /etc/easytier/core.args 600
        crit_end
        svc_write_core 2>/dev/null || true
        msg_info "$(t "Choose '2) Restart services' in the main menu to apply the new params" "请在主菜单选「2) 重启服务」让新参数生效")"
    fi

    while true; do
        _print_header

        printf '\n'
        if [ -f /usr/bin/easytier-core ]; then
            printf "  ${C_DIM}── $(t "Service" "日常") ──${C_RST}\n"
            printf "  ${C_BLD}1)${C_RST}  $(t "View service status" "查看服务状态")\n"
            printf "  ${C_BLD}2)${C_RST}  $(t "Restart services" "重启服务")\n"
            printf "  ${C_BLD}3)${C_RST}  $(t "Stop services" "停止服务")\n"
            printf "  ${C_DIM}── $(t "Configuration" "配置") ──${C_RST}\n"
            printf "  ${C_BLD}4)${C_RST}  $(t "Change configuration (TOML / Web mode wizard)" "修改配置（TOML / Web 模式向导）")\n"
            printf "  ${C_BLD}5)${C_RST}  $(t "Web console management" "Web 控制台管理")\n"
            printf "  ${C_DIM}── $(t "Maintenance" "安装维护") ──${C_RST}\n"
            printf "  ${C_BLD}6)${C_RST}  $(t "Update / reinstall (choose version)" "更新 / 重装（选择版本）")\n"
            printf "  ${C_BLD}7)${C_RST}  $(t "File locations & logs" "文件位置与日志")\n"
            printf "  ${C_BLD}8)${C_RST}  $(t "Uninstall EasyTier" "卸载 EasyTier")\n"
            printf "\n"
            printf "  ${C_BLD}0)${C_RST}  $(t "Exit" "退出")\n"
        else
            printf "  ${C_BLD}1)${C_RST}  $(t "Install" "安装")\n"
            printf "  ${C_BLD}0)${C_RST}  $(t "Exit" "退出")\n"
        fi
        printf "  ─────────────────────────────────────────────────\n"
        printf '%s' "$(t "  Select: " "  请选择: ")"
        read -r choice

        # ── Not installed: only "Install" and "Exit" ──────────────────
        if [ ! -f /usr/bin/easytier-core ]; then
            case "$choice" in
                0) printf "\n  $(t "Bye" "再见")\n\n"; _log "INFO" "Script exit"; exit 0 ;;
                1)
                    select_version                   || continue
                    do_download "$VER" "$ARCH_NAME"  || continue
                    do_install_bins "$EXTRACT_DIR"   || continue
                    if do_setup_mode; then
                        svc_write_core
                        svc_start
                        check_proc easytier-core "easytier-core"
                    else
                        msg_warn "$(t "Binaries installed; complete configuration later via '4) Change configuration'" "二进制已安装，请稍后通过主菜单「4) 修改配置」完成配置")"
                    fi
                    show_file_locations
                    ;;
                *) msg_warn "$(t "Invalid input" "无效输入")" ;;
            esac
            continue
        fi

        case "$choice" in

            # ── Exit ────────────────────────────────────────────────
            0) printf "\n  $(t "Bye" "再见")\n\n"; _log "INFO" "Script exit"; exit 0 ;;

            # ── Status ───────────────────────────────────────
            1) do_view_status ;;

            # ── Restart services ─────────────────────────────
            2)
                msg_info "$(t "Restarting easytier-core..." "重启 easytier-core...")"
                svc_restart
                check_proc easytier-core "easytier-core"
                if [ -f /etc/easytier/web.args ]; then
                    printf '%s' "$(t "  Also restart easytier-web-embed? [Y/n]: " "  同时重启 easytier-web-embed? [Y/n]: ")"
                    read -r a
                    case "$a" in
                        n|N) ;;
                        *)  svc_restart_web
                            check_proc easytier-web-embed "easytier-web-embed" ;;
                    esac
                fi
                ;;

            # ── Stop services ────────────────────────────────
            3)
                msg_info "$(t "Stopping easytier-core..." "停止 easytier-core...")"
                svc_stop && msg_ok "$(t "Stopped" "已停止")"
                if _proc_running "easytier-web-embed"; then
                    printf '%s' "$(t "  Also stop easytier-web-embed? [y/N]: " "  同时停止 easytier-web-embed? [y/N]: ")"
                    read -r a
                    case "$a" in
                        y|Y) svc_stop_web && msg_ok "$(t "easytier-web-embed stopped" "easytier-web-embed 已停止")" ;;
                        *) ;;
                    esac
                fi
                ;;

            # ── Reconfigure ─────────────────────────────────────────────
            4)
                if do_setup_mode; then
                    svc_write_core
                    svc_stop 2>/dev/null || true
                    svc_start
                    check_proc easytier-core "easytier-core"
                fi
                ;;

            # ── Web management ───────────────────────────────────
            5)
                # submenu 3 in do_manage_web calls setup_web_console, which installs web-embed on demand
                do_manage_web
                ;;

            # ── Update / reinstall ─────────────────────────────────────
            6)
                select_version || continue

                local cur latest
                cur=$(/usr/bin/easytier-core --version 2>&1 | \
                      awk '{print $2}' | cut -d'-' -f1)
                latest=$(printf '%s' "$VER" | sed 's/^v//')

                section "$(t "Update method" "更新方式")"
                printf "  ${C_BLD}1)${C_RST}  $(t "Update binaries only (keep current config)" "仅更新二进制（保留现有配置）")\n"
                printf "  ${C_BLD}2)${C_RST}  $(t "Update binaries and reconfigure" "更新二进制并重新配置")\n"
                [ "$cur" = "$latest" ] && \
                    msg_warn "$(t "Already on ${VER}; choosing 1 reinstalls the same version" "当前已是 ${VER}，选 1 将重装相同版本")"
                printf "  ${C_BLD}0)${C_RST}  $(t "Back" "返回")\n\n"
                printf '%s' "$(t "  Select [0-2, default 1]: " "  请选择 [0-2，默认 1]: ")"
                read -r up
                [ -z "$up" ] && up=1

                case "$up" in
                    0) continue ;;
                    1)
                        do_download "$VER" "$ARCH_NAME"  || continue
                        do_install_bins "$EXTRACT_DIR"   || continue
                        # web.args present means web-embed ran here; upgrade it on demand too
                        [ -f /etc/easytier/web.args ] && _install_extra_bin easytier-web-embed
                        # rewrite service files (systemd ExecStart embeds the path, needs updating)
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
                            msg_warn "$(t "Configuration skipped; binaries updated but services not restarted" "已跳过配置，二进制已更新但服务未重启")"
                        fi
                        ;;
                    *) msg_warn "$(t "Invalid input" "无效输入")"; continue ;;
                esac
                show_file_locations
                ;;

            # ── File locations & logs ───────────────────────────────────
            7) show_file_locations ;;

            # ── Uninstall ────────────────────────────────────────────────
            8) do_uninstall || true ;;

            *) msg_warn "$(t "Invalid input" "无效输入")" ;;
        esac
    done
}

# Run main unless the script is sourced for testing (ET_SOURCE_ONLY=1)
[ "${ET_SOURCE_ONLY:-0}" = "1" ] || main "$@"
