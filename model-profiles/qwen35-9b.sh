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

# SPEED SWEEP, CONFIRMED 2026-07-25, RTX 3080 8GB, UD-Q4_K_XL, -c 131072:
# the 24-CPU-FFN-layer config above (needed to fit 131072 ctx with the
# q8_0/q8_0 KV cache default) was the slowest config this project could
# produce for this model. bench/qwen-bench.sh swept KV cache quant type,
# then binary-searched the minimum CPU-resident FFN layer count for the
# type that won - full methodology and raw numbers in bench/qwen-results.md.
#
# KV cache type mattered far more than expected: q8_0/q5_1, q8_0/q4_0, and
# q5_1/q5_1 all loaded fine and passed the smoke test, but a REAL ~36K-token
# /completion on any of them fell onto a catastrophically slow path (30+
# minutes for a request that normally takes under a minute - confirmed via
# even a short cache-hit follow-up alone taking 100+ seconds instead of
# ~600ms). Only q8_0/q8_0 (this project's old default) and q4_0/q4_0 stayed
# fast. Root cause not fully confirmed by reading llama.cpp source, but the
# pattern (symmetric q8_0 or q4_0 fine, q5_1 or any K!=V mismatch collapses)
# matches this project's llama.cpp build having GGML_CUDA_FA_ALL_QUANTS=OFF -
# plausibly no fused flash-attention CUDA kernel for those combos on this
# build, forcing a much slower fallback. Worth retrying if a future rebuild
# turns that flag on (see bench/qwen-results.md's notes).
#
# q4_0/q4_0 uses ~1GB less VRAM than q8_0/q8_0 at the same layer count with
# no quality difference (still 3/3 sentinels + correct generated code, both
# at ~36.5K AND ~99870-token depth) - that freed GB directly funds fewer
# CPU-resident FFN layers, which is where the actual speedup comes from.
# Bisecting on the freed VRAM (not on raw decode speed at a fixed layer
# count, which barely differs between KV types since CPU-offloaded layers
# dominate either way) found override-tensor N=11 is enough, not N=24.
#
# Measured at ~99870 tokens (99.9% of the way to -c 131072, most
# representative depth), q4_0/q4_0 + N=11 vs the old q8_0/q8_0 + N=24:
#   prefill: 1019.2 -> 1233.5 tok/s   (+21.0%)
#   decode:   24.57 ->  39.26 tok/s   (+59.8%)
#   VRAM:      7668 ->    7799 MiB    (still fits, ~393 MiB headroom)
# Thread count (-t 6/8/16 vs unset) made no measurable difference once
# CPU-resident layers dropped to 11 - within run-to-run noise (see
# bench/qwen-results.md's thread-sweep rows), so -t is intentionally still
# not passed anywhere in this project.
# Read by install.d/20-prompts-model.sh: pre-fills the interactive
# "layers to force onto CPU" prompt with this tested value instead of the
# generic light-touch default of 2, and requires an explicit "yes" to type
# in something different (see ask_confirm_override() in
# install.d/00-config.sh). A deliberate override from a previous run of
# THIS profile is still respected on reruns - only switching profiles or a
# first-ever install resets to this value.
LLAMA_CPU_FFN_LAYERS_RECOMMENDED=11

# KV cache quant type - not asked interactively (see the comment next to
# CACHE_TYPE_K/V in install.d/80-launcher.sh: the space of viable combos on
# this project's llama.cpp build turned out to be a landmine, not something
# to ask a user blind - see the SPEED SWEEP comment above for what broke).
CACHE_TYPE_K="q4_0"
CACHE_TYPE_V="q4_0"

# Not a Per-Layer-Embeddings model - nothing to offload here.
PLE_TENSOR_REGEX=""

# CONFIRMED 2026-07-25, live RTX 3080 8GB, UD-Q4_K_XL, real /v1/chat/completions
# path (not the raw /completion endpoint used by the earlier long-context
# probe above): this project's prior claim that "Qwen already defaults to
# reasoning off, nothing to toggle" was WRONG for the real chat-template
# path - a plain request with zero flags sent came back with reasoning_content
# populated (13.5s, 277 completion tokens, for a tool call a forced-off run
# does in ~1.7s/50 tokens). Same failure class this project already found
# and fixed for Nemotron 3 Nano 30B-A3B (see nemotron3-nano-30b.sh and
# README.md's "Thinking mode" section) - just not confirmed here until now.
#
# Qwen/Qwen3.5-9B's own model card and Unsloth's docs give conflicting
# recipes for how this project actually runs the model (thinking forced
# off, tool-calling/agentic use) - the card has no "tool calling" bucket,
# only general/reasoning/precise-coding, and even its own "reasoning"
# bucket is internally inconsistent (see
# https://huggingface.co/Qwen/Qwen3.5-9B/discussions/51). Tested both
# candidates head-to-head with a live grep+read_file tool-call prompt
# against this profile's running server, 5 reps each, --chat-template-kwargs
# '{"enable_thinking":false}' held constant, max_tokens 500:
#   Qwen card "Non-Thinking/Instruct, General" (temp .7/top_p .8/top_k 20):
#     5/5 correct tool calls, but 3/5 runs also leaked stray prose alongside
#     the tool call; avg 64.8 completion tokens, avg 2.90s.
#   Unsloth's own doc example (temp .6/top_p .95/top_k 20, run alongside
#     enable_thinking:false in their command despite being the card's
#     "Thinking/Precise-coding" numbers): 5/5 correct tool calls, 0/5 leaked
#     prose, avg 49.6 completion tokens, avg 1.72s.
# Unsloth's recipe won on every axis (fewer tokens, faster, cleaner output)
# so it's what's set below, not the Qwen card's own "matching" bucket.
DEFAULT_TEMP="0.6"
DEFAULT_TOP_P="0.95"
DEFAULT_TOP_K="20"

# CONFIRMED 2026-07-25 (see DEFAULT_TEMP comment above): forcing this
# explicitly is a real ~8x speed/token win for tool calls, not a formality -
# add it. Matches the other three profiles' pattern (gemma4-e4b.sh,
# nemotron3-nano-4b.sh, nemotron3-nano-30b.sh all set this).
THINKING_KWARG_KEY="enable_thinking"

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
