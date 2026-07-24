# 60-llama-server-build.sh
# Sourced by install.sh. Step 8: makes sure llama-server exists inside the
# container, building it from source (clone + cmake + CUDA compile) if it
# doesn't. Sets LLAMA_SERVER_BIN as a side effect, cached in CONF_FILE so
# re-runs skip straight past this.

# --- Step 8: make sure llama-server exists inside the container, building it if not ---
# Ollama bundles its own runtime; llama-server has to be compiled. This is a
# one-time cost per container - once LLAMA_SERVER_BIN is cached in CONF_FILE,
# re-runs skip straight past it.
ensure_llama_server_binary() {
  if [ -z "$LLAMA_SERVER_BIN" ]; then
    echo "Checking for an existing llama-server build inside $CONTAINER_NAME..."
    local FOUND_BIN
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
      local BUILD_LOG BUILD_STATUS
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
}
