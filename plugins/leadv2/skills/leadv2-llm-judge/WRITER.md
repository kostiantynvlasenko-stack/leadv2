# leadv2-llm-judge — mandatory YAML writer script

Exact script for step 3b ("Mandatory YAML writer"). Runs after parsing the
Opus response and writing `llm-judge.yaml` — and even on the skip path
(writes with `skipped: true`). Copy the command verbatim; do not
re-implement the field-mapping logic inline.

```bash
python3 - "$TASK_ID" "docs/handoff/$TASK_ID/llm-judge.yaml" <<'PY'
import sys, yaml, os
from pathlib import Path
from datetime import datetime, timezone

task_id, src_path = sys.argv[1], sys.argv[2]
src = Path(src_path)

if src.is_file():
    raw = yaml.safe_load(src.read_text()) or {}
    judge = raw.get("llm_judge", raw)
else:
    judge = {}

out = Path(f"docs/handoff/{task_id}/llm-judge.yaml")
out.parent.mkdir(parents=True, exist_ok=True)

data = {
    # Nested llm_judge block — shape expected by existing status/deploy readers.
    "llm_judge": {
        "task_id": task_id,
        "judged_at": datetime.now(timezone.utc).isoformat(),
        "model_used": judge.get("model_used", "opus"),
        "verdict": judge.get("verdict", "unknown"),
        "overall_risk": judge.get("overall_risk", judge.get("risk_score", 0.0)),
        "confidence": judge.get("confidence", 0.0),
        "axes": judge.get("axes", {}),
        "blockers": judge.get("blockers", []),
        "caveats": judge.get("caveats", []),
        "reasoning": judge.get("reasoning", ""),
        "skipped": judge.get("skipped", False),
        "skip_reason": judge.get("skip_reason", ""),
    },
    # Top-level convenience fields (F-PERSIST additions — do not conflict with nested shape).
    "escalated_from_haiku": False,
    "opus_used": judge.get("model_used", "").startswith("opus") if judge.get("model_used") else True,
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
}
import tempfile
tmp = out.with_suffix(".tmp")
tmp.write_text(yaml.safe_dump(data, sort_keys=False))
os.replace(tmp, out)
print(f"[llm-judge-writer] wrote {out}", file=sys.stderr)
PY
```
