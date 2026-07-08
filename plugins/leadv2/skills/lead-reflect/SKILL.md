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

## §4.5. Causal critique (GEPA-style, gated) — LEADV2_CAUSAL_CRITIQUE

Runs BEFORE §5a (reflect-history.yaml write) so its output can be folded into the entry.
Default OFF — flag unset or `0`, OR task_class is Trivial/Light -> skip entirely: do not invoke
the Workflow tool, no tempfile is written, and the §5a entry is byte-identical to today.
Never blocks close: any error/exception/unavailable-tool result is treated as skip.

```bash
critique_flag="${LEADV2_CAUSAL_CRITIQUE:-0}"
task_class_cc="${task_class:-Standard}"   # from context.yaml .class (§2)
cc_tmp_path="docs/handoff/${LEADV2_TASK_ID}/.causal-critique.json.tmp"  # read by §5a below
```

If `critique_flag != "0"` AND `task_class_cc` is NOT `Trivial`/`Light`:

```
Workflow({name:"leadv2-causal-critique", args:{task_id: LEADV2_TASK_ID, task_class: task_class_cc}})
```

- If the Workflow tool is unavailable, throws, or returns null: log one pulse line
  `causal-critique: skipped (<reason>)` and DO NOT write `cc_tmp_path` -- continue to §5a, which
  treats a missing file identically to the flag being off.
- On success: write `JSON.stringify(result.causal_critique)` to `cc_tmp_path` using the **Write
  tool** (`Write({file_path: cc_tmp_path, content: JSON.stringify(result.causal_critique)})`) --
  **NEVER** a shell redirect, `printf`, or heredoc splice. This is the fix for
  REFLECT-CAUSAL-CRITIQUE-01 fix-round-2 C1: `causal_critique` is LLM-derived text quoting raw
  digest content (git-diff/ledger/review-signature excerpts) and MUST NOT be embedded as literal
  source text inside any shell/Python command string -- a triple-quote or backtick/`$(...)`
  sequence inside that text would otherwise break the enclosing quoting and either corrupt the
  whole reflect-history write or execute as code. The `Write` tool takes `content` as inert data,
  never interpolated into a command line, so this is safe regardless of what the critique text
  contains. A critique that filtered out every driver (`root_drivers: []`) is still a valid
  result -- write it as-is, it is not the same as a skip.
- If `result.freeform_insight` is non-null it has ALREADY been appended to
  `docs/leadv2/freeform-insights.jsonl` by the workflow (atomic line-append, `status:"candidate"`)
  -- nothing further to do here; do not duplicate the write.

If `critique_flag == "0"` or `task_class_cc` is Trivial/Light: skip entirely -- no tempfile is
written and §5a's entry omits the `causal_critique:` key exactly as it does today.

---

## §5. Append to STATE history and reflect-history.yaml

### §5a. Append structured entry to `docs/leadv2/reflect-history.yaml` (canonical machine record)

This is the primary machine-readable record consumed by phase8-assert A4
and force-reflect. Write it FIRST, before the human board line.

```bash
REFLECT_HISTORY="docs/leadv2/reflect-history.yaml"

# Build the YAML entry (use python3 for safe multiline quoting)
python3 - <<PYEOF
import yaml, datetime, os, json

entry = {
    "task": "${task_id}",
    "closed_at": datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=2))).isoformat(timespec='minutes'),
    "reflect": {
        "almost_missed": "${almost_missed}",
        "opus_needed_for": "${opus_needed_for}",
        "parallel_win": "${parallel_win}",
        "codex_rounds": ${codex_rounds},
        "pattern_for_immune": "${pattern_for_immune}",
        "fix_quality": "${fix_quality}",
    },
    "signature": {
        "phase": "${phase}",
        "task_class": "${task_class}",
        "failure_class": "${failure_class}",
        "recovery_decision": "${recovery_decision}",
        "outcome": "${outcome}",
        "involved_agents": ${involved_agents_json},
        "change_kind": "${change_kind}",
    },
}

# Section 4.5 LEADV2_CAUSAL_CRITIQUE (gated, default off): fold in only if §4.5 actually wrote
# the tempfile. Missing file (flag off / Trivial-Light / skip / error) -> omit the key entirely,
# so the entry is byte-identical to pre-REFLECT-CAUSAL-CRITIQUE-01 behavior.
#
# fix-round-2 C1: causal_critique content is READ from a file (data), never spliced as literal
# source text into this heredoc -- §4.5 writes it via the Write tool (inert `content` parameter,
# never interpolated into a shell/Python command string). This whole block is additionally
# wrapped in try/except so a bad/missing/malformed tempfile can NEVER abort the reflect-history
# write (matches the "never blocks close" guarantee for every other step in this file).
try:
    cc_tmp_path = "docs/handoff/${task_id}/.causal-critique.json.tmp"
    causal_critique_json = ""
    try:
        with open(cc_tmp_path, encoding="utf-8") as fh:
            causal_critique_json = fh.read()
    except FileNotFoundError:
        causal_critique_json = ""
    if causal_critique_json.strip():
        entry["causal_critique"] = json.loads(causal_critique_json)
        try:
            os.remove(cc_tmp_path)  # best-effort cleanup, never fatal
        except OSError:
            pass
except Exception:
    pass  # malformed/unreadable tempfile -- never blocks the reflect-history write

path = "${REFLECT_HISTORY}"
try:
    with open(path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
except FileNotFoundError:
    data = {}

entries = data.get("entries") or []
entries.append(entry)
data["entries"] = entries

# Atomic write: write to tmp, then rename
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    yaml.dump(data, fh, allow_unicode=True, default_flow_style=False, sort_keys=False)
os.replace(tmp, path)
print(f"[lead-reflect] reflect-history.yaml updated: {len(entries)} entries")
PYEOF
```

Shell variable substitution applies — fill in the reflect field values from §3/§4 before running.

### §5c. Write knowledge archive entry to `docs/leadv2/knowledge/<NN>_<task-slug>.md`

One grep-able entry per completed task. Written ONCE at close — do not overwrite if already exists.

```bash
KNOWLEDGE_DIR="${CWD}/docs/leadv2/knowledge"
mkdir -p "$KNOWLEDGE_DIR"

python3 - <<PYEOF
import os, re, datetime

knowledge_dir = "${KNOWLEDGE_DIR}"
task_id       = "${task_id}"

# Derive slug from task_id (lower, alphanum+hyphen, max 40 chars)
slug = re.sub(r'[^a-z0-9-]', '-', task_id.lower())[:40].strip('-')

# Next sequence number (NN = max existing + 1, zero-padded to 2 digits)
existing = [f for f in os.listdir(knowledge_dir) if re.match(r'^\d+_', f)]
nn = max((int(re.match(r'^(\d+)_', f).group(1)) for f in existing), default=0) + 1
filename = os.path.join(knowledge_dir, f"{nn:02d}_{slug}.md")

if os.path.exists(filename):
    print(f"[lead-reflect] knowledge entry already exists: {filename}")
else:
    # Pull decisions from context.yaml
    import yaml
    ctx = {}
    ctx_path = f"docs/handoff/${task_id}/context.yaml"
    try:
        with open(ctx_path) as fh:
            ctx = yaml.safe_load(fh) or {}
    except FileNotFoundError:
        pass

    decisions_raw = ctx.get("decisions") or []
    decisions_md  = "\n".join(f"- {d}" for d in decisions_raw) if decisions_raw else "- (none recorded)"
    title         = ctx.get("title") or task_id
    closed_at     = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=2))).strftime("%Y-%m-%d")

    content = f"""# {nn:02d} {slug}

**Task:** {title}
**Closed:** {closed_at}

## Decisions
{decisions_md}

## Gotchas
- {("${almost_missed}" or "(none)").strip()}

## Pattern
`{("${pattern_for_immune}" or "none").strip()}`
"""
    with open(filename, "w") as fh:
        fh.write(content)
    print(f"[lead-reflect] knowledge archive entry written: {filename}")
PYEOF
```

Shell variable substitution applies — `${almost_missed}` and `${pattern_for_immune}` must be set from §3 before running.

---

### §5b. Append human board line to `docs/LEAD_V2_STATE.md` under `history:` section

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

After BOTH writes are complete, mark reflect as done so the Stop-hook force-reflect guard (`leadv2-force-reflect.sh`) does not re-fire:

```bash
for d in "docs/handoff/${LEADV2_TASK_ID}" "docs/leadv2/tasks/${LEADV2_TASK_ID}"; do
  [[ -d "$d" ]] && touch "$d/reflect-done.flag"
done
```

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
  source "$(bash .claude/scripts/lv2 --path leadv2-helpers.sh)" 2>/dev/null || true
  # leadv2-correction-detect reads last 6 user messages from session
  # and classifies corrections vs reinforcements vs preferences
  # Results are written to immune memory (live)
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
week_now=$(date +%G-W%V)
last_week=$(grep -E '^# week=' "$LOG" 2>/dev/null | tail -1 | sed 's/^# week=//')
if [[ "$week_now" != "$last_week" ]]; then
  echo "# week=$week_now ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  bash .claude/scripts/lv2 leadv2-skill-usage-tally.sh >> "$LOG"
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
