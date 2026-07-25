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

# UNVERIFIED: no live 8GB-card measurement yet (see model-profiles/
# nemotron3-nano-30b.sh for the same caveat, and the same "no invented
# facts" reasoning). Given every quant here is well under 6 GB, this model
# is expected to comfortably fit at a very large context ceiling on an 8GB
# card - but "expected" isn't "confirmed", so this is left blank rather than
# guessing a number.
RECOMMENDED_CTX_8GB=

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
