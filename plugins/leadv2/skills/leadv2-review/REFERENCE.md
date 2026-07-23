# Extended rationale / historical notes

## Why the Codex availability check must not go through `lv2`

**Do NOT route this through `.claude/scripts/lv2`** — `codex-task.sh` is a global
personal tool (`~/.claude/scripts/codex-task.sh`), not a leadv2-plugin script; the `lv2` dispatcher
only resolves plugin scripts (`<plugin>/scripts/`) and repo overrides
(`.claude/leadv2-overrides/scripts/`), so `bash .claude/scripts/lv2 codex-task.sh status` always
fails with "cannot resolve script" (exit 127) regardless of real Codex availability — this
previously forced every review straight to Case C (critic fallback) even when Codex was healthy
(FIX-FANOUT-MODEL-ROUTING-01, 2026-07-15). `leadv2_codex_ready()` in `leadv2-helpers.sh` and the
`leadv2-review.js` Workflow already call the correct absolute path — this was the one stale
call site.
