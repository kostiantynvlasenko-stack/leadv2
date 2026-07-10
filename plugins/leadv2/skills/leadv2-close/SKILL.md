---
name: leadv2-close
description: "[internal] Phase 8 — cost summary, lead-reflect entry, outcome-watch scheduling for Heavy tasks."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# Lead v2 Close — Task Wrap-Up

## When: Phase 8, after Verify success. When NOT: verify failed (use leadv2-recovery).

## Phase-flow at a glance (map only — each row's steps carry the authoritative detail below)

| Stage | Steps | What happens |
|---|---|---|
| Gate + cost | 0, 0a, 1 | `phase8-close.sh` writes scorecard/ledger/passed.flag; emit+flush+read cost telemetry |
| Persist signals | 1b, 1c, 1d | scorecard row, graph-reflect footprint, opt-in learn aggregation |
| History + ledger | 2, 2b, 5c | LEAD_V2_STATE `history:` entry, `learnings.md` line, correction-detect scan |
| Cleanup + consolidate | 3, 4, 5, 5b, 7 | reset state to idle, cost log, archive handoff, followup consolidator, session-hygiene tip |
| Watch + release | 6, 7b, 8 | schedule outcome-watch, release PO queue item, unregister from `active.md` (the close-succeeded signal) |

## Protocol

### Step 0 — MANDATORY: run phase8-close.sh before any close commit

```bash
bash "$(bash .claude/scripts/lv2 --path leadv2-phase8-close.sh)" "${LEADV2_TASK_ID}"
```

This writes scorecard/ledger/reflect artifacts and sets `docs/handoff/<task_id>/phase8-passed.flag`.
The `leadv2-close-ritual-guard.sh` PreToolUse hook will **block** any close-style git commit
(`chore: close <TASK_ID>` etc.) until both `docs/leadv2/closed/<task_id>.yaml` and
`phase8-passed.flag` exist. To bypass in exceptional circumstances: `LEADV2_SKIP_CLOSE_GUARD=1`.

### Step 0a. Emit cost telemetry (before reading)

```bash
source "$(bash .claude/scripts/lv2 --path leadv2-helpers.sh)"
leadv2_emit_costs "$LEADV2_TASK_ID"
# Continue regardless of exit code — costs.yaml absence does not block Close.
```

This writes `docs/handoff/<task-id>/costs.yaml` by parsing `.stream.jsonl` and
Codex log files in the handoff dir. Idempotent: safe to call multiple times.

Then update `docs/leadv2-cost-accuracy.yaml` with real actual_usd:

```bash
bash .claude/scripts/lv2 leadv2-cost-flush.sh "docs/handoff/$LEADV2_TASK_ID"
```

### Step 1. Read cost telemetry

```
Read docs/handoff/<task-id>/costs.yaml
```

If file exists: sum all `cost_usd` fields → `total_cost_usd`. If file missing or unreadable: `total_cost_usd = null` (log warn, continue).

### Step 1b. Scorecard write (FLYWHEEL-01 / G1d — opt-in behind LEADV2_SCORECARD_ON_CLOSE)

```bash
# Guard: absent LEADV2_SCORECARD_ON_CLOSE leaves existing flow byte-identical (D6)
if [ "${LEADV2_SCORECARD_ON_CLOSE:-0}" = "1" ]; then
  bash "$(bash .claude/scripts/lv2 --path leadv2-scorecard-write.sh)" \
    --task-id "$LEADV2_TASK_ID" \
  || true  # non-blocking: scorecard failure never gates Close
fi
```

Called after `docs/leadv2/closed/<task_id>.yaml` is written (Step 1) and costs.yaml is flushed.
Appends one JSONL row to `docs/leadv2/scorecard.jsonl`. Idempotent: safe to call multiple times.
Schema validated against `contracts/leadv2-scorecard.schema.json`; exit 4 on unknown key.

### Step 1c. Graph-reflect footprint (after commit, before lead-reflect)

Invoke `leadv2-graph-reflect` skill:
- Pass `start_sha` from `docs/handoff/<task-id>/context.yaml` (`git.start_sha`)
- Pass `head_sha` = current HEAD after commit

Capture the returned `graph_footprint:` block. Store as `$GRAPH_FOOTPRINT` for injection into Step 2.

If skill fails or MCP is unavailable: set `$GRAPH_FOOTPRINT = null` and continue — do not block Close.

### Step 1d. Learning aggregation (P1-9, 2026-06-09)

If `LEADV2_LEARN_ON_CLOSE=1` AND (task class >= Standard OR tasks closed since last learn-run > 5):

```
Workflow({name:"leadv2-learn", args:{label: LEADV2_TASK_ID, task_class: LEADV2_TASK_CLASS || 'general', ts: new Date().toISOString()}})
```

Write the returned `proposal_path` to `docs/leadv2/last-learn.txt`. Default is `LEADV2_LEARN_ON_CLOSE=0`
(opt-in — adds latency/cost to every close). If the Workflow tool is unavailable or errors: skip silently,
log one pulse line `learn: skipped (<reason>)`. Never block Close on learn.

### Step 2. Lead-reflect entry

Append to `docs/LEAD_V2_STATE.md` under `history:` (rotate entries >20 to `docs/ops/LEAD_HISTORY.md`):

```yaml
history:
  - task: <task-id>
    closed_at: <ISO timestamp Kyiv UTC+2>
    task_cost_usd: <float | null>   # from costs.yaml sum; null if telemetry missing
    reflect:
      almost_missed: "<one sentence>"
      opus_needed_for: "<one sentence>"
      parallel_win: "<one sentence>"
      codex_rounds: <0|1|2>
      pattern_for_immune: "<trigger → action rule>"
    signature:
      # ... (see lead-reflect skill)
    graph_footprint: <$GRAPH_FOOTPRINT block, or omit if null>
    outcome_watch: pending   # set to stable|regression after 48h watch completes
```

See `lead-reflect` skill for guidance on filling each reflect field. Pass `$GRAPH_FOOTPRINT` as context — lead-reflect merges it and applies risk cross-validation.

### Step 2b. Capture learning to ledger

Append ONE line to `docs/leadv2/learnings.md` summarizing the single key learning
from this task (or the literal word `none` if nothing notable):

```bash
LEDGER="docs/leadv2/learnings.md"
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")
DATE=$(date +%Y-%m-%d)
# Replace <learning> with one concrete sentence; use "none" if task had no new insight
printf '| %s | %s | %s | personal |\n' "$DATE" "$REPO" "<learning>" >> "$LEDGER"
```

If the file is missing, create it first with the standard header (see `docs/leadv2/learnings.md`
in persona-engine for the canonical format). Rules:
- Capture is a side-effect of EVERY close — not optional, not skipped on short tasks.
- Default tier is ALWAYS `personal`. Never write `repo` or `plugin` at close time.
- Promotion to repo/plugin tier is a human-initiated review of the ledger, never automated.

### Step 3. Reset state

Update `docs/LEAD_V2_STATE.md`:
```yaml
status: idle
task: ~
phase: ~
step: ~
note: "closed <task-id> at <timestamp>"
active_subsessions: []
```

### Step 4. Persist costs per-session breakdown (if telemetry present)

Log a one-liner to stdout for the founder:
```
[close] <task-id> total cost: $<X.XX> across <N> sessions
```

If `costs.yaml` has individual rows, print them sorted by cost descending (top 3) in the log.

### Step 5. Archive handoff

```bash
# Move handoff dir to docs/ops/handoff-archive/<task-id>/ (optional, skip if dir large)
# Keep context.yaml and costs.yaml accessible for 48h outcome watch
```

### Step 5b. Followup consolidator (inline, all classes ≥ Standard)

Scan unresolved followups across all tasks; if same key repeats ≥3 over 30d, open a consolidated PO task (pending_review, never auto-claimed).

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

Pattern reference: `skills/leadv2-followup-consolidator/SKILL.md`.

### Step 5c. Correction-detect (inline, all classes)

Scan THIS task's chat for founder corrections ("no", "не так", "stop doing X", "это уже было"); classify and write to the **plugin immune store** as structured entries.

Inline rules (no separate skill call required — apply at close, using lead's own knowledge of the conversation):
- If founder said "stop X" or "не делай Y" twice or more → append to `docs/leadv2/immune-patterns.yaml` (source: correction) if no equivalent id exists
- If founder confirmed an unusual choice ("yes exactly", "правильно") → save as validated-pattern immune entry
- Do NOT save the same feedback twice — idempotency is by stable sha1 id of normalised fact text
- **NEVER write to global `MEMORY.md` or individual `memory/feedback_*.md` files** — immune store only

Immune entry schema: `id` (sha1[:12]), `task_origin`, `keywords`, `summary`, `action`, `created`, `seen_count`, `source: correction`, `confidence`.

Pattern reference: `skills/leadv2-correction-detect/SKILL.md` (immune routing updated 2026-06-05).

### Step 6. Schedule outcome-watch at close (Heavy always; Standard+Light via LEADV2_SOAK_EVERY_DEPLOY)

Check `classification.class` from `docs/handoff/<task-id>/context.yaml`.

**Rule (C2.3/D1/D5):**
- `Heavy` class: always schedule outcome-watch (existing behavior — no flag required).
- `Standard` class: schedule ONLY when `LEADV2_SOAK_EVERY_DEPLOY=1` is set.
- `Light` class: never schedule (soak-class-delays.yaml has skip: true for Light).

**Run this concrete shell command** — do not use CronCreate (session-scoped, unreliable):

```bash
TASK_CLASS=$(python3 -c "
import yaml, sys
ctx = yaml.safe_load(open('docs/handoff/${LEADV2_TASK_ID}/context.yaml')) or {}
cls = ctx.get('class') or (ctx.get('classification') or {}).get('class', 'Standard')
print(cls)
" 2>/dev/null || echo "Standard")

# Heavy always schedules; Standard only if LEADV2_SOAK_EVERY_DEPLOY=1
if [[ "$TASK_CLASS" == "Heavy" ]] || { [[ "$TASK_CLASS" == "Standard" ]] && [[ "${LEADV2_SOAK_EVERY_DEPLOY:-0}" == "1" ]]; }; then
  bash .claude/scripts/lv2 leadv2-outcome-watch.sh \
    --schedule \
    --task-id "${LEADV2_TASK_ID}" \
    --deploy-class "${TASK_CLASS}"
fi
```

This writes `docs/leadv2/watches/<task-id>.yaml` with `status: pending`, `due_at`, `deploy_class`,
`delay_hours`, and `min_hours_before_check` populated from `config/soak-class-delays.yaml` (D22).
The sweep runs automatically at every SessionStart via `leadv2-stale-sweeper.sh`, which calls
`leadv2-outcome-watch.sh --sweep`. When due, the sweep executes `.claude/leadv2-overrides/outcome-watch.sh`
(if present) and flips `outcome_watch: pending` → `stable|regression|inconclusive` in `LEAD_V2_STATE.md`.

**Flag-absent invariant (D1):** LEADV2_SOAK_EVERY_DEPLOY unset → Heavy-only (existing behavior).

Note: `leadv2-phase8-close.sh` (the shell executor for Phase 8) already calls this automatically for
Heavy tasks. This step covers the interactive close path and extends it for Standard tasks.

### Step 7. Session-hygiene suggestion (cost discipline)

Long /leadv2 sessions bloat lead history. After a successful Close, emit a **one-line suggestion** to founder based on session state:

```
If messages in lead context > ~150k tokens OR turn count > 40:
  "💡 Session is long ({N} turns). Consider /compact before the next task to reclaim cache room."

If the next queued task is unrelated to the one just closed (different module / surface):
  "💡 Next task is unrelated. Consider /clear — LEAD_V2_STATE.md and handoff/ archives preserve the state."

Otherwise (short session, related next task):
  — no suggestion, proceed silently.
```

Never auto-run `/compact` or `/clear` — only suggest. Founder decides.

Emit the line to chat as the LAST message of Close phase, after cost log. Do NOT write it into `LEAD_V2_STATE.md` (it's ephemeral advice, not state).

### Step 7b. Release task queue item (if task came from QUEUE)

If this task was sourced from the task queue, release the claimed item now.
`TASK_OUTCOME` is set earlier in close to `done` (success path) or `failed` (recovery path).

`LEADV2_PO_LANE` is exported by `leadv2_po_claim` at intake — the release resolves the lane automatically from this env var.

```bash
source "$(bash .claude/scripts/lv2 --path leadv2-helpers.sh)"

if [[ -n "${LEADV2_PO_ITEM_ID:-}" ]]; then
    # Signature: leadv2_po_release <item_id> <status> [<lane>] [<reject_reason>]
    # Lane resolution: $3 → $LEADV2_PO_LANE env → leadv2_po_lane_for_id $1 → error.
    # reject_reason ($4) is only meaningful for failed/rejected/poison statuses.
    # Example for rejected with reason: leadv2_po_release "$ITEM_ID" rejected "" "test reason"
    # leadv2_po_lane_for_id is implemented in leadv2-helpers.sh — greps queue/*.yaml.
    leadv2_po_release "$LEADV2_PO_ITEM_ID" "${TASK_OUTCOME:-done}"
fi
```

- `status=done` → item status=done in lane yaml, closed_at set.
- `status=failed` → claim cleared, attempts++; item returns to pending (or poisoned at max).

If `LEADV2_PO_ITEM_ID` is unset (user-given task or RECOVERY), this is a no-op.

Do NOT skip this step even on error-path close — failure to release leaves the item stuck until lease expiry.

### Step 8. Unregister from active list

After `LEAD_V2_STATE.md` is finalized (Step 3) and history appended (Step 2), remove this task from `docs/leadv2/active.md`:

```bash
source "$(bash .claude/scripts/lv2 --path leadv2-helpers.sh)"
leadv2_active_unregister
```

This is the success signal for external observers: absence from `active.md` means the task closed cleanly. Do NOT call this before Step 3 — an observer seeing the task absent while state is still mid-write would get an inconsistent view.

## Rules

- Never declare Close complete if outcome_watch is required but not scheduled — log WARN and schedule anyway.
- `task_cost_usd: null` is acceptable; never block Close on telemetry parse failure.
- Rotate history before appending (keep at most 20 entries inline).
- The `outcome_watch` field starts as `pending`; the outcome-watch script updates it to `stable` or `regression`.

## Anti-patterns

- Skipping cost read because costs.yaml is small — always sum and log even if $0.00.
- Forgetting outcome-watch for Heavy tasks — that's the only production feedback loop.
- Writing reflect fields with generic text — each must name a specific decision or signal from this task.
