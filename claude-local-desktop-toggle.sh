#!/usr/bin/env bash
# claude-local-desktop-toggle.sh
# Wrapper around claude-local-toggle.sh for double-clicking from the
# desktop. Flips whatever state you're currently in and confirms with a
# notification, since a desktop icon has no terminal to print to.

set -euo pipefail

TOGGLE_SCRIPT="$HOME/.local/bin/claude-local-toggle.sh"
# If you installed the toggle script somewhere else, change the path above
# to match. install.sh's default is ~/.local/bin.

if [ ! -x "$TOGGLE_SCRIPT" ]; then
  notify-send -u critical "Claude local toggle" "Script not found at $TOGGLE_SCRIPT"
  exit 1
fi

CURRENT="$("$TOGGLE_SCRIPT" status)"

if echo "$CURRENT" | grep -q "ON"; then
  "$TOGGLE_SCRIPT" off
  notify-send "Claude Code: local mode OFF" "Back on Pro subscription. Reload the VS Code/VSCodium window."
else
  "$TOGGLE_SCRIPT" on
  notify-send "Claude Code: local mode ON" "Routing through local Qwen. Sonnet/Opus unavailable. Reload the VS Code/VSCodium window."
fi
