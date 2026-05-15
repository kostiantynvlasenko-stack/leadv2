# Installation

## Prerequisites

### Mandatory

- **Claude Code** v2.1.0+ (`claude --version`)
- Anthropic OAuth subscription **or** `ANTHROPIC_API_KEY` set
- A git repository (the plugin uses `git rev-parse --show-toplevel` to find your project root)

### Strongly recommended

Two external tools the plugin was designed around. Install both, or substitute your own equivalents (see notes in each).

**1. Codex CLI** — 2nd-brain reviewer for Phase 2 (plan) and Phase 5 (review).

```sh
npm i -g @openai/codex
codex auth login
```

Then in your project:
```yaml
# .claude/leadv2-overrides/codex-policy.yaml
codex_enabled: true
```

If you skip Codex, plan and review will run through `Agent(critic, opus)` alone. Quality drops noticeably — the dual-perspective is one of the value props of the plugin.

If you have a different LLM CLI (Gemini CLI, Cursor, your own wrapper), edit `plugins/leadv2/scripts/leadv2-codex-planner.sh` to call your tool. The contract is: takes a prompt path, returns findings to stdout.

**2. codebase-memory-mcp** — MCP server that maintains a structural knowledge graph (functions, classes, call edges, data flow) of your codebase.

Register in `~/.claude/mcp_servers.json`. The exact server URL depends on your install — see the codebase-memory-mcp project.

Used by:
- `architect` and `critic` agents for `search_graph` / `trace_path` / `get_architecture`
- The `Explore` agent for pre-Plan discovery
- Skills `leadv2-plan`, `leadv2-recovery`, `leadv2-build` for impact analysis

Without it, those skills fall back to grep-based text search. Usable, but cross-file architectural analysis is significantly weaker.

If you have a different code-graph MCP server (Sourcegraph, tree-sitter-based, custom), grep the plugin for `mcp__codebase-memory-mcp__` and edit the skill SKILL.md files to reference your tool names instead.

## Install

In Claude Code, run:

```
/plugin marketplace add kostiantynvlasenko-stack/leadv2
/plugin install leadv2
```

This adds the `leadv2` marketplace and installs the plugin into your user-level Claude Code config.

Verify it loaded:

```
/plugin list
```

You should see `leadv2@leadv2 (user)` in the list.

## First run

In your project directory (any git repo):

```
/leadv2
```

On first run, the `leadv2-init` skill activates automatically. It:

1. Detects your stack (Python/Go/TypeScript/Swift) from fingerprint files
2. Detects your DB (Supabase/Postgres/none)
3. Detects your hosting (Vercel/Kubernetes/Hetzner-VPS/App Store/unknown)
4. Detects your CI (GitHub Actions / CircleCI+ArgoCD / unknown)
5. Asks you 1-2 clarifying questions if any field is ambiguous
6. Creates `.claude/leadv2-overrides/` with:
   - `stack.yaml` — detected values
   - `deploy.sh` — skeleton; TODO markers for you to fill
   - `verify.sh` — skeleton; TODO markers
   - `codex-policy.yaml` — `codex_enabled: false` by default
   - `extensions.md` — placeholder for project-specific lead rules

## Fill the overrides

Open `.claude/leadv2-overrides/deploy.sh` and replace the TODO with your actual deploy commands. For example:

**Python / Heroku:**
```sh
#!/usr/bin/env bash
set -euo pipefail
git push heroku main
```

**Go / k8s via ArgoCD:**
```sh
#!/usr/bin/env bash
set -euo pipefail
argocd app sync my-service --grpc-web
argocd app wait my-service --health --grpc-web --timeout 300
```

**Next.js / Vercel:**
```sh
#!/usr/bin/env bash
set -euo pipefail
cd web && vercel --prod --confirm
```

Similarly fill `verify.sh` — it should exit 0 on success, non-zero on failure. Examples in [examples/overrides/](../examples/overrides/).

## Optional: enable Codex 2nd brain

```yaml
# .claude/leadv2-overrides/codex-policy.yaml
codex_enabled: true
codex_model: gpt-5.5
codex_review_rounds_max: 2
```

Then Phase 2 (plan) and Phase 5 (review) will spawn Codex in parallel with the Opus critic. Verdicts are merged and disagreements escalated.

## Run your first task

```
/leadv2 fix the rate-limit bug in api/auth.py
```

The lead will read the task, classify it, propose a plan, and pause for your approval at **Gate 1**. After you approve, autopilot runs through build → review → deploy → verify → close without asking.

## Updating the plugin

```
/plugin update leadv2
```

Or hard-refresh:

```
/plugin remove leadv2
/plugin install leadv2
```

## Uninstalling

```
/plugin remove leadv2
```

This does NOT delete your `.claude/leadv2-overrides/` — those stay until you remove them manually.
