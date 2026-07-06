#!/bin/sh
# shellcheck shell=sh
# ==============================================================================
#  build-zh.sh — generate easytier.zh.sh from easytier.sh (single source of truth)
#
#  easytier.sh is bilingual (see its i18n section). The only difference in the
#  Chinese entry point is that it defaults to Chinese even on an English-locale
#  host. This script flips the one marked line and drops a "generated" banner, so
#  Chinese users can still `curl -fsSL .../easytier.zh.sh | sh` and get Chinese.
#
#  Run from the repo root:  sh tools/build-zh.sh
#  Re-run whenever easytier.sh changes; commit both files.
# ==============================================================================
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/easytier.sh"
dst="$here/easytier.zh.sh"

[ -f "$src" ] || { echo "error: $src not found" >&2; exit 1; }

grep -q '^ET_LANG_DEFAULT="en"[[:space:]]*# et:lang-default$' "$src" || {
    echo "error: language-default marker not found in easytier.sh" >&2
    echo "       expected a line: ET_LANG_DEFAULT=\"en\"  # et:lang-default" >&2
    exit 1
}

# 1) flip the language default en → zh on the marked line only
# 2) insert a generated-file banner right after the shebang
sed \
    -e 's/^ET_LANG_DEFAULT="en"\([[:space:]]*# et:lang-default\)$/ET_LANG_DEFAULT="zh"\1/' \
    -e '1a\
# ============================================================================\
#  GENERATED FILE — do not edit. Source of truth: easytier.sh\
#  Regenerate with:  sh tools/build-zh.sh\
# ============================================================================' \
    "$src" > "$dst"

# sanity: the generated file must carry the zh default and stay valid POSIX sh
grep -q '^ET_LANG_DEFAULT="zh"' "$dst" || { echo "error: flip failed" >&2; exit 1; }
if command -v dash >/dev/null 2>&1; then
    dash -n "$dst" || { echo "error: generated easytier.zh.sh has a syntax error" >&2; exit 1; }
fi

echo "generated: $dst"
