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

For tunable thresholds and detailed canonicalization rules, see [REFERENCE.md](./REFERENCE.md).

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
