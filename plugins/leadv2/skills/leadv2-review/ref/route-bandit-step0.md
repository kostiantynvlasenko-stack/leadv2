# Route-bandit Step 0 — bandit model selection (leadv2-review §2)

Referenced from `leadv2-review/SKILL.md` §2. **MANDATORY when `LEADV2_ROUTE_BANDIT=1`.**
Before invoking `Workflow()`, you MUST run `select-for-workflow` when the bandit is active.
Skipping this step freezes arm posteriors — the bandit never learns from this task.

1. Check flag: `if [[ "${LEADV2_ROUTE_BANDIT:-0}" == "1" ]]`
2. Run selection — writes `docs/handoff/${TASK_ID}/route-decisions.yaml`:
   ```bash
   MODELS=$(bash .claude/scripts/lv2 leadv2-route-bandit.sh select-for-workflow \
     --phase review \
     --class "${TASK_CLASS}" \
     --safety "${SAFETY_TOUCHED:-false}" \
     --task-id "${TASK_ID}")
   ```
3. Pass result as `args.models` to the Workflow call:
   ```
   Workflow({name:"leadv2-review", args:{taskId, base, safetyTouched, ..., models: JSON.parse(MODELS)}})
   ```

The workflow JS consumes `args.models.critic` / `args.models.verify` with fallback to pinned defaults.
**Flag-off (`LEADV2_ROUTE_BANDIT != 1`):** skip the shell call entirely — behavior is byte-identical to pre-BANDIT-WIRE-01.
The bandit writes `docs/handoff/<id>/route-decisions.yaml`; scorecard-write.sh reads it at Phase 8 close.
