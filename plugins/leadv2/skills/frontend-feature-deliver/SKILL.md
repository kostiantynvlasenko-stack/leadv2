---
name: frontend-feature-deliver
description: >-
  [DEPRECATED 2026-06-14: superseded by leadv2-po-feedback-loop] Full pipeline to implement a frontend feature — spec → code → tsc → visual before/after diff → critic → commit + deploy.
triggers:
  - сделай фичу на фронте
  - реализуй UI
  - добавь компонент
  - implement frontend feature
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
---

# Frontend Feature Deliver

## When
Implementing any new UI feature, component, or page on the frontend.

## When NOT
Backend-only changes. Hotfixes with no visual surface. Pure data/API tasks.

## Pipeline

### Step 1 — Architect spec
Spawn `Agent(subagent_type=architect, model=sonnet)`:
- Data flow: which API route feeds the component
- Primitives reuse: shadcn components to use (no new deps unless justified)
- Component placement: file path, parent component, import chain
- Output: `docs/handoff/<task_id>/architect.md`

### Step 2 — Developer implement
Spawn `Agent(subagent_type=developer, model=sonnet)` with architect.md as context:
- Implement the feature per spec
- Follow existing patterns in `web/components/` and `web/app/`
- Output: git diff of changed files

### Step 3 — TypeScript check
```bash
cd web && npx tsc --noEmit 2>&1 | head -30
```
Any error → back to developer with error output. Max 2 rounds.

### Step 4 — Visual before/after
Run `frontend-screenshot-audit` skill:
- BEFORE: if screenshots already exist from prior audit, skip capture
- AFTER: capture fresh screenshots post-implementation
- Visual cap: up to 4 rounds; does NOT count toward codex round cap

### Step 5 — Designer-vision diff
Spawn `Agent(subagent_type=developer, model=sonnet)` reading both BEFORE and AFTER PNGs:
- Compare feature intent vs actual rendering
- Output: `docs/handoff/<task_id>/screenshots/vision-report.md`

### Step 6 — Critic review
Spawn `Agent(subagent_type=critic, model=sonnet)`:
- Review diff + vision-report
- Max 2 codex/critic rounds (separate cap from visual rounds)

### Step 7 — Commit + deploy
If critic → APPROVE:
```bash
git add -p
git commit -m "feat: <feature-name>"
bash .claude/scripts/wait-vercel-ready.sh --commit "$(git rev-parse --short HEAD)" --dir web/
```

## Round caps
- tsc fix rounds: max 2
- codex/critic rounds: max 2 (use `leadv2-judge-review` if >2 needed)
- visual rounds: max 4 (not counted against codex cap)
