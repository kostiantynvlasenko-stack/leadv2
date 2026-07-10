verdict-guard: allow

# WORKFLOW-BASH-FIX-01 — plan.js + review.js migration done

## leadv2-plan.js (4 real bash() sites → 0)
- `_ARCHIVE_ROOT` resolve folded into the single-consumer `archive-read` agent prompt (Move 1b).
- `emitLedger` (×3 runtime) → in-memory `pushLedger`/`ledgerEvents`, flushed inside the `synthesize`
  agent call (zero extra round-trip); a dedicated `flushLedger()` call covers the `architectFailed`
  early-exit path that never reaches Synthesize.
- `persistCodeMap()` + the separate `task_class` flock+heredoc write combined into one
  `buildPersistScript()` JS string, folded as a verbatim-execute instruction onto BOTH
  `synthesize` and `synthesize-retry` (R6 — shared constant, no drift). `resolvedTaskClass` moved
  earlier (right after Classify) so it's available for the fold.
- Net: 0 new agent() calls on the happy path; +1 (`ledger-flush`) only on the rare architect-fail path.

## leadv2-review.js (4 real bash() sites → 0)
- `TS` derive: pass-through `args.ts`, else the agent resolves it itself inside the `archive-write` prompt.
- `_archiveRoot` resolve folded into the same `archive-write` prompt (Move 1b, same pattern as plan.js).
- Semantic-index append: built as one fully self-contained, already-escaped shell command in JS
  (R1 — escaping untouched) and passed to the SAME `archive-write` call as a best-effort trailing
  instruction.
- `emitLedger` (×3) → `pushLedger`, flushed inside the final `reflect` call, which runs
  **unconditionally every round** (not nested in the `verdict==='ACCEPT'` branch — R2 requirement).
- Introduced `ROOT_RESOLVE_CMD` — one canonical un-split template-literal constant reused by both
  the archive-write prompt and the semantic-index command (avoids duplicating/drifting the
  git-common-dir one-liner).

## Verification
- `node --check` clean on both files.
- Zero real `await bash(...)` call-sites in either file (regex scan across both; only 2 comment-
  prose mentions remain, both non-executable).
- Every real `agent()` call is explicitly `model:`-pinned — plan.js: 12 label sites / 13 model
  sites (extra model site is the `synthAgent` fallback chain default); review.js: 8/9 (same
  reason). 1:1 confirmed, zero unpinned.
- Shell strings passed to agents are pre-built/pre-escaped in JS and executed verbatim by the
  agent's own Bash tool — no re-derivation/re-escaping asked of the LLM (R1 preserved).

## Test harness realignment
- `fixtures/codemap-plan-harness.mjs` (covers plan.js): dropped the fictional `bash` global,
  added `pipeline`/`budget` no-op mocks — matches the real runtime contract (agent/phase/log/
  parallel/pipeline/budget only), same signature as the verified `learn-freeform-flag-harness.mjs`
  reference. To still genuinely exercise the folded persist-script side effects, the harness's
  `synthesize`/`synthesize-retry` mock now extracts the embedded shell script from the prompt and
  runs it via `execSync` — a harness-side stand-in for "the agent's own Bash tool", not a global
  injected into the workflow's scope (zero real bash() calls in the workflow source itself,
  confirmed above).
- `test-leadv2-codemap.sh`: **12/12 pass.** The old "PRE-DIFF GOLDEN" byte-identical comparison
  (Test 4) is retired with an explanatory comment, not silently deleted — it ran the pre-diff
  bash()-calling source through the same harness (which no longer provides `bash`, by design) and
  additionally the synthesize prompt text has legitimately changed (now embeds the folded
  persist-script + ledger-flush instructions), so a byte-identical comparison is fundamentally
  incompatible with this migration, not a regression.
- `test-leadv2-learn-freeform-flag.sh`: 3/3 pass (untouched, confirms no collateral damage).
- review.js has **no dedicated interpreter harness** (confirmed — none found); per the plan this
  is a fast-follow, not blocking. It IS covered incidentally by
  `test-leadv2-phase8-learn-counter.sh` Test 7, which regex-extracts the git-common-dir
  resolve one-liner directly from review.js's source. That regex required the now-removed
  `await bash(` prefix — updated to anchor on the git-common-dir marker + `|| pwd` ending inside
  any template literal instead (extracts the canonical `ROOT_RESOLVE_CMD` constant). **7/7 pass**
  after the fix (verified: Test 6 + Test 7 both pass, worktree + unrelated-repo cwd cases correct).

## Caveats
- `causal-critique-harness.mjs` and `leadv2-causal-critique.js` are untouched — out of scope per
  the plan's execution order (flag-gated, lower urgency, do after plan/review).
- The retired golden-comparison logic (`codemap-check-golden.py`) is left on disk unused rather
  than deleted, in case a future task wants to re-pin a NEW post-migration golden baseline.
- Per-round ledger-flush granularity (R2 in the plan) was not adopted for plan.js/review.js —
  both flush once per run (folded into the last-write-anyway call), same trade-off already
  accepted in the verified leadv2-learn.js reference. Flagged, not re-litigated here.

DELIVERABLE_COMPLETE
