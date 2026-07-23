# leadv2-plan — Schemas

Full field-by-field schema for `context.yaml`. Consulted when writing or validating the file in
step **5. Synthesis → context.yaml** — the top-level key summary in SKILL.md is enough for a
quick recall; use this file for the exact structure, comments, and every field.

## context.yaml Schema

Schema from /lead Inter-agent coordination section:

```yaml
task:
  id: <id>
  class: <class>
  mission: <text>
  started_at: <ISO>

decisions:        # combine locked-in picks from all three
  - id: D1
    topic: ...
    choice: ...
    rejected: [...]
    source: architect(sonnet)
  - id: D2
    ...
    source: codex
  - decision: capability-search   # mandatory per plan (see step 2b) — reuse-vs-build check,
    considered: [libX, cliY, mcpZ]  # before committing to custom code
    chosen: "reuse <x>" | "custom (no fit)"
    why: "<one line>"

off_limits:       # union of all off-limits from three sources
  - ...

research:         # pointers to each deliverable
  - source: architect(sonnet)
    summary: "<one sentence from their output>"
    file: docs/handoff/<id>/architect.md#<anchor>
  - source: critic(opus)
    summary: ...
  - source: codex
    summary: ...

plan:
  steps:
    - n: 1
      agent: developer(sonnet)
      mission: ...
      reads: [context.yaml, architect.md#<anchor>]
      writes: [diff.md#step_1]
      deliverable: "diff + 200-word summary"
  parallel_groups:
    - [step_1, step_2]

reviews: {}       # filled during Phase 5

# F4 advisory tool hints — read from .claude/leadv2-overrides/toolsets.yaml if present;
# fall back to phase defaults. Subagents treat this as preference, not enforcement.
allowed_tools:
  intake:   [Read, Glob, Grep, WebFetch, WebSearch, "codebase-memory-mcp-*"]
  classify: [Read, Glob, Grep, WebFetch, WebSearch, "codebase-memory-mcp-*"]
  plan:     [Read, Glob, Grep, WebFetch, WebSearch, "codebase-memory-mcp-*"]
  build:    [Read, Glob, Grep, WebFetch, WebSearch, "codebase-memory-mcp-*", Edit, Write, Bash]
  review:   [Read, Grep, Bash, "codebase-memory-mcp-*"]
  deploy:   [Bash, Read]
  close:    [Read, Write]

verification:
  live_signal: "<from architect recommendation or codex rollback plan>"
  probe: {type: signal-file|log-grep|http-check|supabase-check, args: ...}
  timeout: 1800
  # criteria[] is OPTIONAL and ADDITIVE — omit when no concrete checkable criteria exist.
  # When present, ALL items must pass before Phase 7 verify succeeds.
  # See contracts/context.verification.schema.json for full field definitions.
  criteria:
    - id: "<short-slug>"
      type: programmatic        # or: judge | human
      expect: exit_zero         # or: exit_nonzero | stdout_contains
      check: ["<cmd>", "<arg>"]  # argv; required when type==programmatic
      # contains: "<substr>"   # required when expect==stdout_contains
    - id: "<rubric-slug>"
      type: judge
      rubric: "<natural-language pass/fail criterion for LLM or founder>"
    - id: "<human-gate-slug>"
      type: human
      prompt: "<instruction shown to founder at the manual gate>"
```
