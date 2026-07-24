# model-profiles/gemma4-e2b.sh
# Profile for Gemma 4 E2B. See model-profiles/gemma4-e4b.sh for the fuller
# comments - the two profiles only differ in size/layer numbers and repo
# names. E2B is the weaker tool-use model of the pair (Tau2 tool-use average
# 24.5% vs E4B's 42.2%, per the Google model card) - offered for completeness,
# but install.sh recommends E4B by default for a Claude Code workload.
#
# UNVERIFIED VALUES: several fields below are placeholders, not confirmed
# facts, because confirming them needs a live llama-server build with this
# model's actual GGUF loaded (see gemma4-support-spec.md sections 3 and 4).
# Empty/placeholder values here are intentional - install.sh is written to
# fail loudly (skip the feature, print a warning) rather than guess, per this
# project's "no invented flags" rule. Fill these in only after running the
# verification steps in gemma4-support-spec.md against a real build, then
# remove this warning block.

PROFILE_NAME="Gemma 4 E2B"
HF_REPO_DEFAULT="google/gemma-4-E2B-GGUF"       # UNVERIFIED: confirm exact repo/quant filenames exist before use

DRAFT_REPO=""      # UNVERIFIED: confirm an E2B drafter GGUF repo exists (section 4) before setting this
DRAFT_PATTERN=""   # UNVERIFIED: exact drafter filename fragment, from the repo's file listing
SPEC_MODE="draft-model"                         # none | self-mtp | draft-model
# With DRAFT_REPO/DRAFT_PATTERN empty, install.sh's spec-mode resolution step
# (section 4) will find no drafter, print a warning, and omit --spec-type
# entirely rather than emit a broken --spec-type draft-mtp with no -md.

N_LAYERS=35

# Gemma 4's hybrid local/global attention with unified K/V on global layers
# has no simple closed-form bytes/token the way Qwen3.5-9B's does (see
# gemma4-support-spec.md section 5) - probe a live server instead of
# hand-rolling the arithmetic.
KV_MODEL="probe"                                # manual | probe
BYTES_PER_TOKEN=                                # unused when KV_MODEL=probe

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

QUANT_MENU=(
  "Q4_K_M||UNVERIFIED size - check the repo's file listing before relying on the context estimate"
  "Q5_K_M||UNVERIFIED size - check the repo's file listing before relying on the context estimate"
  "Q8_0||UNVERIFIED size - check the repo's file listing before relying on the context estimate"
)
QUANT_MENU_INTRO="Gemma 4 E2B from \$HF_REPO. Sizes are NOT filled in below
(UNVERIFIED - this profile has not been checked against the real repo file
listing yet); the context-length estimate will be skipped until you supply a
size manually or pick 'custom' and enter one from the repo page."

# Printed inside the generated start-local-llama.sh header, next to -ngl 99.
# Kept to one line here - the generator wraps it to fit the comment column.
ARCH_NOTES="no --n-cpu-moe: Gemma 4 E2B has no MoE layers (dense model), so that flag would be a no-op. PLE tables are the offload lever for this model instead, see PLE_TENSOR_REGEX above"
