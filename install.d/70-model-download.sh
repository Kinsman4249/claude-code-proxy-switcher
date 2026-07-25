# 70-model-download.sh
# Sourced by install.sh. Step 9/9c: downloads the main model (and, for
# profiles that use a separate drafter for speculative decoding, the
# drafter model too) into the container. Sets MODEL_DIR, LLAMA_MODEL_PATH,
# and LLAMA_DRAFT_PATH as side effects - 80-launcher.sh reads all three.

# --- Hugging Face authentication: optional but strongly recommended ---
# Anonymous (unauthenticated) requests share a much lower rate limit than
# authenticated ones. This isn't theoretical - confirmed firsthand while
# testing the Nemotron 3 Nano profiles below: an 18GB anonymous download's
# transfer concurrency got throttled down to a crawl (effectively stalled
# for minutes at a time) after sustained use in one session, and picked
# back up immediately once the container was authenticated. A free,
# read-only token avoids that entirely.
#
# This function never sees or stores the token itself - it always delegates
# to `hf auth login`'s own interactive flow, which prompts for the token
# with input hidden (not echoed to the terminal or shell history) and
# writes it to a permission-restricted file (chmod 600) inside the
# container - the same official mechanism the `hf` CLI itself always uses.
# Deliberately NOT added to save_config()/$CONF_FILE: that file is plaintext
# with no permission restriction (see PROXY_MASTER_KEY in
# install.d/00-config.sh for an existing example of what it already stores
# in the clear) - a token deserves better than that, so this project never
# lets it touch that file, or any bash variable of ours, at all.
ensure_hf_auth() {
  # A completely fresh container may not have the `hf` CLI yet - the
  # regular download path below only installs it once a download actually
  # starts, but this function can run before that, so it needs its own
  # install-if-missing check rather than assuming `hf` is already on PATH.
  distrobox enter "$CONTAINER_NAME" -- bash -lc '
    command -v hf >/dev/null 2>&1 || {
      python3 -m pip --version >/dev/null 2>&1 || sudo dnf install -y python3-pip
      sudo python3 -m pip install -U huggingface_hub --break-system-packages -q
    }
  '

  local HF_WHOAMI
  HF_WHOAMI="$(distrobox enter "$CONTAINER_NAME" -- bash -lc 'hf auth whoami 2>/dev/null')"
  if [ -n "$HF_WHOAMI" ]; then
    log "Already authenticated to Hugging Face inside $CONTAINER_NAME ($HF_WHOAMI)"
    return
  fi

  echo
  echo "Hugging Face downloads work fine without an account, but anonymous"
  echo "requests share a much lower rate limit - on a large model this can mean"
  echo "a download's transfer speed gets throttled down until it looks stalled"
  echo "for minutes at a time. A free, read-only access token removes that limit."
  echo
  echo "Generate one (the 'read' role is enough, no need for 'write') at:"
  echo "  https://huggingface.co/settings/tokens"
  local SETUP_HF_AUTH="yes"
  ask SETUP_HF_AUTH "Set up Hugging Face authentication now? (yes/no)"
  if [ "$SETUP_HF_AUTH" != "yes" ]; then
    echo "Skipping - downloads will use the slower anonymous rate limit."
    return
  fi

  echo "Paste your token at the prompt below (input is hidden). This runs hf's"
  echo "own login flow directly inside the container - this script never sees"
  echo "or stores the token itself."
  distrobox enter "$CONTAINER_NAME" -- hf auth login
}

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
    ensure_hf_auth
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
