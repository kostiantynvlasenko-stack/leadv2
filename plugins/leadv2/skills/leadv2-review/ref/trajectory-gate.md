# Trajectory pre-check — full protocol (leadv2-review §0a)

Referenced from `leadv2-review/SKILL.md` §0a. Run BEFORE §1 for Standard and Heavy tasks only.
Skip for Light class when the §0 skip-review gate has already passed (do not double-gate Light tasks).

```bash
bash .claude/scripts/lv2 leadv2-trajectory-check.sh \
  --task-id "${TASK_ID}" \
  --class "${TASK_CLASS}"
# Exit codes:
#   0 → trajectory ok, proceed to §1
#   1 → trajectory mismatch (missing events or strict-mode extras)
#   2 → script/config error
```

**On exit 0:** proceed normally to §1.

**On exit 1 with `missing_events` non-empty:**
- Read `docs/handoff/<task-id>/trajectory.yaml` to identify which role is responsible for the missing artifact.
  - `build/developer` artifact missing → re-spawn `developer` agent with mission:
    `"Phase 4 build was incomplete — produce artifact '<artifact>' as specified in context.yaml plan.steps"`
  - `plan/architect` artifact missing → re-spawn `architect` agent with mission:
    `"Phase 2 plan was incomplete — produce docs/handoff/<task-id>/architect.md"`
  - `plan/critic` artifact missing → re-spawn `critic` agent similarly.
- Max 1 retry per missing artifact.
- After the re-spawn completes, re-run `leadv2-trajectory-check.sh` once.
  - If still failing → escalate via `ask-lead.sh`.

**On exit 1 with only `out_of_order` (no missing events):**
- Log a warning to `LEAD_V2_STATE.md` history: `"trajectory: out_of_order timing skew, proceeding"`
- Proceed to §1 — timing skew alone is not a blocker.

**On exit 2:**
- Escalate via `ask-lead.sh <task-id> "trajectory-check script error — see stderr"`.
- Do not proceed to review until resolved.

**Save result to handoff dir** (done automatically by the script):
`docs/handoff/<task-id>/trajectory.yaml`
