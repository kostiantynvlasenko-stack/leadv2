# WORKFLOW-BASH-FIX-01 — go-live done

- **Commit:** `078d1cd8103f77f3bfc61fb8685fef4a62f19590` on `main` — 9 workflow files + 3 fixture
  harnesses + 3 test-*.sh + docs/handoff/WORKFLOW-BASH-FIX-01/*.md. `leadv2-ledger.js`
  untouched (confirmed 0 real bash() calls, out of scope). Left 3 unrelated pending changes
  unstaged (`agents/SCHEMA.md`→`README.md` rename, `hooks/leadv2-compact-trigger.sh` edit) —
  not part of this fix, no mention in the task's own handoff docs.
- **Pushed:** NO. Repo is not auto-push (no pre-push hook found); local is ahead-1 of
  `origin/main`. Founder/lead should push explicitly if desired.
- **Sync:** ran `~/Projects/leadv2/plugins/leadv2/scripts/leadv2-plugin-sync.sh` from the
  **source repo path**, not the stale copy at `~/.claude/scripts/leadv2-plugin-sync.sh`. That
  stale copy resolves `PLUGIN_ROOT` relative to its own location (`~/.claude`), so running it
  in-place silently re-syncs `~/.claude/workflows` → cache instead of source repo → cache — a
  real footgun (byte-identical script, wrong invocation path = stale no-op sync that still logs
  `OK`). Confirmed via mtime + diff before/after.
- **Cache verify:** all 9 files (`leadv2-{audit,causal-critique,diagnose,diverge,
  intake-enrich,learn,plan,po-feedback-loop,review}.js`) in
  `~/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/workflows/` now byte-match source. Zero
  real bare `await bash(` call-sites (remaining greps are comment prose only). `node --check`
  clean on all 9. `~/.claude/workflows/` (workflows-sync target) also byte-matches source now.

DELIVERABLE_COMPLETE
