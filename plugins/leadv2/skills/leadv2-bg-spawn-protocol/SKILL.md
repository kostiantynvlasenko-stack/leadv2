# leadv2-bg-spawn-protocol

> **Watchdog is now default-on.** The `leadv2-bg-watchdog-gate.sh` PostToolUse:Agent hook fires immediately after every `Agent(run_in_background=true)` call and injects a blocking `additionalContext` reminder if no Monitor watchdog has been armed since the spawn. There is no opt-out. Failing to arm a Monitor is now caught in the same turn, not at Stop.

## Rule

Every `Agent(run_in_background=true)` call MUST be immediately followed by a `Monitor(path=<deliverable-file>)` call. No exception.

Both `<name>.md` and `<name>.full.md` paths should be monitored where the subagent protocol requires a two-file deliverable split.

## Why

Background agents die silently (spend limit, crash, lost ping). Without a Monitor:
- Lead stalls indefinitely waiting for a completion it will never receive.
- The session appears to hang with no actionable signal.
- Repeated silent deaths indicate a spend limit — tell the founder.

## Enforcement

`leadv2-bg-watchdog-gate.sh` (PostToolUse:Agent):
1. Reads the session ledger written by `leadv2-bg-ledger.sh`.
2. Checks if any BG_SPAWN entry exists after the last WATCHDOG entry.
3. If yes: injects `additionalContext` with a blocking reminder before the next tool is allowed.
4. Counter cap: one reminder per unwatched spawn (keyed by ledger state).

`leadv2-bg-stop-warn.sh` (Stop hook) remains as a backstop, now firing every stop (WARN_EVERY=1).

## Anti-pattern

```
# WRONG: spawn with no Monitor
Agent(subagent_type="developer", run_in_background=true, ...)
# ... next tool call without Monitor -> watchdog gate fires and blocks

# CORRECT
Agent(subagent_type="developer", run_in_background=true, ...)
Monitor(path="docs/handoff/TASK-01/developer.full.md")
```
