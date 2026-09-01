#!/bin/sh
# shellcheck disable=SC2034  # these globals drive the sourced easytier.sh; ShellCheck
#                              cannot see reads that happen across the source boundary
set -eu

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/easytier-manager-core-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP

ET_SOURCE_ONLY=1
ET_LANG=en
LOG_FILE="$TEST_DIR/manager.log"
ET_CACHE_DIR="$TEST_DIR/cache"
ET_CORE_ARGS_FILE="$TEST_DIR/core.args"
ET_CORE_BIN_FILE="$TEST_DIR/no-core"
export ET_SOURCE_ONLY ET_LANG LOG_FILE ET_CACHE_DIR ET_CORE_ARGS_FILE ET_CORE_BIN_FILE

# shellcheck source=../easytier.sh
. "$(dirname "$0")/../easytier.sh"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP
_init_colors

TEST_NO=0
fail() { printf 'not ok %d - %s\n' "$((TEST_NO + 1))" "$1" >&2; exit 1; }
pass() { TEST_NO=$((TEST_NO + 1)); printf 'ok %d - %s\n' "$TEST_NO" "$1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (wanted '$1', got '$2')"; pass "$3"; }

is_valid_cidr 10.0.0.1/24 || fail 'valid IPv4 CIDR was rejected'
! is_valid_cidr 999.999.999.999/32 || fail 'out-of-range IPv4 CIDR was accepted'
! is_valid_cidr 256.1.1.1/8 || fail 'IPv4 octet 256 was accepted'
pass 'IPv4 CIDR validation checks octet ranges'

is_valid_base_port 65533 || fail 'largest valid base port was rejected'
! is_valid_base_port 65534 || fail 'base port that overflows derived listeners was accepted'
pass 'base listener port reserves space for +1 and +2'

escaped=$(_toml_escape 'node\path"quoted')
assert_eq 'node\\path\"quoted' "$escaped" 'TOML string escaping handles slashes and quotes'

is_valid_url 'tcp://example.com:11010' || fail 'valid peer URL was rejected'
! is_valid_url 'tcp://' || fail 'empty peer URL was accepted'
! is_valid_url 'tcp://example.com:11010 bad' || fail 'peer URL containing whitespace was accepted'
pass 'peer URL validation rejects empty and whitespace-containing values'

ET_ARCH=armv7hf
_detect_arch || fail 'valid ET_ARCH override was rejected'
assert_eq armv7hf "$ARCH_NAME" 'explicit architecture override is honored'

ET_NONINTERACTIVE=1
ET_CACHE_TTL=0
TMP_DIR="$TEST_DIR/version"
ET_ALLOW_PRERELEASE=0
ET_ALLOW_VERSION_FALLBACK=0
_gh_api() {
    printf '%s\n' \
        '  "tag_name": "v9.0.0-rc1",' \
        '  "published_at": "2026-09-01T00:00:00Z",' \
        '  "prerelease": true,' \
        '  "tag_name": "v8.0.0",' \
        '  "published_at": "2026-08-01T00:00:00Z",' \
        '  "prerelease": false,'
}
select_version >/dev/null || fail 'stable automatic version selection failed'
assert_eq v8.0.0 "$VER" 'non-interactive selection skips pre-releases by default'

ET_ALLOW_PRERELEASE=1
select_version >/dev/null || fail 'pre-release opt-in selection failed'
assert_eq v9.0.0-rc1 "$VER" 'pre-release selection requires explicit opt-in'

_gh_api() { return 1; }
ET_ALLOW_PRERELEASE=0
set +e
select_version >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'release API failure silently selected a fallback version'
pass 'release API failure aborts instead of silently downgrading'

ET_ALLOW_VERSION_FALLBACK=1
ET_DEFAULT_VERSION=v2.6.4
select_version >/dev/null || fail 'explicit fallback opt-in failed'
assert_eq v2.6.4 "$VER" 'fallback version requires explicit opt-in'

_gh_api() {
    printf '%s\n' \
        '"assets": [' \
        '  {' \
        '    "name": "easytier-linux-x86_64-v2.6.4.zip",' \
        '    "uploader": {"name": "release-bot"},' \
        '    "digest": "sha256:61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6"' \
        '  }' \
        ']'
}
digest=$(_release_sha256 v2.6.4 easytier-linux-x86_64-v2.6.4.zip)
assert_eq 61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6 "$digest" \
    'official release asset digest is extracted by exact asset name'

# An asset published before GitHub added digests must report "unavailable", never
# borrow the digest of the asset that follows it.
_gh_api() {
    printf '%s\n' \
        '"assets": [' \
        '  {' \
        '    "name": "easytier-linux-armv7-v2.6.4.zip",' \
        '    "browser_download_url": "https://example.invalid/armv7.zip"' \
        '  },' \
        '  {' \
        '    "name": "easytier-linux-x86_64-v2.6.4.zip",' \
        '    "digest": "sha256:61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6",' \
        '    "browser_download_url": "https://example.invalid/x86_64.zip"' \
        '  }' \
        ']'
}
set +e
digest=$(_release_sha256 v2.6.4 easytier-linux-armv7-v2.6.4.zip)
rc=$?
set -e
[ "$rc" -ne 0 ] && [ -z "$digest" ] || fail 'a digest-less asset borrowed another asset digest'
pass 'a digest-less asset is reported as unavailable'

is_valid_version_tag v2.6.4 || fail 'a normal release tag was rejected'
is_valid_version_tag v2.6.4-rc1 || fail 'a pre-release tag was rejected'
! is_valid_version_tag '../../etc' || fail 'a path traversal tag was accepted'
! is_valid_version_tag 'v2.6.4 extra' || fail 'a tag containing whitespace was accepted'
pass 'release tags are validated before reaching a URL'

is_valid_rpc_portal 127.0.0.1:15888 || fail 'a loopback RPC portal was rejected'
is_valid_rpc_portal '[::1]:15888' || fail 'an IPv6 RPC portal was rejected'
is_valid_rpc_portal '' || fail 'an empty RPC portal (upstream default) was rejected'
! is_valid_rpc_portal 999.1.1.1:15888 || fail 'an out-of-range RPC portal host was accepted'
! is_valid_rpc_portal 127.0.0.1:70000 || fail 'an out-of-range RPC portal port was accepted'
pass 'RPC portal addresses are validated'

ET_FILE_LOG_DIR="$TEST_DIR/logs"
_write_core_args -w 'udp://127.0.0.1:22020/tester' >/dev/null 2>&1 || \
    fail 'writing Web-mode core.args failed'
assert_eq '-w' "$(sed -n 1p "$ET_CORE_ARGS_FILE")" \
    'the mode option stays on line 1 so Web-mode detection keeps working'
grep -q -- '^--rpc-portal$' "$ET_CORE_ARGS_FILE" || \
    fail 'core.args does not pin the RPC portal'
assert_eq "$ET_RPC_PORTAL" "$(_rpc_portal_addr)" 'the CLI reads the portal back from core.args'
rm -f "$ET_CORE_ARGS_FILE"   # the next case asserts a failed commit leaves no target

_commit_tmp() { return 1; }
set +e
_write_core_args --config-file "$TEST_DIR/config.toml" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'failed atomic commit was reported as success'
[ ! -e "$ET_CORE_ARGS_FILE" ] || fail 'failed atomic commit created the target file'
pass 'atomic write failures propagate to callers'

# Values reaching core.args / web.args are re-read by the service files: OpenRC
# interpolates them in a double-quoted shell assignment, systemd expands $VAR.
is_safe_arg_value 'http://127.0.0.1:11211' || fail 'a plain URL was rejected'
is_safe_arg_value 'udp://h:22020/my%20user' || fail 'a percent-encoded URL was rejected'
! is_safe_arg_value 'http://$(id -u).example.com' || fail 'command substitution was accepted'
! is_safe_arg_value 'http://`id`.example.com' || fail 'a backquote was accepted'
! is_safe_arg_value 'http://a b.example.com' || fail 'an embedded space was accepted'
! is_safe_arg_value 'http://x".example.com' || fail 'a double quote was accepted'
pass 'shell metacharacters cannot reach a generated service file'

# POSIX `read` has no line editing: an arrow key inserts a raw ESC [ C sequence
# that is invisible in the terminal and in `cat`, so it must never validate.
ESC_SEQ=$(printf '\033[C')
! is_valid_url "wss://easytier-cfg.example.com/user${ESC_SEQ}" || \
    fail 'a join URL carrying an arrow-key escape sequence was accepted'
! is_safe_arg_value "http://example.com${ESC_SEQ}" || \
    fail 'control characters could reach a service file'
! is_printable_text "mynode${ESC_SEQ}" || fail 'control characters passed the text check'
is_printable_text 'my node-01_x' || fail 'ordinary text was rejected'
_warn_ctrl_input "x${ESC_SEQ}" >/dev/null || fail 'control input did not raise the arrow-key hint'
! _warn_ctrl_input 'clean-value' >/dev/null || fail 'clean input raised the arrow-key hint'
pass 'stray escape sequences are rejected instead of entering the config'

is_valid_http_url 'https://console.example.com' || fail 'a valid api-host was rejected'
! is_valid_http_url 'udp://console.example.com' || fail 'a non-http api-host was accepted'
! is_valid_http_url 'http://$(reboot).example.com' || fail 'an injected api-host was accepted'
pass 'api-host is validated as an http(s) URL'

# systemd reads '%' in ExecStart as a specifier; a literal one has to be doubled.
assert_eq 'a%%20b' "$(_systemd_escape_args 'a%20b')" 'percent signs are escaped for systemd'

# uninstall runs `rm -rf` on the log directory, so system paths must be refused
is_safe_data_path /var/log/easytier || fail 'the default log directory was rejected'
is_safe_data_path /var/lib/easytier-web/et.db || fail 'the default database path was rejected'
for unsafe in / /var /etc /var/log /usr/local /var/log/ /var/log/../.. ; do
    ! is_safe_data_path "$unsafe" || fail "unsafe data path accepted: $unsafe"
done
pass 'system directories are refused as data paths'

# `\|` alternation is a GNU extension; musl treats it as a literal pipe
ET_CORE_SERVICE_FILE="$TEST_DIR/easytier.service"
printf 'ExecStart=/usr/bin/easytier-core -w udp://h/u --machine-id "abc-123"\n' \
    > "$ET_CORE_SERVICE_FILE"
assert_eq 'abc-123' "$(_machine_id_from_service)" \
    'quotes around a service-file machine ID are stripped portably'

ET_CORE_CONFIG_FILE="$TEST_DIR/config.toml"
printf 'dev_name = "tun-custom"\n' > "$ET_CORE_CONFIG_FILE"
assert_eq tun-custom "$(_tun_dev_name)" 'uninstall targets the configured TUN device'
rm -f "$ET_CORE_CONFIG_FILE"
assert_eq easytier0 "$(_tun_dev_name)" 'TUN device falls back to the default'

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) pass 'staging file mode is checked on the CI runner' ;;
    *)
        _new_private_tmp "$TEST_DIR/private.tmp" || fail 'private staging file was not created'
        printf 'secret\n' > "$TEST_DIR/private.tmp"
        assert_eq 600 "$(stat -c %a "$TEST_DIR/private.tmp")" \
            'staging files are 0600 before anything is written to them'
        ;;
esac

detect_system() { OS_TYPE=debian; INIT_SYS=systemd; ARCH_NAME=x86_64; }
_svc_start() { return 1; }
check_proc() { return 1; }
set +e
(main start >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'start command returned success after service failure'
pass 'one-shot start returns failure when the service cannot start'

printf '1..%d\n' "$TEST_NO"
