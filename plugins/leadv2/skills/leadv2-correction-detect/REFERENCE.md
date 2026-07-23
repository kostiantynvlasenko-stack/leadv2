# Reference (§8-§9 detail)

## Error handling

- LLM call fails (timeout, rate limit): log WARN, return `{"messages_read": N, "candidates_found": 0, "error": "llm_call_failed"}`, exit 0.
- CANDIDATES_FILE directory missing: `mkdir -p` before write.
- JSON parse error from LLM: log raw response to stderr, return empty candidates, exit 0.
- MEMORY.md missing: skip auto-promote, log WARN in return JSON.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `LEADV2_CORRECTION_DETECT` | `0` | `0`=off, `shadow`=candidates-only, `1`=live |
| `LEADV2_CORRECTION_WINDOW` | `6` | Number of last user messages to classify |
| `LEADV2_DETECT_MODEL` | `claude-haiku-4-5` | LLM model for classification |
| `LEADV2_CANDIDATES_FILE` | `docs/leadv2/correction-detect-candidates.jsonl` | Override path for the candidates JSONL file |
| `LEADV2_IMMUNE_STORE` | `docs/leadv2/immune-patterns.yaml` | Override path for the plugin immune store |
