#!/usr/bin/env python3
"""Build a long-context needle-in-haystack + coding-task prompt for Qwen3.5-9B benchmarking.

Filler = real llama.cpp C/C++ source (so the model sees plausible code, not noise).
Three needle functions with random sentinel return values are inserted at
~10%, ~50%, ~90% depth. The final instruction asks the model to find all
three and use them in a small Python function - checks both long-context
retrieval AND basic coding correctness in one shot.
"""
import glob
import os
import random
import sys
import json

random.seed(1234)

SRC_ROOT = os.path.expanduser("~/llama.cpp")
TARGET_CHARS = int(sys.argv[1]) if len(sys.argv) > 1 else 480000  # ~ chars, tuned per quant by caller
# Where generated haystacks land. Defaults to this script's own directory
# (bench/) so a rerun produces a file next to the committed one instead of
# scattering into a session scratchpad that gets garbage collected.
OUT_DIR = os.path.dirname(os.path.abspath(__file__))

files = []
for ext in ("*.cpp", "*.h", "*.hpp", "*.c"):
    files.extend(glob.glob(os.path.join(SRC_ROOT, "**", ext), recursive=True))
files = [f for f in files if "/build/" not in f and "/.git/" not in f]
random.shuffle(files)

chunks = []
total = 0
for f in files:
    try:
        with open(f, "r", errors="ignore") as fh:
            content = fh.read()
    except OSError:
        continue
    chunks.append(f"// ---- file: {os.path.relpath(f, SRC_ROOT)} ----\n" + content)
    total += len(content)
    if total >= TARGET_CHARS:
        break

full_text = "\n".join(chunks)

sentinels = [random.randint(100000, 999999) for _ in range(3)]
names = ["get_partition_flux_a1b2", "get_partition_flux_c3d4", "get_partition_flux_e5f6"]

needles = []
for name, val in zip(names, sentinels):
    needles.append(
        f"\n// ---- injected marker function, do not remove ----\n"
        f"static int {name}(void) {{\n    return {val}; // sentinel\n}}\n"
        f"// ---- end marker ----\n"
    )

n = len(full_text)
positions = [int(n * 0.10), int(n * 0.50), int(n * 0.90)]

# Insert from the back so earlier offsets stay valid.
text = full_text
for pos, needle in sorted(zip(positions, needles), key=lambda x: -x[0]):
    text = text[:pos] + needle + text[pos:]

question = f"""

===== END OF CODE DUMP =====

Task: search the code dump above for three marker functions named
get_partition_flux_a1b2, get_partition_flux_c3d4, and get_partition_flux_e5f6.
Each returns a fixed integer sentinel value.

1. State the three integers each function returns, in order.
2. Write a single Python function `combine_sentinels()` that takes no
   arguments, hardcodes the three integers you found as local variables, and
   returns their sum as an int. Output ONLY valid Python for this function
   (a def block), nothing else executable.

Be precise: do not guess the sentinel values, they must be read exactly
from the marker functions above.
"""

prompt = text + question

out = {
    "prompt": prompt,
    "sentinels": sentinels,
    "expected_sum": sum(sentinels),
    "char_len": len(prompt),
}
outfile = os.path.join(OUT_DIR, f"haystack_{len(prompt)}.json")
with open(outfile, "w") as fh:
    json.dump(out, fh)

print(outfile)
print(f"chars={len(prompt)} expected_sum={sum(sentinels)} sentinels={sentinels}")
