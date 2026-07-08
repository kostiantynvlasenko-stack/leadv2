import json, sys

# Distinct from codemap-check-no-map.py: this is the "codemapEnabled=true but MCP returned
# nothing" case. Per fix-round-1 #1, code_map_included is omitted ONLY when codemapEnabled is
# not true; here it WAS explicitly true, so the key must be PRESENT with value false — that is
# the correct fail-open signal (flag was on, MCP just didn't produce anything), distinct from
# "flag was never on at all".
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
p = d["prompts"].get("architect", "") + d["prompts"].get("synthesize", "")
ctx = d.get("ctx") or ""
ok = (
    "Code map" not in p
    and "code_map" not in p
    and "code_map" not in ctx
    and d["result"].get("code_map_included") is False
)
if not ok:
    print(f"result={d['result']}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
