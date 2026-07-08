import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    off = json.load(f)["result"]
with open(sys.argv[2], encoding="utf-8") as f:
    on = json.load(f)["result"]
for k in ("decisions_count", "steps_count", "context_path", "blocking_concerns", "task_id"):
    if off.get(k) != on.get(k):
        print(f"{k}: {off.get(k)!r} != {on.get(k)!r}", file=sys.stderr)
        sys.exit(1)
sys.exit(0)
