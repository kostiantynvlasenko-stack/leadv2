# Loop Detection — Extended Reference

## Thresholds

| Threshold | Env var | Default | Action |
|-----------|---------|---------|--------|
| Warn at   | `LEADV2_LOOP_WARN_AT` | 3 | Prepend `[LOOP-WARNING]` to next reasoning step |
| Hard block | `LEADV2_LOOP_HARD_AT` | 5 | Emit `DELIVERABLE_BLOCKED: loop detected — <reason>` and stop |
| Per-tool warn | `LEADV2_TOOL_FREQ_WARN` | 30 | Same tool type used ≥30 times → warn |
| Per-tool block | `LEADV2_TOOL_HARD_LIMIT` | 50 | Same tool type used ≥50 times → block |

All thresholds are tunable via environment variables. Defaults are conservative
to avoid false positives on legitimately long sessions.

## Canonicalization rules

The hash key is `tool_name + ":" + canonical_args_json`. Canonical form applies these transformations:

1. **Absolute worktree prefix stripped** to relative path (e.g.
   `/Users/.../worktrees/TASK-01/platform/foo.py` → `platform/foo.py`)
2. **Read args**: `limit` is dropped (cosmetic). `offset` is retained so reads
   at different offsets produce distinct hashes — paging the same file is not a
   loop, it's progress
3. **Tmp paths**: `/tmp/leadv2-${TASK_ID}-*` normalized to
   `/tmp/leadv2-TASKID-PLACEHOLDER`
4. **Timestamps/datetimes**: ISO-8601 patterns and Unix epoch integers
   replaced with `TIMESTAMP_PLACEHOLDER`
5. **Edit/Write loop**: same `file_path` + same `old_string` → same hash.
   Different `old_string` on same file → different hash (CLEAR)
6. **Bash commands**: full command string after stripping leading whitespace
   (no further reduction — minor flag differences are intentional variations)

The goal is to eliminate cosmetic differences (timestamps, offsets between
different pages) while preserving intentional retries and variations.

## State file

Per-session state lives at `/tmp/leadv2-loop-detect-${session_id}.json`.

Structure:
```json
{
  "window": ["hash1", "hash2", ...],
  "tool_counts": {"Bash": 12, "Read": 5},
  "hash_counts": {"<hash>": 3}
}
```

- `window` — sliding window of the last N=10 tool-call hashes in order
- `tool_counts` — frequency of each tool type (used to check per-tool limits)
- `hash_counts` — how many times each unique hash has appeared (used to detect repeats)

File is locked with `flock -x` on every read+write cycle to handle concurrent
access from parallel subagents sharing a session ID.
