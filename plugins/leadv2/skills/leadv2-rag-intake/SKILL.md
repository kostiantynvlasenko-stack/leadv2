---
name: leadv2-rag-intake
description: [internal] Phase 0 mini-RAG: cosine-ranks LEAD_V2_STATE history against new task; surfaces top-3 similar…
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

### 2. Gemini summarize gate (large history)

Before running the script, check if `LEAD_V2_STATE.md` (or the configured
`history_path`) is large enough to warrant summarization:

```bash
HISTORY_PATH="${LEADV2_HISTORY_PATH:-docs/LEAD_V2_STATE.md}"
HISTORY_CHARS=$(wc -c < "$HISTORY_PATH" 2>/dev/null || echo 0)

if [[ "$HISTORY_CHARS" -gt 8000 ]]; then
  # Check if Gemini is available (gate)
  GEMINI_OK=0
  if bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-check.sh" >/dev/null 2>&1; then
    GEMINI_OK=1
  fi

  if [[ "$GEMINI_OK" == "1" ]]; then
    SUMMARY_FILE="$(mktemp /tmp/leadv2-rag-history-summary.XXXXXX)"
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-task.sh" summarize \
      --input-file "$HISTORY_PATH" \
      --prompt "Summarize the completed tasks in this leadv2 state history. For each task include: task_id, outcome, class, and key_lessons (max 2 per task). Output valid YAML list only." \
      --out "$SUMMARY_FILE" || {
        # Fallback: use original file if Gemini fails
        SUMMARY_FILE="$HISTORY_PATH"
      }
    EFFECTIVE_HISTORY="$SUMMARY_FILE"
  else
    # Gemini unavailable — read directly (may be large)
    EFFECTIVE_HISTORY="$HISTORY_PATH"
  fi
else
  EFFECTIVE_HISTORY="$HISTORY_PATH"
fi
```

### 3. Run the script

```bash
bash .claude/scripts/leadv2-rag-intake.sh \
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

One line, ≤25 words, Russian preferred:

Examples:
- Top match ≥ 0.75, outcome success: "Похоже на <task_id> (sim 0.87, успех). Подход: <1-word strategy from key_lessons>."
- Top match ≥ 0.60, outcome rolled_back: "⚠ Похоже на <task_id> (sim 0.73, откат). Разобрать уроки перед планом."
- Top match 0.40–0.59, any outcome: "Слабое совпадение с <task_id> (sim 0.52). Ориентировочно."
- No match or < 0.40: "Новая территория — нет похожих задач."

---

## Thresholds

| Similarity | Treatment |
|---|---|
| ≥ 0.75 | Strong prior art — surface lessons prominently in Plan phase |
| 0.60–0.74 | Moderate — note in prior-art.yaml, mention in Plan |
| 0.40–0.59 | Weak — include in file but label "weak signal" |
| < 0.40 | Cold territory — prior-art.yaml written as `[]` |

---

## Feed into Plan phase

When spawning architect / Codex planner mission files, include prior-art.yaml
content as a top-level section:

```yaml
# In /tmp/mission-<id>.md or docs/handoff/<id>/context.yaml
prior_art:
  - task_id: ...
    similarity: 0.87
    outcome: completed_success
    key_lessons:
      - "when Gate 1 plan bundles commit+deploy into final build step → split explicitly"
```

Only include entries with similarity >= 0.60. If none qualify, omit the section.

---

## Rules

- **Never block intake on failure.** Wrap the bash call in `|| true`; log to stderr.
- **Similarity threshold for "no prior art":** top match < 0.60 → cold territory.
- **Rolled_back / paused_recovery warn rule:** append WARN to state note.
- **Cold start (history empty):** output `[]`, exit 0, no warning needed.
- **History < 5 entries:** script warns to stderr — that's fine, proceed with what's available.
- **Time budget:** script must complete in <10 seconds for ≤500 history entries.

---

## Anti-patterns

- Blocking intake if fastembed is slow on first run (model download). The script exits 0 regardless.
- Reading all of LEAD_V2_STATE.md inline during this step — the script handles parsing.
- Including prior-art entries with similarity < 0.60 in Plan phase mission files.
