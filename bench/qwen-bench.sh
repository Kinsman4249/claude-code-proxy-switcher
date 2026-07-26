#!/usr/bin/env bash
# qwen-bench.sh - speed/quality sweep driver for Qwen3.5-9B-UD-Q4_K_XL at -c 131072.
#
# WHY THIS EXISTS: the model-profiles/qwen35-9b.sh default (24 of 32 FFN
# layers pushed to CPU RAM) is the slowest config this project can produce.
# This script hunts for a faster one at the SAME 131072 context, by testing
# levers one at a time (KV cache quant type, how many layers must stay on
# CPU, batch size, thread count) and checking each candidate against a
# correctness gate before trusting its speed number.
#
# Usage:
#   ./qwen-bench.sh baseline      capture the current running config's numbers
#   ./qwen-bench.sh kv-sweep      try each KV cache quant type at layers=24
#   ./qwen-bench.sh bisect KTYPE VTYPE   binary-search min CPU FFN layers for a KV type
#   ./qwen-bench.sh measure LABEL K V LAYERS [UB] [THREADS]   one-off measurement
#   ./qwen-bench.sh restore-baseline     put the server back to the known-good config
#
# DEBUG=1 (default) writes a full per-request log to bench/logs/; DEBUG=0
# only prints progress lines. Every run also prints this script's build
# stamp so you know which version of the harness produced a given result.
set -uo pipefail

BUILD_STAMP="qwen-bench.sh build 2026-07-25.1"
DEBUG="${DEBUG:-1}"

# ---- fixed facts about this machine/model, see the plan for how these were
# ---- measured (do not re-derive them, they are not guesses) ----
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BENCH_DIR/logs"
RESULTS_MD="$BENCH_DIR/qwen-results.md"
CONTAINER_NAME="ollama-box"
BIN="$HOME/llama.cpp/build/bin/llama-server"
MODEL_PATH="$HOME/models/qwen35-9b/Qwen3.5-9B-UD-Q4_K_XL.gguf"
PORT=8080
CTX=131072
N_LAYERS=32
BASELINE_CPU_FFN_LAYERS=24
SERVER_LOG="$LOG_DIR/server-current.log"
HAYSTACK_PROBE="$BENCH_DIR/haystack_117333.json"   # ~36.5K-token-depth probe (measured, not literally 100K) (already committed)
HAYSTACK_DEEP="$BENCH_DIR/haystack_367510.json"    # ~99870-token-depth probe (measured 2026-07-25) - KV-quant damage shows at depth, not at 36.5K
VRAM_FLOOR_MIB=1500                                # below this, we measured a dead server, not a loaded one

mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"

# ---- small logging helpers ----
# log(): always-on progress line, printed and appended to this run's logfile.
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }
# debug(): verbose detail, only when DEBUG=1. Goes to disk only (not stdout)
# so a long sweep doesn't flood the terminal, per the user's "disk" choice.
debug() { [ "$DEBUG" = "1" ] && echo "[DEBUG $(date +%H:%M:%S)] $*" >> "$RUN_LOG"; }

log "$BUILD_STAMP (DEBUG=$DEBUG, run log: $RUN_LOG)"

# ---- server lifecycle ----
# Stopping does NOT need distrobox: this container shares the host PID
# namespace (confirmed: `ps -p <pid>` on the host sees the container's
# llama-server directly), so a plain host-side pkill is faster and can't
# hang the way `distrobox enter` occasionally does.
stop_server() {
  if pgrep -f "bin/llama-server" > /dev/null 2>&1; then
    log "stopping running llama-server..."
    pkill -f "bin/llama-server" 2>/dev/null
    for _ in $(seq 1 15); do
      pgrep -f "bin/llama-server" > /dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -f "bin/llama-server" > /dev/null 2>&1; then
      log "server did not stop gracefully, sending SIGKILL"
      pkill -9 -f "bin/llama-server" 2>/dev/null
      sleep 2
    fi
  fi
}

# Starting DOES need distrobox (the binary depends on the container's CUDA
# library paths). distrobox enter can hang, so retry a few times with a
# timeout rather than trusting the first attempt.
# Args: cpu_ffn_layers kv_k kv_v ub threads
start_server() {
  # bsz (logical batch, -b) defaults to 512 to match the committed profile
  # exactly for baseline capture. The ub-sweep test (Phase 1 item 3) passes
  # a larger -b explicitly when it wants to test bigger logical batches.
  local layers="$1" kv_k="$2" kv_v="$3" ub="${4:-512}" threads="${5:-}" bsz="${6:-512}"
  stop_server

  local ot_flag=""
  if [ "$layers" -gt 0 ]; then
    local first=$((N_LAYERS - layers))
    local range
    range=$(seq -s'|' "$first" $((N_LAYERS - 1)))
    # llama.cpp wants a regex alternation, e.g. (8|9|10|...|31)
    ot_flag="--override-tensor blk\\.(${range})\\.ffn_(gate|up|down)\\.weight=CPU"
  fi

  local thread_flag=""
  [ -n "$threads" ] && thread_flag="-t $threads"

  debug "start_server layers=$layers kv_k=$kv_k kv_v=$kv_v ub=$ub threads=$threads"
  debug "override-tensor: $ot_flag"

  local ok=0
  for attempt in 1 2 3 4; do
    log "launch attempt $attempt/4 (layers=$layers kv=$kv_k/$kv_v ub=$ub threads=${threads:-default})..."
    # Backgrounded from the host side: distrobox enter blocks in the
    # foreground, so wrap the whole thing in a subshell + & + disown.
    (
      timeout 600 distrobox enter "$CONTAINER_NAME" -- "$BIN" \
        -m "$MODEL_PATH" -ngl 99 \
        -c "$CTX" -b "$bsz" -ub "$ub" -n 4096 -fa on \
        --cache-type-k "$kv_k" --cache-type-v "$kv_v" \
        --fit off --no-webui $thread_flag \
        --port "$PORT" --host 127.0.0.1 $ot_flag \
        --spec-type draft-mtp --spec-draft-n-max 2 \
        > "$SERVER_LOG" 2>&1
    ) &
    disown
    if wait_for_health 180; then
      ok=1
      break
    fi
    log "attempt $attempt did not come up healthy within 180s, retrying..."
    stop_server
  done
  [ "$ok" = "1" ]
}

# Poll /health twice consecutively, then confirm with a REAL /completion -
# health-only is not proof of a working model (this exact gap invalidated
# an earlier Nemotron sweep's results).
#
# Fails FAST if the llama-server process itself has already died (e.g. an
# OOM at compute-buffer allocation exits in ~1s) instead of burning the
# whole timeout polling a port nothing will ever answer on - a real
# 30-layer OOM was mistakenly given a full 180s x 4 retries before this fix.
wait_for_health() {
  local timeout_s="$1" waited=0 healthy_count=0
  while [ "$waited" -lt "$timeout_s" ]; do
    if curl -s -o /dev/null -m 3 "http://127.0.0.1:$PORT/health"; then
      healthy_count=$((healthy_count + 1))
      [ "$healthy_count" -ge 2 ] && break
    else
      healthy_count=0
      if [ "$waited" -ge 10 ] && ! pgrep -f "bin/llama-server" > /dev/null 2>&1; then
        log "llama-server process exited early (crash/OOM) - see $SERVER_LOG"
        return 1
      fi
    fi
    sleep 2
    waited=$((waited + 2))
  done
  [ "$healthy_count" -ge 2 ] || { log "never reported healthy"; return 1; }

  local resp
  resp=$(curl -s -m 30 "http://127.0.0.1:$PORT/completion" \
    -H "Content-Type: application/json" \
    -d '{"prompt":"The capital of France is","n_predict":8}')
  debug "smoke-test /completion response: $resp"
  echo "$resp" | grep -q '"content"' || { log "no real completion after health check"; return 1; }
  return 0
}

# Host-side VRAM read with a plausibility floor - a number below the floor
# means we measured a dead/unloaded server, not a real one.
read_vram_mib() {
  local v=0
  for _ in 1 2 3; do
    v=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
    [ "${v:-0}" -ge "$VRAM_FLOOR_MIB" ] 2>/dev/null && { echo "$v"; return 0; }
    sleep 2
  done
  echo "$v"
  return 1
}

# ---- measurement ----
# One config, one big request that doubles as the speed AND quality
# measurement (prefill+decode timings, plus sentinel grading on the same
# generated content) - this halves how many ~100K-token requests a full
# sweep needs. A short follow-up with cache_prompt=true separately measures
# the cached-latency shape that dominates real agentic use.
measure() {
  local label="$1"
  local haystack="${2:-$HAYSTACK_PROBE}"
  [ -f "$haystack" ] || { log "missing haystack: $haystack"; return 1; }

  local vram tok_count t0 t1 elapsed resp content sentinels found n_found def_present prompt_ms pred_per_s prompt_per_s

  vram=$(read_vram_mib) || log "WARNING: VRAM read below plausibility floor ($vram MiB) - treating server as suspect"

  local prompt
  prompt=$(python3 -c "import json;print(json.load(open('$haystack'))['prompt'])")
  sentinels=$(python3 -c "import json;print(json.dumps(json.load(open('$haystack'))['sentinels']))")

  t0=$(date +%s.%N)
  resp=$(python3 - "$PORT" "$haystack" <<'PYEOF'
import json, sys, urllib.request, time
port, hfile = sys.argv[1], sys.argv[2]
data = json.load(open(hfile))
payload = {"prompt": data["prompt"], "n_predict": 400, "temperature": 0.0, "cache_prompt": True}
req = urllib.request.Request(f"http://127.0.0.1:{port}/completion",
                              data=json.dumps(payload).encode(),
                              headers={"Content-Type": "application/json"})
t0 = time.time()
with urllib.request.urlopen(req, timeout=240) as r:
    result = json.loads(r.read())
result["_elapsed_s"] = time.time() - t0
print(json.dumps(result))
PYEOF
)
  t1=$(date +%s.%N)

  content=$(echo "$resp" | python3 -c "import json,sys;print(json.load(sys.stdin).get('content',''))")
  prompt_ms=$(echo "$resp" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('timings',{}).get('prompt_ms',0))")
  prompt_per_s=$(echo "$resp" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('timings',{}).get('prompt_per_second',0))")
  pred_per_s=$(echo "$resp" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('timings',{}).get('predicted_per_second',0))")
  tok_count=$(echo "$resp" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('timings',{}).get('prompt_n',0))")

  n_found=0
  for s in $(echo "$sentinels" | python3 -c "import json,sys;[print(x) for x in json.load(sys.stdin)]"); do
    echo "$content" | grep -q "$s" && n_found=$((n_found + 1))
  done
  def_present=0
  echo "$content" | grep -q "def combine_sentinels" && def_present=1

  debug "measure($label) raw content: $content"

  # Cached follow-up: same big prompt still in KV cache, short new question.
  local followup_resp followup_ms
  followup_resp=$(python3 - "$PORT" "$haystack" <<'PYEOF'
import json, sys, urllib.request
port, hfile = sys.argv[1], sys.argv[2]
data = json.load(open(hfile))
prompt = data["prompt"] + "\n\nOne more thing: reply with just the word OK."
payload = {"prompt": prompt, "n_predict": 10, "temperature": 0.0, "cache_prompt": True}
req = urllib.request.Request(f"http://127.0.0.1:{port}/completion",
                              data=json.dumps(payload).encode(),
                              headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=300) as r:
    print(json.dumps(json.load(r).read() if False else json.load(r)))
PYEOF
) 2>/dev/null
  followup_ms=$(echo "$followup_resp" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('timings',{}).get('prompt_ms',0))" 2>/dev/null || echo "n/a")

  local pass="FAIL"
  [ "$n_found" -eq 3 ] && [ "$def_present" -eq 1 ] && pass="PASS"

  log "[$label] vram=${vram}MiB prompt_tok=$tok_count prompt_tok/s=$prompt_per_s decode_tok/s=$pred_per_s cached_followup_ms=$followup_ms quality=$pass ($n_found/3 sentinels, def_present=$def_present)"

  {
    echo "| $label | $vram | $tok_count | $prompt_per_s | $pred_per_s | $followup_ms | $pass ($n_found/3) |"
  } >> "$RESULTS_MD"
}

ensure_results_header() {
  [ -f "$RESULTS_MD" ] && return
  {
    echo "# Qwen3.5-9B-UD-Q4_K_XL speed sweep results"
    echo
    echo "Generated by bench/qwen-bench.sh. -c 131072 fixed for every row."
    echo "Quality gate: 3 sentinel functions + a correct combine_sentinels() def,"
    echo "graded at ~36.5K token depth (bench/haystack_117333.json)."
    echo
    echo "| label | VRAM MiB | prompt tokens | prefill tok/s | decode tok/s | cached-followup ms | quality |"
    echo "|---|---|---|---|---|---|---|"
  } >> "$RESULTS_MD"
}

# ---- named commands ----
cmd_baseline() {
  ensure_results_header
  log "=== capturing baseline (current committed config: layers=24, kv=q8_0/q8_0, ub=512) ==="
  start_server "$BASELINE_CPU_FFN_LAYERS" q8_0 q8_0 512 || { log "baseline server failed to start"; exit 1; }
  measure "baseline (layers=24 kv=q8_0/q8_0 ub=512)"
}

cmd_measure() {
  ensure_results_header
  local label="$1" k="$2" v="$3" layers="$4" ub="${5:-512}" threads="${6:-}"
  start_server "$layers" "$k" "$v" "$ub" "$threads" || { log "server failed to start for $label"; return 1; }
  measure "$label"
}

# Deep-context re-check: same config, but graded at ~99870 tokens instead of
# ~36.5K. A KV quant type that passes at 36.5K can still fail near the
# ceiling - this is the check that would actually catch it. Does NOT
# restart the server - call this right after cmd_measure/cmd_kv_sweep while
# the config you want to double-check is still loaded.
cmd_deep_check() {
  ensure_results_header
  local label="$1"
  measure "DEEP $label" "$HAYSTACK_DEEP"
}

cmd_kv_sweep() {
  ensure_results_header
  log "=== KV cache type sweep at fixed layers=$BASELINE_CPU_FFN_LAYERS ==="
  local combo
  for combo in "q8_0 q8_0" "q8_0 q5_1" "q8_0 q4_0" "q5_1 q5_1" "q4_0 q4_0"; do
    set -- $combo
    cmd_measure "kv-sweep ($1/$2 layers=24)" "$1" "$2" "$BASELINE_CPU_FFN_LAYERS"
  done
}

# Binary search the minimum CPU-resident FFN layer count that still loads
# and passes the quality gate, for one KV type. Prints/logs every probe so
# a crash mid-search still leaves a usable trail.
cmd_bisect() {
  ensure_results_header
  local kv_k="$1" kv_v="$2"
  local lo=0 hi="$BASELINE_CPU_FFN_LAYERS" mid best="$BASELINE_CPU_FFN_LAYERS"
  log "=== bisecting min CPU FFN layers for kv=$kv_k/$kv_v (range $lo-$hi) ==="
  while [ "$lo" -le "$hi" ]; do
    mid=$(((lo + hi) / 2))
    if cmd_measure "bisect kv=$kv_k/$kv_v layers=$mid" "$kv_k" "$kv_v" "$mid"; then
      # measure() itself doesn't return pass/fail as exit code; re-check the
      # last results row for PASS before treating this as viable.
      if tail -1 "$RESULTS_MD" | grep -q "PASS"; then
        best="$mid"
        hi=$((mid - 1))
      else
        lo=$((mid + 1))
      fi
    else
      log "layers=$mid failed to load (likely OOM), searching higher"
      lo=$((mid + 1))
    fi
  done
  log "=== bisection done: minimum viable CPU FFN layers for kv=$kv_k/$kv_v is $best ==="
}

cmd_restore_baseline() {
  start_server "$BASELINE_CPU_FFN_LAYERS" q8_0 q8_0 512
}

# Thread count sweep at a fixed (kv, layers, ub) combo - the current config
# never passes -t at all, so this is testing "any thread setting" against
# "let llama.cpp guess".
cmd_thread_sweep() {
  local kv_k="$1" kv_v="$2" layers="$3" ub="${4:-512}"
  ensure_results_header
  log "=== thread sweep at kv=$kv_k/$kv_v layers=$layers ub=$ub ==="
  local t
  for t in "" 6 8 16; do
    cmd_measure "thread-sweep t=${t:-default} kv=$kv_k/$kv_v layers=$layers" "$kv_k" "$kv_v" "$layers" "$ub" "$t"
  done
}

# Pick the best PASSing row out of the kv-sweep block. Rank by LOWEST VRAM,
# not highest decode tok/s: every kv-sweep row runs at the SAME fixed
# layers=24, so decode speed barely differs between them (CPU-offloaded
# layers dominate either way) - what actually matters is how much VRAM a KV
# type frees, because that's what funds fewer CPU-resident layers in the
# bisection step that follows. Picking by raw decode speed here would just
# rediscover the baseline and skip the real lever (this was a real bug: the
# first run of this script picked q8_0/q8_0 baseline as "winner" over
# q4_0/q4_0, which used ~1GB less VRAM at identical quality).
best_passing_kv() {
  awk -F'|' '
    /PASS/ && /kv-sweep/ {
      label=$2; vram=$3+0
      gsub(/^ +| +$/, "", label)
      if (best == 0 || vram < best) { best = vram; bestlabel = label }
    }
    END { print bestlabel }
  ' "$RESULTS_MD"
}

# Full unattended chain: baseline -> KV type sweep -> bisect the winning KV
# type's minimum CPU-layer count -> thread sweep at that winner. Everything
# here avoids sudo on purpose (GPU power tuning is a separate, manual step -
# see handoff.md - because this box needs an interactive sudo password).
# Ends by restoring the server to the best config found so it's left usable.
cmd_auto() {
  ensure_results_header
  log "=== AUTO: full non-interactive sweep starting ==="

  cmd_baseline

  cmd_kv_sweep

  local winner
  winner=$(best_passing_kv)
  if [ -z "$winner" ]; then
    log "AUTO: no KV-sweep row passed the quality gate - falling back to baseline kv=q8_0/q8_0 for bisection"
    winner="q8_0 q8_0"
  else
    # label looks like "kv-sweep (K/V layers=24)" - pull K and V back out.
    winner=$(echo "$winner" | grep -oE '\([a-z0-9_]+/[a-z0-9_]+' | tr -d '(' | tr '/' ' ')
    log "AUTO: best passing KV type from sweep: $winner"
  fi
  set -- $winner
  local win_k="$1" win_v="$2"

  cmd_bisect "$win_k" "$win_v"
  # cmd_bisect logs the winning layer count; pull it back out of the log.
  local win_layers
  win_layers=$(grep -oE 'minimum viable CPU FFN layers for kv='"$win_k"'/'"$win_v"' is [0-9]+' "$RUN_LOG" | tail -1 | grep -oE '[0-9]+$')
  win_layers="${win_layers:-$BASELINE_CPU_FFN_LAYERS}"
  log "AUTO: winning layer count = $win_layers"

  cmd_thread_sweep "$win_k" "$win_v" "$win_layers" 512

  # Deep-context re-check on the winning kv/layers combo (thread count
  # doesn't affect correctness, so reuse whatever's already loaded from the
  # last thread-sweep iteration rather than restarting again).
  cmd_deep_check "kv=$win_k/$win_v layers=$win_layers (final candidate)"

  log "AUTO: sweep complete. Best candidate so far: kv=$win_k/$win_v layers=$win_layers (see $RESULTS_MD for the winning thread count)."
  log "AUTO: leaving server running on this candidate config, NOT restoring baseline, so it's ready to inspect."
  log "AUTO: Phase 3 (GPU power, needs sudo) and profile landing are intentionally left for an interactive session."
}

case "${1:-}" in
  baseline) cmd_baseline ;;
  kv-sweep) cmd_kv_sweep ;;
  bisect) shift; cmd_bisect "$@" ;;
  measure) shift; cmd_measure "$@" ;;
  deep-check) shift; cmd_deep_check "$@" ;;
  thread-sweep) shift; cmd_thread_sweep "$@" ;;
  auto) cmd_auto ;;
  restore-baseline) cmd_restore_baseline ;;
  *)
    echo "Usage: $0 {baseline|kv-sweep|bisect K V|measure LABEL K V LAYERS [UB] [THREADS]|thread-sweep K V LAYERS [UB]|auto|restore-baseline}"
    exit 1
    ;;
esac
