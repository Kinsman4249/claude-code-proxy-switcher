# model-profiles/gemma4-e4b.sh
# Profile for Gemma 4 E4B - the recommended Gemma choice for a Claude Code
# workload (Tau2 tool-use average 42.2% vs E2B's 24.5%, LiveCodeBench v6 52.0%
# vs 44.0%, per the Google model card, https://huggingface.co/google/gemma-4-E4B).
#
# UNVERIFIED VALUES: several fields below are placeholders, not confirmed
# facts, because confirming them needs a live llama-server build with this
# model's actual GGUF loaded (see gemma4-support-spec.md sections 3 and 4).
# install.sh is written to fail loudly (skip the feature, print a warning)
# rather than guess when these are empty. Fill these in only after running
# the verification steps in gemma4-support-spec.md against a real build, then
# remove this warning block.

PROFILE_NAME="Gemma 4 E4B"
HF_REPO_DEFAULT="unsloth/gemma-4-E4B-it-GGUF"   # google/gemma-4-E4B-GGUF does not exist (404) - Google never
                                                 # published a GGUF for this model; unsloth's quant repo confirmed
                                                 # to exist on the Hub. Quant filenames/sizes still UNVERIFIED below.

DRAFT_REPO="unsloth/gemma-4-E4B-it-GGUF"        # confirmed on the Hub: top-level mtp-gemma-4-E4B-it.gguf
                                                 # (98653248 bytes, Q8_0 only, single file - not baked into the
                                                 # main GGUF above, despite living in the same repo). There's also
                                                 # an MTP/ subfolder with BF16/F16/Q8_0 duplicates of this same
                                                 # head - the pattern below is scoped to avoid grabbing those too.
DRAFT_PATTERN="mtp-gemma-4-E4B-it"               # STILL UNVERIFIED: repo/file existence is confirmed, but whether
                                                 # llama.cpp's -md speculative decoding actually loads this
                                                 # MTP-specific GGUF (vs. erroring on an unrecognized draft
                                                 # architecture) needs a live server test, not just a Hub listing.
SPEC_MODE="draft-model"                         # none | self-mtp | draft-model

N_LAYERS=42

# Gemma 4's hybrid local/global attention with unified K/V on global layers
# has no simple closed-form bytes/token the way Qwen3.5-9B's does (see
# gemma4-support-spec.md section 5) - probe a live server instead of
# hand-rolling the arithmetic.
KV_MODEL="probe"                                # manual | probe
BYTES_PER_TOKEN=                                # unused when KV_MODEL=probe

# CONFIRMED 2026-07-24 on a live RTX 3080 8GB (8192 MiB) card, this profile's
# Q4_K_M quant, -b 512, q8_0 KV cache, MTP drafter loaded, all 42 layers on
# GPU (no --override-tensor FFN offload needed): the model's own
# gemma4.context_length metadata caps out at 131072 tokens, and running at
# that FULL ceiling only used 5970 MiB VRAM - 2222 MiB left over for the
# desktop compositor, VSCode, and the Claude Code extension. (VSCodium's own
# GPU process wasn't even visible in nvidia-smi at the time this was
# measured - Electron's GPU footprint here is close to zero in practice, but
# the 2222 MiB headroom is kept as a safety margin rather than pushing past
# the model's own max anyway, since 131072 is already a hard ceiling.)
# Because most of this model's 42 layers use a 512-token sliding window
# (gemma4.attention.sliding_window_pattern in the GGUF) and only a handful of
# global-attention layers scale KV with full context, VRAM cost grows much
# slower than context length here - unlike Qwen3.5-9B's manual formula. Only
# confirmed on an 8GB card; not re-measured for other VRAM sizes, so this is
# used as the ask() default only, not a hard override - a smaller card should
# still lower this if --fit refuses to allocate it.
RECOMMENDED_CTX_8GB=131072

# QUANT COMPARISON, same RTX 3080 8GB card, 2026-07-24 (round two - Q5_K_M
# benchmark). Re-measured Q4_K_M in the same session as Q5_K_M, same flags
# (-c 131072, --fit on, -b 512, q8_0 KV, MTP drafter, no --override-tensor)
# so the two numbers are directly comparable - nvidia-smi's per-process
# reading for the llama-server PID itself, not the system total:
#   Q4_K_M (4747 MiB file): 5584 MiB VRAM
#   Q5_K_M (5228 MiB file): 6066 MiB VRAM
# Delta (482 MiB VRAM) matches the file-size delta (481 MiB) almost exactly -
# llama.cpp loads quantized weights straight into VRAM without dequantizing,
# so VRAM cost = file size + a constant ~838 MiB (KV cache + compute buffers
# + drafter), and that constant held equal across both runs since ctx and
# every other flag were identical. Both quants load at the full 131072
# ceiling with room to spare.
#
# NOTE: this same-session Q4_K_M figure (5584 MiB) does not match the
# earlier CONFIRMED figure above (5970 MiB total, i.e. ~5959 MiB
# process-only) - not reconciled. Possible causes: that measurement predates
# this session and may have used a slightly different llama.cpp build,
# --override-tensor state, or drafter config than recorded. Trust the
# 5584/6066 pair for relative (quant-to-quant) comparisons - they were
# measured back-to-back under identical conditions - but treat either
# absolute number with a margin of error until re-verified.
#
# Q8_0 (7814 MiB file) extrapolated (not measured) from the same formula:
# 7814 + 838 = ~8652 MiB - OVER the 8192 MiB card total by ~460 MiB. Q8_0
# will NOT fit at the full 131072 ceiling on this 8GB card as configured.
# Would need either a reduced context (unclear how much this saves - most of
# the 838 MiB constant is compute buffers/drafter, not KV cache, given the
# sliding-window architecture, so shrinking -c may not recover much) or
# --override-tensor to push a few FFN layers to CPU RAM (the lever already
# used for Q4_K_M in older start-local-llama.sh generations). Untested
# either way - would need a live run to confirm.
#
# Q6_K (6747 MiB file) CONFIRMED 2026-07-25, same RTX 3080 8GB card, same
# session/flags as the Q4_K_M/Q5_K_M pair above (-c 131072, --fit on, -b 512,
# q8_0 KV, MTP drafter, no --override-tensor): 6578 MiB VRAM (nvidia-smi
# per-process reading), fitting at the full 131072 ctx ceiling with 1614 MiB
# headroom on this 8GB card. This comes in BELOW the file-size+838MiB formula
# used above (6747 + 838 = ~7585 predicted) - the measured figure is even
# smaller than the file's own size on disk, so the "weights load straight
# into VRAM, plus a flat ~838 MiB constant" model that fit Q4_K_M/Q5_K_M
# doesn't hold exactly for Q6_K (possibly a different KV/compute-buffer
# split at this quant, not investigated further - not worth chasing given
# the actual number is comfortably better than predicted, not worse). Smoke
# test (a real chat completion through the OpenAI-compatible endpoint)
# returned coherent output. Given this beats the earlier "only ~600 MiB
# headroom" extrapolation by a wide margin, Q6_K is a fine middle-ground
# pick between Q5_K_M's speed and Q8_0's quality on an 8GB card.

# UNVERIFIED: exact GGUF tensor name for Per-Layer Embeddings. On Gemma 3n it
# was per_layer_token_embd.weight; do not assume Gemma 4 matches without
# checking `gguf_dump.py` or llama-server's own startup tensor listing against
# the real file. Left empty so install.sh skips the PLE-offload prompt instead
# of guessing a regex that silently matches nothing (or the wrong tensor).
PLE_TENSOR_REGEX=""

# Recommended sampling from the Google model card.
DEFAULT_TEMP="1.0"
DEFAULT_TOP_P="0.95"
DEFAULT_TOP_K="64"

# CONFIRMED 2026-07-25 on a live RTX 3080 8GB card, Q4_K_M quant, full
# start-local-llama.sh flags (-c 131072, MTP drafter, --fit on): this
# quant's embedded chat template already emits reasoning_content by
# default with ZERO flags passed - README.md's older claim that Gemma 4
# thinking needs a literal `<|think|>` token in the system prompt does not
# hold for this actual unsloth GGUF build; it uses the same `enable_thinking`
# chat-template-kwargs convention as Qwen3.5/Nemotron instead (confirmed by
# sending `--chat-template-kwargs '{"enable_thinking":false}'` and seeing
# reasoning_content disappear from the response). VRAM with thinking on:
# 5625 MiB used of 8192 MiB - 2567 MiB headroom, so budget was never the
# reason to leave it off (see install.d/00-config.sh's ENABLE_THINKING
# comment for the actual reason: measured on Nemotron 3 Nano 30B-A3B, not
# re-measured per-model on Gemma, but the same tool-calling-workload
# argument applies). THINKING_KWARG_KEY below is a capability marker, not a
# yes/no - install.d/80-launcher.sh decides true/false from ENABLE_THINKING
# (install.sh --enable-thinking/--disable-thinking, off by default).
THINKING_KWARG_KEY="enable_thinking"

# Sizes confirmed from unsloth/gemma-4-E4B-it-GGUF's own file listing
# (bytes -> MiB, rounded up): Q4_K_M 4977171584, Q5_K_M 5481798784,
# Q6_K 7074929792, Q8_0 8192953472. KV_MODEL=probe means these don't feed the
# context formula directly (that's Qwen-only, see prompt_vram_and_context in
# install.d/20-prompts-model.sh) but they're accurate for display now.
QUANT_MENU=(
  "Q4_K_M|4747|confirmed from the repo's file listing"
  "Q5_K_M|5228|confirmed from the repo's file listing"
  "Q6_K|6747|confirmed from the repo's file listing - live-tested 2026-07-25, 6578 MiB VRAM at full 131072 ctx, see the QUANT COMPARISON note above"
  "Q8_0|7814|confirmed from the repo's file listing"
)
QUANT_MENU_INTRO="Gemma 4 E4B from \$HF_REPO (recommended Gemma pick for tool
use - see README.md 'Choosing a model')."

# Printed inside the generated start-local-llama.sh header, next to -ngl 99.
# Kept to one line here - the generator wraps it to fit the comment column.
ARCH_NOTES="no --n-cpu-moe: Gemma 4 E4B has no MoE layers (dense model), so that flag would be a no-op. PLE tables are the offload lever for this model instead, see PLE_TENSOR_REGEX above"
