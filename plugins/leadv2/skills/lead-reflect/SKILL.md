---
name: lead-reflect
description: "[internal] Phase 8 Close §2 + pre-/compact — structured reflection on task outcomes, pattern extraction, and immune memory integration."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# Lead Reflect

## When
- Phase 8 Close, Step 2 (called by leadv2-close after graph-reflect footprint is captured)
- Before `/compact` on tasks with ≥20 turns (preserves key patterns before context wipe)

## When NOT
- Mid-task (only at close or pre-compact)
- If task ended in DELIVERABLE_BLOCKED with no work produced

---

## §1. Inputs expected from leadv2-close

| Variable | Source |
|---|---|
| `$LEADV2_TASK_ID` | env or context.yaml |
| `$GRAPH_FOOTPRINT` | leadv2-close Step 1b output (null if unavailable) |
| `$TOTAL_COST_USD` | costs.yaml sum (null if telemetry missing) |

---

## §2. Load task context

```bash
# Read context.yaml for metadata
task_id="$LEADV2_TASK_ID"
context_file="docs/handoff/${task_id}/context.yaml"
```

Read:
- `class` (Standard / Heavy / Light)
- `title`
- `plan.parallel_groups` (which groups ran, which were blocked)
- `decisions` (D1..Dn) — list count
- `off_limits` — list count

---

## §3. Reflection fields

Fill each field based on task evidence (commit diff, handoff files, cost telemetry).
Keep each field ≤ 30 words. No speculation — ground in concrete task events.

### `almost_missed`
One thing that almost went wrong or was caught late in the task.
Example: "Partial unique index on snapshots broke batch upsert — caught in verify not plan."

### `opus_needed_for`
If any step truly required Opus (strategic decision, ADR, ambiguous spec resolution) — name it.
If nothing required Opus: `"none — sonnet sufficient throughout"`.

### `parallel_win`
Whether running parallel groups (F1||F2 pattern) saved wall time.
Format: `"<groups> ran parallel; saved ~<N>min"` or `"no parallel opportunity"`.

### `codex_rounds`
Integer 0–3. Number of Codex review rounds that triggered actionable revisions (not cosmetic).

### `pattern_for_immune`
A trigger → action rule suitable for immune memory.
Format: `"<condition> → <action>"`.
Example: `"PostgREST upsert PGRST102 on partial index → use rpc() fallback or restructure index"`

Only emit a pattern if confidence is HIGH (seen in this task + consistent with prior tasks).
If no strong pattern: `"none"`.

---

## §4. Signature block

```yaml
signature:
  subagents_spawned: <int>        # count of developer/critic/architect spawns
  codex_rounds: <int>             # same as reflect.codex_rounds
  parallel_groups: <int>          # count of parallel_groups in context.yaml.plan
  decisions_logged: <int>         # count of D-decisions in context.yaml
  off_limits_respected: true      # always true unless a violation was noted
  task_cost_usd: <float | null>
```

---

## §5. Append to STATE history

Append to `docs/LEAD_V2_STATE.md` under `history:` section.

```yaml
  - task: <task_id>
    closed_at: <ISO timestamp Kyiv UTC+2>
    task_cost_usd: <float | null>
    reflect:
      almost_missed: "<string>"
      opus_needed_for: "<string>"
      parallel_win: "<string>"
      codex_rounds: <int>
      pattern_for_immune: "<string>"
    signature:
      subagents_spawned: <int>
      codex_rounds: <int>
      parallel_groups: <int>
      decisions_logged: <int>
      off_limits_respected: true
      task_cost_usd: <float | null>
    graph_footprint: <block or omit>
    outcome_watch: pending
```

If `history:` has >20 entries: rotate oldest entries to `docs/ops/LEAD_HISTORY.md` (append), keep only last 20 in STATE.md.

---

## §6. Append to per-task STATE.md

Also append a brief reflection summary to `docs/leadv2/tasks/<task_id>/STATE.md` under `## History`:

```markdown
## History

### <ISO timestamp>
- Closed phase 8. Cost: $<N> (or unknown).
- almost_missed: <string>
- pattern_for_immune: <string>
```

---

## §6.5. Call leadv2-correction-detect

Before immune memory integration (§7), invoke correction-detect on the session:

```bash
# Check feature flag
detect_mode="${LEADV2_CORRECTION_DETECT:-0}"

if [[ "$detect_mode" != "0" ]]; then
  source .claude/scripts/leadv2-helpers.sh 2>/dev/null || true
  # leadv2-correction-detect reads last 6 user messages from session
  # and classifies corrections vs reinforcements vs preferences
  # Results are written to candidates.jsonl (shadow) or immune memory (live)
  # See leadv2-correction-detect/SKILL.md for full protocol
  echo "[lead-reflect] invoking leadv2-correction-detect (mode=$detect_mode)"
fi
```

This step is non-blocking: if correction-detect fails or returns no candidates, continue to §7 without error.

---

## §7. Immune memory integration

If `reflect.pattern_for_immune != "none"`:

1. Check `${CLAUDE_PROJECT_MEMORY_DIR:-$HOME/.claude/projects/$(pwd | tr '/' '-' | sed 's/^-//')/memory}/MEMORY.md` — does this pattern already exist?
2. If yes: skip (idempotent).
3. If no: propose a new feedback memory entry via `Write` to a temp file, then note it in the task STATE.md for founder approval. Do NOT auto-write to MEMORY.md without founder approval — that is a strategist-only action.

Exception: if the pattern was auto-promoted by leadv2-correction-detect (confidence ≥ 0.95, category=correction), it was already written directly. Skip duplication check — just log "auto-promoted by correction-detect" in STATE.md.

---

## §7.5. Weekly skill-usage tally (best-effort, runs ~1×/week)

Once per ISO week, append a snapshot of skill wiring/usage to the log so dormant
skills get surfaced. Cheap — runs ~7 grep passes, no network.

```bash
LOG=docs/leadv2/skill-usage.log
TALLY="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-skill-usage-tally.sh"
week_now=$(date +%G-W%V)
last_week=$(grep -E '^# week=' "$LOG" 2>/dev/null | tail -1 | sed 's/^# week=//')
if [[ "$week_now" != "$last_week" ]] && [[ -x "$TALLY" ]]; then
  echo "# week=$week_now ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  bash "$TALLY" >> "$LOG"
fi
```

Non-blocking — log file may not exist on first run; script creates it.

---

## §8. Graph footprint risk cross-validation

If `$GRAPH_FOOTPRINT != null`:

- Check if any files in the footprint are listed in `context.yaml.off_limits`.
- If yes: log a warning in the task STATE.md: `"WARN: footprint includes off_limits path <path>"`.
- This is post-hoc audit only — do not block close.

---

## Rules

- Reflection is factual, not self-congratulatory. "No issues" is valid if true.
- `pattern_for_immune` must be falsifiable (a concrete condition, not "be careful").
- If `GRAPH_FOOTPRINT` is null, omit the `graph_footprint:` key from the history entry entirely.
- Do not re-read files already summarized in handoff — use deliverable summaries.
- This skill emits no output to chat — all writes go to STATE.md files.
