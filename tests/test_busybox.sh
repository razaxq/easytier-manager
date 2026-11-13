#!/bin/sh
set -eu
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP
mkdir "$TEST_DIR/bin"
"$(command -v busybox)" --install -s "$TEST_DIR/bin"
PATH="$TEST_DIR/bin:$PATH"
export PATH
for suite in test_machine_id test_manager test_releases test_options test_download test_upgrade; do
    printf 'BusyBox: %s\n' "$suite"
    busybox ash "$(dirname "$0")/$suite.sh"
done
