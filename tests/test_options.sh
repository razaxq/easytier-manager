#!/bin/sh
# shellcheck disable=SC2034
set -eu
TEST_DIR=$(mktemp -d)
ET_SOURCE_ONLY=1
LOG_FILE="$TEST_DIR/manager.log"
ET_CORE_CONFIG_FILE="$TEST_DIR/config.toml"
. "$(dirname "$0")/../easytier.sh"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP
_init_colors
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
ET_ARCH=ppc64le
_detect_arch && [ "$ARCH_NAME" = ppc64le ] || fail 'explicit ppc64le rejected'
ET_ARCH=''
uname() { printf 'ppc64le\n'; }
_detect_arch && [ "$ARCH_NAME" = ppc64le ] || fail 'native ppc64le detection failed'
unset -f uname
pass 'PowerPC little-endian architecture is recognized'
ET_NONINTERACTIVE=1
ET_DHCP=1
ET_NETWORK_NAME="test"
ET_NETWORK_SECRET=test-secret
ET_PEERS=tcp://127.0.0.1:11010
ET_DATA_COMPRESS_ALGO=3
_validate_tunables || fail 'LZO tunable rejected'
_toml_wizard >/dev/null
[ "$_TOML_COMPRESS" = 3 ] || fail 'LZO was silently changed'
ET_DATA_COMPRESS_ALGO=bad
! _toml_wizard >/dev/null 2>&1 || fail 'invalid compression silently changed'
pass 'LZO is retained and invalid compression fails explicitly'
printf 'existing config\n' > "$ET_CORE_CONFIG_FILE"
ET_CORE_BIN_FILE="$TEST_DIR/old-core"
cat > "$ET_CORE_BIN_FILE" <<'SH'
#!/bin/sh
printf 'Options: --check-config --compression <none|zstd>\n'
SH
chmod +x "$ET_CORE_BIN_FILE"
_TOML_COMPRESS=3
! _toml_write_config >/dev/null 2>&1 || fail 'old core accepted LZO'
[ "$(cat "$ET_CORE_CONFIG_FILE")" = 'existing config' ] || fail 'unsupported option replaced config'
pass 'older cores reject LZO without changing the existing configuration'

# EasyTier reads ET_* variables of its own. Installer settings exported by the
# caller must never reach an upstream binary or a service launcher.
ET_DHCP=1; ET_PRIVATE_MODE=0; ET_ENABLE_EXIT_NODE=1; ET_USE_SMOLTCP=1
export ET_DHCP ET_PRIVATE_MODE ET_ENABLE_EXIT_NODE ET_USE_SMOLTCP
KEEP_ME=kept; export KEEP_ME
leaked=$(_without_et_env env | grep -c '^ET_' || true)
[ "$leaked" = 0 ] || fail 'installer ET_* variables leaked into a child process'
[ "$(_without_et_env sh -c 'printf %s "$KEEP_ME"')" = kept ] || fail 'unrelated environment was removed'
[ "$ET_DHCP:$ET_PRIVATE_MODE" = 1:0 ] || fail 'isolation changed the installer settings'
rc=0; _without_et_env sh -c 'exit 7' || rc=$?
[ "$rc" = 7 ] || fail 'isolated command lost its exit status'
[ "$(_without_et_env printf '%s|' 'a b' c)" = 'a b|c|' ] || fail 'isolated command arguments were re-split'
pass 'upstream programs run without the installer ET_* environment'
