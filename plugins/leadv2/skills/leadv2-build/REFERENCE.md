# leadv2-build — optional/advisory checks

Referenced from SKILL.md §3. These fire only under specific conditions and
are advisory (never block Build directly) — read the relevant section when
its trigger condition is met.

## §3f — Codex micro-verify on sensitive paths (added 2026-06-30, SONNET5-ADAPT-01)

Two trigger conditions, same underlying call — background, non-blocking, advisory only. Does not gate Phase 5 Review, which still runs its own full Codex pass for Standard+.

1. **Light-class tasks** (skip Phase 2 Plan entirely — see `leadv2-plan/SKILL.md` "When NOT") that touch `supabase/migrations/`, RLS policy files, or `platform/eval/safety*`: fire one background Codex pass here, since Light never reaches Plan where this check normally lives.
2. **Any class**, per `parallel_group` step whose files touch `supabase/migrations/` or `contracts/`: fire a quick per-step verify right after that group's spawn completes, in parallel with the next group — catches a broken migration/contract one step earlier than waiting for the full Phase 5 batch review.

```bash
_SENSITIVE=$(git diff --name-only "${TASK_START_SHA}..HEAD" 2>/dev/null \
  | grep -E '^(supabase/migrations/|.*rls.*\.sql$|platform/eval/safety)' || true)

if [[ -n "$_SENSITIVE" ]] && bash ~/.claude/scripts/codex-task.sh status >/dev/null 2>&1; then
  bash .claude/scripts/lv2 leadv2-codex-planner.sh \
    --task-id "${TASK_ID}" --mode quick-verify --effort low --tier standard \
    --diff-paths "$_SENSITIVE" \
    --out "docs/handoff/${TASK_ID}/codex-step-${STEP_N:-0}-result.md" &   # background, own path — does not race codex-plan-result.md from Phase 2
fi
```

Findings (if any) surface as extra context for Phase 5 Review (read `codex-step-*-result.md` if present); they never block Build directly. Skip silently if `codex-task.sh status` fails (no ChatGPT login) or no sensitive paths touched.
