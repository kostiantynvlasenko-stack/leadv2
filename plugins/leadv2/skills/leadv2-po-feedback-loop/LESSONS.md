# Lessons codified (LOCAL-9 retro, 2026-05-23)

These are MANDATORY checks that fold into the existing phases (see `SKILL.md`). Don't skip.

## 1. Baseline-for-comparisons check (Phase A — audit prompt addition)

Any UI column / badge / value that shows a **delta, percentage, ratio, or comparison** (Floor Δ, % change, vs market, since last…) MUST specify in the audit:
- **Baseline** — what value are we comparing against? `current_floor` vs `floor_at_time_of_event`? `7d_high` vs `all_time_high`?
- **Time semantics** — is the baseline live OR snapshotted at event-time?
- **API contract** — does the API expose a per-row snapshot field, or only the live aggregate?

If the audit produces a delta column without answering all 3 — that's a P0 finding, not a P2. Reason: LOCAL-9 shipped a `Floor Δ` column in Recent Sales using *current* floor against *historical* sale price — semantically wrong, founder caught visually, required Round 2 fix-and-revert. Add this question to `templates/po-audit-mission.md`.

## 2. Playwright PASS ≠ visual OK for numeric/format UI

Playwright "PASS" is necessary but not sufficient for:
- Number formatting (axis labels, currency, percentages)
- Truncation / ellipsis behavior
- Color-coding by value sign
- Y-axis dual-axis layouts

Reason: LOCAL-9 verify reported "Y-axis fix PASS" while UI actually showed `$0/$1/$1/$1` (bars used wrong data key). Selector existed → PASS, but render was wrong.

**Rule for Phase C:** if the verify scenario covers a numeric/format/visual concern, the agent MUST save a `/tmp/v-<n>.png` screenshot for that scenario and reference it in the report. Lead then offers founder visual signoff ("see /tmp/v-3.png") before declaring done. Don't merge on Playwright PASS alone for format-class fixes.

## 3. Lead-direct-verify rule (≤5-line single-file)

When a verify reports a FAIL that requires checking a SINGLE line in a SINGLE file (e.g. "is `hidden sm:inline-flex` on the BETA span?"), lead reads the file directly with `Read offset=N limit=5`. Do NOT spawn a developer agent.

Reason: LOCAL-9 spent 80s on an A1-was-actually-correct re-check of `Header.tsx` line 35 because the QA report's FAIL was a stale Vercel cache, not a real bug. One `Read` call would have closed it instantly.

**Threshold:** if the fix candidate is ≤5 lines AND in 1 file AND clearly localized — lead reads, then either confirms no fix needed OR writes the patch instruction inline into a single agent prompt. Skip a dedicated agent.

## 4. Don't skip Phase 3 (Plan triad) for "obviously well-defined" UI work

LOCAL-9 went audit→build without architect+critic, betting the audit IS the spec. It worked, but the FloorΔ semantic miss is exactly what a critic-Opus pass would have flagged BEFORE writing code. Rule: even if work feels "well-defined P2 polish", run a 30-line `critic-mission.md` over the audit findings, async, parallel with Build. Cost: one Opus call. Saves one round of revert-and-fix.
