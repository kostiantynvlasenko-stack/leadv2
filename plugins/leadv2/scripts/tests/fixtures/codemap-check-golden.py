import json, sys

# [fix-round-1 #6] pinned PRE-DIFF golden comparison — this is the test that actually catches
# finding #1 (a stray code_map_included key leaking into a flag-off return). The golden run
# executes the UNMODIFIED pre-CODEMAP-CONTEXT-01 leadv2-plan.js (via `git show HEAD:...`,
# captured BEFORE this task's first commit) with the exact same fixture/mock/args as the
# current code's flag-off-absent run. Byte-for-byte equality on the result object and the two
# touched-site prompts is required.
with open(sys.argv[1], encoding="utf-8") as f:
    golden = json.load(f)
with open(sys.argv[2], encoding="utf-8") as f:
    current = json.load(f)

errors = []
if golden["result"] != current["result"]:
    errors.append(f"result mismatch: golden={golden['result']} current={current['result']}")
for label in ("architect", "synthesize"):
    g = golden["prompts"].get(label, "")
    c = current["prompts"].get(label, "")
    if g != c:
        errors.append(f"prompt[{label}] mismatch (golden_len={len(g)} current_len={len(c)})")

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
