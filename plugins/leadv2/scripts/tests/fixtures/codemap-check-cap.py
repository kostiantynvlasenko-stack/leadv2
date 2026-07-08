import json, sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
arch = d["prompts"].get("architect", "")
ctx = d.get("ctx") or ""
note = "truncated at 2000 chars"
has_full = ("X" * 5000) in arch
has_note_arch = note in arch
has_note_ctx = note in ctx

# [fix-round-1 #3] capCodeMap previously sliced to MAX chars THEN appended the note, so the
# TOTAL breached the 2000 cap. Extract the actual persisted code_map (real, deterministic
# persistCodeMap() output — not a mock) and assert its length is <= 2000, not just "has a note".
try:
    ctx_doc = yaml.safe_load(ctx) or {}
except Exception:
    ctx_doc = {}
persisted = ctx_doc.get("code_map")
cap_ok = isinstance(persisted, str) and len(persisted) <= 2000

if has_full or not has_note_arch or not has_note_ctx or not cap_ok:
    persisted_len = len(persisted) if isinstance(persisted, str) else None
    print(f"full={has_full} note_arch={has_note_arch} note_ctx={has_note_ctx} cap_ok={cap_ok} persisted_len={persisted_len}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
