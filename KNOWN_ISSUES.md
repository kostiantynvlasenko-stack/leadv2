# Known Issues — v0.1.0 pre-release

> **Status**: NOT YET READY TO PUBLISH. Codex adversarial review (2026-05-15) found 5 Critical + 3 High issues that must be fixed before pushing to GitHub.

## Codex findings (2026-05-15)

Session: `task-mp6z09vo-lgnsr0` / `019e2be3-29b2-7370-8dd9-6e68138d43f6`

### Critical — install/first-run blockers

1. **Missing hook script.** `plugins/leadv2/hooks/hooks.json:50` registers `${CLAUDE_PLUGIN_ROOT}/hooks/leadv2-block-codex.sh` but that file was not copied into the public plugin. First `Agent`/`Bash` tool call will fail on missing-hook.
   - Fix: either copy from `~/.claude/plugins/local/leadv2/plugins/leadv2/hooks/leadv2-block-codex.sh` after audit, or remove the entry from hooks.json.

2. **Wrong scripts path in main command.** `plugins/leadv2/commands/leadv2.md:102,130,144,149` references `.claude/scripts/*` (user's repo) instead of `${CLAUDE_PLUGIN_ROOT}/scripts/*`. First-run breaks on any project that doesn't have the scripts in their `.claude/`.
   - Fix: search-replace `.claude/scripts/` → `${CLAUDE_PLUGIN_ROOT}/scripts/` throughout `commands/leadv2.md`.

3. **Phantom skill/script references.** `plugins/leadv2/commands/leadv2.md` lines 152, 158, 160, 202, 225, 227 reference `lead-classify`, `leadv2-rag-intake`, `lead-gate-check`, `leadv2-test-synthesis`, `leadv2-deliverable-routing-check.sh` — none exist in this plugin.
   - Fix: remove those references and adjust surrounding flow text; they're advanced workflow steps not needed for v0.1.0.

4. **Scripts source helpers from user's `.claude/scripts/`.** `scripts/leadv2-render-close.sh:28`, `scripts/leadv2-phase8-assert.sh:33` (and many other scripts found by grep — see "broader audit needed" below) do `source "$PROJECT_ROOT/.claude/scripts/leadv2-helpers.sh"`. Public install: there is no `$PROJECT_ROOT/.claude/scripts/`. Close/Phase 8 won't execute.
   - Fix: change all such `source` calls to `source "$(dirname "$0")/leadv2-helpers.sh"` (script's own directory in plugin).
   - Broader audit needed: every script in `plugins/leadv2/scripts/` and `plugins/leadv2/hooks/` referencing `.claude/scripts/` must be checked. Current grep finds ~30+ such references in helpers.sh alone.

5. **codebase-memory-mcp "MANDATORY" vs documented "recommended".** `plugins/leadv2/skills/leadv2-plan/SKILL.md:19` and other skill files mark `mcp__codebase-memory-mcp__*` calls as MANDATORY, but README/INSTALLATION docs say the MCP is "strongly recommended, with substitute paths".
   - Fix: pick one truth. Either docs make MCP mandatory (and document install steps), or skills downgrade `MANDATORY` markers to "preferred if available; fall back to grep/Glob otherwise".

### High — silent degradation

6. **leadv2-init doesn't scaffold all promised override files.** `skills/leadv2-init/SKILL.md:133,152` scaffolds `stack.yaml`, `deploy.sh`, `verify.sh`, `outcome-watch.sh`, `extensions.md` but NOT `codex-policy.yaml` and `state-paths.yaml` (README+OVERRIDES.md promise these).
   - Fix: extend Step 4 in `leadv2-init/SKILL.md` to also write these two files with sensible defaults.

7. **Codex default behavior wrong.** `scripts/leadv2-helpers.sh:135` (`_lv2_codex_enabled()`): when `codex-policy.yaml` is missing (which it always will be since #6 above means it's never scaffolded), the function defaults to ENABLED. README says default OFF. Any user with Codex CLI installed gets unexpected Codex calls + cost on first task.
   - Fix: invert default logic in `_lv2_codex_enabled()` so missing config = disabled.

8. **state-paths.yaml contract incomplete.** `scripts/leadv2-state-compact.sh:18`, `scripts/leadv2-stale-sweeper.sh:31` hardcode `docs/leadv2/*` and `docs/handoff/*` instead of reading from `state-paths.yaml`. Advertised path overrides work only partially.
   - Fix: replace hardcodes with `${LEADV2_LEADV2_DIR}` / `${LEADV2_HANDOFF_DIR}` env vars (set by `leadv2-helpers.sh` `_lv2_resolve_paths`).

## What works

- File structure is correct (marketplace.json + plugin.json + plugin tree)
- 0 persona-engine / Timbre / VPS-name references (Codex confirmed)
- Bash scripts all pass `bash -n` syntax check
- README + 5 docs + 2 example override sets in place
- LICENSE MIT
- `state-atomic-write.sh` correctly uses `$CLAUDE_PROJECT_ROOT`
- `leadv2_deploy_via_override()` correctly calls `.claude/leadv2-overrides/deploy.sh`

## Next session checklist

Resume in a fresh Claude Code session (current session token budget exhausted). Tasks:

1. Fix Critical #1: handle `leadv2-block-codex.sh` (copy or remove)
2. Fix Critical #2: search-replace `.claude/scripts/` → `${CLAUDE_PLUGIN_ROOT}/scripts/` in `commands/leadv2.md`
3. Fix Critical #3: remove phantom skill refs from `commands/leadv2.md`
4. Fix Critical #4: broader audit + fix all script `source` paths to use `$(dirname "$0")/`
5. Fix Critical #5: align skills and docs on MCP requirement (recommend: docs say "required", skills keep MANDATORY)
6. Fix High #6: extend `leadv2-init` to scaffold `codex-policy.yaml` + `state-paths.yaml`
7. Fix High #7: invert default in `_lv2_codex_enabled()`
8. Fix High #8: replace hardcoded path strings in startup scripts
9. Re-run Codex review to confirm
10. Smoke-test in a fresh `/tmp/leadv2-test/` directory
11. If clean: `gh repo create kostiantynvlasenko-stack/leadv2 --public --license mit && git push`

Until those steps are done, **do not push to GitHub**.

## Files NOT yet touched

These items in the original plan were deferred to v0.2:
- "founder" → "user" rename across remaining ~25 files (cosmetic; doesn't affect functionality)
- `examples/overrides/go-postgres/` (only python + typescript examples shipped in v0.1)
- CI for plugin-repo (linting, smoke tests)
- Submission to anthropic-community marketplace
