# Schemas (§5-§7 detail)

Exact record/line formats referenced from SKILL.md.

## Candidates JSONL line

Each line is a JSON object (JSONL format), written in both shadow and live mode
(`"mode"` field distinguishes them):

```json
{"task_id": "<task_id>", "ts": "<ISO8601>", "mode": "shadow", "category": "correction", "confidence": 0.91, "source_error": null, "fact": "Never use TaskOutput on background codex/glm jobs.", "message_text": "<original message text>"}
```

Live mode writes the same shape with `"mode": "live"`.

## Immune store entry

Target: `docs/leadv2/immune-patterns.yaml`. Entry schema (matches
`scripts/leadv2-immune-aggregate.py`):

```yaml
- id: <sha1[:12] of normalised fact text>
  task_origin: <task_id>
  keywords: [correction, ...]   # auto-tagged from fact text
  summary: <first sentence of fact, ≤100 chars>
  action: <second sentence or "Check: <summary>", ≤200 chars>
  created: <YYYY-MM-DD>
  seen_count: 1
  source: correction            # marks auto-promoted corrections
  confidence: 0.95              # classifier confidence
```

Idempotency: stable `id` (sha1 of normalised fact) — if already present, increment
`seen_count` only. No duplicates.

## Return value

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
