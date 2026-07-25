# model-profiles/nemotron3-nano-30b.sh
# Profile for NVIDIA Nemotron 3 Nano 30B-A3B (nemotron_h_moe) - a hybrid
# Mamba-2/MoE/Attention model. NVIDIA's own benchmarks (see the model card,
# https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16) show it
# beating Qwen3-30B-A3B-Thinking-2507 and GPT-OSS-20B on several agentic/
# tool-use benchmarks (BFCL v4, SWE-Bench, Arena-Hard-v2 average,
# Terminal-Bench hard subset) and LiveCodeBench v6, which is why this project
# picked it as a Qwen3.5-9B alternative worth adding.
#
# ARCHITECTURE: 52 layers total - 23 Mamba-2, 23 MoE (128 routed experts + 1
# shared expert, top-6 routing), and 6 GQA attention layers (confirmed from
# nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16's config.json:
# hybrid_override_pattern "MEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEMEM*EMEMEMEME"
# has exactly 23 M, 23 E, 6 * across 52 characters). llama.cpp support
# (LLM_ARCH_NEMOTRON_H_MOE) merged 2025-12-16 (llama.cpp PR #18058); an
# earlier crash on load (GGML_ASSERT in mamba-base.cpp, llama.cpp issue
# #20570, reported 2026-03-15) was fixed by PRs #20270/#20335 (mamba2 assert
# fixes) and hardened further by #23082 - confirmed fixed by reading current
# mamba-base.cpp source (checks d_inner % n_head, not the old d_inner %
# (n_group*n_embd) assert from the bug report) on the llama.cpp checkout this
# project builds from (commit c0bc8591, 2026-07-23).

PROFILE_NAME="Nemotron 3 Nano 30B-A3B"
HF_REPO_DEFAULT="unsloth/Nemotron-3-Nano-30B-A3B-GGUF"

# No separate drafter/MTP file found in unsloth's repo listing for this
# model (unlike Gemma 4 or Qwen3.5-9B) - speculative decoding isn't wired up
# for this profile.
DRAFT_REPO=""
DRAFT_PATTERN=""
SPEC_MODE="none"                                # none | self-mtp | draft-model

N_LAYERS=52

# Hybrid Mamba-2/MoE/Attention has no simple closed-form bytes/token (same
# reasoning as Gemma 4, see model-profiles/gemma4-e4b.sh) - probe a live
# server instead of hand-rolling the arithmetic.
KV_MODEL="probe"                                # manual | probe
BYTES_PER_TOKEN=                                # unused when KV_MODEL=probe

# NGL_MODE="fit": tells install.d/80-launcher.sh to leave -ngl unset instead
# of its usual "-ngl 99, always" convention. CONFIRMED by reading llama.cpp's
# --fit implementation (common/fit.cpp, same checkout as above):
# common_params_fit_impl() throws (caught, logged as a harmless-looking
# warning) and skips its ENTIRE layer-placement/MoE-expert-offload pass the
# moment n_gpu_layers is already explicit - see the "n_gpu_layers already set
# by user ... abort" check in that file. This project's other profiles all
# pin -ngl 99 and rely on --fit only for ctx-size sizing (unaffected by this,
# happens earlier in the same function) - harmless for them since Qwen/Gemma
# have no MoE layers, so the skipped pass would've been a no-op anyway. It is
# NOT harmless here: with -ngl 99 forced, every one of this model's 128
# experts x 23 MoE layers would try to load onto GPU, which will not fit an
# 8GB card at any quant (see the file-size note below). Leaving -ngl unset
# lets --fit's real algorithm run: fill every layer's non-expert tensors
# (Mamba-2 state, attention, shared expert) onto GPU first, then backfill as
# many routed-expert tensors as remaining VRAM allows, layer by layer - see
# get_memory_for_layers()/global_surplus_cpu_moe in common/fit.cpp.
NGL_MODE="fit"                                  # fixed | fit

# UNVERIFIED: no live 8GB-card measurement yet for this profile (see todo.md
# history - this profile was added specifically to get that measurement).
# Left blank so prompt_vram_and_context in install.d/20-prompts-model.sh
# falls through to asking for a ceiling directly, rather than asserting a
# number nobody has confirmed. Fill in once a live run confirms a number,
# per this project's "no invented facts" rule - see model-profiles/
# gemma4-e4b.sh's RECOMMENDED_CTX_8GB for the format once that happens.
RECOMMENDED_CTX_8GB=

# Not a Per-Layer-Embeddings model - nothing to offload here.
PLE_TENSOR_REGEX=""

# From nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16's generation_config.json
# (temperature 1.0, top_p 1.0 - both effectively "off") and unsloth's own
# GGUF-repo params file (same temp/top_p, plus top_k -1/min_p 0/repeat_penalty
# 1 - all disabled). --top-k 0 is llama-server's own way of writing "disabled"
# (its help text: "0 = disabled"; the model card's "-1" is the transformers/
# CLI convention, not llama-server's).
DEFAULT_TEMP="1.0"
DEFAULT_TOP_P="1.0"
DEFAULT_TOP_K="0"

# Sizes confirmed from unsloth/Nemotron-3-Nano-30B-A3B-GGUF's own file
# listing (bytes -> MiB, rounded up). Note how little these vary between
# quant levels (IQ4_XS 16.9 GiB vs Q2_K_L 16.85 GiB, barely smaller) -
# unsloth's dynamic quantization keeps the 23 Mamba-2 + 6 attention layers
# and the shared expert at higher precision across every quant level here;
# only the 23 MoE layers' 128 routed experts actually shrink, and even at
# low bit-depths 128 experts x 23 layers stays large. This means the usual
# "pick a smaller quant to save VRAM" logic barely applies to file size for
# this model - what matters for an 8GB card instead is how many of the MoE
# expert tensors --fit (see ARCH_NOTES below) can leave on GPU.
QUANT_MENU=(
  "IQ4_XS|17327|confirmed from the repo's file listing, smallest non-UD quant"
  "Q4_K_S|21000|confirmed from the repo's file listing"
  "UD-Q4_K_XL|21776|Unsloth dynamic quant, better quality at similar size"
  "Q5_K_S|22844|confirmed from the repo's file listing"
  "Q6_K|31956|confirmed from the repo's file listing"
  "Q8_0|32030|confirmed from the repo's file listing"
)
QUANT_MENU_INTRO="Nemotron 3 Nano 30B-A3B from \$HF_REPO. Unlike Qwen3.5-9B or
Gemma 4, quant level barely changes the download size here (see the note in
model-profiles/nemotron3-nano-30b.sh) - pick based on quality, not VRAM,
since VRAM headroom on an 8GB card comes from --fit's MoE-expert offload
below instead."

# Printed inside the generated start-local-llama.sh header, next to the
# -ngl line (see NGL_MODE above - this profile has no fixed -ngl 99 to print
# next to). Kept to one line here - the generator wraps it to fit the
# comment column. --override-tensor dense-FFN offload (the headroom option
# this project offers for Qwen/Gemma) is a no-op here for a different reason
# than those profiles: this model's only FFN-shaped layers ARE the 23 MoE
# layers (ffn_*_exps tensors) - there are no dense ffn_(gate|up|down).weight
# tensors for that flag's regex to match at all.
ARCH_NOTES="no --n-cpu-moe prompt needed: NGL_MODE=fit above already lets --fit place MoE experts automatically; --override-tensor dense-FFN offload is a no-op here since this model's only FFN layers are MoE, not dense"
