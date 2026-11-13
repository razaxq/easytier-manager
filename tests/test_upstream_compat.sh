#!/bin/sh
# shellcheck disable=SC2034  # these globals drive the sourced easytier.sh; ShellCheck
#                              cannot see reads that happen across the source boundary
set -eu

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/easytier-upstream-compat.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP

ET_SOURCE_ONLY=1
ET_LANG=en
LOG_FILE="$TEST_DIR/manager.log"
ET_CACHE_DIR="$TEST_DIR/cache"
export ET_SOURCE_ONLY ET_LANG LOG_FILE ET_CACHE_DIR

# shellcheck source=../easytier.sh
. "$(dirname "$0")/../easytier.sh"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP
_init_colors
TMP_DIR="$TEST_DIR/download"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

channel="${ET_TEST_CHANNEL:-stable}"
case "$channel" in
    stable|prerelease)
        ET_NONINTERACTIVE=1
        ET_CACHE_TTL=0
        ET_RELEASES_COUNT=20
        ET_ALLOW_PRERELEASE=0
        [ "$channel" != prerelease ] || ET_ALLOW_PRERELEASE=1
        unset ET_VERSION
        select_version >/dev/null || fail "could not select $channel release"
        tag="$VER"
        if [ "$channel" = prerelease ]; then
            tag=$(awk '$2=="pre" {print $1; exit}' "$TMP_DIR/releases.txt")
            [ -n "$tag" ] || fail 'no versioned pre-release available for this matrix job'
        fi
        ;;
    nightly) tag=nightly ;;
    *) fail "unknown test channel: $channel" ;;
esac
pass "$channel channel resolved to $tag"

ET_SHA256=''
ET_ALLOW_UNVERIFIED=0
do_download "$tag" x86_64 >/dev/null || fail 'manager download or official digest verification failed'

for bin in easytier-core easytier-cli easytier-web easytier-web-embed; do
    [ -f "$EXTRACT_DIR/$bin" ] || fail "release archive is missing $bin"
done
pass 'release archive still contains all managed binaries'

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        pass 'Linux binary execution checks are deferred to the Ubuntu CI runner'
        exit 0
        ;;
esac

_core_version_matches "$EXTRACT_DIR/easytier-core" "$DOWNLOAD_VERSION" || \
    fail "core version does not match package version $DOWNLOAD_VERSION ($tag)"
pass "core matches package $DOWNLOAD_VERSION: $("$EXTRACT_DIR/easytier-core" --version)"

$EXTRACT_DIR/easytier-core --help | grep -q -- '--check-config' || fail 'core lost --check-config'
$EXTRACT_DIR/easytier-core --help | grep -q -- '--machine-id' || fail 'core lost --machine-id'
$EXTRACT_DIR/easytier-core --help | grep -q -- '--config-server' || fail 'core lost --config-server'
# rpc_portal is a CLI option, not a TOML key: the manager pins it so easytier-cli
# has a deterministic loopback target instead of upstream's 0.0.0.0 scan.
$EXTRACT_DIR/easytier-core --help | grep -q -- '--rpc-portal' || fail 'core lost --rpc-portal'
$EXTRACT_DIR/easytier-cli --help | grep -q -- '--rpc-portal' || fail 'CLI lost --rpc-portal'
$EXTRACT_DIR/easytier-cli --help | grep -q 'peer' || fail 'CLI lost peer command'
$EXTRACT_DIR/easytier-cli --help | grep -q 'route' || fail 'CLI lost route command'
$EXTRACT_DIR/easytier-web-embed --help | grep -q -- '--api-server-addr' || fail 'web lost --api-server-addr'
$EXTRACT_DIR/easytier-web-embed --help | grep -q -- '--web-server-addr' || fail 'web lost --web-server-addr'
$EXTRACT_DIR/easytier-web-embed --help | grep -q -- '--db' || fail 'web lost --db'
pass 'manager-required CLI options remain available'

ET_CORE_BIN_FILE="$EXTRACT_DIR/easytier-core"
ET_CORE_CONFIG_FILE="$TEST_DIR/config.toml"
_TOML_INSTANCE='compat"node'
_TOML_DHCP=0
_TOML_IP=10.20.30.1/24
_TOML_LISTEN_PORT=65533
_TOML_NET_NAME='compat"network'
_TOML_NET_SECRET='compat\secret'
_TOML_PEERS='tcp://127.0.0.1:11010'
_TOML_PROXY_CIDRS='192.168.50.0/24'
_TOML_DEV_NAME=easytier0
_TOML_ENC=true
_TOML_EXITNODE=false
_TOML_USE_SMOLTCP=false
_TOML_PRIVATE=true
_TOML_COMPRESS=0
_toml_write_config >/dev/null || fail 'selected core rejected the generated config'
grep -q '^relay_network_whitelist = "\*"$' "$ET_CORE_CONFIG_FILE" || fail 'generated config uses a stale whitelist field'
grep -q 'wss://0.0.0.0:65535/' "$ET_CORE_CONFIG_FILE" || fail 'maximum valid derived port is incorrect'
pass 'generated TOML is accepted by the selected core'

# Released cores only accept true/false for these names, and newer ones parse
# ET_DHCP as a CIDR. The documented installer values must not reach the core.
ET_DHCP=1; ET_PRIVATE_MODE=0; ET_ENABLE_EXIT_NODE=1; ET_USE_SMOLTCP=1
export ET_DHCP ET_PRIVATE_MODE ET_ENABLE_EXIT_NODE ET_USE_SMOLTCP
_validate_core_config "$ET_CORE_CONFIG_FILE" >/dev/null || fail 'exported installer settings broke config validation'
unset ET_DHCP ET_PRIVATE_MODE ET_ENABLE_EXIT_NODE ET_USE_SMOLTCP
pass 'exported installer settings do not reach the selected core'

for option in --file-log-dir --file-log-level --file-log-size --file-log-count; do
    "$EXTRACT_DIR/easytier-core" --help | grep -q -- "$option" || fail "core lost $option"
done
for option in --api-host --api-server-port --config-server-port --config-server-protocol; do
    "$EXTRACT_DIR/easytier-web-embed" --help | grep -q -- "$option" || fail "web lost $option"
done
pass 'all generated service arguments remain available'

_TOML_COMPRESS=3
if _core_supports_lzo "$ET_CORE_BIN_FILE"; then
    _toml_write_config >/dev/null || fail 'LZO config rejected by an advertising core'
    grep -q '^data_compress_algo = 3$' "$ET_CORE_CONFIG_FILE" || fail 'LZO silently changed'
    pass 'LZO configuration accepted without silently falling back'
else
    before=$(_sha256_file "$ET_CORE_CONFIG_FILE")
    if _toml_write_config >/dev/null 2>&1; then fail 'unsupported LZO was accepted'; fi
    [ "$before" = "$(_sha256_file "$ET_CORE_CONFIG_FILE")" ] || fail 'LZO failure changed the config'
    pass 'core without LZO support is rejected before config replacement'
fi
