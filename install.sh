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
# Model-specific facts (layer counts, MoE-or-not, KV-cache sizing behaviour,
# speculative-decoding wiring) live in model-profiles/*.sh, one file per
# supported model, loaded based on the MODEL_PROFILE prompt below. See that
# directory for the per-model architecture notes this comment used to carry
# directly (it only ever described Qwen3.5-9B, back when that was the only
# model this script supported).

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

# --- Model profile: which model-profiles/*.sh fragment to load ---
# This changes every model-specific default below it (repo, quant sizes,
# layer count, KV sizing behaviour, spec-decoding wiring), so it's asked
# before any of those questions.
PROFILE_DIR="$SCRIPT_DIR/model-profiles"
AVAILABLE_PROFILES="$(cd "$PROFILE_DIR" && ls -1 ./*.sh 2>/dev/null | sed -e 's|^\./||' -e 's|\.sh$||')"
echo
echo "Which model profile? Available: $(echo "$AVAILABLE_PROFILES" | tr '\n' ' ')"
ask MODEL_PROFILE "Model profile name"

PROFILE_FILE="$PROFILE_DIR/$MODEL_PROFILE.sh"
if [ ! -f "$PROFILE_FILE" ]; then
  echo "ERROR: no model-profiles/$MODEL_PROFILE.sh found. Available profiles:" >&2
  echo "$AVAILABLE_PROFILES" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$PROFILE_FILE"
log "Loaded model profile: $PROFILE_NAME ($PROFILE_FILE)"

# Switching profiles from a previous run makes the old run's saved
# HF_REPO/GGUF_PATTERN/QUANT_WEIGHT_MIB/QUANT_CHOICE stale (they belonged to
# a different model) - reset them to this profile's defaults. Re-running the
# same profile leaves them alone, which is what keeps re-runs idempotent.
if [ "$MODEL_PROFILE" != "$LAST_MODEL_PROFILE" ]; then
  HF_REPO="$HF_REPO_DEFAULT"
  GGUF_PATTERN=""
  QUANT_WEIGHT_MIB=""
  QUANT_CHOICE=""
  LAST_MODEL_PROFILE="$MODEL_PROFILE"
fi
[ -z "$HF_REPO" ] && HF_REPO="$HF_REPO_DEFAULT"

ask DOWNLOAD_MODEL_NOW "Download the local model now? (yes/no, big download if not already cached)"
if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
  echo
  echo "Which quantization? $(eval "echo \"$QUANT_MENU_INTRO\"")"
  PICK_NUM=1
  for ENTRY in "${QUANT_MENU[@]}"; do
    IFS='|' read -r FRAG SIZE_MIB DESC <<< "$ENTRY"
    if [ -n "$SIZE_MIB" ]; then
      SIZE_GB="$(awk -v m="$SIZE_MIB" 'BEGIN { printf "%.2f", m/1024 }')"
      SIZE_TXT="${SIZE_GB} GB"
    else
      SIZE_TXT="size UNVERIFIED"
    fi
    if [ -n "$DESC" ]; then
      printf "  %d) %-12s %-14s (%s)\n" "$PICK_NUM" "$FRAG" "$SIZE_TXT" "$DESC"
    else
      printf "  %d) %-12s %s\n" "$PICK_NUM" "$FRAG" "$SIZE_TXT"
    fi
    PICK_NUM=$((PICK_NUM + 1))
  done
  CUSTOM_CHOICE="$PICK_NUM"
  echo "  $CUSTOM_CHOICE) custom      (type your own quant fragment, e.g. 'IQ4_XS')"
  ask QUANT_CHOICE "Pick a number"
  # QUANT_WEIGHT_MIB feeds the context-length recommendation below.
  if [ -z "$QUANT_CHOICE" ]; then
    :  # empty input keeps whatever GGUF_PATTERN/QUANT_WEIGHT_MIB already was (saved default)
  elif [ "$QUANT_CHOICE" = "$CUSTOM_CHOICE" ]; then
    ask GGUF_PATTERN "Exact quant fragment (check the repo's file listing if unsure)"
    ask QUANT_WEIGHT_MIB "Approximate file size of that quant, in MiB (check the repo's file listing; leave blank to skip the context recommendation below)"
  elif [ "$QUANT_CHOICE" -ge 1 ] 2>/dev/null && [ "$QUANT_CHOICE" -le "${#QUANT_MENU[@]}" ] 2>/dev/null; then
    IFS='|' read -r GGUF_PATTERN QUANT_WEIGHT_MIB _ <<< "${QUANT_MENU[$((QUANT_CHOICE - 1))]}"
  else
    echo "Didn't recognize that, keeping $GGUF_PATTERN"
  fi
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
  # KV_MODEL=manual (Qwen only): the bytes/token formula is fully worked out
  # from the model's published config, so compute a recommendation directly.
  # KV_MODEL=probe (Gemma): Gemma 4's hybrid local/global attention with
  # unified K/V on global layers has no simple closed-form bytes/token - see
  # model-profiles/gemma4-e*b.sh. Don't hand-roll a formula for it. Instead
  # let llama.cpp fit the context itself (--fit on, set below in Step 10)
  # and read the measured number back from the log after first start.
  if [ "$KV_MODEL" = "manual" ]; then
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
    # (BYTES_PER_TOKEN itself comes from the profile - see model-profiles/
    # qwen35-9b.sh - this comment documents where that number came from.)

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
  else
    echo
    echo "This profile's KV cache sizing is measured, not estimated (Gemma 4's"
    echo "hybrid attention has no simple closed-form bytes/token - see"
    echo "model-profiles/$MODEL_PROFILE.sh). llama.cpp will size the context"
    echo "itself (--fit on) the first time the server starts, up to the ceiling"
    echo "you give it below; the REAL number it lands on gets read back from"
    echo "$HOME/.local/state/llama-server.log and printed after that first"
    echo "start, not estimated ahead of time."
    echo
    echo "Context window ceiling (-c / --ctx-size). Larger lets Claude Code's"
    echo "full prompt fit without truncation, but --fit on will refuse to"
    echo "exceed available VRAM, so this is a cap, not a guarantee."
    ask LLAMA_CTX_SIZE "Context length ceiling in tokens"
  fi

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
  ask LLAMA_CPU_FFN_LAYERS "Layers to force onto CPU (0-$((N_LAYERS - 1)), 0 to disable)"

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

  if [ -n "${PLE_TENSOR_REGEX:-}" ]; then
    echo
    echo "3) Keep Per-Layer Embedding (PLE) tables in system RAM instead of VRAM"
    echo "   (--override-tensor on the PLE tensors specifically). This is the"
    echo "   OPPOSITE tradeoff from option 1 above, not the same trick again:"
    echo "   PLE tables are pure per-token lookups, no matrix multiply, so"
    echo "   moving them to system RAM costs one small host-memory read per"
    echo "   token instead of a full GEMM's worth of PCIe/RAM bandwidth. That"
    echo "   makes this a large-VRAM-for-little-speed trade, unlike the dense"
    echo "   FFN offload above, which this project deliberately defaults light"
    echo "   on for the opposite reason. Defaulting to 'yes' for this profile."
    ask KEEP_PLE_ON_CPU "Keep Per-Layer Embedding tables in system RAM? (yes/no)"
  else
    KEEP_PLE_ON_CPU="no"
  fi

  echo
  echo "Note: none of the VRAM-headroom options above feed back into the"
  echo "context recommendation above - it was computed assuming everything"
  echo "stays on GPU. If you turn any on, check the real VRAM reading after"
  echo "starting the server (see below), then re-run this script and raise"
  echo "the context/quant if there's more room than the recommendation assumed."

  if [ "$SPEC_MODE" = "self-mtp" ]; then
    echo
    echo "Speculative decoding draft length (--spec-draft-n-max), via the"
    echo "MTP head baked into the $HF_REPO build. Community guidance is"
    echo "around 2 for dense-leaning models, higher for MoE-heavy ones."
    ask LLAMA_SPEC_DRAFT_N "Max draft tokens per step"
  elif [ "$SPEC_MODE" = "draft-model" ]; then
    echo
    echo "Speculative decoding draft length (--spec-draft-n-max), via a"
    echo "separate drafter model (not baked into the main GGUF for this"
    echo "profile - the drafter is downloaded separately below, and this"
    echo "flag only takes effect if that download resolves to a file)."
    ask LLAMA_SPEC_DRAFT_N "Max draft tokens per step"
  fi
  # SPEC_MODE=none: no draft-length prompt, no spec flags emitted below.
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

# --- Step 2: make sure litellm itself is installed inside the container ---
# Must happen before Step 4 enables/starts the systemd service below: on a
# fresh container (or a broken old setup where this got skipped somehow),
# starting the service before litellm exists just crash-loops it.
distrobox enter "$CONTAINER_NAME" -- bash -lc "
  python3 -c 'import litellm' 2>/dev/null || {
    python3 -m pip --version >/dev/null 2>&1 || sudo dnf install -y python3-pip
    sudo python3 -m pip install 'litellm[proxy]' --break-system-packages -q
  }
"
log "Confirmed litellm is installed inside $CONTAINER_NAME"

# --- Step 3: install both systemd unit files, patched for port/path ---
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

# --- Step 4: enable both services ---
# litellm-ollama-box.service: "enable --now" only starts it if it wasn't
# already running - on a re-install over a broken old setup (stale config,
# old ExecStop, whatever) the whole point is to force the fixed unit file
# and config to actually take effect, so explicitly restart it too. This is
# safe: ExecStop only kills the litellm process now, not the container, so
# it will never take llama-server down with it.
systemctl --user enable --now litellm-ollama-box.service
systemctl --user restart litellm-ollama-box.service
systemctl --user enable --now distrobox-reminder.service
log "Enabled litellm-ollama-box.service (restarted to apply any config/unit changes) and distrobox-reminder.service"

# --- Step 5: lingering, if requested ---
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

# --- Step 6: verify the proxy came up ---
# Auth header is required here: LiteLLM's own auth-failure error path throws
# an unrelated ModuleNotFoundError (missing optional 'prisma' package, not
# installed and not needed for this master-key-only setup) instead of a
# clean 401 when a request arrives with no token, so an unauthenticated
# health check gets a misleading 500 instead of a straight pass/fail.
PROXY_UP=no
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

# --- Step 7: install the toggle script, patched with port/token ---
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

# --- Step 7b: desktop shortcut, if requested ---
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

# --- Step 8: make sure llama-server exists inside the container, building it if not ---
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

# --- Step 9: download the model, inside the container ---
# Each profile gets its own directory (~/models/$MODEL_PROFILE/) rather than
# a shared search across the whole home directory - with more than one model
# family downloaded, a bare "find ~" glob can match the wrong family's file,
# or pick up a drafter/mmproj file that happens to share the quant fragment.
# The main-model search also excludes drafter ("mtp-*"/"*assistant*") and
# multimodal-projector ("mmproj-*") files explicitly, since those are real
# GGUF files that would otherwise satisfy the same *.gguf glob.
MODEL_DIR="\$HOME/models/$MODEL_PROFILE"
MAIN_MODEL_FIND="find '$MODEL_DIR' -maxdepth 1 -iname '*$GGUF_PATTERN*.gguf' \
  -not -iname 'mtp-*' -not -iname '*assistant*' -not -iname 'mmproj-*' 2>/dev/null"

LLAMA_MODEL_PATH=""
if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
  echo "Checking whether a *$GGUF_PATTERN*.gguf file is already downloaded inside $CONTAINER_NAME..."
  MATCHES="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "mkdir -p '$MODEL_DIR'; $MAIN_MODEL_FIND")"
  MATCH_COUNT_MODEL="$(echo "$MATCHES" | grep -c . || true)"

  if [ "$MATCH_COUNT_MODEL" = "1" ]; then
    LLAMA_MODEL_PATH="$MATCHES"
    echo "Already have it at $LLAMA_MODEL_PATH, skipping download."
  elif [ "$MATCH_COUNT_MODEL" -gt 1 ] 2>/dev/null; then
    echo "More than one matching GGUF already in $MODEL_DIR - pick the one to use:"
    echo "$MATCHES"
    read -rp "Paste the full path to use: " LLAMA_MODEL_PATH
  else
    echo "Downloading a *$GGUF_PATTERN*.gguf file from $HF_REPO inside $CONTAINER_NAME, this is a multi-GB download..."
    distrobox enter "$CONTAINER_NAME" -- bash -lc "
      mkdir -p '$MODEL_DIR' &&
      (python3 -m pip --version >/dev/null 2>&1 || sudo dnf install -y python3-pip) &&
      sudo python3 -m pip install -U huggingface_hub --break-system-packages -q &&
      hf download '$HF_REPO' --include '*$GGUF_PATTERN*.gguf' --exclude 'mmproj-*' --local-dir '$MODEL_DIR'
    "
    if [ $? -ne 0 ]; then
      echo "WARNING: model download failed. Check the exact quant fragment on the" >&2
      echo "repo's file listing and re-run this script, or run the hf download" >&2
      echo "command manually inside the container." >&2
    else
      LLAMA_MODEL_PATH="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "$MAIN_MODEL_FIND" | head -n1)"
      log "Downloaded to $LLAMA_MODEL_PATH"
    fi
  fi
else
  # Re-runs with DOWNLOAD_MODEL_NOW=no still need a path if one was found before.
  LLAMA_MODEL_PATH="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "$MAIN_MODEL_FIND" | head -n1)"
  echo "Skipped model download. Run this script again with 'yes' when ready."
fi

# --- Step 9c: download the drafter model, if this profile uses one ---
# Only SPEC_MODE=draft-model needs a separate file (Qwen's self-mtp mode
# uses the MTP head already baked into the main GGUF above). If the profile
# hasn't got a confirmed drafter repo/pattern yet (both empty - true for
# both Gemma profiles as shipped, see model-profiles/gemma4-e*b.sh), this
# is skipped entirely and the generation step below omits --spec-type
# rather than emit it without a resolvable -md path.
LLAMA_DRAFT_PATH=""
if [ "$SPEC_MODE" = "draft-model" ]; then
  if [ -n "${DRAFT_REPO:-}" ] && [ -n "${DRAFT_PATTERN:-}" ]; then
    DRAFT_FIND="find '$MODEL_DIR' -maxdepth 1 -iname '*$DRAFT_PATTERN*.gguf' 2>/dev/null"
    if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
      EXISTING_DRAFT="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "$DRAFT_FIND" | head -n1)"
      if [ -n "$EXISTING_DRAFT" ]; then
        LLAMA_DRAFT_PATH="$EXISTING_DRAFT"
        echo "Already have the drafter model at $LLAMA_DRAFT_PATH, skipping download."
      else
        echo "Downloading a *$DRAFT_PATTERN*.gguf drafter from $DRAFT_REPO..."
        distrobox enter "$CONTAINER_NAME" -- bash -lc "
          hf download '$DRAFT_REPO' --include '*$DRAFT_PATTERN*.gguf' --local-dir '$MODEL_DIR'
        "
        LLAMA_DRAFT_PATH="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "$DRAFT_FIND" | head -n1)"
      fi
    else
      LLAMA_DRAFT_PATH="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "$DRAFT_FIND" | head -n1)"
    fi
  fi
  if [ -z "$LLAMA_DRAFT_PATH" ]; then
    echo "WARNING: this profile uses a separate drafter model for speculative" >&2
    echo "decoding, but none is configured/resolved (DRAFT_REPO/DRAFT_PATTERN" >&2
    echo "empty, or the download/search above found nothing). Starting without" >&2
    echo "speculative decoding - slower, but correct, rather than guessing a" >&2
    echo "drafter file. Fill in DRAFT_REPO/DRAFT_PATTERN in $PROFILE_FILE once" >&2
    echo "you've confirmed the real filenames, then re-run install.sh." >&2
  fi
fi

# --- Step 10: generate start-local-llama.sh with all the tuning flags baked in ---
if [ -n "$LLAMA_SERVER_BIN" ] && [ -n "$LLAMA_MODEL_PATH" ]; then
  # Optional VRAM-headroom flags (see the prompts above): neither is on by
  # default, both trade some speed for more room when the quant/context
  # combination above doesn't fit.
  OT_ARGS=""
  if [ "${LLAMA_CPU_FFN_LAYERS:-0}" -gt 0 ] 2>/dev/null; then
    FIRST_OFFLOAD=$(( N_LAYERS - LLAMA_CPU_FFN_LAYERS ))
    if [ "$FIRST_OFFLOAD" -lt 0 ]; then FIRST_OFFLOAD=0; fi
    LAYER_RANGE="$(seq -s'|' "$FIRST_OFFLOAD" "$((N_LAYERS - 1))")"
    OT_ARGS=" --override-tensor \"blk\\.(${LAYER_RANGE})\\.ffn_(gate|up|down)\\.weight=CPU\""
  fi
  KVOFFLOAD_ARGS=""
  if [ "$LLAMA_NO_KV_OFFLOAD" = "yes" ]; then
    KVOFFLOAD_ARGS=" --no-kv-offload"
  fi
  # Kept separate from OT_ARGS on purpose (see the prompt above): this is the
  # opposite tradeoff from the dense-FFN offload, not the same knob again.
  PLE_OFFLOAD_ARGS=""
  if [ -n "${PLE_TENSOR_REGEX:-}" ] && [ "$KEEP_PLE_ON_CPU" = "yes" ]; then
    PLE_OFFLOAD_ARGS=" --override-tensor \"${PLE_TENSOR_REGEX}=CPU\""
  fi
  EXTRA_FLAGS="$OT_ARGS$KVOFFLOAD_ARGS$PLE_OFFLOAD_ARGS"

  # Sampling defaults from the model profile, set on the server so they
  # apply regardless of what the client sends. Empty in a profile (Qwen)
  # means "don't override the server/client default" - no flags emitted.
  SAMPLING_ARGS=""
  [ -n "${DEFAULT_TEMP:-}" ]  && SAMPLING_ARGS="$SAMPLING_ARGS --temp $DEFAULT_TEMP"
  [ -n "${DEFAULT_TOP_P:-}" ] && SAMPLING_ARGS="$SAMPLING_ARGS --top-p $DEFAULT_TOP_P"
  [ -n "${DEFAULT_TOP_K:-}" ] && SAMPLING_ARGS="$SAMPLING_ARGS --top-k $DEFAULT_TOP_K"

  # ARCH_NOTES comes from the model profile (model-profiles/*.sh) as one long
  # line; wrap it here to match the comment column the rest of this header
  # uses, first line after "offload all layers to GPU (", continuation lines
  # under it, closing paren appended to the last line.
  ARCH_NOTES_WRAPPED="$(echo "${ARCH_NOTES})" | fold -s -w 51 | sed '2,$s/^/#                          /')"

  # Speculative-decoding flags depend on the profile's SPEC_MODE. Never emit
  # --spec-type draft-mtp without a resolved -md for draft-model profiles -
  # if LLAMA_DRAFT_PATH didn't resolve (Step 9c warned about this already),
  # fall back to no speculative decoding at all rather than a broken flag.
  SPEC_ARGS=""
  case "$SPEC_MODE" in
    self-mtp)
      SPEC_ARGS=" --spec-type draft-mtp --spec-draft-n-max $LLAMA_SPEC_DRAFT_N"
      SPEC_COMMENT="# --spec-type draft-mtp   self-speculative decoding via the model's MTP head"
      ;;
    draft-model)
      if [ -n "$LLAMA_DRAFT_PATH" ]; then
        SPEC_ARGS=" -md \"$LLAMA_DRAFT_PATH\" --spec-type draft-mtp --spec-draft-n-max $LLAMA_SPEC_DRAFT_N -ngld 0"
        SPEC_COMMENT="# -md / --spec-type       speculative decoding via a separate drafter model
#                          (-ngld 0 keeps the drafter on CPU rather than
#                          eating into the main model's VRAM budget - see
#                          gemma4-support-spec.md section 4)"
      else
        SPEC_COMMENT="# (speculative decoding skipped: no drafter model resolved for this profile)"
      fi
      ;;
    *)
      SPEC_COMMENT="# (no speculative decoding for this profile)"
      ;;
  esac

  # --fit off (manual KV sizing, Qwen): the context/VRAM budget above was
  # computed by hand, and --fit on would fight that manual -ngl/--override-
  # tensor budget - see the discussion linked below.
  # --fit on (probe KV sizing, Gemma): no hand-rolled budget exists for this
  # profile, so let llama.cpp size the context itself, up to the ceiling
  # you gave it, and read back what it actually picked (see Step 11 below).
  if [ "$KV_MODEL" = "manual" ]; then
    FIT_FLAG="--fit off"
    FIT_COMMENT="# --fit off               disable llama.cpp's automatic VRAM-fitting pass: it
#                          can't override the manual -ngl/--override-tensor
#                          budget below, so left on it only produces a
#                          harmless but alarming-looking \"common_fit_params:
#                          ... abort\" warning on every startup (see
#                          https://github.com/ggml-org/llama.cpp/discussions/18049)"
  else
    FIT_FLAG="--fit on"
    FIT_COMMENT="# --fit on                let llama.cpp size the KV cache itself, up to -c
#                          below as a ceiling - this profile has no manual
#                          KV-sizing formula (see model-profiles/$MODEL_PROFILE.sh)"
  fi

  cat > "$BIN_DIR/start-local-llama.sh" << EOF
#!/usr/bin/env bash
# start-local-llama.sh
# Generated by install.sh - re-run install.sh to change any of these flags,
# don't hand-edit (your edits won't survive the next install.sh run).
#
# -ngl 99                 offload all layers to GPU ($ARCH_NOTES_WRAPPED
# -fa on                  flash attention (required for KV cache quant below)
# --cache-type-k/v q8_0   Q8 KV cache quantization, halves KV cache VRAM cost
$SPEC_COMMENT
$FIT_COMMENT
# --no-webui              disable llama.cpp's built-in browser chat UI - you
#                          only talk to this server through Claude Code /
#                          the API, never a browser, so there's no reason to
#                          serve it (doesn't touch VRAM either way, it's just
#                          static asset serving on the same HTTP listener)
# (sliding-window attention: llama.cpp only allocates the local-attention
#  window's worth of KV cache by default, not the full context, on models
#  that use it - this is the default and stays on; --swa-full is never
#  passed here, which would disable that saving)
# -b $LLAMA_BATCH_SIZE               batch size (llama.cpp's own default is 512)
$([ -n "$OT_ARGS" ] && echo "# --override-tensor          last $LLAMA_CPU_FFN_LAYERS layers' FFN weights forced to CPU RAM")
$([ -n "$KVOFFLOAD_ARGS" ] && echo "# --no-kv-offload            whole KV cache kept in system RAM instead of VRAM")
$([ -n "$PLE_OFFLOAD_ARGS" ] && echo "# --override-tensor          Per-Layer Embedding tables kept in system RAM (lookup-only, cheap to offload)")
$([ -n "$SAMPLING_ARGS" ] && echo "# --temp/--top-p/--top-k     sampling defaults from the $PROFILE_NAME model card")
# LOG_FILE            every run's output also goes here (overwritten each
#                      start, not appended) so a crash is diagnosable even if
#                      it happened in a terminal window that already closed.
#
# Runs in the foreground so you can watch its own log output. Ctrl+C to stop.
LOG_FILE="\$HOME/.local/state/llama-server.log"
mkdir -p "\$(dirname "\$LOG_FILE")"

if curl -s -o /dev/null "http://127.0.0.1:$LLAMA_PORT/health"; then
  echo "llama-server is already running at http://127.0.0.1:$LLAMA_PORT - not starting a second one."
  echo "(If you meant to restart it, stop the running one first: Ctrl+C in its terminal, or"
  echo "pkill -f llama-server inside the $CONTAINER_NAME container.)"
  exit 0
fi

distrobox enter "$CONTAINER_NAME" -- "$LLAMA_SERVER_BIN" \\
  -m "$LLAMA_MODEL_PATH" \\
  -ngl 99 \\
  -c $LLAMA_CTX_SIZE \\
  -b $LLAMA_BATCH_SIZE \\
  -fa on \\
  --cache-type-k q8_0 --cache-type-v q8_0 \\
$([ -n "$SPEC_ARGS" ] && echo " $SPEC_ARGS \\")
  $FIT_FLAG \\
  --no-webui \\
$([ -n "$SAMPLING_ARGS" ] && echo " $SAMPLING_ARGS \\")
  --port $LLAMA_PORT --host 127.0.0.1$EXTRA_FLAGS \\
  2>&1 | tee "\$LOG_FILE"
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
  [ -n "$SPEC_ARGS" ] && echo "   $SPEC_ARGS \\"
  echo "    $FIT_FLAG \\"
  echo "    --no-webui \\"
  [ -n "$SAMPLING_ARGS" ] && echo "   $SAMPLING_ARGS \\"
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

    if [ "$KV_MODEL" = "probe" ]; then
      echo
      echo "KV_MODEL=probe for this profile: the real context size llama.cpp"
      echo "fit (--fit on) should be in its own log. Grepping for it now - this"
      echo "pattern (n_ctx) is a best-effort guess at llama.cpp's log format,"
      echo "NOT confirmed against a real run (see gemma4-support-spec.md"
      echo "section 5); if nothing useful prints below, check"
      echo "$HOME/.local/state/llama-server.log yourself for the actual figure."
      grep -i "n_ctx" "$HOME/.local/state/llama-server.log" 2>/dev/null || \
        echo "  (no n_ctx line found - check the log file directly)"
    fi

    # --- Smoke test: a real completion through the PROXY, using the exact
    # model string Claude Code sends (see litellm_config.yaml), not just a
    # /health 200. /health only proves the process is listening; it does not
    # prove the model routing is correct or that a request actually returns
    # text - both of which have separately broken silently in the past.
    echo
    echo "Smoke-testing a real completion through the proxy (this is what Claude Code will see)..."
    SMOKE_RESPONSE="$(curl -s -X POST "http://localhost:$PROXY_PORT/v1/chat/completions" \
      -H "Authorization: Bearer $PROXY_MASTER_KEY" \
      -H "Content-Type: application/json" \
      -d '{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"reply with the word: ok"}],"max_tokens":10}')"
    SMOKE_CONTENT="$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    msg = data['choices'][0]['message']
    print((msg.get('content') or msg.get('reasoning_content') or '').strip())
except Exception:
    sys.exit(1)
" "$SMOKE_RESPONSE" 2>/dev/null)"
    if [ -n "$SMOKE_CONTENT" ]; then
      echo "Smoke test OK - proxy returned real model output: \"$SMOKE_CONTENT\""
    else
      echo "WARNING: smoke test through the proxy did not return usable content." >&2
      echo "Raw response: $SMOKE_RESPONSE" >&2
      echo "Claude Code will likely hang or error in local mode until this is fixed." >&2
      echo "Check: journalctl --user -u litellm-ollama-box.service -n 50" >&2
    fi
  else
    echo "WARNING: llama-server did not respond at http://localhost:$LLAMA_PORT/health." >&2
    echo "Check the terminal window it's running in for the actual error." >&2
  fi
else
  echo "Skipping start-local-llama.sh generation: missing llama-server binary or model path."
  echo "Re-run install.sh once both the build and the download have succeeded."
fi

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
