---
name: leadv2-rag-intake
description: "[internal] Phase 0 mini-RAG — cosine-ranks LEAD_V2_STATE history against the new task and surfaces the top-3 most similar past tasks so the lead can reuse prior decisions and avoid repeating known failures."
status: deferred-v0.2
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# leadv2-rag-intake

## When: Phase 0 Intake, immediately after `lead-classify` writes classification to LEAD_V2_STATE.md
## When NOT: mid-build, during Recovery, if task is bare `/leadv2 status` or `/leadv2 help`

---

## Protocol

### 1. Extract task description

Use the task description from one of:
- The founder's explicit prompt text (for `/leadv2 "<text>"`)
- The PO QUEUE item `body` or `title` field (for `/leadv2 next`)
- `LEAD_V2_STATE.md note:` field as fallback

### 2. Set effective history path

```bash
HISTORY_PATH="${LEADV2_HISTORY_PATH:-docs/LEAD_V2_STATE.md}"
EFFECTIVE_HISTORY="$HISTORY_PATH"
```

### 3. Run the script

```bash
bash .claude/scripts/lv2 leadv2-rag-intake.sh \
  --task-description "<task description>" \
  --top-k 3 \
  --history-path "$EFFECTIVE_HISTORY"
```

Capture stdout as `prior_art_yaml`.

Failure modes (all non-fatal — do NOT block intake):
- Script exits non-zero → log warning, treat as cold territory, continue
- Empty output / `[]` → cold territory, continue
- Embedding model not available → script auto-falls back to keyword similarity; still use result

### 4. Write prior-art.yaml

```bash
mkdir -p docs/handoff/<task-id>
```

Write `docs/handoff/<task-id>/prior-art.yaml` with the captured YAML output.

If output is `[]` or empty, write:
```yaml
# cold territory — no past tasks in history yet
[]
```

### 5. Update LEAD_V2_STATE.md current_task block

Add a `prior_art:` field under the current task block.

Format:
```yaml
prior_art: "<N> similar past tasks found (top match: <task_id>, similarity <score>, outcome: <outcome>)"
```

If cold territory (no results or top similarity < 0.6):
```yaml
prior_art: "cold territory — no similar past tasks"
```

### 6. Warn on rolled_back / paused_recovery outcomes

If the top match has `outcome: rolled_back` OR `outcome: paused_recovery` AND similarity >= 0.6:

Append to LEAD_V2_STATE.md current_task note:
```
WARN: Similar task <task_id> failed recently (outcome: <outcome>) — review key_lessons before Plan
```

### 7. Output to lead (chat)

One line, ≤25 words, Russian preferred.

Examples and guidance: see [REFERENCE.md](./REFERENCE.md) §Output examples.

---

## Rules

- **Never block intake on failure.** Wrap the bash call in `|| true`; log to stderr.
- **Similarity threshold for "no prior art":** top match < 0.60 → cold territory. See [REFERENCE.md](./REFERENCE.md) §Thresholds for full mapping.
- **Rolled_back / paused_recovery warn rule:** append WARN to state note.
- **Cold start (history empty):** output `[]`, exit 0, no warning needed.
- **History < 5 entries:** script warns to stderr — that's fine, proceed with what's available.
- **Time budget:** script must complete in <10 seconds for ≤500 history entries.

---

## Next: Feed into Plan phase

When spawning architect / Codex planner mission files, include prior-art.yaml content at top level (details: [REFERENCE.md](./REFERENCE.md) §Feed into Plan).

Only include entries with similarity >= 0.60; omit the section if none qualify.
