---
name: leadv2-emergency-mode
description: "[DORMANT — zero production firings as of 2026-07-03; e2e-test before relying on it] Reduced-scope review for emergency hotfixes when founder grants \"no approvals\". Syntax check and pinpoint critic still mandatory. Triggers: founder says \"no approvals\"/\"skip review\"/\"emergency\"/\"hotfix now\"; context.yaml has autonomy_level=3; STATE.md has emergency_mode=true."
allowed-tools:
  - Read
  - Write
  - Bash
---

# leadv2-emergency-mode — Reduced Review Protocol

> **ARCHIVED 2026-07-10 (PROMPT-HYGIENE-01 #6).** Moved here because it never fired in production (0 firings as of 2026-07-03). Kept as a fallback reference, not auto-discovered from `skills/archive/`. Restore to `skills/` and e2e-test before relying on it again. See `leadv2-recovery/SKILL.md` for the decision line distinguishing this from Phase-7 recovery.

## Context
V4 restore session (2026-05-13): founder granted "no approvals" → Phase 5 review was fully skipped on ~10 hotfixes. One (`local` keyword outside a function) broke prod. Emergency mode ≠ zero review.

## Minimum checks — NON-NEGOTIABLE even in emergency

Run these BEFORE every deploy, regardless of autonomy_level:

```bash
# 1. Syntax check all changed shell files
git diff --name-only main | grep '\.sh$' | xargs -r bash -n

# 2. Syntax check all changed Python files
git diff --name-only main | grep '\.py$' | xargs -r python3 -m py_compile

# 3. If diff > 30 lines: spawn pinpoint critic
git diff main | wc -l
```

- **diff ≤ 30 lines:** lead reviews inline — 60s max, no spawn needed.
- **diff > 30 lines:** `Agent(critic, sonnet, "pinpoint-review this diff, ≤3 findings, Critical/High only, max 100 words total")` — foreground, ≤2 min.

## What IS skipped in emergency mode
- Full Codex adversarial review round
- Security auditor spawn
- Full test suite run (unless test is ≤10s to run)

## What is NOT skipped (ever)
- `bash -n` / `python3 -m py_compile` syntax check
- Deploy to BOTH VPS (not one, not zero)
- Verify-probe after deploy

## Activation
When founder message contains "no approvals"/"skip review"/"emergency" OR `context.yaml` has `autonomy_level: 3`:
- Lead sets `emergency_mode: true` in `docs/leadv2/tasks/<id>/STATE.md`
- Phase 5 uses this skill instead of full review triad
- Pulse: "Phase 5 emergency mode — syntax+pinpoint only"

## Deactivation
`emergency_mode: true` is valid for ONE task only. Resets to `false` at Phase 8 close.
Next task resets to standard review unless founder re-grants.

## Hard ban
Never set `emergency_mode: true` without a direct founder grant in the same session.
Lead cannot self-grant emergency mode to skip review on a "boring" task.
