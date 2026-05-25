---
name: frontend-screenshot-audit
description: Capture screenshots of every route × theme × state and run designer-vision review. Produces PNG gallery + vision-report.md punch list.
triggers:
  - проверь UI
  - screenshot страницы
  - визуально верифицируй фронт
  - UI test
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
---

# Frontend Screenshot Audit

## When
Any visual verify pass on the frontend — initial audit, post-fix verification, or spot-check.

## When NOT
Backend-only changes with no UI impact. API contract checks only (use wave-XX.spec.ts directly).

## Protocol

### 1. Detect package manager
```bash
LEADV2_PM=$(bash .claude/scripts/detect-package-manager.sh web/)
```

### 2. Ensure Playwright installed
```bash
if ! "$LEADV2_PM" list @playwright/test &>/dev/null 2>&1; then
  "$LEADV2_PM" add -D @playwright/test
  npx playwright install --with-deps chromium
fi
```

### 3. Cookie env
Auth cookie must be at `/tmp/<domain>-cookie.env` (e.g. `/tmp/timbre-cookie.env`).
Format:
```
SB_COOKIE_NAME=sb-<project-ref>-auth-token
SB_COOKIE_VALUE=base64-eyJhY2N...
```
If missing → invoke `auth-cookie-setup` skill and pause.

### 4. Capture matrix
Specs in `web/tests/e2e/`:
- `screenshot-audit.spec.ts` — every route × `light` / `dark` fullPage
- `walkthrough.spec.ts` — interactive states per page (`-hover-kpi`, `-filter-active`, `-loading`, `-error`, `-empty`, `-modal-open`)

Run:
```bash
set -a; . /tmp/timbre-cookie.env; set +a
cd web && npx playwright test screenshot-audit walkthrough \
  --reporter=list 2>&1 | tail -30
```

Output dir: `docs/handoff/<task_id>/screenshots/`

### 5. Designer-vision review
Spawn `Agent(subagent_type=developer, model=sonnet)` with mission:
- Read every PNG via Read tool (multimodal)
- Apply `audit-cluster` criteria: simple, clear, beautiful, working, informative, no-tech-jargon, all-states-wired
- Produce `docs/handoff/<task_id>/screenshots/vision-report.md` — per-page punch list PASS/PARTIAL/FAIL

### 6. Deliverable
- `docs/handoff/<task_id>/screenshots/*.png`
- `docs/handoff/<task_id>/screenshots/vision-report.md`

## dispatch.md example

Input: "проверь UI дашборда после фикса KPI"
Output files:
- `docs/handoff/DASHBOARD-WAVE-02/screenshots/overview-light.png`
- `docs/handoff/DASHBOARD-WAVE-02/screenshots/overview-dark.png`
- `docs/handoff/DASHBOARD-WAVE-02/screenshots/overview-empty-light.png`
- `docs/handoff/DASHBOARD-WAVE-02/screenshots/vision-report.md`
