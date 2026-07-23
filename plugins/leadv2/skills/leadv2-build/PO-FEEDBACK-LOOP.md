# leadv2-build — Phase 4.5 PO Feedback Loop (auto-trigger for UI features)

Referenced from SKILL.md, end of Protocol, before Phase 5 Review. Read this
file when the detection check says the diff is UI-heavy.

**Before proceeding to Phase 5 Review**, check if the diff is UI-heavy. If yes, invoke `leadv2-po-feedback-loop` skill (4-phase Audit → Build → Verify → Iterate orchestration).

Detection:
```bash
ui_diff=$(git diff --name-only HEAD~1 HEAD 2>/dev/null | grep -E "\.tsx?$" | grep -E "(apps/.*/page\.tsx|apps/.*/components/.*\.tsx|packages/features/.*\.tsx|packages/ui/.*\.tsx)" | wc -l | tr -d ' ')

if [ "$ui_diff" -ge 2 ] && [ "$CLASS" != "Trivial" ] && [ "$CLASS" != "Light" ] && [ "$EMERGENCY_MODE" != "true" ]; then
  echo "FE-UI feature shipped → invoking leadv2-po-feedback-loop"
  # Lead invokes Skill(skill="leadv2-po-feedback-loop") with task-id + preprod URL
fi
```

Trigger conditions (ALL must hold):
- `ui_diff ≥ 2` — at least 2 UI files changed
- `CLASS in [Standard, Heavy, Strategic]` — not Trivial / Light
- `EMERGENCY_MODE != true` — skip during hotfixes
- Vercel preview is reachable (no 503/deployment-pending)

Anti-triggers (skip if any):
- `context.yaml` has `skip_po_audit: true`
- Diff touches only `.test.tsx` / `.spec.tsx` / story files
- Refactor commits (preserve UI identical — no UX delta)

When invoked, `leadv2-po-feedback-loop` orchestrates:
1. **Audit** — `Agent(07-architect, opus)` + Playwright + benchmarks → `po-audit-<feature>.md`
2. **Build** — parallel `Agent(09-nextjs-pro, sonnet)` per file-ownership group → fixes
3. **Verify** — `Agent(09-nextjs-pro, sonnet)` + Playwright → PASS/FAIL table
4. **Iterate** — fix-round if FAILs, max 2 rounds, then log to `po-followups.md`

Skill returns: `passed`, `partial`, or `escalate`. On `passed` / `partial` → proceed to Phase 5. On `escalate` → invoke `Skill(leadv2-judge) mode=review`.

Founder is informed of audit P0 count + verify PASS/FAIL summary between phases. No narration mid-phase (silence protocol).

Reference implementation: `~/MythicalGames/m3-market/.claude/leadv2-tasks/LOCAL-9-collections-sidebar/` (commits `90d3a7a9`, `078ff5d5`, `bc670694` — 27 UX improvements via this exact loop on 2026-05-23).

Proceed to Phase 5 Review (after PO loop completes, if invoked).
