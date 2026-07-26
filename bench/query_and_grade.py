#!/usr/bin/env python3
"""Send a haystack prompt to a running llama-server and grade the response.

Usage: query_and_grade.py <haystack_json> <label> [port]
"""
import json
import re
import sys
import time
import urllib.request

haystack_file = sys.argv[1]
label = sys.argv[2]
port = sys.argv[3] if len(sys.argv) > 3 else "8080"

with open(haystack_file) as fh:
    data = json.load(fh)

prompt = data["prompt"]
expected_sum = data["expected_sum"]
sentinels = data["sentinels"]

# Tokenize first, so we know exactly how many tokens we're sending.
tok_req = urllib.request.Request(
    f"http://127.0.0.1:{port}/tokenize",
    data=json.dumps({"content": prompt}).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(tok_req, timeout=120) as resp:
    tok_count = len(json.loads(resp.read())["tokens"])

print(f"[{label}] prompt tokens: {tok_count}")

payload = {
    "prompt": prompt,
    "n_predict": 400,
    "temperature": 0.0,
    "cache_prompt": True,
}
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/completion",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)

t0 = time.time()
with urllib.request.urlopen(req, timeout=1800) as resp:
    result = json.loads(resp.read())
elapsed = time.time() - t0

content = result.get("content", "")
timings = result.get("timings", {})

found = [str(s) in content for s in sentinels]
n_found = sum(found)

sum_match = re.search(r"\breturn\s+(\d+)", content) or re.search(r"=\s*(\d{6,8})\b", content)
def_present = "def combine_sentinels" in content

grade = {
    "label": label,
    "prompt_tokens": tok_count,
    "elapsed_s": round(elapsed, 1),
    "prompt_eval_ms_per_tok": timings.get("prompt_ms", 0) / max(tok_count, 1),
    "sentinels_found": n_found,
    "sentinels_total": len(sentinels),
    "def_combine_sentinels_present": def_present,
    "expected_sum": expected_sum,
}

print(json.dumps(grade, indent=2))
print("---RAW RESPONSE---")
print(content)

resultfile = haystack_file.replace(".json", f".result.{label}.json")
with open(resultfile, "w") as fh:
    json.dump({"grade": grade, "raw": content}, fh, indent=2)
print(f"saved: {resultfile}")
