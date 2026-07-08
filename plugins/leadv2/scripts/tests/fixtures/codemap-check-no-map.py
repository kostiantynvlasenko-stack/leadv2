import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
p = d["prompts"].get("architect", "") + d["prompts"].get("synthesize", "")
ctx = d.get("ctx") or ""
# [fix-round-1 #1] flag-off must OMIT code_map_included entirely — "key absent" is the only
# correct state; a stray code_map_included:false (the pre-fix shipped behavior) must now FAIL.
ok = (
    "Code map" not in p
    and "code_map" not in p
    and "code_map" not in ctx
    and "code_map_included" not in d["result"]
)
if not ok:
    print(f"result_keys={sorted(d['result'].keys())}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
