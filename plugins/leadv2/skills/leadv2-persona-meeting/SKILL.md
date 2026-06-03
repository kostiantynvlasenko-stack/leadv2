---
name: leadv2-persona-meeting
description: "[PE-domain only] Spawns claude-subsession to refresh persona STATE/DIALOGUE/QUEUE. Applies ONLY when: personas/ directory exists at project root AND stack.yaml db == supabase. Skip (no-op) in all other projects."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# Lead v2 Persona Meeting

> **Precondition — skip unless BOTH are true:**
> 1. A `personas/` directory exists at the project root.
> 2. `.claude/leadv2-overrides/stack.yaml` has `db: supabase`.
>
> If either condition is absent: **exit 0 / no-op silently** — do not proceed.
>
> ```bash
> # Guard (run first, before any other step):
> [[ -d "personas" ]] || exit 0
> source "$(bash .claude/scripts/lv2 --path leadv2-helpers.sh)"
> [[ "$(_lv2_stack_scalar db '')" == "supabase" ]] || exit 0
> ```

## When: on staleness trigger during Intake, or `/leadv2 meeting <persona>`.
## When NOT: routine task flow — read STATE.md instead.

## Protocol

### 1. Determine persona + inputs

| Persona | Primary inputs for the meeting |
|---|---|
| product-owner | BOARD HEAD, RECOVERY TRACKER open, past 10 LEAD_V2_STATE history, timbre metrics (if available), last DIALOGUE.md 5 entries |
| architect | context.yaml files from last 10 tasks, current architect/STATE.md, BOARD HEAD, docs/specs/* index |
| strategist | Threads metrics dashboard state, voice-dna.md diff history, past week DIALOGUE.md |

### 2. Compose mission file

Write `/tmp/meeting-<persona>-<date>.md`:

```
Persona meeting: <persona>
Purpose: refresh STATE.md, append DIALOGUE.md, [update docs/tasks.yaml for PO via lib]

Current STATE:
<paste docs/agents/<persona>/STATE.md>

Last 5 DIALOGUE entries:
<paste>

Context inputs:
<paste BOARD HEAD, RECOVERY open, relevant metrics>

Your deliverable — write ALL of these:

1. docs/agents/<persona>/STATE.md — fully rewritten. Keep it ≤100 lines. Sections:
   - Current view: 1-2 paragraphs, what's true right now
   - Priorities: top 3-5 items with rationale
   - Off-limits / decisions made: locked choices (numbered Dn)
   - Open questions for next meeting
   - Last updated: <ISO timestamp>

2. docs/agents/<persona>/DIALOGUE.md — APPEND a new entry:
   ## <ISO timestamp> — Meeting
   - Triggered by: <staleness | user force | recovery | ...>
   - Decided: <3-5 bullet points>
   - Changed in STATE: <what shifted vs last meeting>
   - Follow-ups for lead: <if any>

3. docs/agents/<persona>/LAST_MEETING.md — overwrite with just:
   timestamp: <ISO>
   sessions_since: 0
   triggered_by: <reason>

4. (PO only) Add/update tasks in docs/tasks.yaml via lib — do NOT rewrite QUEUE.md (it is frozen with a redirect banner).
   For each new PO task identified during the meeting:
   ```bash
   source "$(bash .claude/scripts/lv2 --path leadv2-tasks-lib.sh)"
   leadv2_tasks_add "<task-id>" action <priority> \
     --title "<one-sentence mission>" \
     --origin po
   ```
   For tasks that should be blocked-on-human:
   ```bash
   leadv2_tasks_add "<task-id>" human-needed high \
     --title "<what's blocking>" \
     --origin po
   ```
   Keep total new tasks ≤15 per meeting. Anything deferred → note in DIALOGUE.md only.

Constraints:
- No UUIDs, no internal jargon in dialogue (founder-readable).
- Every "decision" must have rationale.
- If you (persona) disagree with prior DIALOGUE entry — note the shift explicitly.
DELIVERABLE_COMPLETE
```

### 3. Spawn claude-subsession

```bash
# Use leadv2-claude-subsession.sh (wraps claude-subsession.sh + enables tool-output compression)
bash .claude/scripts/lv2 leadv2-claude-subsession.sh --role <persona> --model sonnet \
  --task-id meeting-<persona>-<date> \
  --mission-file /tmp/meeting-<persona>-<date>.md \
  --wait
```

Use `--wait` so lead blocks until meeting complete.

### 4. Verify outputs

After subsession exits, verify all 3-4 expected files updated:
```bash
stat -f "%Sm" docs/agents/<persona>/STATE.md                  # should be recent
tail -30 docs/agents/<persona>/DIALOGUE.md                    # new entry present
cat docs/agents/<persona>/LAST_MEETING.md                     # timestamp refreshed
[[ <persona> == "product-owner" ]] && source "$(bash .claude/scripts/lv2 --path leadv2-tasks-lib.sh)" && leadv2_tasks_top_n 5
```

If any missing or stale → flag as incomplete meeting → retry once, else report to founder.

### 5. Update LEAD_V2_STATE

```yaml
personas:
  <persona>:
    last_meeting: <new ISO>
    sessions_since: 0
```

### 6. Propose next (if intake triggered this)

After meeting completes and PO QUEUE refreshed, immediately continue the intake flow — propose top QUEUE item to founder.

## Meeting cadence defaults

| Persona | Auto trigger | Force trigger |
|---|---|---|
| product-owner | >14 days OR >10 sessions | `/leadv2 meeting product-owner` |
| architect | >7 days AND arch keyword match | `/leadv2 meeting architect` |
| strategist | weekly (every 7 days) | `/leadv2 meeting strategist` |

Architect meetings can also be triggered inside a Heavy task before Gate 1 if STATE.md is >7 days old.

## Rules

- **Meeting spawns a real subsession** — not Agent tool. Persona needs its own conversation memory.
- **--wait is mandatory** — lead cannot continue planning until persona has refreshed view.
- **One persona meeting at a time.** No parallel PO + architect meetings — they conflict on priority.
- **Meetings update LAST_MEETING.md even on partial success** — avoid re-triggering same persona multiple times in one session.
- **Meeting output is the persona's view, not lead's.** Lead doesn't rewrite STATE.md post-meeting.

## Anti-patterns

- Re-triggering PO meeting because "its answer I don't like" — that's a scope disagreement, resolve via AskUserQuestion to founder.
- Running architect meeting on Light tasks — overhead not justified.
- Skipping DIALOGUE.md append — loses decision history needed for next meeting's context.
- Including full BOARD in mission file — too many tokens; pass HEAD + relevant items only.
