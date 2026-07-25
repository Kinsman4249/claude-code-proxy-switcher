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
# model-profiles/gemma4-e4b.sh) - it isn't. An explicit `-c 262144` OOMs
# (compute-buffer allocation failure) even with `--fit off` and no other
# flag relying on --fit at all - RE-CONFIRMED this is a real VRAM/compute-
# buffer ceiling for this quant on this card, not a --fit-only quirk (an
# earlier version of this comment blamed it entirely on --fit's "explicit
# value is never a ceiling it can shrink" behavior from
# model-profiles/nemotron3-nano-30b.sh's NGL_MODE comment - that mechanism
# is real, but it isn't the whole story here, since removing --fit from the
# equation entirely didn't fix it).
#
# 92416 was --fit's own auto-picked value (both -ngl and -c left completely
# unset, letting --fit choose, then reproduced identically with explicit
# -ngl 99 -c 92416 --fit off) - but it turns out to be needlessly
# conservative. Explicit -c 131072 (matching Claude Haiku's ~128K context,
# UD-Q8_K_XL quant, -ngl 99 --fit off, no --override-tensor/CPU-offload
# needed) loads and serves real completions using 6975 MiB of 8192 MiB -
# 1217 MiB headroom, comfortably more margin than the ~1700 MiB headroom
# the 92416 figure below was originally accepted with. Raised to 131072 for
# that reason. UPDATE 2026-07-25 (see the CONFIRMED note below this one): the
# real ceiling for UD-Q8_K_XL, the quant this number was tested against, is
# now precisely known - 195584 (binary-searched to +/-512 tokens against the
# real OOM boundary), well above 131072. RECOMMENDED_CTX_8GB is kept at
# 131072 anyway rather than raised to match: it was chosen to match Claude
# Haiku's ~128K context, a goal unrelated to VRAM headroom, and 195584 would
# leave only ~370 MiB of headroom on this card (see the quant-by-quant
# figures below) versus 131072's larger margin - raising it is a deliberate
# tradeoff call for whoever installs this, not something to default silently.
RECOMMENDED_CTX_8GB=131072

# CONFIRMED 2026-07-25 (separate session from the note above), same RTX 3080
# 8GB card: swept every remaining quant in the menu below for its real ceiling
# - each tried at this model's own metadata max (262144) first via a real
# /completion request, and binary-searched (+/-512 token precision) down to
# a real working ceiling whenever that OOM'd, nvidia-smi read immediately
# after each successful load:
#   UD-Q4_K_XL (2988 MiB file): 262144 ctx fits whole - 6815 MiB VRAM
#   Q5_K_M     (3013 MiB file): 262144 ctx fits whole - 6839 MiB VRAM
#   Q6_K       (3868 MiB file): 262144 ctx fits whole - 7573 MiB VRAM
#   Q8_0       (4038 MiB file): 262144 ctx fits whole - 7741 MiB VRAM
#   UD-Q6_K_XL (4348 MiB file): 262144 OOMs - real ceiling 244672, 7821 MiB
#   UD-Q8_K_XL (5365 MiB file): 262144 OOMs - real ceiling 195584, 7823 MiB
# (both binary-searched to +/-512 token precision against the actual OOM
# boundary, not rounded to a convenient power-of-two guess)
# Unlike the 30B-A3B sibling profile, VRAM here tracks file size almost
# exactly monotonically (expected: this is the dense variant, no MoE experts
# for --fit to place off-GPU independently of quant level - every tensor in
# the file goes straight to VRAM at -ngl 99). The two largest quants
# (UD-Q6_K_XL, UD-Q8_K_XL) are the only ones in the menu whose real ceiling
# sits below the model's own 262144 max on this card; every quant at or
# below Q8_0 in file size fits the model's own max whole.

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

# CONFIRMED 2026-07-25 on a live RTX 3080 8GB card, UD-Q8_K_XL quant (the
# tightest-fitting of the three tested), -c 92416, --fit off: this model
# emits reasoning_content by default with zero flags, matching NVIDIA's own
# model card ("By default, enable_thinking is set to be True"). VRAM used:
# 6481 MiB of 8192 MiB - 1711 MiB headroom, matching the QUANT COMPARISON
# note above almost exactly (that measurement was already thinking-mode-on,
# it turns out - the two numbers agreeing is itself a confirmation, not a
# coincidence).
#
# NOT left on by default despite the headroom: a separate live test against
# the 30B-A3B sibling profile (see model-profiles/nemotron3-nano-30b.sh)
# found thinking cost ~13x the tokens and ~11x the latency on a grep+
# read_file tool-calling prompt for no gain in tool-call correctness, and at
# a realistic 500-token budget the model burned the whole budget on
# reasoning and never emitted the tool call at all. THINKING_KWARG_KEY below
# is a capability marker, not a yes/no - install.d/80-launcher.sh decides
# true/false from ENABLE_THINKING (install.sh --enable-thinking/
# --disable-thinking, off by default - see install.d/00-config.sh).
THINKING_KWARG_KEY="enable_thinking"

# Sizes confirmed from unsloth/NVIDIA-Nemotron-3-Nano-4B-GGUF's own file
# listing (bytes -> MiB, rounded up). Every quant here is small enough that
# picking the biggest one that still leaves headroom for a large context is
# a reasonable default, unlike the 30B-A3B model where quant barely affects
# download size at all.
#
# QUANT COMPARISON, same RTX 3080 8GB card, 2026-07-25, same session so
# directly comparable: all three tested at 92416 ctx (NOT the current
# RECOMMENDED_CTX_8GB=131072 above - that was raised later in a separate
# session after this comparison was already recorded; the relative
# quant-to-quant deltas below still hold, but re-add ~500-600 MiB to each
# figure to estimate its footprint at the current 131072 recommendation,
# per the 92416->131072 delta measured on UD-Q8_K_XL: 6467 -> 6975 MiB),
# -b 512, q8_0 KV cache, --fit off (explicit -ngl 99 -c 92416), real
# completions confirmed working (not just a health check) via a direct
# /completion request to each, nvidia-smi read immediately after each load:
#   Q4_K_M     (2766 MiB file): 4383 MiB VRAM - 3809 MiB headroom
#   UD-Q6_K_XL (4348 MiB file): 5817 MiB VRAM - 2375 MiB headroom
#   UD-Q8_K_XL (5365 MiB file): 6467 MiB VRAM - 1725 MiB headroom
# All three comfortably fit at this context; UD-Q8_K_XL has the least
# headroom of the three, which is why it was the one used to determine
# RECOMMENDED_CTX_8GB above (the tightest-fitting case). Q5_K_M/Q6_K/Q8_0/
# UD-Q4_K_XL were live-tested in a later session (see the CONFIRMED note
# above RECOMMENDED_CTX_8GB) rather than left as an extrapolation - the
# straight-line-by-file-size guess this comment used to make turned out
# right in relative ordering but is no longer needed now that every quant
# has a real measured number.
QUANT_MENU=(
  "Q4_K_M|2766|confirmed from the repo's file listing - live-tested at 92416 ctx, 4383 MiB"
  "UD-Q4_K_XL|2988|Unsloth dynamic quant, better quality at similar size - live-tested, fits full 262144 ctx at 6815 MiB"
  "Q5_K_M|3013|confirmed from the repo's file listing - live-tested, fits full 262144 ctx at 6839 MiB"
  "Q6_K|3868|confirmed from the repo's file listing, best quality/size tradeoff - live-tested, fits full 262144 ctx at 7573 MiB"
  "Q8_0|4038|confirmed from the repo's file listing - live-tested, fits full 262144 ctx at 7741 MiB"
  "UD-Q8_K_XL|5365|Unsloth dynamic quant, largest offered - still under 6 GB - live-tested, real ceiling below the model's own 262144 max, see the CONFIRMED note above RECOMMENDED_CTX_8GB"
)
QUANT_MENU_INTRO="Nemotron 3 Nano 4B from \$HF_REPO. Every quant here comfortably
fits an 8GB card - pick based on quality, not VRAM pressure."

# Printed inside the generated start-local-llama.sh header, next to -ngl 99.
# Kept to one line here - the generator wraps it to fit the comment column.
ARCH_NOTES="--n-cpu-moe not applicable: this is the dense nemotron_h variant (no MoE layers) - see model-profiles/nemotron3-nano-30b.sh for the MoE sibling"
