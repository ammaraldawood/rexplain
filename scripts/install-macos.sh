#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REXPLAIN_BIN_DIR:-$HOME/.local/bin}"
LEGACY_AGENT="$HOME/Library/LaunchAgents/com.rexplain.service.plist"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Rexplain requires macOS for Apple Foundation Models." >&2
  exit 1
fi

mkdir -p "$BIN_DIR"

echo "Building Rexplain (release)..."
swift build -c release --package-path "$ROOT"
install -m 0755 "$ROOT/.build/release/rexplain" "$BIN_DIR/rexplain"

# Remove any legacy background LaunchAgent / daemon from earlier versions.
if [[ -f "$LEGACY_AGENT" ]]; then
  launchctl bootout "gui/$(id -u)" "$LEGACY_AGENT" >/dev/null 2>&1 || true
  rm -f "$LEGACY_AGENT"
  echo "Removed legacy LaunchAgent: $LEGACY_AGENT"
fi

echo "Installed on-demand CLI to $BIN_DIR/rexplain"
echo "Ensure $BIN_DIR is on PATH."
echo "Verify with: $BIN_DIR/rexplain status"
