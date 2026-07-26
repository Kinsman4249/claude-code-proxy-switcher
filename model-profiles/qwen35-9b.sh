# model-profiles/qwen35-9b.sh
# Profile for Qwen3.5-9B-MTP. Sourced by install.sh after MODEL_PROFILE is
# chosen. Every value here was previously hardcoded directly in install.sh;
# this is the "default" profile and the regression gate for the profile
# refactor (see README.md "Manual verification").

PROFILE_NAME="Qwen3.5-9B-MTP"
HF_REPO_DEFAULT="unsloth/Qwen3.5-9B-MTP-GGUF"   # MTP build: needed for --spec-type draft-mtp

# No separate drafter model: the MTP head is baked into the main GGUF above.
DRAFT_REPO=""
DRAFT_PATTERN=""
SPEC_MODE="self-mtp"                            # none | self-mtp | draft-model

N_LAYERS=32

# KV cache sizing: Qwen3.5-9B's hybrid dense/linear-attention math is fully
# worked out (see the comment in install.sh's context-sizing step), so this
# profile supplies the constant directly rather than probing a live server.
KV_MODEL="manual"                               # manual | probe
BYTES_PER_TOKEN=16384

# CONFIRMED 2026-07-25, RTX 3080 8GB, unsloth/Qwen3.5-9B-MTP-GGUF Q4_K_M:
# a real long-context needle-retrieval + code-generation test (haystack of
# real llama.cpp source, three sentinel functions buried at ~10/50/90% depth,
# asked to find all three and write a small Python function using them) came
# back 3/3 correct with valid generated code at every context size tried:
# ~14K tokens (Q5_K_M), ~36K (UD-Q4_K_XL), ~50K (Q4_K_M, GPU-only, default
# --override-tensor N=2), and ~105K (Q4_K_M, -c 131072, GPU-only headroom
# exhausted so this one needed --override-tensor raised to N=24 - 24 of 32
# dense FFN layers moved to CPU RAM - not the light default; a real -c 131072
# /completion request at that override-tensor setting used 7819/8192 MiB and
# completed the 105306-token prompt + generation in 107s). No accuracy drop
# observed at any size tested, but this is one repeated needle+codegen probe,
# not a coding benchmark suite (no LiveCodeBench/Tau2 numbers exist for this
# profile - see README.md's model-comparison table).
#
# Bottom line: Q4_K_M's *natural* (default N=2 offload) ceiling on this card
# is close to Q4_K_M's ~64-76K formula estimate in install.d/20-prompts-model.sh,
# not 128K - reaching a full 131072 (Claude Haiku-matching) context on 8GB
# requires deliberately raising --override-tensor well past the light
# default, trading some generation speed for the extra KV cache room. Kept
# at 131072 anyway, same rationale as nemotron3-nano-4b.sh's
# RECOMMENDED_CTX_8GB: it matches Claude Haiku's ~128K context, a goal
# unrelated to whether it fits with zero tradeoffs - raising override-tensor
# to get there is a deliberate call for whoever installs this, not a silent
# default.
RECOMMENDED_CTX_8GB=131072

# Not a Per-Layer-Embeddings model - nothing to offload here.
PLE_TENSOR_REGEX=""

# Empty = let llama-server / the client use its own defaults (this project's
# prior behaviour: no --temp/--top-p/--top-k were ever passed for Qwen).
DEFAULT_TEMP=""
DEFAULT_TOP_P=""
DEFAULT_TOP_K=""

# "fragment|size_mib|description" - fragment matches the GGUF filename,
# size_mib feeds the context-length estimate, description is shown in the
# picker (blank is fine).
QUANT_MENU=(
  "Q4_K_M|5816|most VRAM headroom for a bigger context"
  "UD-Q4_K_XL|6113|Unsloth dynamic quant, better quality at similar size"
  "Q5_K_S|6513|"
  "Q5_K_M|6739|floor recommended for coding/tool-calling precision"
  "UD-Q5_K_XL|6902|previous default, best quality that still leaves headroom"
  "Q6_K|7639|best quality, very little room left for context"
)
QUANT_MENU_INTRO="All are Qwen3.5-9B-MTP from \$HF_REPO
(the MTP build is required for self-speculative decoding via --spec-type draft-mtp).
Larger = better quality, more VRAM. Sizes below are as reported by the repo
(effectively GiB, i.e. already *1024 to MiB in the math further down)."

# Printed inside the generated start-local-llama.sh header, next to -ngl 99.
# Kept to one line here - the generator wraps it to fit the comment column.
ARCH_NOTES="no --n-cpu-moe: Qwen3.5-9B has no MoE layers (confirmed from its config.json: no num_experts field, mlp_only_layers is empty, dense intermediate_size throughout), so that flag would be a no-op"
