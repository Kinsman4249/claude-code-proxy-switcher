# 10-prompts-general.sh
# Sourced by install.sh. The non-model-specific interactive prompts: this
# script's own verbose logging, the container/proxy basics asked up front,
# and the small tail of settings asked after the model section (llama-server
# port, proxy debug logging, desktop shortcut).

prompt_general_settings() {
  ask INSTALL_VERBOSE "Verbose output for this install script? (yes/no)"
  if [ "$INSTALL_VERBOSE" = "yes" ]; then
    ask INSTALL_LOG_DEST "Save that verbose output to disk or just show in console? (disk/console)"
    if [ "$INSTALL_LOG_DEST" = "disk" ]; then
      ask INSTALL_LOG_FILE "Log file path"
    fi
  fi

  ask CONTAINER_NAME "Distrobox container name (needs working NVIDIA GPU passthrough)"
  ask CONFIG_HOME "Directory to store litellm_config.yaml in"
  ask BIN_DIR "Directory to install claude-local-toggle.sh into"
  ask PROXY_PORT "LiteLLM proxy port"
  ask PROXY_MASTER_KEY "Proxy auth token (used as ANTHROPIC_AUTH_TOKEN)"
  ask ENABLE_LINGER "Enable systemd lingering so proxy starts before login too? (yes/no)"
}

prompt_misc_settings() {
  ask LLAMA_PORT "llama-server port"
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
}
