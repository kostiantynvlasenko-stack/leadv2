# D — Capability-search step in Phase-2 Plan

Cost-neutral (no new agent spawn): capability-search is now an inline directive
inside the EXISTING architect cross-check mission prompt (the only Plan-phase
spawn that emits `decisions[]`).

## Changed files
- `workflows/leadv2-plan.js`
  - Architect spawn prompt (line ~268): added mandatory capability-search
    directive — check `pyproject.toml`/`package.json`/requirements, installed
    CLI tools, registered MCP servers, installed Skills before proposing
    custom code. Always emits one `decisions[]` string entry, even a
    "no fit" verdict.
  - Synthesize prompt (line ~379): instructed to parse any `decisions[]`
    string starting with `capability-search:` and write it into context.yaml
    as a structured entry `{decision, considered[], chosen, why}` instead of
    a plain string — never dropped.
- `skills/leadv2-plan/SKILL.md`
  - Step-map row 2b now notes the mandatory capability-search check.
  - `decisions:` schema example extended (non-breaking, additive) with the
    capability-search entry shape.

## Not changed
- No `templates/` plan-mission template exists (only `templates/verify-contracts`)
  — step 4 of the mission is a no-op.
- No new subagent spawn added; Codex planner prompt untouched (it returns
  `concerns[]`, not `decisions[]`, so it isn't the right emitter).

DELIVERABLE_COMPLETE
