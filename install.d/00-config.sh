# 00-config.sh
# Sourced by install.sh. Config defaults (from a prior run's CONF_FILE if
# present, else built-in fallbacks) and the small helper functions the rest
# of install.d/*.sh relies on: log(), backup_config(), save_config(), ask().

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
MODEL_PROFILE="${MODEL_PROFILE:-qwen35-9b}"                # which model-profiles/*.sh to load
LAST_MODEL_PROFILE="${LAST_MODEL_PROFILE:-}"               # profile in effect last run, so we know to reset
                                                            # HF_REPO/GGUF_PATTERN/etc to the new profile's
                                                            # defaults when this run switches profiles
GGUF_PATTERN="${GGUF_PATTERN:-}"                           # quant fragment, matched as a glob (profile default if empty)
QUANT_WEIGHT_MIB="${QUANT_WEIGHT_MIB:-}"                   # weight file size, MiB, feeds the context math
HF_REPO="${HF_REPO:-}"                                     # Hugging Face repo (profile default if empty)
QUANT_CHOICE="${QUANT_CHOICE:-}"
GPU_VRAM_MIB="${GPU_VRAM_MIB:-7885}"                       # usable VRAM, MiB (~7.7 GiB), feeds the context math
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-16384}"
LLAMA_BATCH_SIZE="${LLAMA_BATCH_SIZE:-512}"
LLAMA_CPU_FFN_LAYERS="${LLAMA_CPU_FFN_LAYERS:-2}"          # last N layers' FFN weights forced to CPU, frees VRAM
                                                            # (light default: dense FFN offload costs more per
                                                            # layer than the equivalent MoE trick, see prompt below)
LLAMA_NO_KV_OFFLOAD="${LLAMA_NO_KV_OFFLOAD:-no}"           # whole KV cache in system RAM instead of VRAM
KEEP_PLE_ON_CPU="${KEEP_PLE_ON_CPU:-yes}"                  # Per-Layer Embedding tables in system RAM (Gemma only)
LLAMA_SPEC_DRAFT_N="${LLAMA_SPEC_DRAFT_N:-2}"
LLAMA_N_PREDICT="${LLAMA_N_PREDICT:-4096}"                 # safety cap on tokens per response (llama-server -n);
                                                            # neither llama-server nor Roo Code's own client
                                                            # settings (maxTokens: -1, includeMaxTokens: false)
                                                            # cap output otherwise, so a degenerate/repeating
                                                            # generation would run until it fills the whole
                                                            # context instead of stopping on its own
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-}"                   # resolved during Step 7, cached here
PROXY_DEBUG_LOG="${PROXY_DEBUG_LOG:-no}"
PROXY_LOG_DEST="${PROXY_LOG_DEST:-console}"                # console or disk
PROXY_LOG_FILE="${PROXY_LOG_FILE:-$HOME/.local/state/litellm-proxy.log}"  # a systemd --user unit usually can't write /var/log
INSTALL_DESKTOP_SHORTCUT="${INSTALL_DESKTOP_SHORTCUT:-yes}"
DESKTOP_DIR="${DESKTOP_DIR:-$HOME/Desktop}"
# Whether systemd lingering was already on before install.sh ever touched
# it, recorded once on first install so uninstall.sh knows whether turning
# it off again is safe (i.e. we turned it on) or would undo something the
# user had set up themselves for unrelated reasons.
LINGER_PRE_INSTALL_STATE="${LINGER_PRE_INSTALL_STATE:-}"

# Model reasoning/"thinking" mode: off by default. Measured live (2026-07-25,
# RTX 3080 8GB, Nemotron 3 Nano 30B-A3B, a grep+read_file tool-calling
# prompt) that for Claude Code's mechanical tool-calling workload, thinking
# does not improve tool-call correctness but costs ~13x the tokens and ~11x
# the latency for an equivalent result - and at a realistic per-turn token
# budget (500 tokens), the model burned the entire budget on reasoning and
# never emitted the tool call at all (finish_reason: length). Not a
# CONF_FILE-editable-only setting on purpose - set via install.sh's
# --enable-thinking / --disable-thinking flags, not the interactive prompt
# flow, so flipping it is a deliberate command-line choice each time rather
# than something that can get left on by an "Enter to keep previous answer"
# re-run. See README.md "Thinking mode".
ENABLE_THINKING="${ENABLE_THINKING:-no}"

log() {
  if [ "$INSTALL_VERBOSE" = "yes" ]; then
    if [ "$INSTALL_LOG_DEST" = "disk" ]; then
      echo "[install] $*" | tee -a "$INSTALL_LOG_FILE" >&2
    else
      echo "[install] $*" >&2
    fi
  fi
}

# Backs up a pre-existing file the first time we're about to overwrite it,
# so uninstall.sh can put back whatever was there before install.sh ever
# ran. Only fires once - re-running install.sh on top of its own previous
# output must not clobber the original backup with our own generated file.
backup_config() {
  local target="$1" bak="$1.pre-install.bak"
  if [ -f "$target" ] && [ ! -f "$bak" ]; then
    cp "$target" "$bak"
    log "Backed up pre-existing $target to $bak"
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
MODEL_PROFILE="$MODEL_PROFILE"
LAST_MODEL_PROFILE="$LAST_MODEL_PROFILE"
GGUF_PATTERN="$GGUF_PATTERN"
QUANT_WEIGHT_MIB="$QUANT_WEIGHT_MIB"
HF_REPO="$HF_REPO"
QUANT_CHOICE="$QUANT_CHOICE"
GPU_VRAM_MIB="$GPU_VRAM_MIB"
LLAMA_PORT="$LLAMA_PORT"
LLAMA_CTX_SIZE="$LLAMA_CTX_SIZE"
LLAMA_BATCH_SIZE="$LLAMA_BATCH_SIZE"
LLAMA_CPU_FFN_LAYERS="$LLAMA_CPU_FFN_LAYERS"
LLAMA_NO_KV_OFFLOAD="$LLAMA_NO_KV_OFFLOAD"
KEEP_PLE_ON_CPU="$KEEP_PLE_ON_CPU"
LLAMA_SPEC_DRAFT_N="$LLAMA_SPEC_DRAFT_N"
LLAMA_N_PREDICT="$LLAMA_N_PREDICT"
LLAMA_SERVER_BIN="$LLAMA_SERVER_BIN"
PROXY_DEBUG_LOG="$PROXY_DEBUG_LOG"
PROXY_LOG_DEST="$PROXY_LOG_DEST"
PROXY_LOG_FILE="$PROXY_LOG_FILE"
INSTALL_DESKTOP_SHORTCUT="$INSTALL_DESKTOP_SHORTCUT"
DESKTOP_DIR="$DESKTOP_DIR"
LINGER_PRE_INSTALL_STATE="$LINGER_PRE_INSTALL_STATE"
ENABLE_THINKING="$ENABLE_THINKING"
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
