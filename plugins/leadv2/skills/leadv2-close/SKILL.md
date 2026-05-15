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

## Protocol

### Step 0. Emit cost telemetry (NEW — before reading)

```bash
source .claude/scripts/leadv2-helpers.sh
leadv2_emit_costs "$LEADV2_TASK_ID"
# Continue regardless of exit code — costs.yaml absence does not block Close.
```

This writes `docs/handoff/<task-id>/costs.yaml` by parsing `.stream.jsonl` and
Codex log files in the handoff dir. Idempotent: safe to call multiple times.

Then update `docs/leadv2-cost-accuracy.yaml` with real actual_usd:

```bash
bash .claude/scripts/leadv2-cost-flush.sh "docs/handoff/$LEADV2_TASK_ID"
```

### Step 1. Read cost telemetry

```
Read docs/handoff/<task-id>/costs.yaml
```

If file exists: sum all `cost_usd` fields → `total_cost_usd`. If file missing or unreadable: `total_cost_usd = null` (log warn, continue).

### Step 1b. Graph-reflect footprint (after commit, before lead-reflect)

Invoke `leadv2-graph-reflect` skill:
- Pass `start_sha` from `docs/handoff/<task-id>/context.yaml` (`git.start_sha`)
- Pass `head_sha` = current HEAD after commit

Capture the returned `graph_footprint:` block. Store as `$GRAPH_FOOTPRINT` for injection into Step 2.

If skill fails or MCP is unavailable: set `$GRAPH_FOOTPRINT = null` and continue — do not block Close.

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

### Step 6. For Heavy tasks (or any task that touched runtime) — schedule outcome-watch at +48h

Check `classification.class` from `docs/handoff/<task-id>/context.yaml`.

If class is `Heavy` or `Standard` (touched runtime files):

1. Record the deploy timestamp (`deploy_ts`) — use `context.yaml.verification.confirmed_at` or now().

2. Schedule via CronCreate (session-level cron, fires once):

```
CronCreate(
  cron="<M> <H> <D> <month> *",   # compute deploy_ts + 48h → cron fields
  prompt="/leadv2 outcome-check <task-id>",
  recurring=false
)
```

3. Also write a durable fallback comment to `docs/handoff/<task-id>/outcome-watch.sh` for founder to optionally register in crontab:

```bash
#!/usr/bin/env bash
# Durable fallback — register in crontab if CronCreate was session-scoped:
# <M> <H> * * *  /path/to/.claude/scripts/leadv2-outcome-watch.sh \
#   --task-id <task-id> \
#   --config docs/handoff/<task-id>/outcome-watch-config.yaml \
#   --deploy-ts <deploy_ts>
```

See `.claude/skills/leadv2-outcome-watch/SKILL.md` for the full outcome-watch protocol.

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
source .claude/scripts/leadv2-helpers.sh

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
source .claude/scripts/leadv2-helpers.sh
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
