# Override Configuration

Everything project-specific in leadv2 lives in `.claude/leadv2-overrides/`. The `leadv2-init` skill scaffolds these files on first run. Fill them in to make the orchestrator work for your stack.

## Files

### `stack.yaml`

Auto-detected by `leadv2-init`. Edit if detection is wrong.

```yaml
lang: python              # python | go | typescript | swift | mixed | unknown
db: supabase              # supabase | postgres | mysql | sqlite | none | unknown
hosting: hetzner-vps      # vercel | hetzner-vps | gke | aws-ecs | fly | app-store | unknown
ci: github-actions        # github-actions | circleci+argocd | gitlab-ci | manual | unknown
deploy_method: systemd-bash   # systemd-bash | vercel-deploy | argocd-sync | xcodebuild-altool | docker-compose | unknown
```

Used by skills/architect/critic to tailor their suggestions to your stack.

### `deploy.sh`  (executable)

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

### `verify.sh`  (executable)

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

### `codex-policy.yaml`

Controls whether the Codex CLI (GPT-5.5) is used as a 2nd-brain reviewer in Phase 2 (plan) and Phase 5 (review).

```yaml
codex_enabled: false              # default: false (most teams don't have Codex)
codex_model: gpt-5.5              # gpt-5.5 (default) | gpt-5.4 (adversarial-review pinned)
codex_review_rounds_max: 2        # max Codex review rounds before escape to architect
codex_planner_max_findings: 5     # cap Codex plan-findings to reduce token cost
```

When `codex_enabled: false`, the lead falls back to `Agent(critic, opus)` cleanly. No degradation in plan/review quality — just one less perspective.

### `state-paths.yaml`  (optional)

Override default file locations. Most teams don't need this.

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

### `extensions.md`

Free-form markdown the lead reads at the start of every task. Use it for project-specific rules that don't fit elsewhere.

```markdown
# Project-specific lead rules

- All database changes must use the `migrate` skill, never raw SQL.
- Never deploy on Fridays after 16:00 local.
- The `payments/` directory requires `security-auditor` review on every change.
- When touching `web/`, always start the dev server and visual-test before claiming done.
```

The lead loads this in Phase 0 and respects it as project policy.

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

## Examples

See [examples/overrides/](../examples/overrides/) for working sets per stack:
- `python-django/`
- `go-postgres/`
- `typescript-nextjs/`
