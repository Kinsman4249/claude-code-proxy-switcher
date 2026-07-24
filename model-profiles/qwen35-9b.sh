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
