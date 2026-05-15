---
name: leadv2-loop-detection
description: "Detects repetitive tool-call loops in subagent sessions. Triggers: before each tool dispatch in subagent-preamble. Emits WARN at 3 repeats, BLOCK at 5."
allowed-tools:
  - Bash
  - Read
---

# Lead v2 Loop Detection

## Purpose

Prevent subagents from spinning in infinite tool-call loops (same Bash command,
same Read on same file, same Edit attempt) by hashing canonicalized tool calls
and maintaining a sliding window of the last N=10 calls per session.

## When to activate

- `LEADV2_LOOP_DETECT=1` — active mode: WARN and BLOCK are enforced
- `LEADV2_LOOP_DETECT=shadow` — log-only: always outputs CLEAR, logs to stderr
- `LEADV2_LOOP_DETECT=0` or unset — disabled: skip entirely

## Thresholds

| Threshold | Env var | Default | Action |
|-----------|---------|---------|--------|
| Warn at   | `LEADV2_LOOP_WARN_AT` | 3 | Prepend `[LOOP-WARNING]` to next reasoning step |
| Hard block | `LEADV2_LOOP_HARD_AT` | 5 | Emit `DELIVERABLE_BLOCKED: loop detected — <reason>` and stop |
| Per-tool warn | `LEADV2_TOOL_FREQ_WARN` | 30 | Same tool type used ≥30 times → warn |
| Per-tool block | `LEADV2_TOOL_HARD_LIMIT` | 50 | Same tool type used ≥50 times → block |

## Canonicalization rules

The hash key is `tool_name + ":" + canonical_args_json`. Canonical form:

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

## State file

`/tmp/leadv2-loop-detect-${session_id}.json` — created per subagent session.
Structure:
```json
{
  "window": ["hash1", "hash2", ...],
  "tool_counts": {"Bash": 12, "Read": 5},
  "hash_counts": {"<hash>": 3}
}
```

File is locked with `flock -x` on every read+write cycle to handle concurrent
access from parallel subagents sharing a session ID.

## Invocation (from subagent-preamble §11)

```bash
echo '{"tool_name":"Bash","args_canonical_json":"{\"command\":\"ls -la\"}","session_id":"abc","task_id":"TASK-01"}' \
  | python3 .claude/scripts/leadv2-loop-detect.py
```

Output is exactly one line:
- `CLEAR` — proceed normally
- `WARN <reason>` — prepend `[LOOP-WARNING]` to reasoning, continue
- `BLOCK <reason>` — emit `DELIVERABLE_BLOCKED: loop detected — <reason>`, stop

## Failure modes

- State file unreadable/corrupt → treat as CLEAR (log warning to stderr)
- `flock` unavailable → proceed without lock (log warning to stderr)
- Any unhandled exception → stdout `CLEAR`, full traceback to stderr (fail-open)

## Non-goals

- Does not replace the 30-tool-call hard cap in `leadv2-subagent-protocol`
- Does not track cross-session state (each session starts fresh)
- Does not block legitimate retries after an error (error context changes canonical form)
