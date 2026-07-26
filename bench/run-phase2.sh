#!/usr/bin/env bash
# One-shot continuation after the auto-sweep fix: bisect q4_0/q4_0 (the real
# winner), thread-sweep at that config, deep-check the result.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
DEBUG=1

./qwen-bench.sh bisect q4_0 q4_0

WIN_LAYERS=$(grep -oE 'minimum viable CPU FFN layers for kv=q4_0/q4_0 is [0-9]+' logs/run-*.log | tail -1 | grep -oE '[0-9]+$')
WIN_LAYERS="${WIN_LAYERS:-24}"
echo "winning layers for q4_0/q4_0: $WIN_LAYERS" | tee -a logs/phase2-orchestrator.log

./qwen-bench.sh thread-sweep q4_0 q4_0 "$WIN_LAYERS" 512

./qwen-bench.sh deep-check "kv=q4_0/q4_0 layers=$WIN_LAYERS (final candidate)"

echo "PHASE2 DONE: winning candidate kv=q4_0/q4_0 layers=$WIN_LAYERS" | tee -a logs/phase2-orchestrator.log
