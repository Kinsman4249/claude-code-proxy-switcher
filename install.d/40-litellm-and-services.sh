# 40-litellm-and-services.sh
# Sourced by install.sh. Steps 1-6: writes litellm_config.yaml, makes sure
# litellm is installed inside the container, installs+enables the systemd
# units, handles lingering, and verifies the proxy comes up. Sets
# CONFIG_DEST as a side effect (used by 50-toggle-and-desktop.sh's sed
# patches would not need it, but keeping it a global matches how the rest
# of this script threads state between steps).

# --- Step 1: place litellm_config.yaml, with master_key and port patched in ---
install_litellm_config() {
  mkdir -p "$CONFIG_HOME"
  CONFIG_DEST="$CONFIG_HOME/litellm_config.yaml"
  backup_config "$CONFIG_DEST"
  sed -e "s/sk-local-dev-key/$PROXY_MASTER_KEY/g" \
      -e "s|http://localhost:8080|http://localhost:$LLAMA_PORT|g" \
      "$SCRIPT_DIR/litellm_config.yaml" > "$CONFIG_DEST"

  if [ "$PROXY_DEBUG_LOG" = "yes" ]; then
    sed -i \
      -e "s/^  # log_level: DEBUG/  log_level: DEBUG/" \
      "$CONFIG_DEST"
    if [ "$PROXY_LOG_DEST" = "disk" ]; then
      mkdir -p "$(dirname "$PROXY_LOG_FILE")"
      sed -i \
        -e "s|^  # log_file: ~/.local/state/litellm-proxy.log|  log_file: $PROXY_LOG_FILE|" \
        "$CONFIG_DEST"
    fi
  fi
  log "Wrote $CONFIG_DEST"
}

# --- Step 2: make sure litellm itself is installed inside the container ---
# Must happen before Step 4 enables/starts the systemd service below: on a
# fresh container (or a broken old setup where this got skipped somehow),
# starting the service before litellm exists just crash-loops it.
#
# Two gotchas found the hard way (2026-08-03, live debug of a container with
# both python3.12 and python3.13 installed):
#
# 1. Some containers end up with more than one Python (e.g. one pulled in by
#    an unrelated tool), each with its own site-packages. The "litellm"
#    command on PATH is a shebang script pinned to one specific interpreter,
#    but a bare "python3 -c 'import litellm'" check can silently resolve to
#    a *different* interpreter that happens to have litellm fully installed
#    (proxy extras and all). The check then reports success while the
#    systemd unit - which always runs the "litellm" binary directly, never
#    "python3 -m litellm" - keeps crash-looping on startup. So: resolve the
#    exact interpreter the "litellm" binary itself runs under (its shebang
#    line), and use that same interpreter for both the check and the
#    install, not whatever "python3" happens to be first on PATH.
#
# 2. "import litellm" alone is too weak a check anyway: the base package
#    imports fine without the proxy extras (apscheduler, uvicorn, etc.), so
#    it has to import litellm.proxy.proxy_server specifically - the same
#    module "litellm --config ..." (what the systemd unit runs) imports on
#    startup, and the thing that actually fails with a bare `pip install
#    litellm` (no [proxy] extra).
install_litellm_in_container() {
  distrobox enter "$CONTAINER_NAME" -- bash -lc '
    LITELLM_BIN="$(command -v litellm || true)"
    if [ -n "$LITELLM_BIN" ]; then
      PYBIN="$(head -1 "$LITELLM_BIN" | sed "s/^#!//")"
      [ -x "$PYBIN" ] || PYBIN=python3
    else
      PYBIN=python3
    fi

    "$PYBIN" -c "import litellm.proxy.proxy_server" 2>/dev/null || {
      "$PYBIN" -m pip --version >/dev/null 2>&1 || sudo dnf install -y python3-pip
      # fastapi>=0.140.4 (released 2026-07-27) removed get_flat_dependant(),
      # which the litellm proxy server still imports at startup - pin below
      # that so a plain "pip install litellm[proxy]" cannot pull in a
      # broken fastapi. litellm itself only declares fastapi>=0.136.3,<1.0,
      # a range loose enough to include the broken releases; this is a
      # workaround for that upstream gap, not a formal litellm requirement.
      sudo "$PYBIN" -m pip install "litellm[proxy]" "fastapi<0.140" --break-system-packages -q
    }
  '
  log "Confirmed litellm is installed inside $CONTAINER_NAME"
}

# --- Step 3: install both systemd unit files, patched for port/path ---
install_systemd_units() {
  mkdir -p "$HOME/.config/systemd/user"

  backup_config "$HOME/.config/systemd/user/litellm-ollama-box.service"
  backup_config "$HOME/.config/systemd/user/distrobox-reminder.service"

  sed -e "s|/home/%u/litellm_config.yaml|$CONFIG_DEST|" \
      -e "s/--port 4000/--port $PROXY_PORT/" \
      -e "s/distrobox enter ollama-box/distrobox enter $CONTAINER_NAME/g" \
      "$SCRIPT_DIR/litellm-ollama-box.service" > "$HOME/.config/systemd/user/litellm-ollama-box.service"

  cp "$SCRIPT_DIR/distrobox-reminder.service" "$HOME/.config/systemd/user/distrobox-reminder.service"

  systemctl --user daemon-reload
  log "Installed and reloaded systemd units"
}

# --- Step 4: enable both services ---
# litellm-ollama-box.service: "enable --now" only starts it if it wasn't
# already running - on a re-install over a broken old setup (stale config,
# old ExecStop, whatever) the whole point is to force the fixed unit file
# and config to actually take effect, so explicitly restart it too. This is
# safe: ExecStop only kills the litellm process now, not the container, so
# it will never take llama-server down with it.
enable_services() {
  systemctl --user enable --now litellm-ollama-box.service
  systemctl --user restart litellm-ollama-box.service
  systemctl --user enable --now distrobox-reminder.service
  log "Enabled litellm-ollama-box.service (restarted to apply any config/unit changes) and distrobox-reminder.service"
}

# --- Step 5: lingering, if requested ---
setup_linger() {
  if [ "$ENABLE_LINGER" = "yes" ]; then
    if [ -z "$LINGER_PRE_INSTALL_STATE" ]; then
      if loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q "=yes"; then
        LINGER_PRE_INSTALL_STATE="yes"
      else
        LINGER_PRE_INSTALL_STATE="no"
      fi
      save_config
    fi
    loginctl enable-linger "$USER"
    log "Lingering enabled for $USER"
  fi
}

# --- Step 6: verify the proxy came up ---
# Auth header is required here: LiteLLM's own auth-failure error path throws
# an unrelated ModuleNotFoundError (missing optional 'prisma' package, not
# installed and not needed for this master-key-only setup) instead of a
# clean 401 when a request arrives with no token, so an unauthenticated
# health check gets a misleading 500 instead of a straight pass/fail.
verify_proxy() {
  local PROXY_UP=no i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $PROXY_MASTER_KEY" "http://localhost:$PROXY_PORT/health" | grep -q "200"; then
      PROXY_UP=yes
      break
    fi
    sleep 1
  done
  if [ "$PROXY_UP" = "yes" ]; then
    echo "Proxy is up at http://localhost:$PROXY_PORT"
  else
    echo "WARNING: proxy did not respond at http://localhost:$PROXY_PORT/health after 10s" >&2
    echo "Check: systemctl --user status litellm-ollama-box.service" >&2
  fi
}
