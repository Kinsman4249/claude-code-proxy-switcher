# model-profiles/qwen35-9b-defiant-fable.sh
# Profile for DavidAU's "Qwen3.5-9B-The-Defiant-Fable-Uncensored-Heretic-NEO-
# IMATRIX-MAX-MTP" - an uncensored/de-refusal fine-tune of the same base
# architecture as model-profiles/qwen35-9b.sh (Qwen3.5-9B, 32 layers, hybrid
# dense/linear attention). Everything architecture-derived (N_LAYERS,
# BYTES_PER_TOKEN, the q4_0/q4_0 KV-cache-collapse finding, SPEC_MODE) is
# carried over unchanged from that profile - the fine-tune only changes the
# weights, not the architecture the KV/layer math depends on. Anything
# weight-size-derived (LLAMA_CPU_FFN_LAYERS_RECOMMENDED, QUANT_MENU) does NOT
# carry over: this repo's MTP quants run noticeably larger than the Unsloth
# MTP build qwen35-9b.sh was tuned against (see the comment above
# LLAMA_CPU_FFN_LAYERS_RECOMMENDED below), which is exactly the "needs
# heavier CPU offload than default" a user picking this profile was told to
# expect.

PROFILE_NAME="Qwen3.5-9B-Defiant-Fable-Uncensored-Heretic-MTP"
HF_REPO_DEFAULT="DavidAU/Qwen3.5-9B-The-Defiant-Fable-Uncensored-Heretic-NEO-IMATRIX-MAX-MTP-GGUF"

# No separate drafter model: same as qwen35-9b.sh, the MTP head is baked
# into the main GGUF above (this repo ships both a "-MTP-" suffixed self-
# speculative build and a plain non-MTP build per quant; QUANT_MENU below
# only lists the "-MTP-" ones, see its own comment).
DRAFT_REPO=""
DRAFT_PATTERN=""
SPEC_MODE="self-mtp"

# Same Qwen3.5-9B base architecture as qwen35-9b.sh (32 layers, hybrid
# Gated-DeltaNet/Gated-Attention, unchanged by this fine-tune) - see that
# profile's own N_LAYERS/KV_MODEL/BYTES_PER_TOKEN comments for the full
# derivation. Fine-tuning changes weights, not layer count or attention
# shape, so this number is not re-derived here.
N_LAYERS=32
KV_MODEL="manual"
BYTES_PER_TOKEN=16384

# Same 131072 rationale as qwen35-9b.sh's RECOMMENDED_CTX_8GB comment
# (matches Claude Haiku's ~128K context) - not re-justified here, see that
# profile. Requested explicitly for this profile too.
RECOMMENDED_CTX_8GB=131072

# ESTIMATE, NOT CONFIRMED - no live GPU benchmark exists for this specific
# checkpoint (unlike every other number in this project's model-profiles/,
# which are all measured on a real RTX 3080 8GB run, see qwen35-9b.sh's
# CONFIRMED comments for what that measurement process looks like). Treat
# this as a starting point to verify, not a tested value, and re-run this
# project's bench/qwen-bench.sh-style binary search (or just watch `nvidia-
# smi` while start-local-llama.sh loads and lower the number if it loads
# with headroom to spare) before trusting it for anything beyond "does it
# load without OOM."
#
# Derivation: this repo's MTP Q4_K_M is 6979975392 bytes (6656.6 MiB) vs the
# Unsloth MTP build's Q4_K_M qwen35-9b.sh was tuned against (5816 MiB) -
# ~840 MiB (+14.4%) bigger, plausibly from this repo's own README noting the
# output tensor is kept at full 16-bit precision and MTP tensors at Q8_0 for
# every quant (both add fixed overhead a same-named Unsloth quant doesn't
# carry). qwen35-9b.sh's own history already anchors two data points on the
# SAME llama.cpp build/GPU: N=11 was the tuned minimum for the 5816 MiB
# Unsloth Q4_K_M at 131072 ctx / q4_0 KV (~86-393 MiB headroom, i.e. already
# tight - see qwen35-9b.sh's SPEED SWEEP comment), while N=24 was that same
# profile's original, untuned, confirmed-fitting figure from before the
# q4_0/q4_0 optimization (used with the slower q8_0/q8_0 KV cache, more
# VRAM-hungry than q4_0/q4_0, and still fit). Extrapolating per-layer FFN
# offload savings (~80-85 MiB/layer for this architecture's dense FFN,
# intermediate_size 12288) against the extra ~840 MiB this checkpoint's
# Q4_K_M carries suggests roughly 13 more offloaded layers than qwen35-9b.sh's
# tuned N=11 (11 + ~13 = ~24) - which happens to land back on that same
# already-confirmed-fitting N=24 figure, so it's used here as a safe
# starting point rather than a freshly-derived number that's never been
# tested at any offload level on this checkpoint. Expect slower generation
# than qwen35-9b.sh's tuned N=11 until this is actually re-benchmarked and
# (if VRAM allows) lowered.
LLAMA_CPU_FFN_LAYERS_RECOMMENDED=24

# Same q4_0/q4_0 rationale as qwen35-9b.sh (same llama.cpp build, same
# GGML_CUDA_FA_ALL_QUANTS=OFF finding - a mismatched or non-q4_0/q8_0 K/V
# pair silently falls onto a catastrophically slow non-fused CUDA path on
# this project's build, independent of which checkpoint's weights are
# loaded). Not re-tested on this checkpoint specifically, but the collapse
# is a llama.cpp-build/kernel property, not a model-weights property, so
# there's no reason to expect it differs here.
CACHE_TYPE_K="q4_0"
CACHE_TYPE_V="q4_0"

# Not a Per-Layer-Embeddings model - nothing to offload here (same as
# qwen35-9b.sh).
PLE_TENSOR_REGEX=""

# Carried over unverified from qwen35-9b.sh's own live-tested tool-calling
# sampling comparison (Unsloth's non-thinking recipe beat the Qwen model
# card's own "matching" bucket head-to-head there - see that profile's
# DEFAULT_TEMP comment for the full methodology). Not independently
# re-tested against THIS checkpoint's tool-calling behavior - an uncensored/
# de-refusal fine-tune can plausibly shift sampling-sensitive behavior in
# ways a base-model comparison doesn't capture, so if tool calls come back
# with stray prose or degraded accuracy, re-run that same head-to-head
# against this checkpoint before assuming these numbers are still right.
DEFAULT_TEMP="0.6"
DEFAULT_TOP_P="0.95"
DEFAULT_TOP_K="20"

# Same failure mode qwen35-9b.sh found and fixed (see its THINKING_KWARG_KEY
# comment): the real /v1/chat/completions path returns reasoning_content by
# default unless this is forced off. Same chat template family, so the same
# key applies; not independently re-confirmed against this checkpoint's
# /v1/chat/completions responses.
THINKING_KWARG_KEY="enable_thinking"

# "fragment|size_mib|description" - only the "-MTP-" suffixed files from
# this repo are listed (self-mtp SPEC_MODE above requires the MTP build);
# the repo also ships identically-named non-MTP files (e.g. plain
# "...-Q4_K_M.gguf" alongside "...-MTP-Q4_K_M.gguf"), so every fragment
# below includes the "MTP-" prefix to avoid the download step's glob
# matching the wrong one (see install.d/70-model-download.sh's
# -iname '*$GGUF_PATTERN*.gguf'). Sizes confirmed against the repo's own
# file listing (hf://models/DavidAU/Qwen3.5-9B-The-Defiant-Fable-
# Uncensored-Heretic-NEO-IMATRIX-MAX-MTP-GGUF), 2026-08-03.
QUANT_MENU=(
  "MTP-Q4_K_M|6657|requested default - needs the heavier CPU offload above, see LLAMA_CPU_FFN_LAYERS_RECOMMENDED"
  "MTP-IQ4_XS|6224|smallest MTP quant here, most VRAM headroom"
  "MTP-IQ4_NL|6443|"
  "MTP-Q4_K_S|6379|"
  "MTP-Q5_K_S|7317|"
  "MTP-Q5_K_M|7479|floor recommended for coding/tool-calling precision, same rationale as qwen35-9b.sh"
  "MTP-Q6_K|8353|best quality, very little VRAM room left for context"
)
QUANT_MENU_INTRO="All are the MTP build of DavidAU's Qwen3.5-9B-The-Defiant-Fable-Uncensored-Heretic-NEO-IMATRIX-MAX from \$HF_REPO
(NEO Imatrix + full-precision output tensor + Q8_0 MTP tensors - see the
repo's README for what that trades off against the same-named Unsloth
quant). Larger = better quality, more VRAM. Sizes below are as reported by
the repo (effectively GiB, i.e. already *1024 to MiB in the math further
down)."

# Printed inside the generated start-local-llama.sh header, next to -ngl 99.
ARCH_NOTES="no --n-cpu-moe: same dense (non-MoE) Qwen3.5-9B architecture as qwen35-9b.sh, so that flag would still be a no-op here"
