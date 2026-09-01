#!/bin/sh
set -eu

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/easytier-manager-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP

ET_SOURCE_ONLY=1
ET_LANG=en
LOG_FILE="$TEST_DIR/manager.log"
ET_CORE_ARGS_FILE="$TEST_DIR/core.args"
ET_MACHINE_ID_STATE_FILE="$TEST_DIR/state/machine_id"
ET_LEGACY_MACHINE_ID_FILE="$TEST_DIR/et_machine_id"
ET_CORE_SERVICE_FILE="$TEST_DIR/easytier.service"
ET_CORE_BIN_FILE="$TEST_DIR/easytier-core"
ET_FILE_LOG_DIR="$TEST_DIR/log"
export ET_SOURCE_ONLY ET_LANG LOG_FILE ET_CORE_ARGS_FILE ET_MACHINE_ID_STATE_FILE
export ET_LEGACY_MACHINE_ID_FILE ET_CORE_SERVICE_FILE ET_CORE_BIN_FILE ET_FILE_LOG_DIR

# shellcheck source=../easytier.sh
. "$(dirname "$0")/../easytier.sh"
# The sourced script installs its own cleanup trap; tests only own TEST_DIR.
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP
_init_colors

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_line_pair() {
    awk -v key="$1" -v value="$2" '
        previous == key && $0 == value { found=1 }
        { previous=$0 }
        END { exit(found ? 0 : 1) }
    ' "$3" || fail "$4"
}
reset_inputs() {
    unset ET_MACHINE_ID || true
    rm -f "$ET_CORE_ARGS_FILE" "$ET_MACHINE_ID_STATE_FILE" \
        "$ET_LEGACY_MACHINE_ID_FILE" "$ET_CORE_SERVICE_FILE" "$ET_CORE_BIN_FILE"
    rm -f "$TEST_DIR/state/.legacy-machine-id-migration"
}

MID_ARGS="cad9ff67-2bff-a0d5-5968-0b3f453fe982"
MID_STATE="57fcfe37-2343-36e3-63a9-d054f748ebe8"
MID_ENV="11111111-2222-3333-4444-555555555555"

reset_inputs
printf '%s\n' -w udp://old.example/user --machine-id "$MID_ARGS" > "$ET_CORE_ARGS_FILE"
_write_core_args -w udp://new.example/user
assert_line_pair --machine-id "$MID_ARGS" "$ET_CORE_ARGS_FILE" \
    'Web reconfiguration did not preserve core.args machine ID'
pass 'Web reconfiguration preserves an explicit machine ID'

reset_inputs
mkdir -p "$(dirname "$ET_MACHINE_ID_STATE_FILE")"
printf '%s\n' "$MID_STATE" > "$ET_MACHINE_ID_STATE_FILE"
_write_core_args -w udp://new.example/user
assert_line_pair --machine-id "$MID_STATE" "$ET_CORE_ARGS_FILE" \
    'persisted machine ID was not imported'
pass 'persisted EasyTier state is imported into core.args'

ET_MACHINE_ID="$MID_ENV"; export ET_MACHINE_ID
_write_core_args -w udp://new.example/user
assert_line_pair --machine-id "$MID_ENV" "$ET_CORE_ARGS_FILE" \
    'ET_MACHINE_ID did not override persisted state'
pass 'ET_MACHINE_ID has highest priority'

printf '%s\n' sentinel > "$ET_CORE_ARGS_FILE"
ET_MACHINE_ID='invalid value with spaces'; export ET_MACHINE_ID
set +e
_write_core_args -w udp://new.example/user >/dev/null 2>&1
INVALID_RC=$?
set -e
[ "$INVALID_RC" -ne 0 ] || fail 'invalid ET_MACHINE_ID was accepted'
[ "$(cat "$ET_CORE_ARGS_FILE")" = sentinel ] || fail 'invalid ID overwrote core.args'
pass 'invalid identity is rejected without overwriting configuration'

reset_inputs
printf '%s\n' -w udp://old.example/user --machine-id > "$ET_CORE_ARGS_FILE"
cp "$ET_CORE_ARGS_FILE" "$TEST_DIR/core.args.before"
set +e
_write_core_args -w udp://new.example/user >/dev/null 2>&1
MALFORMED_RC=$?
set -e
[ "$MALFORMED_RC" -ne 0 ] || fail 'missing --machine-id value was accepted'
cmp -s "$ET_CORE_ARGS_FILE" "$TEST_DIR/core.args.before" || \
    fail 'malformed machine ID overwrote core.args'
pass 'a malformed existing machine-ID option blocks a destructive rewrite'

reset_inputs
printf '%s\n' -w udp://old.example/user --machine-id --file-log-dir "$TEST_DIR/old-log" \
    > "$ET_CORE_ARGS_FILE"
cp "$ET_CORE_ARGS_FILE" "$TEST_DIR/core.args.before"
set +e
_write_core_args -w udp://new.example/user >/dev/null 2>&1
OPTION_VALUE_RC=$?
set -e
[ "$OPTION_VALUE_RC" -ne 0 ] || fail 'an option was accepted as a machine ID value'
cmp -s "$ET_CORE_ARGS_FILE" "$TEST_DIR/core.args.before" || \
    fail 'option-like machine ID overwrote core.args'
pass 'an option after --machine-id is rejected as a missing value'

reset_inputs
printf '%s\n' \
    '[Service]' \
    "ExecStart=/usr/bin/easytier-core -w udp://old/user --machine-id=$MID_ARGS" \
    > "$ET_CORE_SERVICE_FILE"
_write_core_args -w udp://new.example/user
assert_line_pair --machine-id "$MID_ARGS" "$ET_CORE_ARGS_FILE" \
    'machine ID embedded in service was not recovered'
pass 'identity is recovered from a legacy service file'

reset_inputs
printf '%s\n' \
    '[Service]' \
    'ExecStart=/usr/bin/easytier-core -w udp://old/user --machine-id --file-log-dir /tmp/log' \
    > "$ET_CORE_SERVICE_FILE"
set +e
_write_core_args -w udp://new.example/user >/dev/null 2>&1
SERVICE_VALUE_RC=$?
set -e
[ "$SERVICE_VALUE_RC" -ne 0 ] || fail 'a service option was accepted as a machine ID value'
[ ! -f "$ET_CORE_ARGS_FILE" ] || fail 'malformed service identity created core.args'
pass 'a malformed service machine-ID option blocks configuration rewrite'

reset_inputs
mkdir -p "$(dirname "$ET_MACHINE_ID_STATE_FILE")"
printf '%s\n' not-a-uuid > "$ET_MACHINE_ID_STATE_FILE"
printf '%s\n' --config-file /etc/easytier/config.toml > "$ET_CORE_ARGS_FILE"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$ET_CORE_BIN_FILE"
chmod +x "$ET_CORE_BIN_FILE"
_prepare_machine_id_upgrade >/dev/null
_write_core_args --config-file /etc/easytier/config.toml
grep -q -- '--machine-id' "$ET_CORE_ARGS_FILE" && \
    fail 'non-Web configuration imported a Web machine ID'
pass 'non-Web install and configuration ignore Web machine-ID state'

reset_inputs
printf '%s\n' '#!/bin/sh' 'exit 0' > "$ET_CORE_BIN_FILE"
chmod +x "$ET_CORE_BIN_FILE"
printf '%s\n' -w udp://old.example/user > "$ET_CORE_ARGS_FILE"
_prepare_machine_id_upgrade >/dev/null
[ -f "$TEST_DIR/state/.legacy-machine-id-migration" ] || \
    fail 'legacy migration marker was not created before binary replacement'
pass 'legacy Web upgrades prime the upstream 2.4.x identity migration'

printf '1..10\n'
