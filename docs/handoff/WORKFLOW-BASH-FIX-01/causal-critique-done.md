# leadv2-causal-critique.js — bash() migration done

- **Diff shape (9→2 real agent() call-sites, matching plan):** 7 bash() call-sites
  (DURABLE_ROOT resolve + ctx_digest/scorecard_tail/review_sig/ledger_slice/diff_stat/
  neg_mem_lines) collapsed into ONE `gather-digest` agent() call. The 2 remaining bash()
  call-sites (freeform-insight append + emitLedger) collapsed into ONE reusable `persist`
  agent() call (via `persistAndFlush()`, invoked at both the early Critique-unavailable
  return and the final Persist return). The pre-existing `causal-critique` synthesis
  agent() call is untouched (never a bash() call).
- **All-pinned:** every real agent() call has explicit `model:` — `gather-digest`=haiku,
  `persist`=haiku, `causal-critique`=dynamic sonnet/opus (synthesis, explicit either way).
  Zero unpinned calls.
- **Verbatim-shell confirmed:** every command string is built entirely in JS (unchanged
  shq()/JSON.stringify escaping) and handed to the agent between `<<<CMD:name>>> ...
  <<<END>>>` markers with explicit "run EXACTLY as given, do not modify/re-escape/re-derive"
  instructions. diff_stat's start_sha substitution is restricted to the same hex-only
  charset the original JS regex enforced — the agent never authors shell quoting.
- **Test result:** 16/16 pass, incl. the malicious-taskid injection re-attack test (proves
  shq() escaping survives being routed through agent()-execution instead of direct bash()).
  Harness realigned to mock `agent()` (not fictional `bash`/`bashImpl`); for `gather-digest`
  and `persist` labels the mock genuinely execSyncs the embedded commands against the
  fixture repo (not canned), preserving real end-to-end proof. Replaced the old
  `BASH_CALLS>3` check with `realExec>3` + a `digestReflectsFixture` content check.
- **Caveats:** (1) ledger task_close event's `freeform_written` field now reflects "had a
  candidate to persist" not confirmed append success, to keep flush+append in one call —
  documented inline, ledger is best-effort telemetry only. (2) ledger events themselves are
  not execSync'd for real in the harness (no test asserts ledger.jsonl content) — kept
  minimal/honest per harness scope.

DELIVERABLE_COMPLETE
