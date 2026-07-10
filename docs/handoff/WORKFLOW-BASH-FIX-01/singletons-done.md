# WORKFLOW-BASH-FIX-01 — singletons batch (5 files)

Per-file fix (bash() -> agent() pattern, mirrors leadv2-learn.js):

- **leadv2-diverge.js** — emitLedger() bash-wrote per event -> Move 2: sync `pushLedger` (in-memory array) + one `flushLedger()` agent(haiku) call before the final `return`.
- **leadv2-diagnose.js** — same Move 2 pattern; flush added before the single `return result || {...}` path.
- **leadv2-po-feedback-loop.js** — same Move 2 pattern; 4 phase_enter call sites -> pushLedger; one flush before the final return (after Iterate loop).
- **leadv2-audit.js** — Move 2, PLUS a real pre-existing scope bug fixed as a side effect: old `emitLedger` was declared *inside* the `mode=personas` if-block only, so the `mode=pages` branch's 3 call sites referenced it out of scope (latent ReferenceError). Lifted `ledgerEvents`/`pushLedger`/`flushLedger` to top level, shared by both branches; flush added at all 3 return points (personas-end, pages-empty-early-exit, pages-end).
- **leadv2-intake-enrich.js** — Move 1(b): deleted the standalone `_ARCHIVE_ROOT` bash() line; folded the git-common-dir resolve command verbatim into the text of its one consumer, the `archive-top-k` agent() prompt.

All-pinned confirmation: grepped every `agent(` call site in all 5 files — every real call carries explicit `model:` (haiku for gather/flush/read, sonnet for judge/build/verify, opus/sonnet chain inside pre-existing `synthAgent` fallback in diverge.js/diagnose.js). No unpinned calls introduced.

Verification: `grep bash(\|emitLedger(` on all 5 files -> zero real hits (only comment prose). `node --check` passed clean on all 5. No test harness exists under `scripts/tests/fixtures/` for any of these 5 files (only causal-critique/learn/plan are covered) — nothing to realign or run.

**leadv2-ledger.js intentionally NOT touched** — plan confirmed 0 real bash() calls (doc-stub, comment-only mentions), out of scope per task brief.

DELIVERABLE_COMPLETE
