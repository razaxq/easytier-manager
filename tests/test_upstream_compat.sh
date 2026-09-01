#!/bin/sh
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

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

release_json=$(_gh_api 'https://api.github.com/repos/EasyTier/EasyTier/releases/latest') || \
    fail 'could not query the latest stable EasyTier release'
tag=$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$tag" ] || fail 'latest stable release did not contain a tag'
pass "latest stable release resolved to $tag"

TMP_DIR="$TEST_DIR/download"
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

version=$($EXTRACT_DIR/easytier-core --version 2>/dev/null | awk '{print $2}' | cut -d- -f1)
[ "v$version" = "$tag" ] || fail "core version $version does not match release $tag"

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
_toml_write_config >/dev/null || fail 'latest stable core rejected the generated config'
grep -q '^relay_network_whitelist = "\*"$' "$ET_CORE_CONFIG_FILE" || fail 'generated config uses a stale whitelist field'
grep -q 'wss://0.0.0.0:65535/' "$ET_CORE_CONFIG_FILE" || fail 'maximum valid derived port is incorrect'
pass 'generated TOML is accepted by the latest stable core'
