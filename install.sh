#!/usr/bin/env bash
# install.sh
# Runs every step described in README.md. Run this from the same
# directory as the other files (litellm_config.yaml,
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
#
# Local runtime is llama-server (llama.cpp's own server), not Ollama:
# Ollama doesn't expose generic speculative decoding, which this script
# wires up (self-speculative MTP). See README.md for the reasoning.
#
# Qwen3.5-9B has no MoE layers (confirmed from its config.json: no
# num_experts field, mlp_only_layers is empty, dense intermediate_size
# throughout) so this script does not use --n-cpu-moe - it would be a
# no-op on this specific model. It's a hybrid dense model instead: only
# every 4th layer is full attention, the rest are linear/DeltaNet
# attention with a small fixed state, which is what the context-length
# math further down is based on.

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
GGUF_PATTERN="${GGUF_PATTERN:-UD-Q5_K_XL}"                 # quant fragment, matched as a glob
QUANT_WEIGHT_MIB="${QUANT_WEIGHT_MIB:-6902}"               # weight file size, MiB, feeds the context math
HF_REPO="${HF_REPO:-unsloth/Qwen3.5-9B-MTP-GGUF}"          # MTP build: needed for --spec-type draft-mtp
QUANT_CHOICE="${QUANT_CHOICE:-5}"
GPU_VRAM_MIB="${GPU_VRAM_MIB:-7885}"                       # usable VRAM, MiB (~7.7 GiB), feeds the context math
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-16384}"
LLAMA_BATCH_SIZE="${LLAMA_BATCH_SIZE:-512}"
LLAMA_CPU_FFN_LAYERS="${LLAMA_CPU_FFN_LAYERS:-2}"          # last N layers' FFN weights forced to CPU, frees VRAM
                                                            # (light default: dense FFN offload costs more per
                                                            # layer than the equivalent MoE trick, see prompt below)
LLAMA_NO_KV_OFFLOAD="${LLAMA_NO_KV_OFFLOAD:-no}"           # whole KV cache in system RAM instead of VRAM
LLAMA_SPEC_DRAFT_N="${LLAMA_SPEC_DRAFT_N:-2}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-}"                   # resolved during Step 7, cached here
PROXY_DEBUG_LOG="${PROXY_DEBUG_LOG:-no}"
PROXY_LOG_DEST="${PROXY_LOG_DEST:-console}"                # console or disk
PROXY_LOG_FILE="${PROXY_LOG_FILE:-/var/log/litellm-proxy.log}"
INSTALL_DESKTOP_SHORTCUT="${INSTALL_DESKTOP_SHORTCUT:-yes}"
DESKTOP_DIR="${DESKTOP_DIR:-$HOME/Desktop}"
# Whether systemd lingering was already on before install.sh ever touched
# it, recorded once on first install so uninstall.sh knows whether turning
# it off again is safe (i.e. we turned it on) or would undo something the
# user had set up themselves for unrelated reasons.
LINGER_PRE_INSTALL_STATE="${LINGER_PRE_INSTALL_STATE:-}"

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
LLAMA_SPEC_DRAFT_N="$LLAMA_SPEC_DRAFT_N"
LLAMA_SERVER_BIN="$LLAMA_SERVER_BIN"
PROXY_DEBUG_LOG="$PROXY_DEBUG_LOG"
PROXY_LOG_DEST="$PROXY_LOG_DEST"
PROXY_LOG_FILE="$PROXY_LOG_FILE"
INSTALL_DESKTOP_SHORTCUT="$INSTALL_DESKTOP_SHORTCUT"
DESKTOP_DIR="$DESKTOP_DIR"
LINGER_PRE_INSTALL_STATE="$LINGER_PRE_INSTALL_STATE"
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

ask CONTAINER_NAME "Distrobox container name (needs working NVIDIA GPU passthrough)"
ask CONFIG_HOME "Directory to store litellm_config.yaml in"
ask BIN_DIR "Directory to install claude-local-toggle.sh into"
ask PROXY_PORT "LiteLLM proxy port"
ask PROXY_MASTER_KEY "Proxy auth token (used as ANTHROPIC_AUTH_TOKEN)"
ask ENABLE_LINGER "Enable systemd lingering so proxy starts before login too? (yes/no)"
ask DOWNLOAD_MODEL_NOW "Download the local model now? (yes/no, big download if not already cached)"
if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
  echo
  echo "Which quantization? All are Qwen3.5-9B-MTP from $HF_REPO"
  echo "(the MTP build is required for self-speculative decoding via --spec-type draft-mtp)."
  echo "Larger = better quality, more VRAM. Sizes below are as reported by the repo"
  echo "(effectively GiB, i.e. already *1024 to MiB in the math further down)."
  echo "  1) Q4_K_M      5.68 GB  (most VRAM headroom for a bigger context)"
  echo "  2) UD-Q4_K_XL  5.97 GB  (Unsloth dynamic quant, better quality at similar size)"
  echo "  3) Q5_K_S      6.36 GB"
  echo "  4) Q5_K_M      6.58 GB  (floor recommended for coding/tool-calling precision)"
  echo "  5) UD-Q5_K_XL  6.74 GB  (previous default, best quality that still leaves headroom)"
  echo "  6) Q6_K        7.46 GB  (best quality, very little room left for context)"
  echo "  7) custom      (type your own quant fragment, e.g. 'IQ4_XS')"
  ask QUANT_CHOICE "Pick a number"
  # QUANT_WEIGHT_MIB feeds the context-length recommendation below. Sizes are
  # the repo-reported "GB" figures * 1024 (they're effectively GiB already,
  # the usual llama.cpp/HF convention).
  case "$QUANT_CHOICE" in
    1) GGUF_PATTERN="Q4_K_M";     QUANT_WEIGHT_MIB=5816 ;;
    2) GGUF_PATTERN="UD-Q4_K_XL"; QUANT_WEIGHT_MIB=6113 ;;
    3) GGUF_PATTERN="Q5_K_S";     QUANT_WEIGHT_MIB=6513 ;;
    4) GGUF_PATTERN="Q5_K_M";     QUANT_WEIGHT_MIB=6739 ;;
    5) GGUF_PATTERN="UD-Q5_K_XL"; QUANT_WEIGHT_MIB=6902 ;;
    6) GGUF_PATTERN="Q6_K";       QUANT_WEIGHT_MIB=7639 ;;
    7) ask GGUF_PATTERN "Exact quant fragment (check the repo's file listing if unsure)"
       ask QUANT_WEIGHT_MIB "Approximate file size of that quant, in MiB (check the repo's file listing; leave blank to skip the context recommendation below)" ;;
    "") ;;  # empty input keeps whatever GGUF_PATTERN/QUANT_WEIGHT_MIB already was (saved default)
    *) echo "Didn't recognize that, keeping $GGUF_PATTERN" ;;
  esac
  ask HF_REPO "Hugging Face repo"

  echo
  echo "How much usable VRAM does your card have for this? Check 'nvidia-smi'"
  echo "for total VRAM, then subtract a few hundred MiB the desktop compositor"
  echo "and driver keep for themselves. 7885 MiB (~7.7 GiB) was measured on an"
  echo "8 GB card previously used with this project."
  ask GPU_VRAM_MIB "Usable VRAM in MiB"

  echo
  echo "Batch size (-b / --batch-size). llama.cpp's own default is 512. Larger"
  echo "values (e.g. 2048) speed up prompt processing but the compute buffer"
  echo "they require eats directly into the VRAM left over for context - on a"
  echo "~8 GB card with a Q5-class quant, batch 2048 can leave close to zero"
  echo "room for KV cache, which is the 'ran out of context' symptom. 512 is"
  echo "the recommended default here; raise it only if the numbers below show"
  echo "you have real headroom to spare."
  ask LLAMA_BATCH_SIZE "Batch size"

  # --- Context-length recommendation ---
  # Qwen3.5-9B is a hybrid dense model: 32 layers total, but only every 4th
  # layer (8 of 32) is full quadratic attention - the other 24 are
  # linear/DeltaNet attention with a small fixed-size recurrent state that
  # does NOT grow with context length. Only the 8 full-attention layers
  # matter for KV cache sizing (confirmed from Qwen/Qwen3.5-9B's
  # config.json: full_attention_interval=4, num_key_value_heads=4,
  # head_dim=256; the model has no MoE layers at all - mlp_only_layers is
  # empty and there's no num_experts field, so --n-cpu-moe would be a
  # no-op here and isn't used).
  #
  # bytes/token = 2(K+V) x num_kv_heads(4) x head_dim(256) x attn_layers(8)
  #             x bytes_per_element(1 for q8_0, always on in this project)
  #             = 16384 bytes/token = 16 KiB/token
  BYTES_PER_TOKEN=16384

  # Compute buffer scales roughly with batch size; ~1508 MiB was measured at
  # batch 2048 in community reports, scaled linearly here as an estimate.
  COMPUTE_BUF_MIB=$(( LLAMA_BATCH_SIZE * 1508 / 2048 ))
  # CUDA context, desktop compositor, and the linear-attention layers' small
  # fixed recurrent state, bundled into one conservative fixed reserve.
  FIXED_OVERHEAD_MIB=350

  if [ -n "${QUANT_WEIGHT_MIB:-}" ]; then
    AVAILABLE_KV_MIB=$(( GPU_VRAM_MIB - QUANT_WEIGHT_MIB - COMPUTE_BUF_MIB - FIXED_OVERHEAD_MIB ))
    echo
    echo "Estimate: ${GPU_VRAM_MIB} MiB VRAM - ${QUANT_WEIGHT_MIB} MiB weights"
    echo "  - ${COMPUTE_BUF_MIB} MiB compute buffer - ${FIXED_OVERHEAD_MIB} MiB fixed"
    echo "  overhead = ${AVAILABLE_KV_MIB} MiB left for KV cache."
    if [ "$AVAILABLE_KV_MIB" -gt 0 ]; then
      MAX_TOKENS=$(( AVAILABLE_KV_MIB * 1024 * 1024 / BYTES_PER_TOKEN ))
      REC_CTX=$(( MAX_TOKENS * 85 / 100 / 1024 * 1024 ))
      if [ "$REC_CTX" -lt 1024 ]; then REC_CTX=1024; fi
      echo "  That's roughly ${MAX_TOKENS} tokens of KV cache at this quant/batch"
      echo "  size; recommending $REC_CTX tokens of context (15% safety margin,"
      echo "  rounded down), press Enter below to accept it."
      LLAMA_CTX_SIZE="$REC_CTX"
    else
      echo "  WARNING: that's negative - this quant doesn't fit at this batch"
      echo "  size and VRAM budget with any context at all. Lower the batch"
      echo "  size above, or pick a smaller quant, and re-run this script."
      LLAMA_CTX_SIZE=4096
    fi
  else
    echo
    echo "No quant size given, can't estimate a safe context length. Falling"
    echo "back to a conservative default; watch the VRAM check after you"
    echo "start llama-server and reduce this if it's too much."
  fi

  echo
  echo "Context window (-c / --ctx-size). Larger lets Claude Code's full prompt fit"
  echo "without truncation, but costs more VRAM on top of the quant above."
  echo "20480 truncated on real Claude Code requests in earlier testing"
  echo "(system prompt + tool schemas alone can be tens of thousands of tokens)."
  ask LLAMA_CTX_SIZE "Context length in tokens"

  echo
  echo "Need more headroom than the above gives you? Nothing overflows to RAM"
  echo "automatically - if a setting doesn't fit VRAM, llama-server just fails"
  echo "to allocate it. Two ways to deliberately trade speed for more room:"
  echo
  echo "1) Force the last N layers' FFN weights onto CPU RAM instead of GPU"
  echo "   (via --override-tensor). IMPORTANT DIFFERENCE FROM --n-cpu-moe ON"
  echo "   MoE MODELS: a community guide to this technique"
  echo "   (github.com/DocShotgun's llama.cpp offload gist) explicitly"
  echo "   recommends AGAINST offloading dense FFN tensors, only MoE expert"
  echo "   tensors - on a MoE model, only a couple of experts activate per"
  echo "   token, so CPU only does a little work. Qwen3.5-9B has no experts;"
  echo "   every offloaded layer's FULL FFN matrix (4096x12288, three of"
  echo "   them) gets read from RAM on every single token, every time. Rough"
  echo "   math: at ~40 GB/s of RAM bandwidth, that's ballpark 2-3ms added"
  echo "   per offloaded layer per token - noticeable, unlike the MoE case."
  echo "   Defaulting to a light touch (2 layers) for this reason: enough to"
  echo "   free a little VRAM without a big hit, not the aggressive default"
  echo "   you might reach for on a MoE model. Raise it only if you actually"
  echo "   need the extra room and can accept slower generation; 0 disables"
  echo "   this entirely (everything on GPU, fastest, and arguably the"
  echo "   better choice for a Haiku-replacement workload where a smaller"
  echo "   quant is usually the better way to free VRAM instead)."
  ask LLAMA_CPU_FFN_LAYERS "Layers to force onto CPU (0-31, 0 to disable)"

  echo
  echo "2) Keep the ENTIRE KV cache in system RAM instead of VRAM"
  echo "   (--no-kv-offload). This decouples context length from VRAM"
  echo "   almost completely (bound by system RAM instead)."
  echo "   WARNING: every attention step now has to move cache data over"
  echo "   PCIe to system RAM and back, on every token, for the entire"
  echo "   conversation - this is a real, ongoing latency cost for the whole"
  echo "   session, not a one-time hit, and it's not yet confirmed clean on"
  echo "   every backend/model combination (some Vulkan/model pairings have"
  echo "   reported broken output with this flag). Default is 'no' for this"
  echo "   reason; only turn it on if you specifically need more context"
  echo "   than VRAM can hold and can live with slower responses."
  ask LLAMA_NO_KV_OFFLOAD "Move the whole KV cache to system RAM? (yes/no)"

  echo
  echo "Note: neither of the above feeds back into the context recommendation"
  echo "above - it was computed assuming everything stays on GPU. If you turn"
  echo "either on, check the real VRAM reading after starting the server (see"
  echo "below), then re-run this script and raise the context/quant if there's"
  echo "more room than the recommendation assumed."

  echo
  echo "Speculative decoding draft length (--spec-draft-n-max), via the"
  echo "MTP head baked into the $HF_REPO build. Community guidance is"
  echo "around 2 for dense-leaning models, higher for MoE-heavy ones."
  ask LLAMA_SPEC_DRAFT_N "Max draft tokens per step"
fi
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

save_config
echo
echo "Saved your answers to $CONF_FILE for next time."
echo

# --- Sanity check: does the container exist? ---
# Case-insensitive on purpose: container-manager GUIs (Kontainer, etc.) often
# display names title-cased even though the underlying distrobox container is
# lowercase. Match loosely, then resolve to whatever casing distrobox itself
# reports, so every later command (distrobox enter/stop) uses the real name.
# If the typed name doesn't match exactly one container (zero matches, or
# more than one - e.g. typing "box" when you have both "ollama-box" and
# "dev-box"), fall back to listing everything and letting you pick, rather
# than guessing or just failing.
DISTROBOX_LIST_RAW="$(distrobox list 2>/dev/null)"
if [ -z "$DISTROBOX_LIST_RAW" ]; then
  echo "ERROR: 'distrobox list' returned nothing - is distrobox installed, and" >&2
  echo "do you have any containers created yet?" >&2
  exit 1
fi

# distrobox list output is a table; the name is the second field, whitespace
# padded, header row first.
MATCH_COUNT="$(echo "$DISTROBOX_LIST_RAW" | tail -n +2 | grep -ic "$CONTAINER_NAME" || true)"

if [ "$MATCH_COUNT" = "1" ]; then
  RESOLVED_NAME="$(echo "$DISTROBOX_LIST_RAW" | tail -n +2 | grep -i "$CONTAINER_NAME" \
    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
  if [ "$RESOLVED_NAME" != "$CONTAINER_NAME" ]; then
    echo "Note: using '$RESOLVED_NAME' (the actual container name), not '$CONTAINER_NAME' as typed."
    CONTAINER_NAME="$RESOLVED_NAME"
    save_config
  fi
else
  if [ "$MATCH_COUNT" -gt 1 ] 2>/dev/null; then
    echo "'$CONTAINER_NAME' matches more than one container - pick the one you mean:"
  else
    echo "No distrobox container matching '$CONTAINER_NAME' was found. Here's what's actually there:"
  fi
  echo
  echo "$DISTROBOX_LIST_RAW"
  echo

  NAMES="$(echo "$DISTROBOX_LIST_RAW" | tail -n +2 | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
  if [ -z "$NAMES" ]; then
    echo "ERROR: couldn't parse any container names out of the listing above." >&2
    exit 1
  fi

  declare -a NAME_ARR=()
  PICK_NUM=1
  while IFS= read -r NAME_LINE; do
    [ -z "$NAME_LINE" ] && continue
    NAME_ARR+=("$NAME_LINE")
    echo "  $PICK_NUM) $NAME_LINE"
    PICK_NUM=$((PICK_NUM + 1))
  done <<< "$NAMES"

  read -rp "Pick a number: " PICK
  if ! [[ "$PICK" =~ ^[0-9]+$ ]] || [ "$PICK" -lt 1 ] || [ "$PICK" -gt "${#NAME_ARR[@]}" ]; then
    echo "ERROR: '$PICK' isn't a valid choice." >&2
    exit 1
  fi
  CONTAINER_NAME="${NAME_ARR[$((PICK - 1))]}"
  save_config
  echo "Using '$CONTAINER_NAME', saved as the new default for next time."
fi
log "Found container $CONTAINER_NAME"

# --- Step 1: place litellm_config.yaml, with master_key and port patched in ---
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
    sed -i \
      -e "s|^  # log_file: /var/log/litellm-proxy.log|  log_file: $PROXY_LOG_FILE|" \
      "$CONFIG_DEST"
  fi
fi
log "Wrote $CONFIG_DEST"

# --- Step 2: install both systemd unit files, patched for port/path ---
mkdir -p "$HOME/.config/systemd/user"

backup_config "$HOME/.config/systemd/user/litellm-ollama-box.service"
backup_config "$HOME/.config/systemd/user/distrobox-reminder.service"

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

# --- Step 5: verify the proxy came up ---
PROXY_UP=no
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PROXY_PORT/health" | grep -q "200"; then
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

# --- Step 6: install the toggle script, patched with port/token ---
mkdir -p "$BIN_DIR"
sed -e "s|http://localhost:4000|http://localhost:$PROXY_PORT|g" \
    -e "s|http://localhost:8080|http://localhost:$LLAMA_PORT|g" \
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

# --- Step 7: make sure llama-server exists inside the container, building it if not ---
# Ollama bundles its own runtime; llama-server has to be compiled. This is a
# one-time cost per container - once LLAMA_SERVER_BIN is cached in CONF_FILE,
# re-runs skip straight past it.
if [ -z "$LLAMA_SERVER_BIN" ]; then
  echo "Checking for an existing llama-server build inside $CONTAINER_NAME..."
  FOUND_BIN="$(distrobox enter "$CONTAINER_NAME" -- bash -lc '
    if command -v llama-server >/dev/null 2>&1; then
      command -v llama-server
    elif [ -x "$HOME/llama.cpp/build/bin/llama-server" ]; then
      echo "$HOME/llama.cpp/build/bin/llama-server"
    fi
  ' 2>/dev/null)"

  if [ -n "$FOUND_BIN" ]; then
    LLAMA_SERVER_BIN="$FOUND_BIN"
    save_config
    echo "Found existing llama-server at $LLAMA_SERVER_BIN"
  else
    echo "llama-server not found inside $CONTAINER_NAME, building it from source"
    echo "(clone + cmake + CUDA compile, takes several minutes)..."
    BUILD_LOG="$(distrobox enter "$CONTAINER_NAME" -- bash -lc '
      set -e
      # cuda-toolkit installs nvcc under /usr/local/cuda/bin, but does not add
      # it to PATH itself (that normally happens via a fresh shell login after
      # the alternatives symlink is set up) - add it here so nvcc is usable in
      # this same subshell immediately after installing below, without needing
      # a new distrobox enter.
      export PATH="/usr/local/cuda/bin:$PATH"
      command -v cmake  >/dev/null 2>&1 || sudo dnf install -y cmake
      command -v git    >/dev/null 2>&1 || sudo dnf install -y git
      command -v g++    >/dev/null 2>&1 || sudo dnf install -y gcc-c++
      if ! command -v nvcc >/dev/null 2>&1; then
        echo "nvcc not found, attempting to install the CUDA toolkit..."
        # Fedora'\''s own repos do not carry "cuda-toolkit" at all - it only exists
        # once NVIDIA'\''s own repo is added, matched to the container'\''s Fedora
        # version (confirmed empty on a stock Fedora 41 container: the plain
        # "sudo dnf install -y cuda-toolkit" 404s with "No match for argument").
        # See https://developer.download.nvidia.com/compute/cuda/repos/ for the
        # list of repo files NVIDIA publishes per distro version.
        if ! dnf list available cuda-toolkit >/dev/null 2>&1; then
          FEDORA_VER="$(. /etc/os-release && echo "$VERSION_ID")"
          REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/fedora${FEDORA_VER}/x86_64/cuda-fedora${FEDORA_VER}.repo"
          if curl -fsI "$REPO_URL" >/dev/null 2>&1; then
            echo "Adding NVIDIA'\''s CUDA repo for Fedora $FEDORA_VER ($REPO_URL)..."
            sudo dnf config-manager addrepo --from-repofile="$REPO_URL"
            sudo dnf makecache
          else
            echo "NVIDIA has no published CUDA repo for Fedora $FEDORA_VER yet" >&2
            echo "($REPO_URL 404s). Check developer.nvidia.com/cuda-downloads for" >&2
            echo "a supported release, or add a matching repo manually." >&2
          fi
        fi
        sudo dnf install -y cuda-toolkit || true
      fi
      if ! command -v nvcc >/dev/null 2>&1; then
        echo "ERROR: nvcc still not available after attempting install." >&2
        echo "Install a CUDA toolkit matching your driver manually (e.g. from" >&2
        echo "developer.nvidia.com/cuda-downloads or your distro repos), then" >&2
        echo "re-run install.sh." >&2
        exit 1
      fi

      if [ -d "$HOME/llama.cpp" ]; then
        git -C "$HOME/llama.cpp" pull
      else
        git clone https://github.com/ggml-org/llama.cpp "$HOME/llama.cpp"
      fi
      cd "$HOME/llama.cpp"
      cmake -B build -DGGML_CUDA=ON
      cmake --build build --config Release -j"$(nproc)" --target llama-server
    ' 2>&1)"
    BUILD_STATUS=$?

    if [ "$INSTALL_VERBOSE" = "yes" ]; then
      log "llama-server build output:"
      log "$BUILD_LOG"
    fi

    if [ $BUILD_STATUS -ne 0 ]; then
      echo "WARNING: llama-server build failed. Last part of the build output:" >&2
      echo "$BUILD_LOG" | tail -n 20 >&2
      echo "Fix the issue above (often a missing CUDA toolkit) and re-run install.sh." >&2
    else
      LLAMA_SERVER_BIN="$HOME/llama.cpp/build/bin/llama-server"
      # $HOME here is the host's, but distrobox mounts the host home into the
      # container at the same path, so this resolves correctly inside it too.
      save_config
      echo "Built llama-server at $LLAMA_SERVER_BIN"
    fi
  fi
else
  log "Using cached llama-server path: $LLAMA_SERVER_BIN"
fi

# --- Step 8: download the model, inside the container ---
LLAMA_MODEL_PATH=""
if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
  echo "Checking whether a *$GGUF_PATTERN*.gguf file is already downloaded inside $CONTAINER_NAME..."
  ALREADY_HAVE="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "find ~ -maxdepth 3 -iname '*$GGUF_PATTERN*.gguf' 2>/dev/null | head -n1")"

  if [ -n "$ALREADY_HAVE" ]; then
    LLAMA_MODEL_PATH="$ALREADY_HAVE"
    echo "Already have it at $LLAMA_MODEL_PATH, skipping download."
  else
    echo "Downloading a *$GGUF_PATTERN*.gguf file from $HF_REPO inside $CONTAINER_NAME, this is a multi-GB download..."
    distrobox enter "$CONTAINER_NAME" -- bash -lc "
      (python3 -m pip --version >/dev/null 2>&1 || sudo dnf install -y python3-pip) &&
      sudo python3 -m pip install -U huggingface_hub --break-system-packages -q &&
      hf download '$HF_REPO' --include '*$GGUF_PATTERN*.gguf' --local-dir ~/
    "
    if [ $? -ne 0 ]; then
      echo "WARNING: model download failed. Check the exact quant fragment on the" >&2
      echo "repo's file listing and re-run this script, or run the hf download" >&2
      echo "command manually inside the container." >&2
    else
      LLAMA_MODEL_PATH="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "find ~ -maxdepth 3 -iname '*$GGUF_PATTERN*.gguf' 2>/dev/null | head -n1")"
      log "Downloaded to $LLAMA_MODEL_PATH"
    fi
  fi
else
  # Re-runs with DOWNLOAD_MODEL_NOW=no still need a path if one was found before.
  LLAMA_MODEL_PATH="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "find ~ -maxdepth 3 -iname '*$GGUF_PATTERN*.gguf' 2>/dev/null | head -n1")"
  echo "Skipped model download. Run this script again with 'yes' when ready."
fi

# --- Step 9: generate start-local-llama.sh with all the tuning flags baked in ---
if [ -n "$LLAMA_SERVER_BIN" ] && [ -n "$LLAMA_MODEL_PATH" ]; then
  # Optional VRAM-headroom flags (see the prompts above): neither is on by
  # default, both trade some speed for more room when the quant/context
  # combination above doesn't fit.
  OT_ARGS=""
  if [ "${LLAMA_CPU_FFN_LAYERS:-0}" -gt 0 ] 2>/dev/null; then
    FIRST_OFFLOAD=$(( 32 - LLAMA_CPU_FFN_LAYERS ))
    if [ "$FIRST_OFFLOAD" -lt 0 ]; then FIRST_OFFLOAD=0; fi
    LAYER_RANGE="$(seq -s'|' "$FIRST_OFFLOAD" 31)"
    OT_ARGS=" --override-tensor \"blk\\.(${LAYER_RANGE})\\.ffn_(gate|up|down)\\.weight=CPU\""
  fi
  KVOFFLOAD_ARGS=""
  if [ "$LLAMA_NO_KV_OFFLOAD" = "yes" ]; then
    KVOFFLOAD_ARGS=" --no-kv-offload"
  fi
  EXTRA_FLAGS="$OT_ARGS$KVOFFLOAD_ARGS"

  cat > "$BIN_DIR/start-local-llama.sh" << EOF
#!/usr/bin/env bash
# start-local-llama.sh
# Generated by install.sh - re-run install.sh to change any of these flags,
# don't hand-edit (your edits won't survive the next install.sh run).
#
# -ngl 99                 offload all layers to GPU (no --n-cpu-moe: Qwen3.5-9B
#                          has no MoE layers, so that flag would be a no-op)
# -fa on                  flash attention (required for KV cache quant below)
# --cache-type-k/v q8_0   Q8 KV cache quantization, halves KV cache VRAM cost
# --spec-type draft-mtp   self-speculative decoding via the model's MTP head
# -b $LLAMA_BATCH_SIZE               batch size (llama.cpp's own default is 512)
$([ -n "$OT_ARGS" ] && echo "# --override-tensor          last $LLAMA_CPU_FFN_LAYERS layers' FFN weights forced to CPU RAM")
$([ -n "$KVOFFLOAD_ARGS" ] && echo "# --no-kv-offload            whole KV cache kept in system RAM instead of VRAM")
#
# Runs in the foreground so you can watch its own log output. Ctrl+C to stop.
exec distrobox enter "$CONTAINER_NAME" -- "$LLAMA_SERVER_BIN" \\
  -m "$LLAMA_MODEL_PATH" \\
  -ngl 99 \\
  -c $LLAMA_CTX_SIZE \\
  -b $LLAMA_BATCH_SIZE \\
  -fa on \\
  --cache-type-k q8_0 --cache-type-v q8_0 \\
  --spec-type draft-mtp --spec-draft-n-max $LLAMA_SPEC_DRAFT_N \\
  --port $LLAMA_PORT --host 127.0.0.1$EXTRA_FLAGS
EOF
  chmod +x "$BIN_DIR/start-local-llama.sh"
  log "Generated $BIN_DIR/start-local-llama.sh"

  # --- Step 9b: desktop icon that opens start-local-llama.sh in its own ---
  # --- terminal window, so starting the model is a single double-click. ---
  if [ "$INSTALL_DESKTOP_SHORTCUT" = "yes" ]; then
    cat > "$BIN_DIR/start-local-llama-desktop.sh" << EOF
#!/usr/bin/env bash
# start-local-llama-desktop.sh
# Generated by install.sh. Double-click target for the "Start Local Model"
# desktop icon: opens start-local-llama.sh in its own terminal window so you
# can watch it while you work, without typing anything by hand. Falls back
# to a copy-paste notification if no terminal emulator can be found.

if curl -s -o /dev/null "http://localhost:$LLAMA_PORT/health"; then
  notify-send "Local model" "llama-server is already running at http://localhost:$LLAMA_PORT"
  exit 0
fi

TERMINAL_CMD=""
if command -v konsole >/dev/null 2>&1; then
  TERMINAL_CMD="konsole -e"
elif command -v gnome-terminal >/dev/null 2>&1; then
  TERMINAL_CMD="gnome-terminal --"
elif command -v xterm >/dev/null 2>&1; then
  TERMINAL_CMD="xterm -e"
fi

if [ -z "\$TERMINAL_CMD" ]; then
  notify-send -u critical "Local model: no terminal emulator found" \\
    "Paste this into a terminal yourself: $BIN_DIR/start-local-llama.sh"
  exit 1
fi

\$TERMINAL_CMD bash -c "$BIN_DIR/start-local-llama.sh; echo; echo 'llama-server exited.'; read -p 'Press Enter to close this window.'" &
disown
notify-send "Local model" "Starting llama-server in a new terminal window..."
EOF
    chmod +x "$BIN_DIR/start-local-llama-desktop.sh"

    cat > "$DESKTOP_DIR/claude-local-start-model.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Start Local Model
Comment=Launch llama-server for Claude Code local mode in its own terminal window
Exec=$BIN_DIR/start-local-llama-desktop.sh
Icon=media-playback-start
Terminal=false
Categories=Utility;
EOF
    chmod +x "$DESKTOP_DIR/claude-local-start-model.desktop"
    log "Generated $BIN_DIR/start-local-llama-desktop.sh and its desktop icon"
    echo "Desktop icon 'Start Local Model' installed - double-click it to launch"
    echo "llama-server in its own terminal window (falls back to a copy-paste"
    echo "notification if no terminal emulator is found; not yet verified on"
    echo "your specific desktop session, check that it actually pops a window)."
  fi

  echo
  echo "llama-server is ready to launch, but not started automatically."
  echo "Open another terminal and run this (the wrapper script does the same thing,"
  echo "printed here in full so you don't have to go find it):"
  echo
  echo "  distrobox enter \"$CONTAINER_NAME\" -- \"$LLAMA_SERVER_BIN\" \\"
  echo "    -m \"$LLAMA_MODEL_PATH\" \\"
  echo "    -ngl 99 -c $LLAMA_CTX_SIZE -b $LLAMA_BATCH_SIZE \\"
  echo "    -fa on --cache-type-k q8_0 --cache-type-v q8_0 \\"
  echo "    --spec-type draft-mtp --spec-draft-n-max $LLAMA_SPEC_DRAFT_N \\"
  echo "    --port $LLAMA_PORT --host 127.0.0.1$EXTRA_FLAGS"
  echo
  echo "Or just: $BIN_DIR/start-local-llama.sh"
  echo "Or use the 'Start Local Model' desktop icon (if installed) to open this"
  echo "in its own terminal window automatically from now on."
  read -rp "Press Enter here once it's running (or Ctrl+C to skip this check)... " _

  if curl -s -o /dev/null "http://localhost:$LLAMA_PORT/health"; then
    echo "llama-server is up at http://localhost:$LLAMA_PORT"
    if command -v nvidia-smi >/dev/null 2>&1; then
      echo "VRAM after loading:"
      nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
    fi
  else
    echo "WARNING: llama-server did not respond at http://localhost:$LLAMA_PORT/health." >&2
    echo "Check the terminal window it's running in for the actual error." >&2
  fi
else
  echo "Skipping start-local-llama.sh generation: missing llama-server binary or model path."
  echo "Re-run install.sh once both the build and the download have succeeded."
fi

# --- Step 10: make sure litellm itself is installed inside the container ---
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
echo "  $BIN_DIR/start-local-llama.sh"
