import json, sys
import yaml

# [fix-round-1 #2] regression test: validate-ctx returns invalid once, forcing the
# synthesize-retry path. The retry prompt never mentions code_map at all — the ONLY way
# code_map can survive is the deterministic persistCodeMap() call being re-run after retry.
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
inp = d["inputCodeMap"]
ctx = d.get("ctx") or ""
try:
    ctx_doc = yaml.safe_load(ctx) or {}
except Exception:
    ctx_doc = {}
persisted = ctx_doc.get("code_map")
retry_happened = d["prompts"].get("synthesize-retry") is not None
survived = isinstance(persisted, str) and inp.strip() in persisted
if not (retry_happened and survived):
    print(f"retry_happened={retry_happened} survived={survived}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
