# Manual dispatch — Cases A/B/C (leadv2-review §2)

Referenced from `leadv2-review/SKILL.md` §2. Used when `LEADV2_WORKFLOW_ENABLED` is unset or ≠ 1
(the Workflow tool path is unavailable). This is the actual spawn logic — the compact table in
SKILL.md summarizes *when* each case fires; this file has the exact commands.

```bash
# Manual path (default — LEADV2_WORKFLOW_ENABLED unset or ≠ 1):
#
# Case A: Codex OK, non-safety → Codex + hack-detection, parallel
if $CODEX_OK && ! safety_touched; then
  # ONE message, two calls:
  Bash(codex-task.sh adversarial-review --wait --base main, run_in_background=true)
  Agent(subagent_type=developer, model=sonnet, prompt="run hack-detection per .claude/skills/leadv2-hack-detection/SKILL.md on diff /tmp/leadv2-review-<id>.diff; write findings YAML to docs/handoff/<id>/hack-findings.yaml and summary to docs/handoff/<id>/hack-detection.summary.md")
fi

# Case B: Codex OK, safety-touched → Codex + critic(opus) + security-auditor + hack-detection, parallel
if $CODEX_OK && safety_touched; then
  # ONE message, four calls:
  Bash(codex-task.sh adversarial-review --wait --base main, run_in_background=true)
  Agent(subagent_type=critic, model=opus, prompt="review diff /tmp/leadv2-review-<id>.diff per critic role frontmatter; brief /tmp/review-mission-<id>.md; write to docs/handoff/<id>/critic.summary.md + critic.full.md with DELIVERABLE_COMPLETE")
  Agent(subagent_type=security-auditor, model=sonnet, prompt="security review diff /tmp/leadv2-review-<id>.diff per role frontmatter; always-read-full for security-sensitive paths; write to docs/handoff/<id>/security-auditor.summary.md + security-auditor.full.md with DELIVERABLE_COMPLETE")
  Agent(subagent_type=developer, model=sonnet, prompt="run hack-detection per .claude/skills/leadv2-hack-detection/SKILL.md on diff /tmp/leadv2-review-<id>.diff; write findings YAML to docs/handoff/<id>/hack-findings.yaml and summary to docs/handoff/<id>/hack-detection.summary.md")
fi

# Case C: Codex down → critic(opus) via Agent promoted to primary + hack-detection
if ! $CODEX_OK; then
  Agent(subagent_type=critic, model=opus, prompt="primary adversarial review — full-coverage (Codex unavailable); diff /tmp/leadv2-review-<id>.diff; brief /tmp/review-mission-<id>.md; write to docs/handoff/<id>/critic.full.md + critic.summary.md")
  Agent(subagent_type=developer, model=sonnet, prompt="run hack-detection per .claude/skills/leadv2-hack-detection/SKILL.md on diff /tmp/leadv2-review-<id>.diff; write findings to docs/handoff/<id>/hack-findings.yaml")
  # If safety-touched, also Agent(security-auditor, sonnet) parallel
fi
```

Mission file for critic:
```
Review the diff in docs/handoff/<id>/diff.md for:
- Architecture violations of context.yaml decisions
- Missed off_limits
- Second-order effects
- Hidden assumptions
Output: CHALLENGE blocks per devils-advocate skill format.
```
