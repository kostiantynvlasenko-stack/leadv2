# leadv2-build — Agent() spawn call templates

Referenced from SKILL.md §2 ("For each parallel_group — spawn in ONE message").
These are the literal call shapes to follow when spawning a parallel group —
the model-routing table and subagent-type rules in SKILL.md decide *which*
template applies to a given step; this file shows the exact call to make.

```
# Example: parallel_groups: [[1, 2], [3]]
# Group [1, 2] → parallel; group [3] runs after both complete.

# Trivial step → haiku, no isolation needed (single file, no collisions)
Agent(
  subagent_type: general-purpose,
  model: haiku,
  prompt="Mission: <plan.steps[2].mission — mechanical, ≤30 LOC>
  Reads: <...>
  Writes: <single file>"
)

# Normal step → sonnet, isolation:worktree if group has ≥2 spawns OR step touches >1 file
Agent(
  developer, sonnet,
  isolation: "worktree",   # ← parallel-safe checkout, see WORKTREE-MERGE.md
  prompt="Codebase graph project: ${LEADV2_CODEBASE_PROJECT}

  ## Graph context (pre-loaded — do NOT re-discover)
  <embed search_graph + trace_path output from §1e here>

  Mission: <plan.steps[1].mission>
  Read docs/handoff/<id>/context.yaml FIRST. Respect decisions and off_limits.
  Reads: <plan.steps[1].reads>
  **Reads budget: ≤5 files. No exploratory reads beyond the list above.**
  **Bash budget: ≤3 Bash calls for discovery. Use Graph context above instead of grep.**
  Writes: <plan.steps[1].writes>
  Skills: codebase-memory, <domain skills from /lead Skill injection table>

  Deliverable: <plan.steps[1].deliverable>
  **Output:** write full detail to docs/handoff/<id>/developer.md. Chat reply: ≤50 words + file pointer."
)

Agent(
  postgres-pro, sonnet,
  isolation: "worktree",
  prompt=... for step 2 ...
)
```
