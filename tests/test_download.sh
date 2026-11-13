#!/bin/sh
# shellcheck disable=SC2034
set -eu
TEST_DIR=$(mktemp -d)
ET_SOURCE_ONLY=1
LOG_FILE="$TEST_DIR/manager.log"
. "$(dirname "$0")/../easytier.sh"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP
TMP_DIR="$TEST_DIR/work"
ET_GITHUB_MIRRORS=''
_init_colors
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
_check_space() { :; }
_resolve_release_asset() {
    ASSET_NAME=fixture.zip
    ASSET_URL=https://example.invalid/fixture.zip
    ASSET_SHA256=$(_sha256_file "$TEST_DIR/package.zip")
    DOWNLOAD_VERSION=2.7.0
}
# Keep actual archive extraction and checksum verification, replace only transport.
curl() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then cp "$TEST_DIR/package.zip" "$2"; return; fi
        shift
    done
    return 1
}
python3 - "$TEST_DIR" <<'PY'
from pathlib import Path
import sys, zipfile
root = Path(sys.argv[1])
for name, content in [('first', 'old'), ('second', 'new')]:
    with zipfile.ZipFile(root / (name + '.zip'), 'w') as z:
        z.writestr('easytier-linux-x86_64/easytier-core', content)
with zipfile.ZipFile(root / 'missing.zip', 'w') as z:
    z.writestr('easytier-linux-x86_64/README', 'no binary')
PY
cp "$TEST_DIR/first.zip" "$TEST_DIR/package.zip"
do_download nightly x86_64 > /dev/null || fail 'first download'
first="$EXTRACT_DIR"
cp "$TEST_DIR/second.zip" "$TEST_DIR/package.zip"
do_download nightly x86_64 > /dev/null || fail 'second download'
[ "$EXTRACT_DIR" != "$first" ] || fail 'download reused extraction directory'
[ "$(cat "$EXTRACT_DIR/easytier-core")" = new ] || fail 'download selected stale core'
pass 'repeated downloads use only binaries from the current archive'
cp "$TEST_DIR/missing.zip" "$TEST_DIR/package.zip"
! do_download nightly x86_64 > /dev/null 2>&1 || fail 'missing binary reused stale extraction'
[ -z "$EXTRACT_DIR" ] || fail 'failed extraction retained selected binaries'
pass 'an archive without core cannot fall back to an earlier download'
ET_SHA256=1111111111111111111111111111111111111111111111111111111111111111
! do_download nightly x86_64 > /dev/null 2>&1 || fail 'mismatched checksum accepted'
[ -z "$EXTRACT_DIR" ] || fail 'checksum failure retained selected binaries'
pass 'checksum mismatch fails before exposing extracted binaries'
