---
name: leadv2-correction-detect
description: "[internal] §6.5 of lead-reflect — classify last N user messages as correction/reinforcement/preference/context using haiku; write high-confidence items to candidates.jsonl or immune memory."
allowed-tools:
  - Read
  - Write
  - Bash
---

# leadv2-correction-detect

## When
Called by lead-reflect §6.5 at Phase 8 Close, when `LEADV2_CORRECTION_DETECT != 0`.

## When NOT
- `LEADV2_CORRECTION_DETECT=0` or unset → skip entirely
- Standalone / ad-hoc — always invoked through lead-reflect

---

## §1. Feature flag

```bash
detect_mode="${LEADV2_CORRECTION_DETECT:-0}"
# Values:
#   0        → disabled (skip this skill entirely)
#   shadow   → classify and write to candidates.jsonl only; never write immune memory
#   1        → classify; confidence ≥ 0.8 → write feedback memory; ≥ 0.95+correction → write immune
```

If `detect_mode=0`: exit 0 immediately. No reads, no writes.

---

## §2. Read last N user messages

```bash
N=6   # default window; override via LEADV2_CORRECTION_WINDOW env var
```

Source: the current session transcript (the last N `role: user` messages in chronological order, most-recent first when reading but pass oldest-first to LLM for context).

Implementation note: in Claude Code context, the session transcript is not directly readable as a file. The caller (lead-reflect, running inside the lead's session) must pass the messages as a JSON array argument:

```bash
# Expected call convention from lead-reflect:
# leadv2_correction_detect "$task_id" "$messages_json"
# where messages_json is a JSON array of strings (user message texts, oldest-first)
```

---

## §3. Classification prompt (haiku)

Send the messages array to `claude-haiku-4-5` (or `LEADV2_DETECT_MODEL` env override).

### System prompt

```
You are a message classifier for an AI orchestration system. Classify each user message into one of four categories based on what the user is communicating to the AI assistant.

Categories:
- correction: User is correcting a mistake the AI made (factual error, wrong behavior, wrong output). Signals: "не так", "не делай X", "это неправильно", "stop doing X", "wrong", "incorrect", "you should not", "не нужно", "перестань".
- reinforcement: User is confirming the AI is on the right track. Signals: "да, именно", "продолжай", "отлично", "exactly", "yes", "good", "keep going", "правильно", "верно".
- preference: User is expressing a style/format/workflow preference, not correcting an error. Signals: "мне нравится когда", "prefer", "лучше если", "I like", "always do X instead of Y".
- context: User is providing context, background, or information — not feedback on AI behavior.

Rules:
1. Handle bilingual Russian/English mixed messages naturally.
2. If a message could be correction OR reinforcement depending on interpretation, assign the one with higher evidence, but set confidence lower (≤ 0.7).
3. Low confidence on ambiguous messages — do not force a category.
4. Short acknowledgments ("ok", "хорошо", "понял") are context, confidence ≤ 0.5.
5. "не так" alone = correction with confidence 0.85; "не так, как ты думаешь" = context, confidence 0.5.

Output: a JSON array, one object per message, in input order.
Schema per object:
{
  "category": "correction|reinforcement|preference|context",
  "confidence": 0.00,       // 0.00-1.00, two decimal places
  "source_error": "regex",  // optional: pattern that identifies the error being corrected; null if not applicable
  "fact": "text"            // ≤40 words: the actionable fact or rule being communicated
}
```

### User prompt

```
Classify these {N} user messages (oldest first):

{message_1}
---
{message_2}
---
...
{message_N}
```

---

## §4. Filter by confidence threshold

```python
WRITE_THRESHOLD = 0.8
AUTO_PROMOTE_THRESHOLD = 0.95

candidates = [m for m in classifications if m["confidence"] >= WRITE_THRESHOLD]
# Drop anything below threshold — do not write anywhere
```

---

## §5. Write based on mode

### Shadow mode (`LEADV2_CORRECTION_DETECT=shadow`)

Write ALL candidates (confidence ≥ 0.8) to candidates file. Never write immune memory.

```bash
CANDIDATES_FILE="${CLAUDE_PROJECT_MEMORY_DIR:-$HOME/.claude/projects/$(pwd | tr '/' '-' | sed 's/^-//')/memory}/correction-detect-candidates.jsonl"
```

Each line is a JSON object (JSONL format):

```json
{"task_id": "<task_id>", "ts": "<ISO8601>", "mode": "shadow", "category": "correction", "confidence": 0.91, "source_error": null, "fact": "Never use TaskOutput on background codex/glm jobs.", "message_text": "<original message text>"}
```

Append (do not overwrite). File is rotated when it exceeds 500 lines (keep last 500).

### Live mode (`LEADV2_CORRECTION_DETECT=1`)

For each candidate with confidence ≥ 0.8:
1. Append to candidates.jsonl (same format, `"mode": "live"`)
2. If `category == "correction"` AND `confidence >= 0.95`:
   - Auto-promote: write directly to immune memory (see §6)
3. Else: write to candidates.jsonl only; human review required for promotion

---

## §6. Auto-promote to immune memory

Auto-promote path: `${CLAUDE_PROJECT_MEMORY_DIR:-$HOME/.claude/projects/$(pwd | tr '/' '-' | sed 's/^-//')/memory}/MEMORY.md`

Auto-promote only when ALL of:
- `detect_mode == "1"` (not shadow)
- `category == "correction"`
- `confidence >= 0.95`

Write format — append to the `## Feedback — Tech` section (or `## Feedback — Process` if the correction is process-related):

```markdown
- [<short title derived from fact>](<snake_case_filename>.md) — <fact text> (<task_id> auto-promoted by correction-detect)
```

Also create the individual feedback file at:
`${CLAUDE_PROJECT_MEMORY_DIR:-$HOME/.claude/projects/$(pwd | tr '/' '-' | sed 's/^-//')/memory}/<snake_case_filename>.md`

```markdown
# <Short Title>

<full fact text>

Source: auto-promoted by leadv2-correction-detect from task <task_id> at <ISO ts>. Confidence: <float>.
```

Idempotency check: before writing, grep MEMORY.md for the `fact` text (first 30 chars). If already present, skip.

---

## §7. Return value

Output a JSON summary to stdout (consumed by lead-reflect §6.5 caller):

```json
{
  "messages_read": 6,
  "candidates_found": 2,
  "written_shadow": 2,
  "auto_promoted": 0,
  "skipped_low_confidence": 4
}
```

Exit 0 always — detection errors must not block Phase 8 Close.

---

## §8. Error handling

- LLM call fails (timeout, rate limit): log WARN, return `{"messages_read": N, "candidates_found": 0, "error": "llm_call_failed"}`, exit 0.
- CANDIDATES_FILE directory missing: `mkdir -p` before write.
- JSON parse error from LLM: log raw response to stderr, return empty candidates, exit 0.
- MEMORY.md missing: skip auto-promote, log WARN in return JSON.

---

## §9. Environment variables

| Variable | Default | Description |
|---|---|---|
| `LEADV2_CORRECTION_DETECT` | `0` | `0`=off, `shadow`=candidates-only, `1`=live |
| `LEADV2_CORRECTION_WINDOW` | `6` | Number of last user messages to classify |
| `LEADV2_DETECT_MODEL` | `claude-haiku-4-5` | LLM model for classification |

---

## Rules

- Shadow mode NEVER writes immune memory. Hard rule, no override.
- Confidence < 0.8 → drop silently. Do not write partial results.
- Auto-promote is idempotent: duplicate fact = skip.
- This skill exits 0 even on LLM failure — correction-detect is advisory, never blocking.
- No output to chat — all writes are file-based.
