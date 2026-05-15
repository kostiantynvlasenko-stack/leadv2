# Supported Stacks

## Tested

| Stack | Status | Notes |
|---|---|---|
| Python + Supabase + Hetzner VPS | ✅ Production | Original stack the plugin grew from; battle-tested |
| Python + Postgres + systemd | ⚠️ Untested but should work | Same deploy pattern as above without Supabase |

## Untested but expected to work

The plugin is project-agnostic — your stack just needs to provide a `deploy.sh` and a `verify.sh`. The orchestration loop doesn't care about the language or hosting.

These stacks should work; PRs welcome to add tested examples:

- Go + Postgres + Kubernetes/ArgoCD
- TypeScript + Vercel + Supabase
- Next.js + Prisma + Fly.io
- Swift + App Store Connect (via `xcrun altool`)
- Ruby on Rails + Heroku
- Java/Kotlin + ECS

## Known limitations

- **Monorepos**: the lead derives the project root from `git rev-parse --show-toplevel`. In a monorepo, it sees the top-level repo, not your app subdirectory. Workaround: set `CLAUDE_PROJECT_ROOT=/path/to/app` in your shell env, or scope `/leadv2` runs to the subdirectory.

- **No git, no plugin**: many scripts use git for state (project root, commit hashes for `causal-replay`, blame for `negative-memory`). Without git, expect degraded behavior.

- **Worktrees**: full support — leadv2 detects worktrees and adjusts paths. The `leadv2-worktree-enforce` hook will offer to spin up a worktree for risky Heavy-class tasks.

- **Multi-user / shared dev box**: every leadv2 session writes to `.claude/leadv2-overrides/` and `docs/leadv2/`. If two engineers run leadv2 on the same machine at the same time on the same repo, you'll get file-lock contention. Use separate worktrees or separate dev boxes.

- **Windows**: the plugin uses bash scripts with bash-specific features (`set -euo pipefail`, `[[ ... ]]`, process substitution). WSL works. Native Windows shells don't.

## Adding your stack

If you get leadv2 running on a new stack, please open a PR:

1. Add a working override set under `examples/overrides/<stack-name>/`:
   - `stack.yaml`
   - `deploy.sh`
   - `verify.sh`
   - `codex-policy.yaml`
   - `extensions.md`
2. Update this file with a row in **Tested**
3. Document any quirks in `extensions.md` or open an issue

## Stack detection

The `leadv2-init` skill auto-detects:

| Signal | Result |
|---|---|
| `pyproject.toml` / `setup.py` / `requirements.txt` | `lang: python` |
| `go.mod` | `lang: go` |
| `package.json` / `pnpm-workspace.yaml` (no go.mod) | `lang: typescript` |
| `Package.swift` | `lang: swift` |
| go.mod AND package.json | `lang: mixed` |
| `supabase/` directory | `db: supabase` |
| `.sql` files matching `*migrat*` + postgres deps | `db: postgres` |
| `kustomization.yaml` | `hosting: gke` |
| `vercel.json` / `.vercel/project.json` | `hosting: vercel` |
| `.github/workflows/` | `ci: github-actions` |
| `.circleci/config.yml` | `ci: circleci+argocd` |

If detection is ambiguous (e.g. multi-stack), `leadv2-init` asks 1-2 questions to disambiguate.
