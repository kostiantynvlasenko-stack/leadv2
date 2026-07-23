# Workflow-based Review path (opt-in, `LEADV2_WORKFLOW_ENABLED=1`)

**Workflow fan-out toggle:** `LEADV2_WORKFLOW_ENABLED=1` enables the dynamic-Workflow path (requires Max/Team plan `Workflow` tool). Default (unset) uses the manual Cases A/B/C in SKILL.md.
> **Self-enable (orchestrator-judged):** you MAY set `LEADV2_WORKFLOW_ENABLED=1` for the session yourself — without a founder prompt — when Review meets the fan-out test (multi-dimension review / adversarial verify). See `docs/goal-workflow-autonomy.md`.

**If `LEADV2_WORKFLOW_ENABLED=1` and the `Workflow` tool is available — PREFERRED path**
(ships at `~/.claude/workflows/leadv2-review.js`, all repos):
```
Workflow({ name: "leadv2-review", args: { taskId: "<id>", base: "main",
           safetyTouched: <bool>, codexEnabled: <bool>, missionPath: "docs/handoff/<id>/review-mission.md" } })
```
Returns ONE synthesized verdict `{verdict, blocking_count, blocking[], followups[]}` — lead context
stays clean. `blocking_count==0` → ACCEPT → Phase 6. `blocking_count>=1` → developer fix → re-run
(max 2 rounds) → judge. The workflow is **model-pinned** (critic sonnet / opus-on-safety, hack+codex
haiku, verify sonnet) — never Opus-by-inheritance. `m3-market`: set `codexEnabled:false` if managed
settings disable Codex/workflows; fall back to manual Cases A/B/C.

The reference JS shape for that workflow is at **`ref/workflow-review-reference.md`** — illustrative
only (the saved `.js` is canonical); do NOT hand-inline a fresh script from it. The Workflow returns
structured JSON findings directly — no Monitor polling, no manual deliverable-file reads. Write the
JSON results to `docs/handoff/<id>/reviews/round1-findings.json` and proceed to §3 (SKILL.md) using
the structured output. Codex review stays orthogonal: fire it as an optional background Bash call
outside the Workflow if available.

**Note:** `Workflow` requires Max or Team plan. If the tool is not available in the current session,
fall through to the manual path in SKILL.md.
