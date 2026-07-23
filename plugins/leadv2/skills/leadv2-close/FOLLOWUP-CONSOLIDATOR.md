# Step 5b detail — Followup consolidator script

Moved out of `SKILL.md` (leadv2-close). Referenced from Step 5b: "Followup consolidator
(inline, all classes ≥ Standard)". This fires only when a followup key repeats ≥3 times
across `docs/handoff/*/followups.md` in the last 30 days — the common case (no repeats) is
a no-op and this file is never consulted.

Pattern reference (canonical skill doc): `skills/leadv2-followup-consolidator/SKILL.md`.

## Purpose

Scan unresolved followups across all tasks; if the same key repeats ≥3 over 30d, open a
consolidated PO task (`pending_review`, never auto-claimed).

## Env knobs

- `LEADV2_FU_MIN_REPEATS` (default `3`) — repeat threshold before a key is consolidated.
- `LEADV2_FU_MAX_PER_RUN` (default `2`) — caps how many consolidated tasks one Close can open.

## Full script

```bash
MIN_REPEATS=${LEADV2_FU_MIN_REPEATS:-3}
MAX_PER_RUN=${LEADV2_FU_MAX_PER_RUN:-2}
opened=0

repeated_keys=$(grep -rh '^- \[ \] ' docs/handoff/*/followups.md 2>/dev/null \
  | sed -E 's/^- \[ \] ([A-Z0-9_-]+):.*/\1/' \
  | sort | uniq -c | sort -rn \
  | awk -v t="$MIN_REPEATS" '$1>=t {print $2}')

for KEY in $repeated_keys; do
  [[ $opened -ge $MAX_PER_RUN ]] && break
  # Skip if KEY already in followup-noise (founder-dismissed) or has open consolidated task
  grep -qE "^- $KEY:" docs/leadv2/followup-noise.yaml 2>/dev/null && continue
  grep -qE "^  PO-CONSOLIDATED-${KEY}-" docs/leadv2/tasks.yaml 2>/dev/null && continue

  bundle="docs/handoff/CONSOLIDATED-${KEY}-$(date +%Y%m%d)"
  mkdir -p "$bundle"
  grep -rh --include='followups.md' "^- \[ \] $KEY:" docs/handoff/ \
    > "$bundle/context-bundle.md"
  related=$(grep -rl "^- \[ \] $KEY:" docs/handoff/*/followups.md \
    | awk -F/ '{print $(NF-1)}' | sort -u | tr '\n' ',' | sed 's/,$//')

  # Pre-fill tasks.yaml entry (pending_review — surfaces in next /leadv2 greeting)
  python3 -c "
import yaml, sys, datetime
f='docs/leadv2/tasks.yaml'
d=yaml.safe_load(open(f)) or {}
tid=f'PO-CONSOLIDATED-${KEY}-'+datetime.date.today().strftime('%Y%m%d')
d.setdefault('tasks',{})[tid]={
  'priority':'medium','class':'Standard','status':'pending_review',
  'source':'followup-consolidator','related':'${related}'.split(','),
  'brief':f'Consolidated fix for ${KEY} — surfaced in repeated followups (last 30d)'
}
yaml.dump(d,open(f,'w'))
"
  opened=$((opened+1))
done

# Append to close yaml
[[ $opened -gt 0 ]] && echo "consolidator: { triggered: true, opened: $opened }" \
  >> "docs/leadv2/closed/${LEADV2_TASK_ID}.yaml"
```
