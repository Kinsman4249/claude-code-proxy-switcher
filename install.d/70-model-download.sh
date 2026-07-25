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
      local MAIN_DOWNLOAD_CMD="hf download '$HF_REPO' --include '*$GGUF_PATTERN*.gguf' --exclude 'mmproj-*' --local-dir '$MODEL_DIR'"
      local attempt=1
      while :; do
        echo "Downloading a *$GGUF_PATTERN*.gguf file from $HF_REPO inside $CONTAINER_NAME, this is a multi-GB download (attempt $attempt)..."
        distrobox enter "$CONTAINER_NAME" -- bash -lc "
          mkdir -p '$MODEL_DIR' &&
          (python3 -m pip --version >/dev/null 2>&1 || sudo dnf install -y python3-pip) &&
          sudo python3 -m pip install -U huggingface_hub --break-system-packages -q &&
          $MAIN_DOWNLOAD_CMD
        "
        local download_rc=$?
        LLAMA_MODEL_PATH="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "$MAIN_MODEL_FIND" | head -n1)"
        if [ -n "$LLAMA_MODEL_PATH" ]; then
          log "Downloaded to $LLAMA_MODEL_PATH"
          break
        fi
        # Either hf download itself failed (download_rc != 0), or it exited 0
        # but no matching *.gguf turned up - e.g. a resumed/interrupted
        # transfer that left only a .incomplete file behind. Same recovery
        # either way: offer a retry (hf download resumes partial transfers by
        # default) before giving up and handing back the exact command to run
        # by hand, rather than silently letting this surface later as
        # 80-launcher.sh's generic "missing model path" skip message, which
        # wouldn't point back at this download step at all.
        if [ "$download_rc" -ne 0 ]; then
          echo "WARNING: model download failed (exit $download_rc)." >&2
        else
          echo "WARNING: hf download reported success, but no *$GGUF_PATTERN*.gguf" >&2
          echo "file was found in $MODEL_DIR afterward - the transfer likely got" >&2
          echo "interrupted partway. Check for a *.incomplete file inside" >&2
          echo "$MODEL_DIR (distrobox enter \"$CONTAINER_NAME\" -- find '$MODEL_DIR' -name '*.incomplete')." >&2
        fi
        local RETRY_DOWNLOAD="yes"
        ask RETRY_DOWNLOAD "Retry the download? (yes/no)"
        if [ "$RETRY_DOWNLOAD" != "yes" ]; then
          echo "Giving up on the main model download. Check the exact quant fragment" >&2
          echo "on the repo's file listing, then run this yourself inside the container:" >&2
          echo "  distrobox enter \"$CONTAINER_NAME\" -- bash -lc \"$MAIN_DOWNLOAD_CMD\"" >&2
          echo "Re-run install.sh once that file exists in $MODEL_DIR." >&2
          break
        fi
        attempt=$((attempt + 1))
      done
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
          # --exclude 'MTP/*': unsloth's Gemma 4 repos duplicate the top-level
          # drafter file inside an MTP/ subfolder (BF16/F16/Q8_0 variants) -
          # without this, the glob below matches those too and downloads an
          # extra ~340 MiB that never gets used (maxdepth 1 finds only the
          # top-level file when picking LLAMA_DRAFT_PATH below).
          local DRAFT_DOWNLOAD_CMD="hf download '$DRAFT_REPO' --include '*$DRAFT_PATTERN*.gguf' --exclude 'MTP/*' --local-dir '$MODEL_DIR'"
          local draft_attempt=1
          while :; do
            echo "Downloading a *$DRAFT_PATTERN*.gguf drafter from $DRAFT_REPO (attempt $draft_attempt)..."
            distrobox enter "$CONTAINER_NAME" -- bash -lc "$DRAFT_DOWNLOAD_CMD"
            local draft_rc=$?
            LLAMA_DRAFT_PATH="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "$DRAFT_FIND" | head -n1)"
            if [ -n "$LLAMA_DRAFT_PATH" ]; then
              log "Downloaded drafter to $LLAMA_DRAFT_PATH"
              break
            fi
            # Same failure mode as the main-model download above: a report of
            # success with no matching file usually means an interrupted
            # transfer left only a .incomplete file behind - but this is also
            # the path that silently ate the whole download once already (see
            # handoff.md 2026-07-24: file never appeared, no .incomplete
            # either, root cause not pinned down), so don't just warn and move
            # on - offer a retry before falling back to a manual command.
            if [ "$draft_rc" -ne 0 ]; then
              echo "WARNING: drafter download failed (exit $draft_rc)." >&2
            else
              echo "WARNING: hf download reported success, but no *$DRAFT_PATTERN*.gguf" >&2
              echo "drafter file was found in $MODEL_DIR afterward - the transfer likely" >&2
              echo "got interrupted partway. Check for a *.incomplete file inside" >&2
              echo "$MODEL_DIR (distrobox enter \"$CONTAINER_NAME\" -- find '$MODEL_DIR' -name '*.incomplete')." >&2
            fi
            local RETRY_DRAFT="yes"
            ask RETRY_DRAFT "Retry the drafter download? (yes/no)"
            if [ "$RETRY_DRAFT" != "yes" ]; then
              echo "Giving up on the drafter download. Check the exact filename fragment" >&2
              echo "on the repo's file listing, then run this yourself inside the container:" >&2
              echo "  distrobox enter \"$CONTAINER_NAME\" -- bash -lc \"$DRAFT_DOWNLOAD_CMD\"" >&2
              echo "Re-run install.sh once that file exists in $MODEL_DIR, or start" >&2
              echo "llama-server without it (slower, no speculative decoding)." >&2
              break
            fi
            draft_attempt=$((draft_attempt + 1))
          done
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
