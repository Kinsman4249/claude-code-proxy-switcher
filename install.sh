#!/usr/bin/env bash
# install.sh
# Runs every step from setup-directions.md. Run this from the same
# directory as the other files (litellm_config.yaml, local-model.Modelfile,
# litellm-ollama-box.service, distrobox-reminder.service,
# claude-local-toggle.sh, claude-local-desktop-toggle.sh,
# claude-local-toggle.desktop).
#
# Interactive: prompts for anything that needs a decision, shows your
# previous answer as the default so re-running is just hitting Enter
# through it. Answers are saved to CONF_FILE and reloaded automatically.
#
# Safe to re-run. Steps that are already done (services enabled, model
# already built, etc.) are skipped or just re-applied harmlessly.

set -uo pipefail   # not -e: a failed step should be reported, not kill
                    # the whole interactive script mid-way

CONF_FILE="$HOME/.config/claude-local-setup.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$(dirname "$CONF_FILE")"
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

# --- Debug logging toggle for THIS script's own output ---
# Defaults come from the saved config if present, else these fallbacks.
INSTALL_VERBOSE="${INSTALL_VERBOSE:-no}"
INSTALL_LOG_DEST="${INSTALL_LOG_DEST:-console}"   # console or disk
INSTALL_LOG_FILE="${INSTALL_LOG_FILE:-$HOME/claude-local-install.log}"

# --- Config values this script manages, with prior-run or built-in defaults ---
CONTAINER_NAME="${CONTAINER_NAME:-ollama-box}"
CONFIG_HOME="${CONFIG_HOME:-$HOME}"                        # where litellm_config.yaml lives
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"                     # where claude-local-toggle.sh goes
PROXY_PORT="${PROXY_PORT:-4000}"
PROXY_MASTER_KEY="${PROXY_MASTER_KEY:-sk-local-dev-key}"
ENABLE_LINGER="${ENABLE_LINGER:-no}"
DOWNLOAD_MODEL_NOW="${DOWNLOAD_MODEL_NOW:-yes}"
GGUF_FILENAME="${GGUF_FILENAME:-Qwen3.5-9B-UD-Q5_K_XL.gguf}"
HF_REPO="${HF_REPO:-unsloth/Qwen3.5-9B-GGUF}"
OLLAMA_MODEL_TAG="${OLLAMA_MODEL_TAG:-local-qwen35-coder-cc}"
PROXY_DEBUG_LOG="${PROXY_DEBUG_LOG:-no}"
PROXY_LOG_DEST="${PROXY_LOG_DEST:-console}"                # console or disk
PROXY_LOG_FILE="${PROXY_LOG_FILE:-/var/log/litellm-proxy.log}"
INSTALL_DESKTOP_SHORTCUT="${INSTALL_DESKTOP_SHORTCUT:-yes}"
DESKTOP_DIR="${DESKTOP_DIR:-$HOME/Desktop}"

log() {
  if [ "$INSTALL_VERBOSE" = "yes" ]; then
    if [ "$INSTALL_LOG_DEST" = "disk" ]; then
      echo "[install] $*" | tee -a "$INSTALL_LOG_FILE" >&2
    else
      echo "[install] $*" >&2
    fi
  fi
}

save_config() {
  cat > "$CONF_FILE" << EOF
INSTALL_VERBOSE="$INSTALL_VERBOSE"
INSTALL_LOG_DEST="$INSTALL_LOG_DEST"
INSTALL_LOG_FILE="$INSTALL_LOG_FILE"
CONTAINER_NAME="$CONTAINER_NAME"
CONFIG_HOME="$CONFIG_HOME"
BIN_DIR="$BIN_DIR"
PROXY_PORT="$PROXY_PORT"
PROXY_MASTER_KEY="$PROXY_MASTER_KEY"
ENABLE_LINGER="$ENABLE_LINGER"
DOWNLOAD_MODEL_NOW="$DOWNLOAD_MODEL_NOW"
GGUF_FILENAME="$GGUF_FILENAME"
HF_REPO="$HF_REPO"
OLLAMA_MODEL_TAG="$OLLAMA_MODEL_TAG"
PROXY_DEBUG_LOG="$PROXY_DEBUG_LOG"
PROXY_LOG_DEST="$PROXY_LOG_DEST"
PROXY_LOG_FILE="$PROXY_LOG_FILE"
INSTALL_DESKTOP_SHORTCUT="$INSTALL_DESKTOP_SHORTCUT"
DESKTOP_DIR="$DESKTOP_DIR"
EOF
}

ask() {
  # ask VAR_NAME "question text" 
  local varname="$1" question="$2" current="${!1}" answer
  read -rp "$question [$current]: " answer
  if [ -n "$answer" ]; then
    printf -v "$varname" '%s' "$answer"
  fi
}

echo "== Claude Code local-model setup =="
echo "Answers from previous runs are shown as defaults, press Enter to keep them."
echo

ask INSTALL_VERBOSE "Verbose output for this install script? (yes/no)"
if [ "$INSTALL_VERBOSE" = "yes" ]; then
  ask INSTALL_LOG_DEST "Save that verbose output to disk or just show in console? (disk/console)"
  if [ "$INSTALL_LOG_DEST" = "disk" ]; then
    ask INSTALL_LOG_FILE "Log file path"
  fi
fi

ask CONTAINER_NAME "Distrobox container name running Ollama"
ask CONFIG_HOME "Directory to store litellm_config.yaml in"
ask BIN_DIR "Directory to install claude-local-toggle.sh into"
ask PROXY_PORT "LiteLLM proxy port"
ask PROXY_MASTER_KEY "Proxy auth token (used as ANTHROPIC_AUTH_TOKEN)"
ask ENABLE_LINGER "Enable systemd lingering so proxy starts before login too? (yes/no)"
ask DOWNLOAD_MODEL_NOW "Download the Qwen3.5-9B model now? (yes/no, big download)"
if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
  ask GGUF_FILENAME "Exact GGUF filename (check the repo listing if unsure)"
  ask HF_REPO "Hugging Face repo"
fi
ask OLLAMA_MODEL_TAG "Ollama tag name to build"
ask PROXY_DEBUG_LOG "Enable verbose LiteLLM proxy logging? (yes/no)"
if [ "$PROXY_DEBUG_LOG" = "yes" ]; then
  ask PROXY_LOG_DEST "Proxy logs to disk or console? (disk/console)"
  if [ "$PROXY_LOG_DEST" = "disk" ]; then
    ask PROXY_LOG_FILE "Proxy log file path"
  fi
fi
ask INSTALL_DESKTOP_SHORTCUT "Install a desktop icon to flip local mode on/off? (yes/no)"
if [ "$INSTALL_DESKTOP_SHORTCUT" = "yes" ]; then
  ask DESKTOP_DIR "Desktop directory"
fi

save_config
echo
echo "Saved your answers to $CONF_FILE for next time."
echo

# --- Sanity check: does the container exist? ---
# Case-insensitive on purpose: container-manager GUIs (Kontainer, etc.) often
# display names title-cased even though the underlying distrobox container is
# lowercase. Match loosely, then resolve to whatever casing distrobox itself
# reports, so every later command (distrobox enter/stop) uses the real name.
MATCHED_LINE="$(distrobox list 2>/dev/null | grep -i "$CONTAINER_NAME" || true)"
if [ -z "$MATCHED_LINE" ]; then
  echo "ERROR: no distrobox container matching '$CONTAINER_NAME' found." >&2
  echo "This script assumes it already exists with Ollama installed inside it." >&2
  echo "Run 'distrobox list' yourself to check the exact name, then re-run this script." >&2
  exit 1
fi

# distrobox list output is a table; the name is the second field, whitespace
# padded. This extracts it and trims surrounding spaces.
RESOLVED_NAME="$(echo "$MATCHED_LINE" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
if [ -n "$RESOLVED_NAME" ] && [ "$RESOLVED_NAME" != "$CONTAINER_NAME" ]; then
  echo "Note: using '$RESOLVED_NAME' (the actual container name), not '$CONTAINER_NAME' as typed."
  CONTAINER_NAME="$RESOLVED_NAME"
  save_config
fi
log "Found container $CONTAINER_NAME"

# --- Step 1: place litellm_config.yaml, with master_key patched in ---
mkdir -p "$CONFIG_HOME"
CONFIG_DEST="$CONFIG_HOME/litellm_config.yaml"
sed -e "s/sk-local-dev-key/$PROXY_MASTER_KEY/g" "$SCRIPT_DIR/litellm_config.yaml" > "$CONFIG_DEST"

if [ "$PROXY_DEBUG_LOG" = "yes" ]; then
  sed -i \
    -e "s/^  # log_level: DEBUG/  log_level: DEBUG/" \
    "$CONFIG_DEST"
  if [ "$PROXY_LOG_DEST" = "disk" ]; then
    sed -i \
      -e "s|^  # log_file: /var/log/litellm-proxy.log|  log_file: $PROXY_LOG_FILE|" \
      "$CONFIG_DEST"
  fi
fi
log "Wrote $CONFIG_DEST"

# --- Step 2: install both systemd unit files, patched for port/path ---
mkdir -p "$HOME/.config/systemd/user"

sed -e "s|/home/%u/litellm_config.yaml|$CONFIG_DEST|" \
    -e "s/--port 4000/--port $PROXY_PORT/" \
    -e "s/distrobox enter ollama-box/distrobox enter $CONTAINER_NAME/" \
    -e "s/distrobox stop --yes ollama-box/distrobox stop --yes $CONTAINER_NAME/" \
    "$SCRIPT_DIR/litellm-ollama-box.service" > "$HOME/.config/systemd/user/litellm-ollama-box.service"

cp "$SCRIPT_DIR/distrobox-reminder.service" "$HOME/.config/systemd/user/distrobox-reminder.service"

systemctl --user daemon-reload
log "Installed and reloaded systemd units"

# --- Step 3: enable both services ---
systemctl --user enable --now litellm-ollama-box.service
systemctl --user enable --now distrobox-reminder.service
log "Enabled litellm-ollama-box.service and distrobox-reminder.service"

# --- Step 4: lingering, if requested ---
if [ "$ENABLE_LINGER" = "yes" ]; then
  loginctl enable-linger "$USER"
  log "Lingering enabled for $USER"
fi

# --- Step 5: verify the proxy came up ---
sleep 2
if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PROXY_PORT/health" | grep -q "200"; then
  echo "Proxy is up at http://localhost:$PROXY_PORT"
else
  echo "WARNING: proxy did not respond at http://localhost:$PROXY_PORT/health" >&2
  echo "Check: systemctl --user status litellm-ollama-box.service" >&2
fi

# --- Step 6: install the toggle script, patched with port/token ---
mkdir -p "$BIN_DIR"
sed -e "s|http://localhost:4000|http://localhost:$PROXY_PORT|g" \
    -e "s/sk-local-dev-key/$PROXY_MASTER_KEY/g" \
    "$SCRIPT_DIR/claude-local-toggle.sh" > "$BIN_DIR/claude-local-toggle.sh"
chmod +x "$BIN_DIR/claude-local-toggle.sh"
log "Installed toggle script to $BIN_DIR/claude-local-toggle.sh"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH. Add it to ~/.bashrc if you want to run" \
          "claude-local-toggle.sh by name instead of full path." ;;
esac

# --- Step 6b: desktop shortcut, if requested ---
if [ "$INSTALL_DESKTOP_SHORTCUT" = "yes" ]; then
  # This wrapper flips whatever state you're currently in and confirms via
  # notify-send, since a desktop icon has no terminal to print to. It reads
  # TOGGLE_SCRIPT's path, patched here to match wherever BIN_DIR actually is.
  sed -e "s|\$HOME/.local/bin/claude-local-toggle.sh|$BIN_DIR/claude-local-toggle.sh|" \
      "$SCRIPT_DIR/claude-local-desktop-toggle.sh" > "$BIN_DIR/claude-local-desktop-toggle.sh"
  chmod +x "$BIN_DIR/claude-local-desktop-toggle.sh"

  mkdir -p "$DESKTOP_DIR"
  sed -e "s|/home/YOUR_USERNAME/.local/bin/claude-local-desktop-toggle.sh|$BIN_DIR/claude-local-desktop-toggle.sh|" \
      "$SCRIPT_DIR/claude-local-toggle.desktop" > "$DESKTOP_DIR/claude-local-toggle.desktop"
  chmod +x "$DESKTOP_DIR/claude-local-toggle.desktop"

  log "Installed desktop shortcut to $DESKTOP_DIR/claude-local-toggle.desktop"
  echo "Desktop icon installed. On KDE Plasma (Bazzite default), the first"
  echo "double-click may prompt to trust/execute it, click through it once"
  echo "and it won't ask again."
fi

# --- Step 7: download the model and build the Ollama tag, inside the container ---
if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
  echo "Downloading $GGUF_FILENAME from $HF_REPO inside $CONTAINER_NAME, this is a multi-GB download..."
  distrobox enter "$CONTAINER_NAME" -- bash -lc "
    (python3 -m pip --version >/dev/null 2>&1 || sudo dnf install -y python3-pip) &&
    sudo python3 -m pip install -U huggingface_hub --break-system-packages -q &&
    hf download '$HF_REPO' --include '$GGUF_FILENAME' --local-dir ~/
  "
  if [ $? -ne 0 ]; then
    echo "WARNING: model download failed. Check the exact filename on the repo's" >&2
    echo "file listing and re-run this script, or run the hf download command" >&2
    echo "manually inside the container." >&2
  else
    log "Downloaded $GGUF_FILENAME"
  fi

  echo "Building Ollama tag $OLLAMA_MODEL_TAG..."
  distrobox enter "$CONTAINER_NAME" -- bash -lc "
    set -e
    GGUF_PATH=\$(find ~ -maxdepth 3 -iname '$GGUF_FILENAME' 2>/dev/null | head -n1)
    if [ -z \"\$GGUF_PATH\" ]; then
      echo 'ERROR: could not locate $GGUF_FILENAME anywhere under home. Check the download step above.' >&2
      exit 1
    fi
    echo \"Found downloaded model at: \$GGUF_PATH\"
    sed \"s|^FROM .*|FROM \$GGUF_PATH|\" '$SCRIPT_DIR/local-model.Modelfile' > /tmp/local-model.resolved.Modelfile
    ollama create '$OLLAMA_MODEL_TAG' -f /tmp/local-model.resolved.Modelfile
  "
  if [ $? -ne 0 ]; then
    echo "WARNING: 'ollama create' failed. Confirm the .gguf file and Modelfile" >&2
    echo "are both accessible inside the container, then retry manually." >&2
  else
    log "Built Ollama tag $OLLAMA_MODEL_TAG"
  fi
else
  echo "Skipped model download/build. Run this script again with 'yes' when ready," \
       "or do it manually per local-model.Modelfile."
fi

# --- Step 8: make sure litellm itself is installed inside the container ---
distrobox enter "$CONTAINER_NAME" -- bash -lc "
  python3 -c 'import litellm' 2>/dev/null || {
    python3 -m pip --version >/dev/null 2>&1 || sudo dnf install -y python3-pip
    sudo python3 -m pip install 'litellm[proxy]' --break-system-packages -q
  }
"
log "Confirmed litellm is installed inside $CONTAINER_NAME"

echo
echo "== Done =="
echo "Proxy: always running via systemd, currently OFF from Claude Code's perspective."
echo "To switch Claude Code to local mode: $BIN_DIR/claude-local-toggle.sh on"
if [ "$INSTALL_DESKTOP_SHORTCUT" = "yes" ]; then
  echo "Or just double-click the Claude Local Toggle icon on your desktop."
fi
echo "Then reload the VS Code/VSCodium window."
echo "To start the model itself (not loaded by default):"
echo "  distrobox enter $CONTAINER_NAME"
echo "  ollama serve"
