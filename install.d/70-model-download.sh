# 70-model-download.sh
# Sourced by install.sh. Step 9/9c: downloads the main model (and, for
# profiles that use a separate drafter for speculative decoding, the
# drafter model too) into the container. Sets MODEL_DIR, LLAMA_MODEL_PATH,
# and LLAMA_DRAFT_PATH as side effects - 80-launcher.sh reads all three.

# --- Step 9: download the model, inside the container ---
# Each profile gets its own directory (~/models/$MODEL_PROFILE/) rather than
# a shared search across the whole home directory - with more than one model
# family downloaded, a bare "find ~" glob can match the wrong family's file,
# or pick up a drafter/mmproj file that happens to share the quant fragment.
# The main-model search also excludes drafter ("mtp-*"/"*assistant*") and
# multimodal-projector ("mmproj-*") files explicitly, since those are real
# GGUF files that would otherwise satisfy the same *.gguf glob.
download_main_model() {
  MODEL_DIR="\$HOME/models/$MODEL_PROFILE"
  MAIN_MODEL_FIND="find '$MODEL_DIR' -maxdepth 1 -iname '*$GGUF_PATTERN*.gguf' \
    -not -iname 'mtp-*' -not -iname '*assistant*' -not -iname 'mmproj-*' 2>/dev/null"

  LLAMA_MODEL_PATH=""
  if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
    echo "Checking whether a *$GGUF_PATTERN*.gguf file is already downloaded inside $CONTAINER_NAME..."
    local MATCHES MATCH_COUNT_MODEL
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
}

# --- Step 9c: download the drafter model, if this profile uses one ---
# Only SPEC_MODE=draft-model needs a separate file (Qwen's self-mtp mode
# uses the MTP head already baked into the main GGUF above). If the profile
# hasn't got a confirmed drafter repo/pattern yet (both empty - true for
# both Gemma profiles as shipped, see model-profiles/gemma4-e*b.sh), this
# is skipped entirely and the generation step below omits --spec-type
# rather than emit it without a resolvable -md path.
download_drafter_model() {
  LLAMA_DRAFT_PATH=""
  if [ "$SPEC_MODE" = "draft-model" ]; then
    if [ -n "${DRAFT_REPO:-}" ] && [ -n "${DRAFT_PATTERN:-}" ]; then
      local DRAFT_FIND EXISTING_DRAFT
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
}
