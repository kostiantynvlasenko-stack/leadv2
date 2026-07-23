---
name: leadv2-founder-input
description: "[internal] Composes structured decision file and waits for founder choice."
allowed-tools:
  - Read
  - Write
  - Bash
---

# Lead v2 — Founder Input

## TIER CLASSIFIER (check FIRST before anything else)

### Tier definitions

**Tier A — silent auto-decide** (no notification, no wait):
- File choice, function-signature variation, test variant, code-style preference
- Retry vs single-failed probe (retry first)
- Phase re-ordering for efficiency
- Any choice where past history shows high-consistency outcome (>80% of similar decisions resolved the same way)
- Plan phase consensus: if architect + Codex + critic all converge → no Gate 1 ask

**Tier B — default-timeout** (notify + auto-apply in 10 min if no founder response):
- Recovery strategy when retry budget partially used (retry vs rollback)
- Coverage 40–60% (borderline)
- Risk score = medium with graph footprint orphans
- Classification at Light/Standard boundary

**Tier C — mandatory founder confirm** (blocks indefinitely, no auto-apply):
- Truly irreversible: data deletion, destructive migration without rollback
- Invariant conflict: bypassing safety gate, writing to prod without Supabase-as-truth
- Strategic trade-off: product direction change, cross-persona policy shift
- First-time unfamiliar pattern (no RAG intake similar match ≥ 0.60)

### Classifier rules (apply in order)

1. Is choice explicitly on "invariant list" (CLAUDE.md non-negotiables)? → **Tier C**
2. Does choice modify production data irreversibly without rollback path? → **Tier C**
3. Is this first-time pattern (RAG intake similarity < 0.60)? → **Tier C**
4. Does choice involve recovery retry budget ≥ 50% used? → **Tier B**
5. Is borderline metric (coverage 40–60%, risk medium)? → **Tier B**
6. Else → **Tier A**

---

## When to trigger founder-input protocol

Invoke this skill (do not self-resolve) when:

1. Recovery has exhausted 2 retry rounds without success
2. An off-limits warning fires (not a hard block — defer to founder)
3. Coverage gate < 50% with no auto-fix path available
4. Plan-review disagreement that lead cannot arbitrate internally

## When NOT to trigger

- First verify failure (use `leadv2-recovery` first)
- Routine blocked tasks (use `skip_task` path in queue)
- Any case where an auto-path exists and is within bounds
- Tier A decisions (auto-decide silently, log to autonomous-decisions section)

---

## Protocol

### Step 0 — Classify tier

Run the tier classifier above. Then:

- **Tier A** → go to Step 0-A (silent auto-decide)
- **Tier B** → go to Step 1 (compose file) then Step 2 (notify) then Step 3b-timeout
- **Tier C** → go to Step 1 (compose file) then Step 2 (notify) then Step 3a (blocking wait)

### Step 0-A — Tier A: silent auto-decide

1. Write decision to `docs/leadv2-decisions/<id>.yaml` with `status: auto-decided`, `answer.selected` = `recommended`.
2. Append to `docs/LEAD_V2_STATUS.md` under `## Recent autonomous decisions (last 10)`:

```
| <ISO-time> | <task-id> | A | "<chosen option label>" | "<reasoning one line>" |
```

3. Rotate table if > 50 rows: move oldest rows to `_resolved/auto-decisions-<YYYYMMDD>.md`.
4. Continue task — no notification.

---

### Step 1 — Compose the decision file

Create `docs/leadv2-decisions/<YYYY-MM-DDThh-mm-ssZ>-<task-id>.yaml`.

For the full YAML schema (all fields, all option entries) and the `fix_quality` semantics, see [SCHEMAS.md](./SCHEMAS.md).

Write atomically: write to `<file>.tmp` then `os.replace()` / `mv`.

Decision file name format: `YYYY-MM-DDThh-mm-ssZ-<task-id>.yaml` (colons replaced with dashes).

### Step 2 — PushNotification

Send a `PushNotification` with:
- Subject: `[/leadv2] Decision needed: <task-id> (Tier <tier>)`
- Body (≤160 chars): the question + top 2 option labels + recommended + file path

### Step 3a — Tier C: blocking wait

**Interactive mode** (not daemon):

1. Monitor the decision file for `status: answered` — poll every 10s, timeout 30 min
2. At 15 min without answer: send a second `PushNotification` reminder
3. If 30 min expires without answer: fall back to `AskUserQuestion` directly (user is live — get synchronous input)
4. Once answered: read `answer.selected` and `answer.action`, apply inline, continue task
5. **No auto-apply for Tier C.** Wait indefinitely; no timeout fallback.

For the poll-loop bash implementation, see [EXAMPLES.md](./EXAMPLES.md).

**Daemon mode** (`LEADV2_DAEMON=1`):

1. Write the decision file (Step 1)
2. Send `PushNotification` (Step 2)
3. Return immediately — daemon's `check_answered_decisions` function will pick it up on next poll
4. **No auto-apply.** Wait indefinitely for founder.

For the daemon's escalation re-ping cadence while paused, see [REFERENCE.md](./REFERENCE.md).

### Step 3b — Tier B: default-timeout (10 min auto-apply)

1. Write decision file with `escalation.auto_apply_at: <now + 10 min ISO>`.
2. Send `PushNotification` (Step 2) — include "auto-apply in 10 min if no response".
3. Poll decision file every 30s for up to 10 min.
4. If founder responds via `leadv2-decide.sh` before timeout → apply chosen option.
5. If timeout expires with no answer:
   - Set `status: auto-applied-default`, `answer.selected` = `recommended`, `answer.selected_at` = now.
   - Apply the recommended action.
   - Append to `docs/LEAD_V2_STATUS.md` autonomous-decisions table (Tier B row).
   - Send `PushNotification`: "auto-applied: <recommended option label> for <task-id>"

---

## Applying the answer

| `action` value | What to do |
|---|---|
| `retry_task` | Clear `paused`, reset consecutive_failures=0, re-run the task |
| `skip_task` | Mark task as `blocked` via lib, resume normal flow:<br>`source "$(bash .claude/scripts/lv2 --path leadv2-tasks-lib.sh)" && leadv2_tasks_update <id> --key status --value blocked` |
| `pause_indefinite` | Keep paused, wait for `leadv2-daemon.sh --resume` |
| `rollback_and_investigate` | Call `leadv2-rollback.sh --yes`, open recovery task via lib (replaces former QUEUE.md append):<br>`source "$(bash .claude/scripts/lv2 --path leadv2-tasks-lib.sh)" && leadv2_tasks_add "RECOVERY-<id>" recovery high --title "investigate rollback: <id>" --origin founder`, then resume |

After applying: move the decision file to `docs/leadv2-decisions/_resolved/<YYYYMMDD>/<id>.yaml`.

---

## Quality gates

- Decision file must be valid YAML before sending PushNotification
- `recommended` field is REQUIRED in every decision yaml — missing → treat as Tier B (conservative)
- `fix_quality` tag REQUIRED per option — missing → treat option as `band-aid` (conservative)
- `tier` field REQUIRED in every decision yaml
- Never create more than one pending decision per task_id
- Never block indefinitely without emitting a decision file — the founder must always have a path forward
- `--resume` hard-override always clears paused regardless of pending decisions (do not block it)
- Silent-decision log in LEAD_V2_STATUS is append-only (rotated when > 50 entries)
