#!/bin/sh
# shellcheck disable=SC2034
set -eu
TEST_DIR=$(mktemp -d)
ET_SOURCE_ONLY=1
LOG_FILE="$TEST_DIR/manager.log"
ET_CACHE_DIR="$TEST_DIR/cache"
. "$(dirname "$0")/../easytier.sh"
TMP_DIR="$TEST_DIR/download"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP
_init_colors
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

_gh_api() { cat "$TEST_DIR/api.json"; }
cat > "$TEST_DIR/api.json" <<'JSON'
[
 {"tag_name":"nightly","prerelease":true,"published_at":"2026-10-14T00:00:00Z","updated_at":"2026-11-12T00:00:00Z"},
 {"tag_name":"v2.7.0","prerelease":true,"published_at":"2026-10-06T00:00:00Z"},
 {"tag_name":"v2.6.4","prerelease":false,"published_at":"2026-05-12T00:00:00Z"}
]
JSON
ET_CACHE_TTL=0
ET_NONINTERACTIVE=1
select_version >/dev/null
[ "$VER" = v2.6.4 ] || fail 'stable automatic default'
ET_NONINTERACTIVE=0
select_version >/dev/null <<EOF

EOF
[ "$VER" = v2.6.4 ] || fail 'interactive Enter must select stable'
ET_NONINTERACTIVE=1
ET_ALLOW_PRERELEASE=1
select_version >/dev/null
[ "$VER" = v2.7.0 ] || fail 'prerelease opt-in must not silently select rolling nightly'
ET_VERSION=nightly
select_version >/dev/null
[ "$VER" = nightly ] || fail 'explicit nightly was rejected'
ET_VERSION=2.7.0
select_version >/dev/null
[ "$VER" = v2.7.0 ] || fail 'numeric tag normalization'
unset ET_VERSION
pass 'stable, prerelease and nightly selection are distinct'

cat > "$TEST_DIR/api.json" <<'JSON'
{"draft":false,"assets":[{"uploader":{"name":"decoy.zip"},"browser_download_url":"https://github.com/EasyTier/EasyTier/releases/download/nightly/easytier-linux-x86_64-v2.7.0.zip","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","name":"easytier-linux-x86_64-v2.7.0.zip"}],"tag_name":"nightly","body":"An escaped quote: \" and braces {} []"}
JSON
_resolve_release_asset nightly x86_64 || fail 'compact and reordered metadata rejected'
[ "$ASSET_NAME" = easytier-linux-x86_64-v2.7.0.zip ] || fail 'nightly filename'
[ "$DOWNLOAD_VERSION" = 2.7.0 ] || fail 'nightly package version'
[ "$ASSET_SHA256" = 1111111111111111111111111111111111111111111111111111111111111111 ] || fail 'nightly digest'
pass 'nightly resolves actual asset and digest from one official response'

cat > "$TEST_DIR/api.json" <<'JSON'
{"tag_name":"nightly","assets":[{"name":"easytier-linux-armv7-v2.7.0.zip","browser_download_url":"https://github.com/EasyTier/EasyTier/releases/download/nightly/easytier-linux-armv7-v2.7.0.zip"},{"name":"easytier-linux-x86_64-v2.7.0.zip","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","browser_download_url":"https://github.com/EasyTier/EasyTier/releases/download/nightly/easytier-linux-x86_64-v2.7.0.zip"}]}
JSON
_resolve_release_asset nightly armv7 || fail 'digest-less metadata rejected before explicit override'
[ -z "$ASSET_SHA256" ] || fail 'digest borrowed from adjacent asset'
! _resolve_release_asset nightly ppc64le || fail 'missing architecture accepted'
[ -z "$DOWNLOAD_VERSION" ] || fail 'failed resolution kept a stale version'
pass 'missing digest and missing architecture never reuse another asset'

sed 's@https://github.com/@https://example.invalid/@g' "$TEST_DIR/api.json" > "$TEST_DIR/wrong.json"
mv "$TEST_DIR/wrong.json" "$TEST_DIR/api.json"
! _resolve_release_asset nightly x86_64 || fail 'foreign asset URL accepted'
printf '%s' '{"tag_name":"nightly","assets":[' > "$TEST_DIR/api.json"
! _resolve_release_asset nightly x86_64 || fail 'truncated JSON accepted'
! is_valid_version_tag '../nightly' || fail 'unsafe tag accepted'
pass 'invalid metadata and foreign download URLs fail closed'

cat > "$TEST_DIR/core" <<'SH'
#!/bin/sh
printf 'easytier-core 2.7.0-3b32aaff-20261112\n'
SH
chmod +x "$TEST_DIR/core"
_core_version_matches "$TEST_DIR/core" 2.7.0 || fail 'dated build version rejected'
! _core_version_matches "$TEST_DIR/core" 2.6.4 || fail 'wrong version accepted'
pass 'dated build versions are validated against the package version'

# Raw controls inside JSON strings must never forge another parsed field.
printf '{"body":"bad\n/tag_name\t\"nightly\""}' > "$TEST_DIR/api.json"
! _json_fields < "$TEST_DIR/api.json" > /dev/null || fail 'raw control in JSON accepted'
printf '%s' '{"body":"invalid\q"}' > "$TEST_DIR/api.json"
! _json_fields < "$TEST_DIR/api.json" > /dev/null || fail 'invalid JSON escape accepted'
printf '%s' '{"body":"valid\u4e2d\n\t\/"}' > "$TEST_DIR/api.json"
_json_fields < "$TEST_DIR/api.json" > /dev/null || fail 'valid JSON escape rejected'
pass 'JSON control characters and escape sequences are validated'

# Documents larger than the tokenizer window must parse identically wherever a
# chunk boundary happens to fall (inside strings, numbers, literals, escapes).
awk 'BEGIN {
    printf "{\"items\":["
    for (i = 0; i < 1500; i++) {
        if (i) printf ","
        printf "{\"id\":%d.5e2,\"ok\":true,\"none\":null,\"name\":\"asset-%d\\\"q\\u00e9\"}", i, i
    }
    long = ""; for (i = 0; i < 9000; i++) long = long "x"
    printf "],\"body\":\"%s\",\"tag_name\":\"v1.2.3\"}\n", long
}' > "$TEST_DIR/api.json"
[ "$(wc -c < "$TEST_DIR/api.json")" -gt 65536 ] || fail 'large fixture is too small'
_json_fields < "$TEST_DIR/api.json" > "$TEST_DIR/fields.txt" || fail 'large document rejected'
[ "$(grep -c '^/items/[0-9]*/id	[0-9]*\.5e2$' "$TEST_DIR/fields.txt")" = 1500 ] || fail 'numbers split at a chunk boundary'
[ "$(grep -c '^/items/[0-9]*/ok	true$' "$TEST_DIR/fields.txt")" = 1500 ] || fail 'literals split at a chunk boundary'
[ "$(grep -c '^/items/[0-9]*/name	"asset-[0-9]*\\"q\\u00e9"$' "$TEST_DIR/fields.txt")" = 1500 ] || fail 'strings split at a chunk boundary'
grep -q '^/items/1499/none	null$' "$TEST_DIR/fields.txt" || fail 'last array element lost'
grep -q '^/tag_name	"v1.2.3"$' "$TEST_DIR/fields.txt" || fail 'field after a long string lost'
pass 'documents larger than the tokenizer window parse intact'

# With the API unreachable a versioned tag still resolves to its standard asset
# name, but without a digest; a rolling tag cannot be resolved at all.
_gh_api() { return 1; }
_resolve_release_asset v2.6.4 aarch64 > /dev/null 2>&1 || fail 'versioned tag needs the API'
[ "$ASSET_URL" = https://github.com/EasyTier/EasyTier/releases/download/v2.6.4/easytier-linux-aarch64-v2.6.4.zip ] || fail 'offline asset URL'
[ -z "$ASSET_SHA256" ] || fail 'offline resolution invented a digest'
[ "$DOWNLOAD_VERSION" = 2.6.4 ] || fail 'offline package version'
rc=0; _resolve_release_asset nightly aarch64 > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail 'nightly resolved without official metadata'
pass 'API outage keeps versioned downloads possible and never yields a digest'
