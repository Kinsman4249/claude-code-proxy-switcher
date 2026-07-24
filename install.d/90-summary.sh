# 90-summary.sh
# Sourced by install.sh. Final "what to do next" message, printed
# regardless of whether the launcher step above actually ran.

print_summary() {
  echo
  echo "== Done =="
  echo "Proxy: always running via systemd, currently OFF from Claude Code's perspective."
  echo "To switch Claude Code to local mode: $BIN_DIR/claude-local-toggle.sh on"
  if [ "$INSTALL_DESKTOP_SHORTCUT" = "yes" ]; then
    echo "Or just double-click the Claude Local Toggle icon on your desktop."
  fi
  echo "Then reload the VS Code/VSCodium window."
  echo "To start the model itself (not loaded by default):"
  echo "  $BIN_DIR/start-local-llama.sh"
}
