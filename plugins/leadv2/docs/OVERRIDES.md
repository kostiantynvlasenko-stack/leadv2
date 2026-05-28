# Override Configuration

Everything project-specific in leadv2 lives in `.claude/leadv2-overrides/`. The `leadv2-init` skill scaffolds these files on first run. Fill them in to make the orchestrator work for your stack.

Override files live under `<repo-root>/.claude/leadv2-overrides/`.
All files and all keys are **optional** — missing file or key falls back to the
documented default so existing repos (persona-engine, m3-market, respiro-ios)
behave identically to before this feature was introduced.

---

## state-paths.yaml

Controls where leadv2 writes state, handoff, board, and queue files.

| Key | Default | Description |
|---|---|---|
| `leadv2_dir` | `docs/leadv2` | Directory for per-task STATE.md files |
| `handoff_dir` | `docs/handoff` | Root for handoff artefacts |
| `board_path` | `docs/BOARD.md` | Project board path |
| `dialogue_path` | `docs/agents/product-owner/DIALOGUE.md` | PO dialogue log |
| `queue_path` | `docs/agents/product-owner/QUEUE.md` | PO queue |
| `lead_state_path` | `docs/LEAD_V2_STATE.md` | Live lead state file |
| `queue_archive_dir` | `docs/agents/product-owner/queue/_archive` | Closed queue items |

---

## stack.yaml

Controls language/toolchain-specific behaviour in gate scripts and hooks.
All keys are optional; fallback values equal the current persona-engine (PE) hardcoding.

| Key | Type | Default (PE value) | Description |
|---|---|---|---|
| `lang` | string | `python` | Primary language of the repo (`python`, `typescript`, etc.) |
| `src_roots` | list | `[platform, agent]` | Directories scanned for source files in coverage-gate and schema-audit. Used to build file-path filters. |
| `hot_paths` | list | `[agent/state/, personas/, agent/safety/]` | Paths treated as shared/hot in collision-check. Changes to these files trigger a collision warning. Trailing slash is preserved and used as a prefix match. |
| `migration_glob` | string | `supabase/migrations/*.sql` | Glob pattern matched against staged files to identify migration files in schema-audit-pre-gate. |
| `test_cmd` | string | `pytest tests/leadv2/ -q` | Test invocation used by fix-from-findings. |
| `scope_terms` | list | `[]` | Extra project nouns for scope-creep regex. Defaults to empty — do NOT default to PE names. |

### Behaviour notes

**`src_roots`** — used in:
- `scripts/leadv2-coverage-gate.sh`: builds the grep pattern `^(root1|root2)/.*\.py$` for changed-file detection.
- `hooks/leadv2-schema-audit-pre-gate.sh`: Python walk over each root looking for upsert and date-cast patterns.

If `lang` is not `python` AND `src_roots` is not explicitly set (i.e. still at the
`platform agent` fallback), coverage-gate emits a one-line warning to stderr and
exits 0 (visible skip, not silent pass):
```
coverage gate: no src_roots configured for stack=<lang>, skipping
```

**`hot_paths`** — used in `scripts/leadv2-collision-check.sh`.
Each entry is treated as a path prefix; the awk condition is built dynamically so
any number of paths can be specified.

**`migration_glob`** — used in `hooks/leadv2-schema-audit-pre-gate.sh` inside a
`case` statement. Must be a valid bash glob pattern relative to the repo root.

### Example (persona-engine values, fully explicit)

```yaml
# .claude/leadv2-overrides/stack.yaml
lang: python
src_roots:
  - platform
  - agent
hot_paths:
  - agent/state/
  - personas/
  - agent/safety/
migration_glob: "supabase/migrations/*.sql"
```

---

## codex-policy.yaml

| Key | Default | Description |
|---|---|---|
| `codex_enabled` | `false` | Set `true` to allow `leadv2-codex-planner.sh` to run in this repo. m3-market: absolute ban. |

---

## active-limits.yaml

Overrides session concurrency limits. Keys: `hard_limit`, `heavy_strategic_solo`.
See `scripts/leadv2-budget-check.sh` for full schema.

---

## deploy.sh  (executable)

Called by Phase 6 with `LEAD_V2_TASK_ID` env set. Must exit 0 on success.

```sh
#!/usr/bin/env bash
set -euo pipefail

log() { printf -- '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
log "Deploying task=$LEAD_V2_TASK_ID"

# Your deploy commands here
git push production main
ssh user@host "cd /var/www/app && systemctl restart app.service"

log "Deploy complete"
```

The script receives:
- `LEAD_V2_TASK_ID` — task being deployed
- `LEAD_V2_PROJECT_ROOT` — absolute path to project root
- `LEAD_V2_DRY_RUN` — `1` if leadv2 is in dry-run mode (echo, don't execute)

---

## verify.sh  (executable)

Called by Phase 7 after deploy. Must exit:
- `0` — verification passed, proceed to Phase 8 Close
- `1` — timeout (probe didn't see signal) → triggers `leadv2-recovery`
- `2` — negative signal seen (error log spike, 5xx jump) → triggers immediate rollback + recovery

```sh
#!/usr/bin/env bash
set -euo pipefail

# Wait for the deploy to settle, then check health
sleep 30

# Example: health endpoint check with timeout
if ! curl -fsS --max-time 30 https://your-app.example.com/health; then
  echo "[verify] health check failed"
  exit 2
fi

# Example: tail logs for a specific success signal
if timeout 300 ssh user@host "tail -F /var/log/app.log" | grep -m1 "task_complete=${LEAD_V2_TASK_ID}"; then
  echo "[verify] success signal seen"
  exit 0
fi

echo "[verify] timeout — never saw success signal"
exit 1
```

---

## codex-policy.yaml (full schema)

Controls whether the Codex CLI (GPT-5.5) is used as a 2nd-brain reviewer in Phase 2 (plan) and Phase 5 (review).

```yaml
codex_enabled: false              # default: false (most teams don't have Codex)
codex_model: gpt-5.5              # gpt-5.5 (default) | gpt-5.4 (adversarial-review pinned)
codex_review_rounds_max: 2        # max Codex review rounds before escape to architect
codex_planner_max_findings: 5     # cap Codex plan-findings to reduce token cost
```

When `codex_enabled: false`, the lead falls back to `Agent(critic, opus)` cleanly. No degradation in plan/review quality — just one less perspective.

---

## state-paths.yaml (yaml block)

```yaml
# Defaults (no need to set if these are fine):
# board_path: docs/BOARD.md
# dialogue_path: docs/agents/product-owner/DIALOGUE.md
# queue_path: docs/agents/product-owner/QUEUE.md
# lead_state_path: docs/LEAD_V2_STATE.md
# handoff_dir: docs/handoff
# leadv2_dir: docs/leadv2
# queue_archive_dir: docs/agents/product-owner/queue/_archive
```

---

## extensions.md

Free-form markdown the lead reads at the start of every task. Use it for project-specific rules that don't fit elsewhere.

```markdown
# Project-specific lead rules

- All database changes must use the `migrate` skill, never raw SQL.
- Never deploy on Fridays after 16:00 local.
- The `payments/` directory requires `security-auditor` review on every change.
- When touching `web/`, always start the dev server and visual-test before claiming done.
```

The lead loads this in Phase 0 and respects it as project policy.

---

## Environment variables (rare)

Most behavior is config-driven, but a few env vars are honored:

| Variable | Purpose | Default |
|---|---|---|
| `LEADV2_TIMEZONE` | Timezone for daemon scheduling | `UTC` |
| `LEADV2_TASK_QUEUE` | Path to task queue YAML | `docs/leadv2/tasks.yaml` |
| `LEADV2_TASK_QUEUE_DIR` | Path to task queue dir | `docs/leadv2/queue` |
| `LEADV2_CODEBASE_PROJECT` | codebase-memory-mcp project name | derived from cwd |
| `LEADV2_BOT_MODE` | Run headless (no Gate 1 prompts) | unset |
| `CLAUDE_PROJECT_ROOT` | Override project root detection | derived from `git rev-parse` |

---

## Examples

See [`examples/overrides/`](../examples/overrides/) for working sets per stack:
- `generic/` — fallback stubs (exit non-zero until filled in)
- `python-supabase-vps/` — Python + Supabase + Hetzner VPS systemd
- `typescript-nextjs-vercel/` — TypeScript + Next.js + Vercel
- `pe/` — persona-engine reference (fully explicit PE values)
