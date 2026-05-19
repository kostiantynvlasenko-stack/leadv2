---
name: leadv2-causal-graph
description: [internal] Links RECOVERY- tasks to root cause via git blame + time proximity; feeds counterfactual…
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# Lead v2 Causal Graph — Incident Causality Linking

## When: (a) recovery skill starts RECOVERY- task, (b) outcome-watch detects regression, (c) CLI --regression-task flag
## When NOT: Light tasks, docs-only changes, tasks with no code diff

---

## Protocol

### Step 1 — Gather the failing task's footprint

Read `docs/handoff/<effect-task-id>/context.yaml`:
- `graph_footprint.modified_symbols` — list of fully-qualified symbol names changed
- `graph_footprint.changed_files` — list of files changed (if present)
- `classification.scope.surfaces` — affected subsystems

If `graph_footprint` is absent, use `docs/handoff/<effect-task-id>/diff.md` to extract
changed file paths manually.

### Step 2 — Find candidate commits on those files

For each changed file, run:
```bash
git log --since="14 days ago" --oneline --follow -- <file>
```

Extract commit hashes and task-id references from commit messages:
- Commit message format: `feat: <description> [Task-Id: NIK-42]` or `platform: NIK-42 — <description>`
- Regex: `[A-Z]+-\d+` in subject line or `Task-Id:` trailer

Collect candidate `(commit_hash, task_id, age_days, files_changed)` tuples.
Deduplicate by `task_id` (earliest commit per task).

### Step 3 — Compute blame overlap

For each candidate task, run git blame on the changed files as of the effect task's deploy commit:
```bash
git blame --porcelain <file> | grep "^[0-9a-f]\{40\}" | awk '{print $1}' | sort | uniq -c
```

Cross-reference commit hashes from step 2 with blame output to get:
```
blame_overlap_lines = count of lines in changed functions authored by candidate's commits
total_lines_in_changed_functions = total lines in those same functions
blame_overlap_pct = (blame_overlap_lines / total_lines_in_changed_functions) * 100
```

**Rename handling:** use `git log --follow` to track files across renames. If a file was
renamed between the candidate commit and the effect task, adjust blame reference accordingly.

### Step 4 — Compute temporal proximity weight

```
temporal_days = age_days of candidate commit (days before effect task's deploy)
temporal_proximity_weight = max(0, 1.0 - (temporal_days / 14))
# linear decay: commit today = 1.0, commit 14 days ago = 0.0, older = clamped to 0
```

### Step 5 — Score and select cause

For each candidate:
```
causality_score = (blame_overlap_pct / 100) * 0.7 + temporal_proximity_weight * 0.3
```

Pick the candidate with `causality_score >= 0.3` (tunable via `CAUSAL_THRESHOLD` env var,
default 0.3). If no candidate meets threshold → result is `cause_unknown`.

**Failure is non-blocking:** if git blame fails (shallow clone, binary file, no commits) →
log warning and continue with `cause_unknown`. Never block recovery on causal lookup failure.

### Step 6 — Write to causal log

Append to `docs/leadv2-causal-log.yaml` (create if absent, file is append-only):

```yaml
- timestamp: <ISO UTC>
  effect_task: <RECOVERY-XX or REGRESSION-XX>
  cause_task: <NIK-XX or null if cause_unknown>
  causality_score: <float, 2dp>
  blame_overlap_pct: <int>
  temporal_days: <int>
  mechanism: "<cause task> modified <symbol/file>; <effect task> caught <error type> in same location"
  impact_window: t+<N>h   # hours between cause deploy and effect detection
  counterfactual_note: "If <cause task> had <what fix>, <effect task> would not have occurred"
  cause_unknown: false   # set true when no candidate met threshold
```

If `cause_unknown: true`, still append the entry with null `cause_task` for audit trail.

### Step 7 — Return cause context

Return a structured result for injection into recovery/reflect:

```yaml
caused_by:
  task_id: <cause_task or null>
  causality_score: <float>
  detected_at: <Nh post-original-deploy>
  lesson: "<one-sentence mechanism — what the cause task did that created the failure condition>"
  cause_unknown: <bool>
```

---

## CLI Usage

```bash
# Analyze a specific regression task
.claude/scripts/leadv2-causal-analyze.sh --regression-task <task-id>

# Show last 10 causal links (for leadv2-status.sh --causal-log)
grep -A9 '- timestamp:' docs/leadv2-causal-log.yaml | head -100
```

---

## Thresholds (tunable)

| Parameter | Default | Override |
|---|---|---|
| `CAUSAL_THRESHOLD` | 0.3 | env var |
| `GIT_LOOKBACK_DAYS` | 14 | env var |
| `BLAME_WEIGHT` | 0.7 | hardcoded |
| `TEMPORAL_WEIGHT` | 0.3 | hardcoded |

---

## Rules

- Append-only causal log — never modify or delete existing entries.
- `cause_unknown` entries still get written — absence of evidence is itself evidence.
- Git blame runs against the effect task's deploy commit, not HEAD — avoids confusion from subsequent changes.
- Handle renames with `git log --follow`; log a warning if rename detection fails.
- Causal lookup must complete within 60 seconds — set `git` timeout; on timeout write `cause_unknown`.
- Score threshold 0.3 is intentionally low — false positives are labeled, false negatives are worse.

## Anti-patterns

- Blocking recovery on causal lookup failure — causal linking is enrichment, not a gate.
- Running blame against HEAD instead of the effect task's deploy commit — produces wrong attribution.
- Skipping `cause_unknown: true` entries — absence of a known cause is still worth logging.
- Deleting or overwriting existing log entries — the log is an audit trail.
