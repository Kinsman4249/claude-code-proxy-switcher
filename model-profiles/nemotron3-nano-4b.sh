# model-profiles/nemotron3-nano-4b.sh
# Profile for NVIDIA Nemotron 3 Nano 4B (nemotron_h) - the dense (non-MoE)
# sibling of model-profiles/nemotron3-nano-30b.sh. Same Mamba-2/Attention
# hybrid family (llama.cpp calls this architecture nemotron_h, merged
# 2025-12-16 via llama.cpp PR #18058, well before the MoE variant's crash-fix
# history described in the 30B-A3B profile - the dense architecture never hit
# that bug), just without the MoE layers, so it's the much smaller/simpler of
# the two to run: every GGUF quant on unsloth's repo listing is under 6 GB,
# meaning this model fits an 8GB card whole, with room to spare, at every
# quant level offered - no CPU-offload tradeoffs needed the way the 30B-A3B
# profile or even Qwen3.5-9B/Gemma 4 sometimes need.
#
# ARCHITECTURE: 42 layers total (confirmed from
# nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16's config.json: hybrid_override_pattern
# "M-M-M-MM-M-M*-M-M*-M-M-M*-M-M-MM*-MMM-M-M-" is 42 characters - M=Mamba-2,
# *=GQA attention (6 of them, same count as the 30B-A3B model), -=dense FFN
# layer). Unlike the 30B-A3B profile, this model DOES have real dense FFN
# layers, so the --override-tensor headroom option (prompt_vram_headroom in
# install.d/20-prompts-model.sh) is meaningful here if ever needed - but
# given the file sizes below, it's unlikely to be.

PROFILE_NAME="Nemotron 3 Nano 4B"
HF_REPO_DEFAULT="unsloth/NVIDIA-Nemotron-3-Nano-4B-GGUF"

# No separate drafter/MTP file found in unsloth's repo listing for this
# model - speculative decoding isn't wired up for this profile.
DRAFT_REPO=""
DRAFT_PATTERN=""
SPEC_MODE="none"                                # none | self-mtp | draft-model

N_LAYERS=42

# Same hybrid-attention reasoning as Gemma 4 and the 30B-A3B Nemotron
# profile - no simple closed-form bytes/token for this mix of Mamba-2 and
# attention layers. Probe a live server instead.
KV_MODEL="probe"                                # manual | probe
BYTES_PER_TOKEN=                                # unused when KV_MODEL=probe

# CONFIRMED 2026-07-25 on a live RTX 3080 8GB (8192 MiB) card: this model's
# own gguf metadata max context is 262144, but DON'T assume that's a safe
# default the way Gemma 4 E4B's own max turned out to be (see
# model-profiles/gemma4-e4b.sh) - it isn't. Learned the hard way: an explicit
# `-c 262144` OOM'd immediately (compute-buffer allocation failure), because
# --fit only auto-sizes an argument that's left COMPLETELY UNSET - the same
# "n_gpu_layers already set by user ... abort" mechanism documented in
# model-profiles/nemotron3-nano-30b.sh's NGL_MODE comment turns out to apply
# to `-c`/n_ctx too (confirmed by reading llama.cpp's common/fit.cpp: an
# explicit n_ctx hits its own "context size set by user ... -> no change"
# early-return, separate from but structurally identical to the n_gpu_layers
# guard). Passing a "ceiling" value doesn't work the way this project's own
# prompt text (prompt_vram_and_context in install.d/20-prompts-model.sh)
# describes for probe-model profiles - an explicit -c is always a fixed
# value, never a ceiling --fit is free to shrink below.
#
# The value below was determined the correct way for a probe/fit profile:
# started llama-server with BOTH -ngl and -c left unset (--fit on) against
# this profile's largest quant (UD-Q8_K_XL, the tightest fit of the three
# tested), read the real n_ctx_slot it picked from the server's own startup
# log, then re-confirmed that exact number reproduces identically with
# explicit -ngl 99 -c 92416 --fit off (same VRAM, same behavior - fit's
# choice wasn't a fluke of that one run).
RECOMMENDED_CTX_8GB=92416

# Not a Per-Layer-Embeddings model - nothing to offload here.
PLE_TENSOR_REGEX=""

# Same reasoning as the 30B-A3B profile: nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16
# shares the same Nemotron post-training recipe, so its generation_config.json
# and unsloth's GGUF-repo params file carry the same effectively-disabled
# defaults (temperature 1.0, top_p 1.0, top_k off). --top-k 0 is
# llama-server's own spelling of "disabled" (its help text: "0 = disabled").
DEFAULT_TEMP="1.0"
DEFAULT_TOP_P="1.0"
DEFAULT_TOP_K="0"

# Sizes confirmed from unsloth/NVIDIA-Nemotron-3-Nano-4B-GGUF's own file
# listing (bytes -> MiB, rounded up). Every quant here is small enough that
# picking the biggest one that still leaves headroom for a large context is
# a reasonable default, unlike the 30B-A3B model where quant barely affects
# download size at all.
#
# QUANT COMPARISON, same RTX 3080 8GB card, 2026-07-25, same session so
# directly comparable: all three tested at the RECOMMENDED_CTX_8GB value
# above (92416), -b 512, q8_0 KV cache, --fit off (explicit -ngl 99 -c
# 92416), real completions confirmed working (not just a health check) via
# a direct /completion request to each, nvidia-smi read immediately after
# each load:
#   Q4_K_M     (2766 MiB file): 4383 MiB VRAM - 3809 MiB headroom
#   UD-Q6_K_XL (4348 MiB file): 5817 MiB VRAM - 2375 MiB headroom
#   UD-Q8_K_XL (5365 MiB file): 6467 MiB VRAM - 1725 MiB headroom
# All three comfortably fit at this context; UD-Q8_K_XL has the least
# headroom of the three, which is why it was the one used to determine
# RECOMMENDED_CTX_8GB above (the tightest-fitting case). Q5_K_M/Q6_K/Q8_0/
# UD-Q4_K_XL weren't live-tested but sit between these measured points by
# file size, so expect proportionally similar VRAM (see model-profiles/
# gemma4-e4b.sh's quant-comparison note for why that extrapolation is
# reasonable at fixed context/flags - llama.cpp loads quantized weights
# straight into VRAM without dequantizing, so VRAM cost tracks file size
# plus a roughly-constant KV-cache/compute-buffer overhead).
QUANT_MENU=(
  "Q4_K_M|2766|confirmed from the repo's file listing"
  "UD-Q4_K_XL|2988|Unsloth dynamic quant, better quality at similar size"
  "Q5_K_M|3013|confirmed from the repo's file listing"
  "Q6_K|3868|confirmed from the repo's file listing, best quality/size tradeoff"
  "Q8_0|4038|confirmed from the repo's file listing"
  "UD-Q8_K_XL|5365|Unsloth dynamic quant, largest offered - still under 6 GB"
)
QUANT_MENU_INTRO="Nemotron 3 Nano 4B from \$HF_REPO. Every quant here comfortably
fits an 8GB card - pick based on quality, not VRAM pressure."

# Printed inside the generated start-local-llama.sh header, next to -ngl 99.
# Kept to one line here - the generator wraps it to fit the comment column.
ARCH_NOTES="--n-cpu-moe not applicable: this is the dense nemotron_h variant (no MoE layers) - see model-profiles/nemotron3-nano-30b.sh for the MoE sibling"
