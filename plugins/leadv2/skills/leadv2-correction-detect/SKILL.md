---
name: leadv2-correction-detect
description: "[internal] At reflection, classify recent user corrections and update plugin immune patterns; never global memory."
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

## §3. Classify via LLM (haiku)

Send the messages array to `claude-haiku-4-5` (or `LEADV2_DETECT_MODEL` env override).

Output: a JSON array, one object per message, in input order. Schema per object:
```json
{
  "category": "correction|reinforcement|preference|context",
  "confidence": 0.00,
  "source_error": "regex",
  "fact": "text"
}
```

For the full classification system prompt (all four categories, disambiguation rules, worked examples) and the user-prompt template, see [PROMPT.md](./PROMPT.md).

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
# Default: docs/leadv2/correction-detect-candidates.jsonl in project root
# Override: LEADV2_CANDIDATES_FILE env var
CANDIDATES_FILE="${LEADV2_CANDIDATES_FILE:-$(git rev-parse --show-toplevel)/docs/leadv2/correction-detect-candidates.jsonl}"
```

Append (do not overwrite). File is rotated when it exceeds 500 lines (keep last 500). Line format (JSONL): see [SCHEMAS.md](./SCHEMAS.md#candidates-jsonl-line).

### Live mode (`LEADV2_CORRECTION_DETECT=1`)

For each candidate with confidence ≥ 0.8:
1. Append to candidates.jsonl (same format, `"mode": "live"`)
2. If `category == "correction"` AND `confidence >= 0.95`:
   - Auto-promote: write directly to immune memory (see §6)
3. Else: write to candidates.jsonl only; human review required for promotion

---

## §6. Auto-promote to plugin immune store

**Target: `docs/leadv2/immune-patterns.yaml`** (the plugin immune store).
Global `MEMORY.md` is NEVER written by this skill.

Auto-promote only when ALL of:
- `detect_mode == "1"` (not shadow)
- `category == "correction"`
- `confidence >= 0.95`

Entry schema (matches `scripts/leadv2-immune-aggregate.py`) and idempotency rule (stable `id` = sha1 of normalised fact — duplicate → increment `seen_count` only): see [SCHEMAS.md](./SCHEMAS.md#immune-store-entry).

Override store path: `LEADV2_IMMUNE_STORE` env var.
Override candidates path: `LEADV2_CANDIDATES_FILE` env var.

---

## §7. Return value

Output a JSON summary to stdout (consumed by lead-reflect §6.5 caller). Fields: `messages_read`, `candidates_found`, `written_shadow`, `auto_promoted`, `skipped_low_confidence`. Full example: see [SCHEMAS.md](./SCHEMAS.md#return-value).

Exit 0 always — detection errors must not block Phase 8 Close.

---

## §8. Error handling

Every failure mode (LLM call fails, CANDIDATES_FILE dir missing, JSON parse error, MEMORY.md missing) degrades to a WARN + exit 0 — never blocks Phase 8 Close. Full per-case table: see [REFERENCE.md](./REFERENCE.md#error-handling).

---

## §9. Environment variables

`LEADV2_CORRECTION_DETECT` (default `0`) is the main gate. Full table of all five vars (defaults + descriptions): see [REFERENCE.md](./REFERENCE.md#environment-variables).

---

## Rules

- Shadow mode NEVER writes immune memory. Hard rule, no override.
- Confidence < 0.8 → drop silently. Do not write partial results.
- Auto-promote is idempotent: duplicate fact = skip.
- This skill exits 0 even on LLM failure — correction-detect is advisory, never blocking.
- No output to chat — all writes are file-based.
- **[BROKEN-SIGNAL-GATE] handling:** When `[BROKEN-SIGNAL-GATE]` appears in session context (injected by the `leadv2-broken-signal-gate.sh` UserPromptSubmit hook), immediately invoke Phase 0 Intake with a new `TASK_ID`. Log the old task_id as `superseded_by: <old_task_id>` in `docs/leadv2/active.yaml`. Do NOT resume the previous task's work.
