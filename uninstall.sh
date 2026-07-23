#!/usr/bin/env bash
# uninstall.sh
# Reverses everything install.sh did: stops and removes the systemd units,
# restores any config files install.sh backed up before overwriting them
# (litellm_config.yaml, the systemd unit files, ~/.claude/settings.json),
# turns lingering back off (only if install.sh was the one who turned it
# on), and deletes every file install.sh generated (toggle script,
# start-local-llama.sh, desktop icons).
#
# Non-interactive except for one question: whether to also delete the
# downloaded GGUF model file(s) and the llama.cpp build directory inside
# the distrobox container. Defaults to "keep them" (answering Enter is
# safe) since they're multi-GB and slow to re-fetch/rebuild.
#
# Run from anywhere; it only reads $HOME/.config/claude-local-setup.conf,
# it doesn't need to be run from inside the repo clone.

set -uo pipefail

CONF_FILE="$HOME/.config/claude-local-setup.conf"

if [ ! -f "$CONF_FILE" ]; then
  echo "No $CONF_FILE found - install.sh doesn't appear to have run, nothing to undo."
  exit 0
fi
# shellcheck disable=SC1090
source "$CONF_FILE"

CONTAINER_NAME="${CONTAINER_NAME:-}"
CONFIG_HOME="${CONFIG_HOME:-$HOME}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DESKTOP_DIR="${DESKTOP_DIR:-$HOME/Desktop}"
INSTALL_DESKTOP_SHORTCUT="${INSTALL_DESKTOP_SHORTCUT:-no}"
ENABLE_LINGER="${ENABLE_LINGER:-no}"
LINGER_PRE_INSTALL_STATE="${LINGER_PRE_INSTALL_STATE:-}"
GGUF_PATTERN="${GGUF_PATTERN:-}"

echo "== Reversing claude-code-proxy-switcher install =="
echo

# --- Restore a file we backed up before install.sh overwrote it, or just ---
# --- remove it if install.sh created it fresh (no backup exists). ---
restore_or_remove() {
  local target="$1" bak="$1.pre-install.bak"
  if [ -f "$bak" ]; then
    mv -f "$bak" "$target"
    echo "Restored $target from its pre-install backup."
  elif [ -f "$target" ]; then
    rm -f "$target"
    echo "Removed $target (install.sh created it, nothing to restore)."
  fi
}

# --- Step 1: stop and disable the systemd units ---
if systemctl --user list-unit-files litellm-ollama-box.service >/dev/null 2>&1; then
  systemctl --user disable --now litellm-ollama-box.service 2>/dev/null
fi
if systemctl --user list-unit-files distrobox-reminder.service >/dev/null 2>&1; then
  systemctl --user disable --now distrobox-reminder.service 2>/dev/null
fi
echo "Stopped and disabled litellm-ollama-box.service and distrobox-reminder.service."

restore_or_remove "$HOME/.config/systemd/user/litellm-ollama-box.service"
restore_or_remove "$HOME/.config/systemd/user/distrobox-reminder.service"
systemctl --user daemon-reload

# --- Step 2: lingering - only turn it off if install.sh was the one who ---
# --- turned it on; leave it alone if it was already on for another reason. ---
if [ "$ENABLE_LINGER" = "yes" ]; then
  if [ "$LINGER_PRE_INSTALL_STATE" = "no" ]; then
    loginctl disable-linger "$USER" 2>/dev/null
    echo "Disabled systemd lingering (install.sh had turned it on)."
  else
    echo "Leaving systemd lingering as-is (it was already on before install.sh ran, or its prior state is unknown)."
  fi
fi

# --- Step 3: litellm_config.yaml ---
restore_or_remove "$CONFIG_HOME/litellm_config.yaml"

# --- Step 4: ~/.claude/settings.json - undo claude-local-toggle.sh's edits ---
SETTINGS_FILE="$HOME/.claude/settings.json"
TOGGLE_BACKUP="$HOME/.claude/settings.json.pre-local-toggle.bak"
if [ -f "$TOGGLE_BACKUP" ]; then
  mv -f "$TOGGLE_BACKUP" "$SETTINGS_FILE"
  echo "Restored $SETTINGS_FILE to its state from before local mode was ever switched on."
else
  echo "$SETTINGS_FILE was never modified (local mode was never switched on), leaving it alone."
fi

# --- Step 5: generated scripts in BIN_DIR ---
for f in claude-local-toggle.sh claude-local-desktop-toggle.sh \
         start-local-llama.sh start-local-llama-desktop.sh; do
  if [ -f "$BIN_DIR/$f" ]; then
    rm -f "$BIN_DIR/$f"
    echo "Removed $BIN_DIR/$f"
  fi
done

# --- Step 6: desktop icons ---
for f in claude-local-toggle.desktop claude-local-start-model.desktop; do
  if [ -f "$DESKTOP_DIR/$f" ]; then
    rm -f "$DESKTOP_DIR/$f"
    echo "Removed $DESKTOP_DIR/$f"
  fi
done

# --- Step 7: the one interactive question ---
echo
if [ -n "$CONTAINER_NAME" ] && distrobox list 2>/dev/null | tail -n +2 | grep -qi "$CONTAINER_NAME"; then
  FOUND_GGUF=""
  if [ -n "$GGUF_PATTERN" ]; then
    FOUND_GGUF="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "find ~ -maxdepth 3 -iname '*.gguf' 2>/dev/null")"
  fi
  HAVE_LLAMACPP="$(distrobox enter "$CONTAINER_NAME" -- bash -lc '[ -d "$HOME/llama.cpp" ] && echo yes' 2>/dev/null)"

  if [ -n "$FOUND_GGUF" ] || [ "$HAVE_LLAMACPP" = "yes" ]; then
    echo "Found leftovers inside container '$CONTAINER_NAME':"
    [ -n "$FOUND_GGUF" ] && echo "$FOUND_GGUF" | sed 's/^/  /'
    [ "$HAVE_LLAMACPP" = "yes" ] && echo "  ~/llama.cpp (source + compiled llama-server)"
    echo
    read -rp "Delete these too? Multi-GB, slow to re-fetch/rebuild if you say yes. [y/N]: " DELETE_MODEL
    case "$DELETE_MODEL" in
      [yY]|[yY][eE][sS])
        distrobox enter "$CONTAINER_NAME" -- bash -lc "find ~ -maxdepth 3 -iname '*.gguf' -delete; rm -rf ~/llama.cpp"
        echo "Deleted model file(s) and ~/llama.cpp inside '$CONTAINER_NAME'."
        ;;
      *)
        echo "Leaving model file(s) and ~/llama.cpp in place inside '$CONTAINER_NAME'."
        ;;
    esac
  else
    echo "No downloaded model files or llama.cpp build found inside container '$CONTAINER_NAME'."
  fi
else
  echo "Container '$CONTAINER_NAME' not found (or none recorded) - skipping the model-file cleanup question."
fi

# --- Step 8: the install config itself ---
rm -f "$CONF_FILE"
echo
echo "Removed $CONF_FILE."

echo
echo "== Done =="
echo "Claude Code is back to normal subscription auth, and the systemd units,"
echo "generated scripts, and desktop icons from this project are gone."
