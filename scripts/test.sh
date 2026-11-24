#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "=== 1. Swift Tests (Swift Testing) ==="
SWIFT_TEST_ARGS=(--disable-xctest --enable-swift-testing)
CLT_TESTING_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [[ -d "$CLT_TESTING_PLUGINS" ]]; then
  SWIFT_TEST_ARGS+=(-Xswiftc -plugin-path -Xswiftc "$CLT_TESTING_PLUGINS")
fi
swift test "${SWIFT_TEST_ARGS[@]}"

echo "=== 2. Rex Lua Adapter Tests ==="
luajit Tests/RexTests/run_rex_tests.lua

echo "=== 3. Neovim Headless Adapter Tests ==="
nvim --headless -u NONE -l Tests/NvimTests/run_nvim_tests.lua

echo "ALL TEST SUITES PASSED"
