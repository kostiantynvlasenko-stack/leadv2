# Anti-lying-green invariants — Verify gate (Phase 7)

Referenced from `leadv2-verify/SKILL.md` §"VERIFY PASS requires". Full text of the 4 invariants
that must ALL hold before verify is declared complete — never remove/weaken these, only relocate.

1. **Concrete live signal** — at least one of: a real DB row (with distinct id/media_id logged), a non-zero metric delta, a log line with timestamp, or a confirmed HTTP response. "No error" alone is NOT a pass.
2. **Exit code captured non-masked** — probe exit code must be captured and checked explicitly; never swallowed by `|| true` or `2>/dev/null` after the signal step.
3. **0/null/empty result → mandatory layer-by-layer probe** — if the expected signal returns 0 rows, null, or empty: re-query by alternate key (e.g. slug not UUID), check RUN_MODE=prod, confirm the event was emitted at all. Only after all layers return negative is the result treated as PROBE_NEG → recovery. Never close on a 0/null result without the layer probe (root of lying-green closes).
4. **`verify-probe-result.yaml` written** — `outcome:` field must be `probe_ok`; no other value admits close.
