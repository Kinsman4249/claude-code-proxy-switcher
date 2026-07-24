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
#
# This file only wires the steps together. The steps themselves - one
# function each - live in install.d/*.sh, numbered in the order they run:
#   00  config defaults + log/backup_config/save_config/ask helpers
#   10  general prompts (container/proxy basics, port/logging/desktop tail)
#   20  model-profile and model-sizing prompts
#   30  distrobox container name resolution
#   40  litellm_config.yaml + systemd units + proxy verification (steps 1-6)
#   50  claude-local-toggle.sh + its desktop icon (step 7/7b)
#   60  llama-server build-from-source (step 8)
#   70  main + drafter model download (step 9/9c)
#   80  start-local-llama.sh generation, launch, smoke test (step 10)
#   90  final "what to do next" summary
# All of them run in the same shell (sourced, not executed), so plain bash
# globals are how state - config answers, resolved paths - passes between
# them, same as when this was one file.

set -uo pipefail   # not -e: a failed step should be reported, not kill
                    # the whole interactive script mid-way

CONF_FILE="$HOME/.config/claude-local-setup.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_D="$SCRIPT_DIR/install.d"

mkdir -p "$(dirname "$CONF_FILE")"
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

for step_file in "$INSTALL_D"/*.sh; do
  # shellcheck source=/dev/null
  source "$step_file"
done

main() {
  echo "== Claude Code local-model setup =="
  echo "Answers from previous runs are shown as defaults, press Enter to keep them."
  echo

  prompt_general_settings
  prompt_model_profile
  prompt_model_download_settings
  prompt_misc_settings

  save_config
  echo
  echo "Saved your answers to $CONF_FILE for next time."
  echo

  resolve_container_name

  install_litellm_config
  install_litellm_in_container
  install_systemd_units
  enable_services
  setup_linger
  verify_proxy

  install_toggle_script
  install_desktop_shortcut

  ensure_llama_server_binary

  download_main_model
  download_drafter_model

  run_launcher_step

  print_summary
}

main
