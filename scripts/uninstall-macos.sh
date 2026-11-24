#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${REXPLAIN_BIN_DIR:-$HOME/.local/bin}"
LEGACY_AGENT="$HOME/Library/LaunchAgents/com.rexplain.service.plist"

if [[ -f "$LEGACY_AGENT" ]]; then
  launchctl bootout "gui/$(id -u)" "$LEGACY_AGENT" >/dev/null 2>&1 || true
  rm -f "$LEGACY_AGENT"
fi

rm -f "$BIN_DIR/rexplain"

echo "Removed Rexplain executable ($BIN_DIR/rexplain)."
echo "Your Rex and Neovim configuration files were left untouched."
