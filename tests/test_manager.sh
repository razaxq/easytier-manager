#!/bin/sh
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
