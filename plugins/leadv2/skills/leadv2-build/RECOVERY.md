# leadv2-build — recovery / fallback branches

Referenced from SKILL.md §3b and §3c. These are the branches that fire only
when something goes wrong (invalid schema, failed build round) — read the
relevant section when that condition actually occurs.

## §3b (continued) — semantic validator for the three typed handoff files

After the generic YAML check in SKILL.md §3b passes, use the stricter semantic
validator on the three typed handoff files (context.yaml is the one Build
depends on):

```bash
source .claude/scripts/lv2 leadv2-helpers.sh
# Validate context.yaml schema before spawning build agents
if ! leadv2_validate_handoff "docs/handoff/<task-id>/context.yaml" context 2>/tmp/hv-err.txt; then
  err=$(</tmp/hv-err.txt)
  # Call back to the producing agent (Plan phase) ONCE with the error:
  .claude/scripts/ask-lead.sh "<task-id>" "context.yaml schema invalid: $err — please fix and re-write"
  # Re-validate; if still failing, escalate to Tier B via ask-lead.sh
  leadv2_validate_handoff "docs/handoff/<task-id>/context.yaml" context \
    || { .claude/scripts/ask-lead.sh "<task-id>" "context.yaml still invalid after fix attempt: $err"; exit 1; }
fi
```

## §3c — Diff-only build-feedback (failed round re-prompt)

When a build round fails and next round needs re-prompt, send only the
compact diff-based prompt below — do not replay the full context.

**Protocol:**
1. Call `bash .claude/scripts/lv2 leadv2-build-feedback.sh --task-id <id> --previous-attempt <n>`
2. The script emits a compact prompt: `<previous-summary ≤80w>\n<diff-only>\n<failure reason>\n<fix request>`
3. Inject that output as the ONLY context in the next developer mission (not the full plan)
4. Target: 70-90% reduction vs full context replay

**Fallback:** if diff generation fails, the script falls back to the tail of the previous full deliverable. Always pass compact tail context through rather than skipping context entirely — it's better than none.

**Save explicit diff file for later rounds:**
```bash
git diff "${TASK_START_SHA}..HEAD" > "docs/handoff/${TASK_ID}/build-attempt-${N}.diff"
```
This lets attempt N+1 diff precisely against what attempt N actually committed.
