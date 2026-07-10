# Hack-detection processing — parsing + fold-in scripts (leadv2-review §3)

Referenced from `leadv2-review/SKILL.md` §3. The gate decision itself (has_block → AskUserQuestion)
lives inline in SKILL.md; this file has the parsing/fold-in scaffolding that feeds that gate.

## Read hack findings

```bash
# Read hack findings (written by the parallel Agent(developer) hack-detection run)
# If file missing: treat as has_block=false, warn_count=0 (don't block on tooling absence)
HACK_FILE="docs/handoff/<id>/hack-findings.yaml"
```

Parse the file and extract counts. Then **immediately execute** the following logic:

```python
# Pseudocode — execute inline or via a python3 -c call:
import yaml, os
hack_file = f"docs/handoff/{task_id}/hack-findings.yaml"
if os.path.exists(hack_file):
    findings = yaml.safe_load(open(hack_file)) or {}
    summary = findings.get("summary", {})
else:
    summary = {"block_count": 0, "warn_count": 0, "has_block": False}
block_count = summary.get("block_count", 0)
warn_count  = summary.get("warn_count", 0)
has_block   = summary.get("has_block", False)
```

## Fold hack-detection summary into round1-findings

```bash
# Fold hack-detection summary into round1-findings (concrete append, not optional):
HACK_SUMMARY="docs/handoff/<id>/hack-detection.summary.md"
ROUND1_FINDINGS="docs/handoff/<id>/reviews/round1-findings.md"
mkdir -p "docs/handoff/<id>/reviews"
if [[ -f "$HACK_SUMMARY" ]]; then
  printf -- '\n## hack-detection\n' >> "$ROUND1_FINDINGS"
  cat "$HACK_SUMMARY"              >> "$ROUND1_FINDINGS"
fi

# If has_block=true: HARD GATE — must get founder approval before disposition=resolved
# Extract block snippets for the question:
block_snippets=$(python3 -c "
import yaml, sys, os
f = 'docs/handoff/$TASK_ID/hack-findings.yaml'
if not os.path.exists(f): sys.exit(0)
d = yaml.safe_load(open(f)) or {}
blocks = [x for x in d.get('findings',[]) if x.get('severity')=='block']
for b in blocks[:3]: print(f\"  {b.get('type')}: {b.get('snippet','')[:80]}\")
" 2>/dev/null || true)
```
