#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` — not POSIX strict, but widely supported (dash/busybox)
# shellcheck disable=SC2059  # printf format with color vars — intentional for ANSI codes
# shellcheck disable=SC2155  # declare-and-assign — readable for local scalar capture
# ==============================================================================
#  easytier-manager.sh — EasyTier install & management script
#  Version: see SCRIPT_VERSION below (single source; menu title & logs both read it)
#  Repo: https://github.com/razaxq/easytier-manager
#  Upstream: https://github.com/EasyTier/EasyTier
#  License: MIT (c) 2026 razaxq
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
#    ET_VERSION=v2.4.5           — version to install
#    ET_MODE=toml|web            — config mode
#    ET_INSTANCE_NAME=mynode     — node instance name
#    ET_VIRTUAL_IP=10.0.0.1/24  — virtual IPv4 (with mask)
#    ET_NETWORK_NAME=mynet       — virtual network name
#    ET_NETWORK_SECRET=xxx       — network secret (auto-generated if empty)
#    ET_PEERS=tcp://a:11010,tcp://b:11010  — comma-separated peer list
#    ET_PROXY_CIDR=192.168.1.0/24          — subnet proxy CIDR (optional)
#    ET_WEB_URL=udp://host:22020/user      — Web mode join URL
#    ET_FILE_LOG_DIR=...                   — core log directory
#    ET_FILE_LOG_LEVEL=off|error|warn|info|debug|trace
#    ET_FILE_LOG_SIZE=<MB>                 — size per log file
#    ET_FILE_LOG_COUNT=<N>                 — number of logs to keep
#    ET_INSTALL_WEB_GUI=1                  — install easytier-web GUI client
#    ET_DEFAULT_VERSION=v2.4.5             — fallback version when GitHub API fails
# Note: defaults are in the ── Tunables ── section below; on procd (OpenWrt) BACKUP_KEEP/LOG_SIZE/LOG_COUNT
#     are auto-tightened by main() (values you set explicitly still win)
# ==============================================================================

SCRIPT_VERSION="2.4.0"

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

# All managed binaries (install / backup rotation / uninstall / status all iterate this list; add new binaries here only)
ET_ALL_BINS="easytier-core easytier-cli easytier-web easytier-web-embed"

# core file-log params — default avoids EasyTier writing 100MB×10 into the process cwd
# Note: on OpenWrt /var → /tmp (tmpfs), cleared on reboot; persistent on other distros
ET_FILE_LOG_DIR="${ET_FILE_LOG_DIR:-/var/log/easytier}"
ET_FILE_LOG_LEVEL="${ET_FILE_LOG_LEVEL:-error}"  # off|error|warn|info|debug|trace
ET_FILE_LOG_SIZE="${ET_FILE_LOG_SIZE:-10}"       # size per log file (MB)
ET_FILE_LOG_COUNT="${ET_FILE_LOG_COUNT:-5}"      # max log files to keep

# ── Runtime state (filled by detection, do not edit by hand) ──────────────
OS_TYPE=""      # openwrt | debian | rhel | arch | alpine | unknown
INIT_SYS=""     # procd | systemd | openrc | unknown
ARCH_NAME=""    # x86_64 | aarch64 | armv7 | riscv64 | unknown
VER=""          # selected version (set by select_version; falls back to $ET_DEFAULT_VERSION)
EXTRACT_DIR=""  # extraction dir (set by do_download)
KEEP_BACKUP=0   # do_install_bins decides whether to back up; _install_extra_bin reuses it

# TOML wizard temp vars
_TOML_INSTANCE=""
_TOML_IP=""
_TOML_NET_NAME=""
_TOML_NET_SECRET=""
_TOML_PEERS=""          # space-separated
_TOML_PROXY_CIDR=""

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
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        >> "$LOG_FILE" 2>/dev/null || true
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
#
#  Note: the old trap pointed INT at _cleanup without exiting — Ctrl+C only silently deleted
#        the temp dir and the script kept running, i.e. you could not interrupt. This now truly exits safely.
# ==============================================================================
_cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
    # fallback cleanup of atomic-write temp files (the normal path already removes/renames them)
    rm -f /etc/easytier/*.tmp.[0-9]*      /usr/bin/*.tmp.[0-9]* \
          /etc/init.d/*.tmp.[0-9]*        /etc/systemd/system/*.tmp.[0-9]* 2>/dev/null || true
}

_on_signal() {
    printf '\n'
    msg_warn "Interrupt received, exiting safely…"
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
    msg_warn "Interrupted as requested; uncommitted changes discarded, exiting safely"
    exit 130
}

# Leave critical section: restore normal signal handling; if interrupted during it (commit already done atomically), exit safely
crit_end() {
    trap '_on_signal' INT TERM HUP
    if [ "$_SIG_PENDING" = "1" ]; then
        printf '\n'
        msg_warn "Current operation completed; exiting safely as requested"
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

    msg_err "Missing dependencies:${missing}"
    case "$OS_TYPE" in
        openwrt) msg_info "opkg update && opkg install${missing}" ;;
        alpine)  msg_info "apk add${missing}" ;;
        debian)  msg_info "apt-get install -y${missing}" ;;
        rhel)    msg_info "dnf install -y${missing}" ;;
        arch)    msg_info "pacman -S${missing}" ;;
        *)       msg_info "Install via your system package manager:${missing}" ;;
    esac
    die "Please install the missing dependencies and re-run"
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
            msg_warn "Unrecognized arch: $(uname -m); EasyTier may not support this platform"
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

check_proc() {
    local bin="$1" label="${2:-$1}"
    sleep 2
    if _proc_running "$bin"; then
        msg_ok "${label} running (PID: $(_proc_pid "$bin"))"
        return 0
    fi
    msg_warn "${label} process not detected; check the logs"
    return 1
}

# Poll for port readiness: prefer nc, fall back to /proc/net/tcp
wait_for_port() {
    local port="$1" timeout="${2:-12}" i=0
    printf "    Waiting for port %s" "$port"
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
    printf " ${C_YLW}(timeout)${C_RST}\n"
    msg_warn "Port ${port} not ready; check the logs"
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
    msg_warn "${label} low on space: ${have}MB free / ~${need}MB needed"
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        die "${label} out of space; refusing to continue in non-interactive mode"
    fi
    printf "  Continue anyway? [y/N]: "
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
        msg_warn "Cannot read /dev/urandom; secret is weak, replace it manually before production" >&2
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
# 
# ==============================================================================
svc_write_core() {
    [ -f /etc/easytier/core.args ] || { msg_err "core.args not found"; return 1; }

    # systemd / openrc need the multi-line args merged into a single line
    local args_line
    args_line=$(tr '\n' ' ' < /etc/easytier/core.args | sed 's/[[:space:]]*$//')

    # normalize unknown init to systemd up front, to avoid recursing inside the critical section
    case "$INIT_SYS" in procd|systemd|openrc) ;;
        *) msg_warn "Unknown init system; writing systemd format, adjust manually"; INIT_SYS="systemd" ;;
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
    msg_ok "easytier-core service file written"
}

# ==============================================================================
#  Service file writer — web-embed
# ==============================================================================
svc_write_web() {
    [ -f /etc/easytier/web.args ] || { msg_err "web.args not found"; return 1; }

    local args_line
    args_line=$(tr '\n' ' ' < /etc/easytier/web.args | sed 's/[[:space:]]*$//')

    # normalize unknown init to systemd up front, to avoid recursing inside the critical section
    case "$INIT_SYS" in procd|systemd|openrc) ;;
        *) msg_warn "Unknown init system; writing systemd format"; INIT_SYS="systemd" ;;
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
    msg_ok "easytier-web-embed service file written"
}

# ==============================================================================
#  Version selection
# 
#  Added: show release date (GitHub published_at)
#  Returns 0 = selected ($VER)   1 = user chose 0 to go back
# ==============================================================================
select_version() {
    # non-interactive mode: use the env var directly
    if [ -n "${ET_VERSION:-}" ]; then
        VER="$ET_VERSION"
        msg_ok "Using preset version: $VER"
        return 0
    fi

    section "Select version to install"
    msg_info "Fetching release list from GitHub..."

    local json
    json=$(curl -sf --connect-timeout 10 \
        "https://api.github.com/repos/EasyTier/EasyTier/releases?per_page=${ET_RELEASES_COUNT}") || true

    mkdir -p "$TMP_DIR"
    local rel_file="${TMP_DIR}/releases.txt"

    if [ -z "$json" ]; then
        msg_warn "Fetch failed; falling back to built-in default ${ET_DEFAULT_VERSION}"
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
        msg_warn "Parse failed; falling back to built-in default ${ET_DEFAULT_VERSION}"
        VER="$ET_DEFAULT_VERSION"; return 0
    fi

    # non-interactive and no explicit ET_VERSION: take the first (latest) entry, skip interactive selection
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        VER=$(sed -n '1p' "$rel_file" | awk '{print $1}')
        [ -z "$VER" ] && VER="$ET_DEFAULT_VERSION"
        msg_ok "Non-interactive: using latest version ${VER}"
        return 0
    fi

    while true; do
        # header (all ASCII, strictly aligned with the %-16s %-14s columns of the data rows below)
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

        printf "  ${C_BLD}%3s)${C_RST}  Back\n" "0"
        printf "  %s\n" \
            "────────────────────────────────────────────────────"
        printf "  Select [0-%d, default 1]: " "$count"
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
            msg_ok "Selected: ${VER}  (released ${chosen_date})"
            return 0
        fi
        msg_warn "Invalid input, please choose again"
    done
}

# ==============================================================================
#  Download (verify first, stop services only after success)
# ==============================================================================
do_download() {
    local ver="$1" arch="$2"

    [ "$arch" = "unknown" ] && \
        die "Unrecognized arch $(uname -m); download manually from https://github.com/EasyTier/EasyTier/releases"

    local zip_name="easytier-linux-${arch}-${ver}.zip"
    local url="https://github.com/EasyTier/EasyTier/releases/download/${ver}/${zip_name}"

    section "Download EasyTier"
    msg_info "Version: ${ver}  Arch: ${arch}"
    msg_info "URL:  ${url}"

    # /tmp must hold at least the zip (~30MB) + extracted contents (~80MB)
    _check_space "/tmp" 120 "/tmp (download + extract)" || return 1

    mkdir -p "$TMP_DIR"
    if ! curl -L --progress-bar --retry 3 --retry-delay 3 --connect-timeout 15 \
            -o "${TMP_DIR}/${zip_name}" "$url"; then
        msg_err "Download failed; check your network or the version number"
        return 1
    fi

    msg_info "Extracting..."
    if ! unzip -o "${TMP_DIR}/${zip_name}" -d "${TMP_DIR}/"; then
        msg_err "Extraction failed"
        case "$OS_TYPE" in
            openwrt) msg_info "First run: opkg install unzip" ;;
            alpine)  msg_info "First run: apk add unzip" ;;
            debian)  msg_info "First run: apt-get install -y unzip" ;;
            rhel)    msg_info "First run: dnf install -y unzip" ;;
            arch)    msg_info "First run: pacman -S unzip" ;;
        esac
        return 1
    fi

    local core_path
    core_path=$(find "$TMP_DIR" -maxdepth 2 -name "easytier-core" -type f 2>/dev/null | head -1)
    [ -z "$core_path" ] && { msg_err "easytier-core not found after extraction (is the version correct?)"; return 1; }

    EXTRACT_DIR=$(dirname "$core_path")
    msg_ok "Download and extraction complete"
    return 0
}

# ==============================================================================
#  Install binaries (stop services only after download verified)
# ==============================================================================
do_install_bins() {
    local extract_dir="$1"

    msg_info "Stopping running services..."
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
            printf "  Keep old binaries as backups (.bak.<ts>)? [y/N]: "
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

    section "Installing binaries → /usr/bin/"
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
            printf "  ${C_DIM}-  %-30s  (not in this release)${C_RST}\n" "$bin"
        else
            printf "  ${C_DIM}-  %-30s  (skipped, installed on demand)${C_RST}\n" "$bin"
        fi
    done
    crit_end

    [ "$installed" -eq 0 ] && { msg_err "No installable files found"; return 1; }

    if ! /usr/bin/easytier-core --version > /dev/null 2>&1; then
        msg_err "easytier-core failed to run (incompatible architecture?)"
        return 1
    fi

    printf "\n"
    msg_ok "Installed: $(/usr/bin/easytier-core --version)"
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
        msg_ok "Installed on demand: ${bin}${size:+ ($size)}"
        return 0
    fi
    [ -f "/usr/bin/$bin" ] && return 0
    msg_warn "${bin} is not in the downloaded archive and is not installed"
    msg_info "First choose '1) Update / reinstall' in the main menu to fetch the full archive for this version"
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
            msg_info "Removing old ${label}: $(basename "$f")"
        done
}

_prune_backups() {
    for bin in $ET_ALL_BINS; do
        _prune_glob "/usr/bin/${bin}.bak.*" "binary backup"
    done
    _prune_glob "/etc/easytier/config.toml.bak.*" "config backup"
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
#
# ==============================================================================
_toml_wizard() {
    section "TOML config wizard"

    # ── Node instance name ────────────────────────────────────
    local def_name
    def_name="${ET_INSTANCE_NAME:-$(hostname 2>/dev/null || echo "easytier-node")}"
    printf "  Node instance name  [default: %s]: " "$def_name"
    [ "${ET_NONINTERACTIVE:-0}" = "1" ] && printf '\n' && _TOML_INSTANCE="$def_name" || {
        read -r _TOML_INSTANCE
        [ -z "$_TOML_INSTANCE" ] && _TOML_INSTANCE="$def_name"
    }

    # ── Virtual IP ───────────────────────────────────────
    local def_ip="${ET_VIRTUAL_IP:-}"
    while true; do
        printf "  Virtual IPv4   [e.g. 10.0.0.1/24]: "
        if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
            [ -n "$def_ip" ] || die "Non-interactive mode requires ET_VIRTUAL_IP (e.g. 10.0.0.1/24)"
            is_valid_cidr "$def_ip" || die "Invalid ET_VIRTUAL_IP format: $def_ip"
            printf '%s\n' "$def_ip"; _TOML_IP="$def_ip"; break
        fi
        read -r _TOML_IP
        [ -z "$_TOML_IP" ] && { msg_warn "Virtual IP cannot be empty"; continue; }
        is_valid_cidr "$_TOML_IP" && break
        msg_warn "Invalid format; enter a.b.c.d/n (e.g. 10.0.0.1/24)"
    done

    # ── Network name ──────────────────────────────────────
    local def_net="${ET_NETWORK_NAME:-}"
    while true; do
        printf "  Network name    [any string]: "
        if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
            [ -n "$def_net" ] || die "Non-interactive mode requires ET_NETWORK_NAME"
            printf '%s\n' "$def_net"; _TOML_NET_NAME="$def_net"; break
        fi
        read -r _TOML_NET_NAME
        [ -n "$_TOML_NET_NAME" ] && break
        msg_warn "Network name cannot be empty"
    done

    # ── Network secret ──────────────────────────────────────
    printf "  Network secret    [empty = auto-generate]: "
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        printf '\n'
        _TOML_NET_SECRET="${ET_NETWORK_SECRET:-}"
    else
        read -r _TOML_NET_SECRET
    fi
    if [ -z "$_TOML_NET_SECRET" ]; then
        _TOML_NET_SECRET=$(gen_secret)
        msg_ok "Generated a random secret"
        printf "    ${C_DIM}%s${C_RST}\n" "$_TOML_NET_SECRET"
        msg_info "Record this secret — all nodes in the same network must use the same secret"
    fi

    # ── Peer list ─────────────────────────────────────
    _TOML_PEERS=""
    if [ -n "${ET_PEERS:-}" ]; then
        # env var is comma-separated → convert to space-separated
        _TOML_PEERS=$(printf '%s' "$ET_PEERS" | tr ',' ' ')
    else
        msg_info "Enter peer addresses (optional, blank line to finish)"
        msg_info "Format: tcp://host:11010  or  udp://host:11010"
        while true; do
            printf "  Peer URL (blank line to finish): "
            local peer; read -r peer
            [ -z "$peer" ] && break
            if ! is_valid_url "$peer"; then
                msg_warn "Protocol must be tcp/udp/ws/wss, try again"
                continue
            fi
            _TOML_PEERS="${_TOML_PEERS}${_TOML_PEERS:+ }${peer}"
        done
    fi

    # ── Subnet proxy ──────────────────────────────────────
    _TOML_PROXY_CIDR="${ET_PROXY_CIDR:-}"
    if [ -z "$_TOML_PROXY_CIDR" ] && [ "${ET_NONINTERACTIVE:-0}" != "1" ]; then
        printf "  Subnet proxy CIDR [optional, e.g. 192.168.1.0/24]: "
        read -r _TOML_PROXY_CIDR
        if [ -n "$_TOML_PROXY_CIDR" ] && ! is_valid_cidr "$_TOML_PROXY_CIDR"; then
            msg_warn "Invalid CIDR format; subnet proxy ignored"
            _TOML_PROXY_CIDR=""
        fi
    fi
}

_toml_write_config() {
    local cfg="/etc/easytier/config.toml"
    local _tmp="${cfg}.tmp.$$"

    crit_begin
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
    } > "$_tmp"
    _commit_tmp "$_tmp" "$cfg" 600
    crit_end
    msg_ok "TOML config written: $cfg"
}

setup_toml_config() {
    mkdir -p /etc/easytier

    if [ -f /etc/easytier/config.toml ]; then
        if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
            msg_info "Non-interactive mode: auto-backup and overwrite config"
            cp /etc/easytier/config.toml "/etc/easytier/config.toml.bak.$(date +%s)"
            _prune_glob "/etc/easytier/config.toml.bak.*" "config backup"
        else
            printf "  Config already exists, overwrite? [y/N/0=back]: "
            read -r a
            case "$a" in
                0)    return 1 ;;
                y|Y)  cp /etc/easytier/config.toml "/etc/easytier/config.toml.bak.$(date +%s)"
                      _prune_glob "/etc/easytier/config.toml.bak.*" "config backup" ;;
                *)    msg_info "Kept the existing config"
                      # keep the existing file, but still update core.args to point at it
                      _write_core_args "--config-file" "/etc/easytier/config.toml"
                      return 0 ;;
            esac
        fi
    fi

    _toml_wizard
    _toml_write_config

    _write_core_args "--config-file" "/etc/easytier/config.toml"
    return 0
}

# ==============================================================================
#  Web console configuration
# 
# ==============================================================================
setup_web_console() {
    section "Configure easytier-web-embed"

    # install web-embed on demand (do_install_bins does not install it by default)
    _install_extra_bin easytier-web-embed || return 1

    # ── API port ──────────────────────────────────────
    local api_port
    while true; do
        printf "  Web API/frontend port   [default 11211]: "
        read -r api_port
        [ -z "$api_port" ] && api_port=11211
        is_valid_port "$api_port" && break
        msg_warn "Port range: 1-65535"
    done

    # ── Config-serving port ──────────────────────────────────
    local cfg_port
    while true; do
        printf "  Config-serving port        [default 22020]: "
        read -r cfg_port
        [ -z "$cfg_port" ] && cfg_port=22020
        is_valid_port "$cfg_port" && break
        msg_warn "Port range: 1-65535"
    done

    # ── Protocol ────────────────────────────────
    printf '\n'
    msg_info "Config-serving protocol notes:"
    msg_info "  udp — recommended, lowest latency"
    msg_info "  tcp — better NAT traversal"
    msg_info "  ws  — good behind an HTTP reverse proxy; if Cloudflare Tunnel upgrades ws to wss,"
    msg_info "        then easytier-core should join with wss (not ws)"
    printf "  Protocol (tcp/udp/ws) [default udp]: "
    local cfg_proto; read -r cfg_proto
    case "$cfg_proto" in tcp|udp|ws) ;; *) cfg_proto=udp ;; esac

    # ── API Host ────────────────────────────
    printf '\n'
    msg_info "--api-host sets the address the web frontend uses to call the API backend:"
    msg_info "  · local access only:      http://127.0.0.1:${api_port}"
    msg_info "  · Cloudflare Tunnel:  https://your-domain.example.com"
    msg_info "  (after Tunnel setup, reconfigure this via 'Web console management')"
    printf "  API Host [default http://127.0.0.1:%s]: " "$api_port"
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
    printf "  ${C_GRN}┌─ easytier-web-embed started ────────────────────────┐${C_RST}\n"
    printf "  ${C_GRN}│${C_RST}  Web console:  http://0.0.0.0:%-6s                ${C_GRN}│${C_RST}\n" "$api_port"
    printf "  ${C_GRN}│${C_RST}  Config push:  %-3s://0.0.0.0:%-6s                 ${C_GRN}│${C_RST}\n" "$cfg_proto" "$cfg_port"
    printf "  ${C_GRN}│${C_RST}  Default login:  admin / user  ${C_YLW}← change now${C_RST}         ${C_GRN}│${C_RST}\n"
    printf "  ${C_GRN}└─────────────────────────────────────────────────────┘${C_RST}\n\n"
    msg_info "First open the console in a browser and register an account, then fill in the join URL"
    return 0
}

ask_core_web_url() {
    local started_web="${1:-false}"
    section "easytier-core joining the web console"
    msg_info "Format: <protocol>://<host>:<port>/<username>"
    msg_info "Example: udp://127.0.0.1:22020/myuser"
    msg_info "      wss://easytier-web.example.com/22020/myuser"
    msg_info "Note: behind a Cloudflare Tunnel with a ws serving protocol, join with wss"

    # non-interactive mode
    if [ -n "${ET_WEB_URL:-}" ]; then
        if ! is_valid_url "$ET_WEB_URL"; then
            die "Invalid ET_WEB_URL protocol (must be tcp/udp/ws/wss://): $ET_WEB_URL"
        fi
        _write_core_args "-w" "$ET_WEB_URL"
        msg_ok "Join URL saved (non-interactive): $ET_WEB_URL"
        return 0
    fi
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        die "Non-interactive web mode requires ET_WEB_URL (e.g. udp://host:22020/user)"
    fi

    while true; do
        local hint=""
        [ "$started_web" = "true" ] && hint="/undo web-embed"
        printf "\n  Join URL [0=back%s]: " "$hint"
        read -r w_url

        case "$w_url" in
            0)
                if [ "$started_web" = "true" ]; then
                    msg_info "Undoing web-embed configuration..."
                    svc_stop_web; svc_remove_web
                    rm -f /etc/easytier/web.args
                    msg_ok "web-embed service undone"
                fi
                return 1
                ;;
            "")
                msg_warn "URL cannot be empty"
                ;;
            *)
                if ! is_valid_url "$w_url"; then
                    msg_warn "URL must start with tcp:// udp:// ws:// wss://"
                    continue
                fi
                _write_core_args "-w" "$w_url"
                msg_ok "Join URL saved: $w_url"
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
        section "Choose configuration method"
        printf "  ${C_BLD}1)${C_RST}  TOML config file  —  standalone node, local management\n"
        printf "  ${C_BLD}2)${C_RST}  Web console push —  centrally manage many nodes\n"
        printf "  ${C_BLD}0)${C_RST}  Back\n\n"
        printf "  Select [0-2]: "
        read -r mode

        case "$mode" in
            0) return 1 ;;
            1) setup_toml_config && return 0 ;;
            2)
                printf '\n'
                printf "  Run easytier-web-embed on this machine?\n"
                printf "  ${C_BLD}1)${C_RST}  Yes, deploy the web console here\n"
                printf "  ${C_BLD}2)${C_RST}  No, connect to an existing external console\n"
                printf "  ${C_BLD}0)${C_RST}  Back\n"
                printf "  Select [0-2]: "
                read -r rw
                case "$rw" in
                    0) continue ;;
                    1)
                        # setup_web_console installs easytier-web-embed on demand itself
                        setup_web_console || continue
                        ask_core_web_url "true" && return 0 || continue
                        ;;
                    2) ask_core_web_url "false" && return 0 || continue ;;
                    *) msg_warn "Invalid input" ;;
                esac
                ;;
            *) msg_warn "Invalid input" ;;
        esac
    done
}

# ==============================================================================
#  Service status view
# ==============================================================================
do_view_status() {
    section "Service status"

    _print_svc_block() {
        local label="$1" bin="$2" args_file="$3"
        printf "  ${C_BLD}[ %s ]${C_RST}\n" "$label"
        if _proc_running "$bin"; then
            printf "    Status: ${C_GRN}✓ running${C_RST} (PID: $(_proc_pid "$bin"))\n"
        else
            printf "    Status: ${C_RED}✗ stopped${C_RST}\n"
        fi
        [ -f "$args_file" ] && \
            printf "    Args: ${C_DIM}%s${C_RST}\n" "$(tr '\n' ' ' < "$args_file")"
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

    printf "  ${C_BLD}[ Log commands ]${C_RST}\n"
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
    printf "    Install log   : %s\n" "$LOG_FILE"
}

# ==============================================================================
#  Standalone web console management
# ==============================================================================
do_manage_web() {
    while true; do
        section "Web console management"

        if _proc_running "easytier-web-embed"; then
            local port=""
            [ -f /etc/easytier/web.args ] && \
                port=$(grep -A1 '^--api-server-port$' /etc/easytier/web.args 2>/dev/null \
                       | tail -1 | tr -d ' \t')
            printf "  Status: ${C_GRN}✓ running${C_RST}${port:+  (port ${port})}\n"
        else
            printf "  Status: ${C_RED}✗ stopped${C_RST}\n"
        fi
        [ -f /etc/easytier/web.args ] && \
            printf "  Args: ${C_DIM}%s${C_RST}\n" "$(tr '\n' ' ' < /etc/easytier/web.args)"

        printf '\n'
        printf "  ${C_BLD}1)${C_RST}  Start / restart\n"
        printf "  ${C_BLD}2)${C_RST}  Stop\n"
        printf "  ${C_BLD}3)${C_RST}  Reconfigure (port / api-host, etc.)\n"
        printf "  ${C_BLD}4)${C_RST}  Remove service and config\n"
        printf "  ${C_BLD}0)${C_RST}  Back to main menu\n\n"
        printf "  Select [0-4]: "
        read -r wc

        case "$wc" in
            0) return 0 ;;
            1)
                if [ ! -f /etc/easytier/web.args ]; then
                    msg_warn "web.args not found; run 'Reconfigure (3)' first"
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
            2) svc_stop_web && msg_ok "Stopped" ;;
            3) setup_web_console ;;
            4)
                printf "  Really remove the web-embed service and config files? [y/N]: "
                read -r a
                case "$a" in
                    y|Y)
                        svc_stop_web; svc_remove_web
                        rm -f /etc/easytier/web.args
                        msg_ok "Removed"
                        ;;
                    *) msg_info "Cancelled" ;;
                esac
                ;;
            *) msg_warn "Invalid input" ;;
        esac
    done
}

# ==============================================================================
#  File location display
# ==============================================================================
show_file_locations() {
    section "Installed file locations"

    printf "  ${C_BLD}[ Binaries ]${C_RST}  /usr/bin/\n"
    for bin in $ET_ALL_BINS; do
        if [ -f "/usr/bin/$bin" ]; then
            local size; size=$(du -sh "/usr/bin/$bin" 2>/dev/null | awk '{print $1}')
            printf "  ${C_GRN}✓${C_RST}  %-30s  %s\n" "$bin" "$size"
        else
            printf "  ${C_DIM}-  %-30s  (not in this release)${C_RST}\n" "$bin"
        fi
    done

    printf '\n'
    printf "  ${C_BLD}[ Config ]${C_RST}  /etc/easytier/\n"
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
    [ "$cfg_found" = false ] && printf "  ${C_DIM}(no config files)${C_RST}\n"

    printf '\n'
    printf "  ${C_BLD}[ Service files ]${C_RST}\n"
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
    [ "$svc_found" = false ] && printf "  ${C_DIM}(no service files)${C_RST}\n"

    printf '\n'
    printf "  ${C_BLD}[ Backups ]${C_RST}  /usr/bin/  ${C_DIM}(keep latest %d per binary)${C_RST}\n" \
        "$ET_BACKUP_KEEP"
    local bak_list
    bak_list=$(ls /usr/bin/easytier-*.bak.* 2>/dev/null) || true
    if [ -n "$bak_list" ]; then
        printf '%s\n' "$bak_list" | while read -r f; do
            local size; size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
            printf "  ${C_DIM}*  %-44s  %s${C_RST}\n" "$(basename "$f")" "$size"
        done
    else
        printf "  ${C_DIM}(no backup files)${C_RST}\n"
    fi

    printf '\n'
    printf "  ${C_BLD}[ Logs ]${C_RST}\n"
    printf "  Install log: %s\n" "$LOG_FILE"
    if [ -d "$ET_FILE_LOG_DIR" ]; then
        local cur_log_size
        cur_log_size=$(du -sh "$ET_FILE_LOG_DIR" 2>/dev/null | awk '{print $1}')
        printf "  Core logs: %s/  ${C_DIM}(now %s, cap %dMB×%d, level %s)${C_RST}\n" \
            "$ET_FILE_LOG_DIR" "${cur_log_size:-?}" \
            "$ET_FILE_LOG_SIZE" "$ET_FILE_LOG_COUNT" "$ET_FILE_LOG_LEVEL"
    fi
    case "$INIT_SYS" in
        procd)   printf "  Runtime log: logread -f | grep easytier\n" ;;
        systemd) printf "  Runtime log: journalctl -u easytier -f\n"
                 [ -f /etc/systemd/system/easytier-web.service ] && \
                     printf "            journalctl -u easytier-web -f\n" ;;
        openrc)  printf "  Runtime log: tail -f /var/log/easytier.log\n" ;;
    esac

    # old versions (< 2.1.0) without --file-log-dir wrote 100MB×10 logs to cwd
    if ls /easytier.log /easytier.log.[0-9] /easytier.log.[0-9][0-9] >/dev/null 2>&1; then
        local legacy_size
        legacy_size=$(du -ch /easytier.log* 2>/dev/null | tail -1 | awk '{print $1}')
        printf '\n'
        printf "  ${C_YLW}⚠  Found legacy logs /easytier.log* (%s); remove manually${C_RST}\n" \
            "${legacy_size:-?}"
        printf "  ${C_DIM}   rm -f /easytier.log /easytier.log.[0-9] /easytier.log.[0-9][0-9]${C_RST}\n"
    fi
}

# ==============================================================================
#  Uninstall — single binary (also removes its service, but leaves config/backups/logs)
# ==============================================================================
_uninstall_one() {
    local bin="$1"
    printf "  Really remove ${C_BLD}%s${C_RST}? [y/N]: " "$bin"
    local a; read -r a
    case "$a" in y|Y) ;; *) msg_info "Cancelled"; return 1 ;; esac

    case "$bin" in
        easytier-core)
            msg_info "Stopping and removing the easytier service..."
            svc_stop; svc_remove
            _kill_bin easytier-core
            ip link del easytier0 2>/dev/null || true
            ;;
        easytier-web-embed)
            msg_info "Stopping and removing the easytier-web service..."
            svc_stop_web; svc_remove_web
            _kill_bin easytier-web-embed
            ;;
    esac

    rm -f "/usr/bin/$bin"
    msg_ok "${bin} removed"
    return 0
}

# ==============================================================================
#  Uninstall — everything (services/config/backups/logs/legacy logs)
# ==============================================================================
_uninstall_all() {
    printf "  ${C_YLW}⚠  This removes all EasyTier services and binaries${C_RST}\n"
    printf "  Confirm full uninstall? [y/N]: "
    local a; read -r a
    case "$a" in y|Y) ;; *) msg_info "Cancelled"; return 1 ;; esac

    msg_info "Stopping and removing services..."
    svc_stop; svc_stop_web
    svc_remove; svc_remove_web
    _kill_bin easytier-core
    _kill_bin easytier-web-embed
    for bin in $ET_ALL_BINS; do
        rm -f "/usr/bin/$bin"
    done
    ip link del easytier0 2>/dev/null || true
    msg_ok "Binaries and services removed"

    local bak_list
    bak_list=$(ls /usr/bin/easytier-*.bak.* 2>/dev/null) || true
    if [ -n "$bak_list" ]; then
        local bak_count
        bak_count=$(printf '%s\n' "$bak_list" | wc -l | tr -d ' ')
        printf "  Delete %d backup file(s)? [y/N]: " "$bak_count"
        read -r a
        case "$a" in
            y|Y) printf '%s\n' "$bak_list" | while read -r f; do rm -f "$f"; done
                 msg_ok "Backup files removed" ;;
            *)   msg_info "Backup files kept in /usr/bin/" ;;
        esac
    fi

    printf "  Delete config dir /etc/easytier? [y/N]: "
    read -r a
    case "$a" in
        y|Y) rm -rf /etc/easytier && msg_ok "Config dir deleted" ;;
        *)   msg_info "Config dir kept: /etc/easytier" ;;
    esac

    if [ -d "$ET_FILE_LOG_DIR" ]; then
        local log_size
        log_size=$(du -sh "$ET_FILE_LOG_DIR" 2>/dev/null | awk '{print $1}')
        printf "  Delete log dir %s (%s)? [y/N]: " "$ET_FILE_LOG_DIR" "${log_size:-?}"
        read -r a
        case "$a" in
            y|Y) rm -rf "$ET_FILE_LOG_DIR" && msg_ok "Log dir deleted" ;;
            *)   msg_info "Log dir kept: $ET_FILE_LOG_DIR" ;;
        esac
    fi

    # legacy: before v2.0.x without --file-log-dir, core wrote logs to cwd (=/ on procd)
    local legacy
    legacy=$(ls /easytier.log /easytier.log.[0-9] /easytier.log.[0-9][0-9] 2>/dev/null) || true
    if [ -n "$legacy" ]; then
        local n; n=$(printf '%s\n' "$legacy" | wc -l | tr -d ' ')
        printf "  Found %d legacy log file(s) (/easytier.log*), delete? [y/N]: " "$n"
        read -r a
        case "$a" in
            y|Y) printf '%s\n' "$legacy" | while read -r f; do rm -f "$f"; done
                 msg_ok "Legacy logs removed" ;;
            *)   msg_info "Legacy logs kept" ;;
        esac
    fi

    msg_ok "Uninstall complete"
    return 0
}

# ==============================================================================
#  Uninstall entry — let the user pick a single binary or everything
# ==============================================================================
do_uninstall() {
    section "Uninstall EasyTier"

    # collect the currently installed binaries
    local installed="" idx=0
    for bin in $ET_ALL_BINS; do
        [ -f "/usr/bin/$bin" ] && installed="${installed}${installed:+ }$bin"
    done
    if [ -z "$installed" ]; then
        msg_warn "No EasyTier binaries found"
        return 1
    fi

    printf "  Installed binaries:\n\n"
    idx=0
    for bin in $installed; do
        idx=$((idx + 1))
        local size; size=$(du -sh "/usr/bin/$bin" 2>/dev/null | awk '{print $1}')
        local tag=""
        case "$bin" in
            easytier-core)      tag="  ${C_DIM}(incl. easytier service)${C_RST}" ;;
            easytier-web-embed) tag="  ${C_DIM}(incl. easytier-web service)${C_RST}" ;;
        esac
        printf "  ${C_BLD}%d)${C_RST}  %-22s %s%s\n" "$idx" "$bin" "$size" "$tag"
    done
    local all_idx=$((idx + 1))
    printf "  ${C_BLD}%d)${C_RST}  ${C_YLW}Delete all${C_RST}  ${C_DIM}(incl. services/config/backups/logs)${C_RST}\n" "$all_idx"
    printf "  ${C_BLD}0)${C_RST}  Back\n\n"
    printf "  Select [0-%d]: " "$all_idx"
    local choice; read -r choice

    [ "$choice" = "0" ] && return 1
    [ "$choice" = "$all_idx" ] && { _uninstall_all; return $?; }

    # validate the numeric range
    if ! printf '%s' "$choice" | grep -qE '^[0-9]+$' || \
       [ "$choice" -lt 1 ] || [ "$choice" -gt "$idx" ]; then
        msg_warn "Invalid choice"
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
    local cur="" mode_str="not configured" web_str=""

    [ -f /usr/bin/easytier-core ] && \
        cur=$(/usr/bin/easytier-core --version 2>&1 | awk '{print $2}' | cut -d'-' -f1)

    if [ -f /etc/easytier/core.args ]; then
        local first; first=$(head -1 /etc/easytier/core.args)
        case "$first" in
            --config-file) mode_str="TOML config file" ;;
            -w)
                local wurl; wurl=$(sed -n '2p' /etc/easytier/core.args 2>/dev/null)
                mode_str="Web console (${wurl})"
                ;;
        esac
    fi

    if _proc_running "easytier-web-embed"; then
        local port=""
        [ -f /etc/easytier/web.args ] && \
            port=$(grep -A1 '^--api-server-port$' /etc/easytier/web.args 2>/dev/null \
                   | tail -1 | tr -d ' ')
        web_str="${C_GRN}✓ running${C_RST}${port:+  (port ${port})}"
    elif [ -f /etc/easytier/web.args ]; then
        web_str="${C_YLW}✗ configured but not running${C_RST}"
    fi

    # separator width is content-independent, sidestepping CJK double-width alignment issues
    local SEP="${C_BLD}  ──────────────────────────────────────────${C_RST}"
    printf "\n%s\n" "$SEP"
    printf "  ${C_BLD}  EasyTier Manager${C_RST}  v%s\n" "$SCRIPT_VERSION"
    printf "%s\n" "$SEP"
    # label column widths (System/Arch/Version/Config) — kept simple for alignment
    # values follow the labels directly, no right-border alignment needed
    printf "  System  %-12s  Arch  %s\n" "$OS_TYPE" "$ARCH_NAME"
    printf "  Init  %s\n" "$INIT_SYS"
    if [ -n "$cur" ]; then
        printf "  Version  %s\n" "$cur"
        printf "  Config   %s\n" "$mode_str"
        [ -n "$web_str" ] && printf "  Web   %s\n" "$web_str"
    else
        printf "  ${C_YLW}Status  not installed${C_RST}\n"
    fi
    printf "%s\n" "$SEP"
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

    check_deps

    _log "INFO" "Script start v${SCRIPT_VERSION} OS=${OS_TYPE} INIT=${INIT_SYS} ARCH=${ARCH_NAME} BACKUP=${ET_BACKUP_KEEP} LOG=${ET_FILE_LOG_SIZE}MB×${ET_FILE_LOG_COUNT}"

    # ── Non-interactive mode: do the install / update once, then exit (for CI / Ansible) ────
    # the interactive menu needs a tty; non-interactively stdin is EOF and the menu would spin, so dispatch here directly.
    if [ "${ET_NONINTERACTIVE:-0}" = "1" ]; then
        select_version                   || die "Version selection failed"
        do_download "$VER" "$ARCH_NAME"  || die "Download failed"
        do_install_bins "$EXTRACT_DIR"   || die "Install failed"
        # if web-embed was deployed, upgrade it too to avoid version skew with core
        [ -f /etc/easytier/web.args ] && _install_extra_bin easytier-web-embed
        do_setup_mode                    || die "Configuration failed (check ET_MODE / ET_VIRTUAL_IP / ET_WEB_URL, etc.)"
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
        msg_warn "Detected old core.args missing log params; appending --file-log-*"
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
        msg_info "Choose '4) Restart services only' in the main menu to apply the new params"
    fi

    while true; do
        _print_header

        printf '\n'
        if [ -f /usr/bin/easytier-core ]; then
            printf "  ${C_BLD}1)${C_RST}  Update / reinstall (choose version)\n"
            printf "  ${C_BLD}2)${C_RST}  Uninstall\n"
            printf "  ${C_BLD}3)${C_RST}  Reconfigure and restart services\n"
            printf "  ${C_BLD}4)${C_RST}  Restart services only\n"
            printf "  ${C_BLD}5)${C_RST}  View service status\n"
            printf "  ${C_BLD}6)${C_RST}  Web console management\n"
            printf "  ${C_BLD}7)${C_RST}  Show installed file locations\n"
            printf "  ${C_BLD}0)${C_RST}  Exit\n"
        else
            printf "  ${C_BLD}1)${C_RST}  Install\n"
            printf "  ${C_BLD}0)${C_RST}  Exit\n"
        fi
        printf "  ─────────────────────────────────────────────────\n"
        printf "  Select: "
        read -r choice

        case "$choice" in

            # ── Exit ────────────────────────────────────────────────
            0) printf "\n  Bye\n\n"; _log "INFO" "Script exit"; exit 0 ;;

            # ── Install / update ─────────────────────────────────────────
            1)
                select_version || continue

                if [ -f /usr/bin/easytier-core ]; then
                    local cur latest
                    cur=$(/usr/bin/easytier-core --version 2>&1 | \
                          awk '{print $2}' | cut -d'-' -f1)
                    latest=$(printf '%s' "$VER" | sed 's/^v//')

                    section "Update method"
                    printf "  ${C_BLD}1)${C_RST}  Update binaries only (keep current config)\n"
                    printf "  ${C_BLD}2)${C_RST}  Update binaries and reconfigure\n"
                    [ "$cur" = "$latest" ] && \
                        msg_warn "Already on ${VER}; choosing 1 reinstalls the same version"
                    printf "  ${C_BLD}0)${C_RST}  Back\n\n"
                    printf "  Select [0-2, default 1]: "
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
                                msg_warn "Configuration skipped; binaries updated but services not restarted"
                            fi
                            ;;
                        *) msg_warn "Invalid input"; continue ;;
                    esac
                else
                    # fresh install
                    do_download "$VER" "$ARCH_NAME"  || continue
                    do_install_bins "$EXTRACT_DIR"   || continue
                    if do_setup_mode; then
                        svc_write_core
                        svc_start
                        check_proc easytier-core "easytier-core"
                    else
                        msg_warn "Binaries installed; complete configuration later via option 3"
                    fi
                fi
                show_file_locations
                ;;

            # ── Uninstall ────────────────────────────────────────────────
            2)
                [ -f /usr/bin/easytier-core ] || { msg_warn "EasyTier is not installed"; continue; }
                do_uninstall || true
                ;;

            # ── Reconfigure ─────────────────────────────────────────────
            3)
                [ -f /usr/bin/easytier-core ] || { msg_warn "EasyTier is not installed"; continue; }
                if do_setup_mode; then
                    svc_write_core
                    svc_stop 2>/dev/null || true
                    svc_start
                    check_proc easytier-core "easytier-core"
                fi
                ;;

            # ── Restart only ─────────────────────────────────────
            4)
                [ -f /usr/bin/easytier-core ] || { msg_warn "EasyTier is not installed"; continue; }
                msg_info "Restarting easytier-core..."
                svc_restart
                check_proc easytier-core "easytier-core"
                if [ -f /etc/easytier/web.args ]; then
                    printf "  Also restart easytier-web-embed? [Y/n]: "
                    read -r a
                    case "$a" in
                        n|N) ;;
                        *)  svc_restart_web
                            check_proc easytier-web-embed "easytier-web-embed" ;;
                    esac
                fi
                ;;

            # ── Status ───────────────────────────────────────
            5) do_view_status ;;

            # ── Web management ───────────────────────────────────
            6)
                # submenu 3 in do_manage_web calls setup_web_console, which installs web-embed on demand
                do_manage_web
                ;;

            # ── File locations ─────────────────────────────────────────────
            7) show_file_locations ;;

            *) msg_warn "Invalid input" ;;
        esac
    done
}

main