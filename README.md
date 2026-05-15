# leadv2

> **Autonomous engineering orchestrator for Claude Code.** One plan-approval gate, then autopilot to live verification — across any stack.

`leadv2` turns Claude Code into a self-driving engineer. You give it a task, it plans (Opus architect + Codex 2nd brain optional), builds (Sonnet specialists), reviews (adversarial critic + security auditor), deploys, verifies on live production, and reflects. You step in at exactly one gate — the initial plan — then everything else runs without asking.

## Features

- **Phased orchestration** — `intake → classify → plan → build → review → deploy → verify → reflect → close`.
- **Multi-model routing** — Sonnet for chat/build, Opus for architect/critic via Agent tool, Haiku for discovery via Explore, optional Codex GPT-5.5 as 2nd-brain reviewer.
- **One gate, then autopilot** — only the initial plan needs your approval. Every later step is gated by automated checks (tests, review verdict, security audit, verify-probe) with a circuit breaker on failure.
- **Self-learning** — captures corrections and successful patterns into `immune memory`, pre-filters future approaches against past failures.
- **Multi-stack** — works on any project (Python/Go/TS/Swift) via `.claude/leadv2-overrides/` config files that describe your deploy/verify pipeline.
- **35+ guard hooks** — bash linting, env audit, schema audit, read deduplication, output capping, token discipline, loop detection, edit guards.
- **20+ skills** — judge, recovery, iterative recovery, emergency mode, founder-question router, subagent protocol, token discipline.

## Quickstart

```sh
# In Claude Code:
/plugin marketplace add kostiantynvlasenko-stack/leadv2
/plugin install leadv2
```

Then in any project:

```sh
/leadv2
```

First run triggers `leadv2-init` which detects your stack (Python/Go/TS/Swift/etc.) and scaffolds `.claude/leadv2-overrides/`. Fill in the deploy/verify scripts for your project, then run `/leadv2` again with a task description.

## How it works

```
You ── task ──▶ /leadv2
                  │
                  ▼
            Phase 0  Intake — read task, classify (Trivial/Light/Standard/Heavy/Strategic)
            Phase 1  History primer — pull similar past tasks from immune memory
            Phase 2  Plan       (Opus architect + critic + optional Codex)  ←── ONLY GATE
            Phase 3  Premortem  (probability of success, rollback risk)
            Phase 4  Build      (Sonnet developer/frontend/devops/postgres-pro subagents)
            Phase 5  Review     (critic + security-auditor + optional Codex review)
            Phase 6  Deploy     (your .claude/leadv2-overrides/deploy.sh)
            Phase 7  Verify     (your .claude/leadv2-overrides/verify.sh)
            Phase 8  Close      (cost summary, lead-reflect, queue next)
                  │
                  ▼
              Done
```

## Configuration

Everything project-specific lives in `.claude/leadv2-overrides/` (auto-scaffolded by `leadv2-init`):

| File | Purpose |
|---|---|
| `stack.yaml` | lang / db / hosting / ci / deploy_method (auto-detected) |
| `deploy.sh` | executable; called by Phase 6 with `$LEAD_V2_TASK_ID` |
| `verify.sh` | executable; called by Phase 7; exit 0 = pass |
| `codex-policy.yaml` | `codex_enabled: true|false` |
| `state-paths.yaml` | (optional) override STATE.md / tasks dir paths |
| `extensions.md` | project-specific lead rules (e.g. "always migrate via skill X") |

See **[docs/OVERRIDES.md](docs/OVERRIDES.md)** for the full reference.

## Requirements

### Mandatory

- **Claude Code** v2.1.0 or later
- An active Anthropic OAuth subscription or `ANTHROPIC_API_KEY`

### Strongly recommended (or substitute your own equivalents)

The orchestrator was designed around two external tools. Without them, several phases will degrade. You either install them as-is, or override the corresponding skill behavior with your own equivalents in `.claude/leadv2-overrides/extensions.md`.

1. **Codex CLI** (OpenAI GPT-5.5) — used as a 2nd-brain reviewer in Phase 2 (plan) and Phase 5 (review). Two independent models catch ~30% more issues than one. Install + log in:
   ```sh
   npm i -g @openai/codex
   codex auth login
   ```
   Enable in `.claude/leadv2-overrides/codex-policy.yaml`: `codex_enabled: true`.
   - **Substitute:** any other LLM CLI you trust. Re-implement `scripts/leadv2-codex-planner.sh` to call your tool, or set `codex_enabled: false` and accept that all plan/review goes through a single perspective (Opus critic).

2. **codebase-memory-mcp** — MCP server that builds a structural knowledge graph of your codebase. The architect, critic, and Explore skills use it for `search_graph`, `trace_path`, `get_architecture` queries. Without it, those skills fall back to text-only grep — usable, but significantly weaker for cross-file analysis.
   - Register the MCP server in `~/.claude/mcp_servers.json` per the [project README](https://github.com/your-org/codebase-memory-mcp).
   - **Substitute:** any code-graph MCP server. The skills call `mcp__codebase-memory-mcp__*` tool names — if you wire a different graph server, either rename the tools to match or edit the skill SKILL.md files to use your tool names.

The plugin will technically run without these two, but plan/review quality drops noticeably. Treat them as part of the stack, not optional polish.

## Philosophy

This is opinionated tooling. The opinions:

1. **You don't write code in the orchestrator chat.** The lead delegates everything to subagents. Code edits in the main thread are blocked by a hook.
2. **Token discipline is enforced.** Reading files over 100 lines requires `offset/limit`. Heredocs in bash are blocked. Output is capped. Read deduplication kills repeated reads.
3. **One gate.** Adding more gates feels safer but makes the lead useless — you spend 5 minutes approving things that should run themselves. The lead has a circuit breaker if Verify fails, so the floor is "rollback + escalate", not "shipped broken code".
4. **Memory is asymmetric.** Lead remembers failures (immune memory) more aggressively than successes — past mistakes pre-filter future plans.
5. **Codex is optional, not required.** Many teams don't have Codex. The lead falls back to `Agent(critic, opus)` cleanly.

## Status

**v0.1.0** — initial public release. Tested on:
- Python + Supabase + Hetzner VPS deploy
- (More stacks coming — please open PRs with `examples/overrides/<your-stack>/`)

This is the same orchestrator that runs a production multi-tenant SaaS — but the persona-engine specifics have been stripped out. The core orchestration loop is what's in this repo.

## Documentation

- **[docs/INSTALLATION.md](docs/INSTALLATION.md)** — Install + first-run walkthrough
- **[docs/OVERRIDES.md](docs/OVERRIDES.md)** — Configuring leadv2 for your project
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — Phase model, model routing, subagent protocol
- **[docs/SUPPORTED_STACKS.md](docs/SUPPORTED_STACKS.md)** — Tested combinations + known issues
- **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** — Contributing, adding skills, plugin structure
- **[examples/overrides/](examples/overrides/)** — Working override sets for common stacks

## License

MIT — see [LICENSE](LICENSE).

## Credits

Built by [@kostiantynvlasenko-stack](https://github.com/kostiantynvlasenko-stack) for the Timbre / Persona Engine project, then generalized. PRs welcome.
