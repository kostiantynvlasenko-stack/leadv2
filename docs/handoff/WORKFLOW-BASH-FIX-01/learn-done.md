# WORKFLOW-BASH-FIX-01 — leadv2-learn.js fix done

Source: `plugins/leadv2/workflows/leadv2-learn.js`
Harness: `plugins/leadv2/scripts/tests/fixtures/learn-freeform-flag-harness.mjs`
Test: `plugins/leadv2/scripts/tests/test-leadv2-learn-freeform-flag.sh`

## Diff shape (4 real bash() sites -> 0)
- Move 1 (gather-fold): TS+DURABLE_ROOT bash() calls -> one upfront `agent(label:'gather-init', schema)`
  call. **Deviation from plan's literal snippet**: kept SEQUENTIAL (awaited before building
  `gatherLegs`), not folded as a 4th parallel leg — gather-rejected/-exemplars/-freeform-recall
  prompts embed `${TS.slice(0,10)}`/`${DURABLE_ROOT}` directly in template literals, and
  `parallel()`'s `Promise.all(fns.map(fn=>fn()))` invokes all legs synchronously before any
  resolves, so those values must already be concrete or sibling prompts would read
  undefined/unresolved data — a real correctness bug, not just a style choice. `a.ts||a.durable_root`
  fast-path still short-circuits the extra call when both are supplied by caller.
- TS fallback on total gather-init failure is a static sentinel `'1970-01-01T00:00:00Z'`
  (marked `lean:`), NOT `new Date()` — runtime throws on argless `new Date()`.
- Move 2 (ledger-flush): `emitLedger` (bash-per-event) -> `pushLedger` (sync, in-memory push) +
  one `flushLedger()` agent() call before each `return` (early-exit and final path both covered).
- Move 3 (loop-collapse): per-proposal `bash()` shadow-emit loop -> JS still builds every
  already-escaped command string (untouched escaping logic), collects into `emitCandidates[]`,
  then ONE `agent(label:'shadow-emit-batch')` call executes all commands verbatim in order and
  returns `{index,id}[]` — agent never re-derives/re-escapes shell (R1 preserved).
- MEM-WRITE-PATH-FIX-01 marker-check logic (git-common-dir + docs/leadv2 existence check,
  fail-safe to pwd) preserved verbatim inside the gather-init agent prompt.

## Test result
`bash scripts/tests/test-leadv2-learn-freeform-flag.sh` — 3/3 PASS (node --check, flag-off
byte-identical shape, flag-on freeform_recalled key present). Harness rewritten to mock
`agent()` only (dropped fictional `bashImpl`; added `pipeline`/`budget` no-op params matching
real runtime signature); added `gather-init` and `ledger-flush` mock cases.

## Caveats
- R2 (ledger crash-recovery granularity) left as single-flush-per-return-path, per plan's
  explicit open decision — not per-phase-boundary. Founder/lead call if tighter granularity
  needed.
- Only this file + its harness touched, per mission scope. `leadv2-plugin-sync.sh` + new
  session still required before this is live (per plan's go-live steps) — not run here.

## Model-pin audit (coordinator correction, addressed)
Bracket-matched scan of every `agent(` call site in leadv2-learn.js (post-fix) found **11 total
calls, all 11 explicitly pinned** (10 literal `model: 'haiku'|'opus'`, 1 dynamic `model: m` inside
`synthAgent`'s explicit opus→sonnet fallback chain — never inherits session model either way).
Zero unpinned. Note: the flagged count of "15 calls / 3 unpinned" does not match this file's
current state (the 3 new calls this task added — gather-init, ledger-flush, shadow-emit-batch —
were already written with explicit `model:'haiku'` from the start); re-verified structurally, not
just by eyeball. Harness re-run after audit: 3/3 PASS, unchanged.

DELIVERABLE_COMPLETE
