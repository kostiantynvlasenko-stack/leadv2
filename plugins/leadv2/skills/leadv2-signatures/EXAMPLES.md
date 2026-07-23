# Signature Entry Schema (in LEAD_V2_STATE history)

Referenced from SKILL.md. Each signature block also tracks temporal metadata for decay:

```yaml
signature:
  phase: build
  task_class: Heavy
  failure_class: logic-bug
  recovery_decision: hotfix
  outcome: success
  involved_agents: [developer, critic]
  change_kind: bugfix-pure
  fix_quality: reasonable    # band-aid | reasonable | durable
  approach: ""               # optional free-text; captured from developer deliverable summary; used by negative-memory-compile
  negative_memory_hit: false # true if negative-memory skill blocked/flagged this task's approach at any phase
  first_seen: "2026-04-24"
  last_seen: "2026-04-24"
  usage_count: 1
```

**`approach` field:** Free-text description of the specific approach taken (e.g., "added index on messages.created_at"). Captured in `lead-reflect` when the developer-agent logged the approach in their deliverable. No closed vocab — leave empty string if not described. Used by `leadv2-negative-memory-compile.sh` to match repeated failures across history.

**`negative_memory_hit` field:** Set to `true` by lead when `leadv2-negative-memory` produced a `disposition: blocked` match during any phase of this task. Used for aggregation: high hit rates signal that the negative-memory store is catching real patterns, or that unblock criteria need refinement.

On subsequent tasks with same `(phase, failure_class)`:
- Do NOT add duplicate entries — update the existing entry: bump `usage_count`, set `last_seen`.
- When deduplicating, match on `(phase, failure_class, recovery_decision, outcome, change_kind, fix_quality)` six-tuple. Treat missing fields as `null` for matching purposes.
