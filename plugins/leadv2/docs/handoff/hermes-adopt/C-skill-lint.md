# C-skill-lint — deterministic ZERO-LLM skill/agent-config linter

**Shipped:** `scripts/leadv2-skill-lint.sh [files...]` — no LLM call, pure
grep/python3-yaml. Defaults to `skills/**/SKILL.md` + `agents/*.md`
(README.md excluded to avoid a false-positive frontmatter-missing hit).

## Checks (each finding: `FILE:LINE  [check:SEVERITY]  message`)
1. `frontmatter-missing` / `frontmatter-unparsable` (HIGH)
2. `description-missing` (HIGH) / `description-vague` (HIGH for placeholder
   or 1-word, MEDIUM for <4 words)
3. `frontmatter-duplicate-key` (HIGH) — raw-text scan since PyYAML silently
   keeps the last occurrence and never errors on dup keys
4. `loop-no-termination` (HIGH) — loop/repeat language within 3 lines of a
   spawn/Agent( reference, only if the WHOLE file has no max/limit/cap/
   iteration/terminate keyword anywhere (low false-positive by design)
5. `tool-mismatch` / `skill-mismatch` (MEDIUM) — backtick-quoted tool name
   (fixed vocab: Read/Write/Edit/Bash/Glob/Grep/WebFetch/WebSearch/Task/
   TodoWrite/NotebookEdit/Monitor/AskUserQuestion/Agent) or `` `skill-name`
   skill `` reference not present in declared `tools`/`allowed-tools`/`skills`

Exit 0 = clean/MEDIUM-only. Exit 2 = ≥1 HIGH. Exit 1 = usage/internal error
(missing file, no PyYAML).

## Verification
- `shellcheck -x` clean on both the linter and the test suite.
- `scripts/tests/test-leadv2-skill-lint.sh` — 7/7 pass: syntax, shellcheck,
  bad-fixture→exit2 (+2 specific findings), clean-fixture→exit0,
  missing-file→exit1.
- Full real-repo run (all live `skills/**/SKILL.md` + `agents/*.md`):
  **exit 0**, only 6 MEDIUM tool-mismatch findings (plausible genuine drift
  signals in leadv2-llm-judge, leadv2-plan, leadv2-diverge,
  leadv2-founder-input SKILL.md — not false positives, worth a glance but
  non-blocking).

## Files
- `scripts/leadv2-skill-lint.sh` (new, 231 lines)
- `scripts/tests/test-leadv2-skill-lint.sh` (new)
- `scripts/tests/fixtures/skill-lint-bad/SKILL.md`,
  `scripts/tests/fixtures/skill-lint-clean/SKILL.md` (new)

## Notes for adoption
- Distinct from `leadv2-prompt-lint.sh` (spawn-prompt word cap) and
  `leadv2-mission-lint.sh` (mission-file size/dup checks) — this validates
  the SKILL.md/agent.md config files themselves.
- `hooks.json` NOT touched (per constraint) — wiring as a pre-commit/CI gate
  is a follow-up for whoever owns that file.
- No git command run; only new files created, zero pre-existing drift touched.

DELIVERABLE_COMPLETE
