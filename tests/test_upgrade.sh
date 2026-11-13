#!/bin/sh
# shellcheck disable=SC2034
set -eu
TEST_DIR=$(mktemp -d)
ET_SOURCE_ONLY=1
LOG_FILE="$TEST_DIR/manager.log"
ET_CORE_ARGS_FILE="$TEST_DIR/config/core.args"
ET_WEB_ARGS_FILE="$TEST_DIR/config/web.args"
ET_CORE_CONFIG_FILE="$TEST_DIR/config/config.toml"
ET_CORE_SERVICE_FILE="$TEST_DIR/systemd/easytier.service"
ET_MACHINE_ID_STATE_FILE="$TEST_DIR/state/machine_id"
ET_WEB_DB_PATH="$TEST_DIR/db/et.db"
ET_UPGRADE_BACKUP_DIR="$TEST_DIR/backups"
. "$(dirname "$0")/../easytier.sh"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP
BIN_DIR="$TEST_DIR/bin"
SYSTEMD_DIR="$TEST_DIR/systemd"
INIT_DIR="$TEST_DIR/init"
TMP_DIR="$TEST_DIR/tmp"
INIT_SYS=procd
ET_NONINTERACTIVE=1
ET_BACKUP_KEEP=0
mkdir -p "$BIN_DIR" "$SYSTEMD_DIR" "$INIT_DIR" "$TEST_DIR/config" "$TEST_DIR/db" "$TMP_DIR"
_init_colors
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
CORE_RUNNING=1; WEB_RUNNING=1
_proc_running() {
    case "$1" in easytier-core) [ "$CORE_RUNNING" = 1 ] ;; easytier-web-embed) [ "$WEB_RUNNING" = 1 ] ;; *) return 1 ;; esac
}
svc_stop() { CORE_RUNNING=0; }
svc_stop_web() { WEB_RUNNING=0; }
svc_start() { CORE_RUNNING=1; }
svc_start_web() { WEB_RUNNING=1; }
check_proc() { _proc_running "$1"; }
_prune_backups() { :; }
_prepare_machine_id_upgrade() { :; }
cat > "$BIN_DIR/easytier-core" <<'SH'
#!/bin/sh
printf 'easytier-core 2.6.4-old\n'
SH
chmod +x "$BIN_DIR/easytier-core"
printf 'old-cli\n' > "$BIN_DIR/easytier-cli"
printf 'old-web\n' > "$BIN_DIR/easytier-web-embed"
printf '%s\n' --db "$ET_WEB_DB_PATH" > "$ET_WEB_ARGS_FILE"
printf 'old-config\n' > "$ET_CORE_CONFIG_FILE"
printf 'old-service\n' > "$ET_CORE_SERVICE_FILE"
# Leave committed data in WAL, as after an unclean SQLite shutdown.
python3 - "$ET_WEB_DB_PATH" <<'PY'
import os,sqlite3,sys
c=sqlite3.connect(sys.argv[1]);c.execute('pragma journal_mode=wal')
c.execute('create table test(value text)');c.execute("insert into test values('before')");c.commit()
os._exit(0)
PY
[ -s "$ET_WEB_DB_PATH-wal" ] || fail 'fixture did not retain WAL'
mkdir "$TEST_DIR/new"
cat > "$TEST_DIR/new/easytier-core" <<'SH'
#!/bin/sh
printf 'easytier-core 2.7.0-3b32aaff-20261112\n'
SH
chmod +x "$TEST_DIR/new/easytier-core"
printf 'new-cli\n' > "$TEST_DIR/new/easytier-cli"
printf 'new-web\n' > "$TEST_DIR/new/easytier-web-embed"
VER=nightly; DOWNLOAD_VERSION=2.7.0
do_install_bins "$TEST_DIR/new" > "$TEST_DIR/install.log" || { cat "$TEST_DIR/install.log"; fail 'isolated upgrade'; }
original="$UPGRADE_SNAPSHOT"
_validate_upgrade_snapshot "$original" || fail 'snapshot integrity'
[ -s "$original/files/database-wal" ] || fail 'WAL absent from snapshot'
[ "$(stat -c %a "$original")" = 700 ] || fail 'snapshot directory permissions'
[ "$(stat -c %a "$original/files/config.toml")" = 600 ] || fail 'snapshot file permissions'
[ "$CORE_RUNNING:$WEB_RUNNING" = 0:0 ] || fail 'upgrade did not stop services'
grep -q 2.7.0 "$BIN_DIR/easytier-core" || fail 'nightly install version check'
pass 'upgrade saves a private complete cold snapshot before replacing binaries'

sqlite3 "$ET_WEB_DB_PATH" "update test set value='after'; create table added(v);"
printf 'new-config\n' > "$ET_CORE_CONFIG_FILE"
printf 'new-service\n' > "$ET_CORE_SERVICE_FILE"
printf 'added-binary\n' > "$BIN_DIR/easytier-web"
CORE_RUNNING=1; WEB_RUNNING=1
do_rollback "$original" > "$TEST_DIR/rollback.log" || { cat "$TEST_DIR/rollback.log"; fail 'rollback'; }
[ "$(sqlite3 "$ET_WEB_DB_PATH" 'select value from test')" = before ] || fail 'WAL data not recovered'
[ "$(sqlite3 "$ET_WEB_DB_PATH" "select count(*) from sqlite_master where name='added'")" = 0 ] || fail 'schema not recovered'
[ "$(cat "$ET_CORE_CONFIG_FILE")" = old-config ] || fail 'config not restored'
[ "$(cat "$ET_CORE_SERVICE_FILE")" = old-service ] || fail 'service not restored'
grep -q 2.6.4 "$BIN_DIR/easytier-core" || fail 'binary not restored'
[ ! -e "$BIN_DIR/easytier-web" ] || fail 'newly added file not removed'
[ "$CORE_RUNNING:$WEB_RUNNING" = 1:1 ] || fail 'service state not restored'
rescue="$UPGRADE_SNAPSHOT"
_validate_upgrade_snapshot "$rescue" || fail 'rescue snapshot missing'
pass 'rollback restores SQLite data, schema, binaries, config and prior service state'

printf 'corrupt\n' >> "$original/files/database"
! do_rollback "$original" > /dev/null 2>&1 || fail 'corrupt snapshot accepted'
[ "$CORE_RUNNING:$WEB_RUNNING" = 1:1 ] || fail 'corruption check stopped services'
cp -p "$rescue/files/database" "$original/files/database"
# Use the known-valid rescue for failure injection.
failed_once=0
mv() {
    if [ "$failed_once" = 0 ] && [ "${2:-}" = "$ET_CORE_CONFIG_FILE.restore.$$" ]; then
        failed_once=1; return 1
    fi
    command mv "$@"
}
! do_rollback "$rescue" > "$TEST_DIR/failure.log" 2>&1 || fail 'commit failure reported success'
[ "$failed_once" = 1 ] || fail 'failure injection did not trigger'
[ "$(cat "$ET_CORE_CONFIG_FILE")" = old-config ] || fail 'failed rollback did not recover config'
grep -q 2.6.4 "$BIN_DIR/easytier-core" || fail 'failed rollback left mixed binaries'
[ "$(sqlite3 "$ET_WEB_DB_PATH" 'select value from test')" = before ] || fail 'failed rollback damaged DB'
[ "$CORE_RUNNING:$WEB_RUNNING" = 1:1 ] || fail 'failed rollback did not resume services'
unset -f mv
pass 'partial restore failure recovers the complete pre-rollback state'

cp "$rescue/targets" "$TEST_DIR/targets"
printf 'arbitrary|/etc/passwd|600\n' >> "$rescue/targets"
! _validate_upgrade_snapshot "$rescue" || fail 'altered target list accepted'
cp "$TEST_DIR/targets" "$rescue/targets"
rm "$rescue/files/config.toml"
ln -s "$ET_CORE_CONFIG_FILE" "$rescue/files/config.toml"
! _validate_upgrade_snapshot "$rescue" || fail 'symlink payload accepted'
pass 'altered restore targets and symlink payloads are rejected'

# A failed rename after core replacement must recover the whole installed set.
failed_once=0
mv() {
    if [ "$failed_once" = 0 ] && [ "${2:-}" = "$BIN_DIR/easytier-cli.tmp.$$" ]; then
        failed_once=1; return 1
    fi
    command mv "$@"
}
! do_install_bins "$TEST_DIR/new" > "$TEST_DIR/install-failure.log" 2>&1 || fail 'partial install reported success'
unset -f mv
[ "$failed_once" = 1 ] || fail 'install failure injection did not trigger'
grep -q 2.6.4 "$BIN_DIR/easytier-core" || fail 'failed install left new core'
[ "$(cat "$BIN_DIR/easytier-cli")" = old-cli ] || fail 'failed install changed CLI'
[ "$CORE_RUNNING:$WEB_RUNNING" = 1:1 ] || fail 'failed install did not resume services'
pass 'partial binary replacement restores the previous complete binary set'

# A binary that fails only at its final path must also roll back.
cp "$TEST_DIR/new/easytier-core" "$TEST_DIR/good-core"
cat > "$TEST_DIR/new/easytier-core" <<'SH'
#!/bin/sh
case "$0" in *.tmp.*) printf 'easytier-core 2.7.0-test\n' ;; *) exit 1 ;; esac
SH
! do_install_bins "$TEST_DIR/new" > "$TEST_DIR/final-check.log" 2>&1 || fail 'unusable final binary accepted'
grep -q 2.6.4 "$BIN_DIR/easytier-core" || fail 'final validation did not restore old core'
[ "$(cat "$BIN_DIR/easytier-web-embed")" = old-web ] || fail 'final validation left new web binary'
[ "$CORE_RUNNING:$WEB_RUNNING" = 1:1 ] || fail 'final validation left services stopped'
cp "$TEST_DIR/good-core" "$TEST_DIR/new/easytier-core"
pass 'final-path validation failure restores binaries and service state'

# If even binary recovery fails, never restart a mixed installation.
mv() {
    case "${2:-}" in
        "$BIN_DIR/easytier-cli.tmp.$$"|"$BIN_DIR/easytier-core.restore.$$") return 1 ;;
    esac
    command mv "$@"
}
! do_install_bins "$TEST_DIR/new" > "$TEST_DIR/recovery-failure.log" 2>&1 || fail 'double failure reported success'
unset -f mv
[ "$CORE_RUNNING:$WEB_RUNNING" = 0:0 ] || fail 'mixed binaries were started'
recovery_snapshot="$UPGRADE_SNAPSHOT"
_validate_upgrade_snapshot "$recovery_snapshot" || fail 'double failure lost recovery snapshot'
# a tab-completed trailing slash must be accepted
do_rollback "$recovery_snapshot/" > /dev/null || fail 'manual recovery after double failure'
grep -q 2.6.4 "$BIN_DIR/easytier-core" || fail 'manual recovery left mixed core'
[ "$CORE_RUNNING:$WEB_RUNNING" = 1:1 ] || fail 'manual recovery lost original service state'
pass 'failed binary recovery leaves services stopped and a usable full snapshot'

# Stale partial copies are discarded together with old snapshots.
mkdir "$ET_UPGRADE_BACKUP_DIR/.pending.stale"
_prune_upgrade_snapshots || fail 'snapshot pruning failed'
[ ! -e "$ET_UPGRADE_BACKUP_DIR/.pending.stale" ] || fail 'stale partial snapshot kept'
[ -d "$UPGRADE_SNAPSHOT" ] || fail 'pruning removed the current snapshot'
pass 'pruning removes abandoned partial snapshots and keeps the current one'

# A snapshot that cannot fit must fail before anything is copied.
_avail_mb() { printf 0; }
# shellcheck disable=SC2218  # the real function; it is only stubbed further down
! _create_upgrade_snapshot "$ET_WEB_DB_PATH" > /dev/null 2>&1 || fail 'snapshot ignored missing space'
! ls -d "$ET_UPGRADE_BACKUP_DIR"/.pending.* > /dev/null 2>&1 || fail 'space failure left a partial snapshot'
_avail_mb() { :; }   # unknown free space skips the check for the remaining cases
pass 'insufficient space aborts the snapshot before copying'

# An unmanaged easytier-web only blocks upgrades that touch the Web database,
# and is detected before any managed service is stopped.
_proc_running() {
    case "$1" in easytier-core) [ "$CORE_RUNNING" = 1 ] ;; easytier-web-embed) [ "$WEB_RUNNING" = 1 ] ;; easytier-web) return 0 ;; *) return 1 ;; esac
}
! _stop_upgrade_services db > /dev/null 2>&1 || fail 'shared-database process ignored'
[ "$CORE_RUNNING:$WEB_RUNNING" = 1:1 ] || fail 'services were stopped before the refusal'
_stop_upgrade_services > /dev/null || fail 'core-only upgrade blocked by unmanaged easytier-web'
[ "$CORE_RUNNING:$WEB_RUNNING" = 0:0 ] || fail 'core-only stop did not stop services'
_resume_upgrade_services > /dev/null || fail 'services did not resume'
pass 'a separate easytier-web blocks only database-affecting upgrades'

# A backup failure must leave the installed binaries intact and resume services.
_create_upgrade_snapshot() { return 1; }
! do_install_bins "$TEST_DIR/new" > /dev/null 2>&1 || fail 'upgrade ignored backup failure'
grep -q 2.6.4 "$BIN_DIR/easytier-core" || fail 'backup failure changed installed binary'
[ "$CORE_RUNNING:$WEB_RUNNING" = 1:1 ] || fail 'backup failure left services stopped'
pass 'backup failure aborts installation and resumes the existing services'
