---
name: leadv2-init
description: "[internal] First-run init — detects project stack and generates .claude/leadv2-overrides/ scaffolding. Triggers when stack.yaml is missing."
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
---

# Lead v2 Init — Project Override Scaffolding

## When: First /leadv2 run in a repo that has no `.claude/leadv2-overrides/stack.yaml`.
## When NOT: overrides already exist; stack.yaml already present.

## Trigger check

```bash
if [[ ! -f ".claude/leadv2-overrides/stack.yaml" ]]; then
  echo "leadv2-init required"
fi
```

## Protocol

### Step 1. Detect stack

Scan project root for fingerprint files:

```bash
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-.}"

# Detection signals
has_pyproject=false; has_gomod=false; has_package_json=false
has_swift=false; has_dockerfile=false; has_k8s=false

[[ -f "$PROJECT_ROOT/pyproject.toml" || -f "$PROJECT_ROOT/setup.py" || -f "$PROJECT_ROOT/requirements.txt" ]] && has_pyproject=true
[[ -f "$PROJECT_ROOT/go.mod" ]] && has_gomod=true
[[ -f "$PROJECT_ROOT/package.json" || -f "$PROJECT_ROOT/pnpm-workspace.yaml" ]] && has_package_json=true
[[ -f "$PROJECT_ROOT/Package.swift" ]] && has_swift=true
[[ -f "$PROJECT_ROOT/Dockerfile" || -f "$PROJECT_ROOT/docker-compose.yaml" || -f "$PROJECT_ROOT/docker-compose.yml" ]] && has_dockerfile=true
find "$PROJECT_ROOT" -maxdepth 4 -name "kustomization.yaml" -o -name "kustomization.yml" 2>/dev/null | grep -q . && has_k8s=true

# DB detection
has_supabase=false; has_postgres=false; has_migrations=false
[[ -d "$PROJECT_ROOT/supabase" ]] && has_supabase=true
find "$PROJECT_ROOT" -maxdepth 3 -name "*.sql" 2>/dev/null | grep -qiE 'migrat' && has_migrations=true

# CI detection
has_circleci=false; has_gha=false
[[ -f "$PROJECT_ROOT/.circleci/config.yml" ]] && has_circleci=true
[[ -d "$PROJECT_ROOT/.github/workflows" ]] && has_gha=true

# Hosting detection
has_vercel=false; has_vercel_json=false
[[ -f "$PROJECT_ROOT/vercel.json" || -f "$PROJECT_ROOT/.vercel/project.json" ]] && has_vercel=true
```

### Step 2. Determine lang, db, hosting, ci, deploy_method

Resolution rules (in order):

| Condition | lang |
|-----------|------|
| has_swift | swift |
| has_gomod AND has_package_json | mixed |
| has_gomod | go |
| has_package_json (no go.mod) | typescript |
| has_pyproject | python |
| else | unknown |

| Condition | db |
|-----------|---|
| has_supabase | supabase |
| has_migrations AND has_postgres | postgres |
| else | unknown |

| Condition | hosting |
|-----------|---------|
| has_k8s | gke |
| has_vercel | vercel |
| has_swift | app-store |
| else | unknown |

| Condition | ci |
|-----------|---|
| has_circleci AND has_k8s | circleci+argocd |
| has_gha | github-actions |
| else | unknown |

| Condition | deploy_method |
|-----------|---------------|
| has_swift | xcodebuild-altool |
| has_k8s | argocd-sync |
| has_vercel AND NOT has_gomod | vercel-deploy |
| hosting=hetzner-vps | systemd-bash |
| else | unknown |

### Step 3. Ask founder if detection is ambiguous

If ANY field resolved to `unknown` OR lang=mixed (genuinely multi-stack), ask via:

```bash
source .claude/scripts/ask-lead.sh <task-id> "leadv2-init: detected stack is ambiguous. Questions:
1. What hosting does this project deploy to? (hetzner-vps / gke / vercel / app-store / other)
2. What CI/CD tool? (github-actions / circleci+argocd / manual)
3. Any specific deploy command or script to run?" --timeout 300
```

Default to `unknown` with TODO comment in stack.yaml if TIMEOUT.

### Step 4. Create .claude/leadv2-overrides/

```bash
mkdir -p ".claude/leadv2-overrides"
```

#### 4a. Resolve example source directory

Map detected stack to a working example under `examples/overrides/`. Copy files from the example when a match exists; fall back to the `generic/` stub set (which exits non-zero so failures are loud) when no match is found.

Stack → example dir mapping (checked in order):

| lang | hosting/deploy_method | example dir |
|------|-----------------------|-------------|
| typescript | vercel / vercel-deploy | `typescript-nextjs-vercel` |
| python | hetzner-vps / systemd-bash | `python-supabase-vps` |
| (anything else) | (any) | `generic` |

```bash
# Locate the plugin's examples directory.
# CLAUDE_PLUGIN_ROOT is exported by Claude Code for plugin skills (points at .../plugins/leadv2).
# When a skill's bash block runs via the Bash tool, BASH_SOURCE is empty — so prefer the env var
# and only fall back to path-derivation if it is unset (e.g. manual sourcing during tests).
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)}"
EXAMPLES_DIR="$PLUGIN_DIR/examples/overrides"

# Determine which example set to use
EXAMPLE_KEY="generic"
if [[ "$lang" == "typescript" && ( "$hosting" == "vercel" || "$deploy_method" == "vercel-deploy" ) ]]; then
  EXAMPLE_KEY="typescript-nextjs-vercel"
elif [[ "$lang" == "python" && ( "$hosting" == "hetzner-vps" || "$deploy_method" == "systemd-bash" ) ]]; then
  EXAMPLE_KEY="python-supabase-vps"
fi

EXAMPLE_SRC="$EXAMPLES_DIR/$EXAMPLE_KEY"
if [[ ! -d "$EXAMPLE_SRC" ]]; then
  # Defensive fallback: plugin examples dir missing — use generic stub inline
  EXAMPLE_SRC="$EXAMPLES_DIR/generic"
fi
```

#### 4b. Copy deploy/verify/outcome-watch from example (do NOT overwrite existing files)

```bash
OVERRIDE_DIR=".claude/leadv2-overrides"
COPIED_FROM_EXAMPLE=false

for f in deploy.sh verify.sh outcome-watch.sh codex-policy.yaml extensions.md; do
  if [[ ! -f "$OVERRIDE_DIR/$f" && -f "$EXAMPLE_SRC/$f" ]]; then
    cp "$EXAMPLE_SRC/$f" "$OVERRIDE_DIR/$f"
    # Make shell scripts executable
    [[ "$f" == *.sh ]] && chmod +x "$OVERRIDE_DIR/$f"
    COPIED_FROM_EXAMPLE=true
  fi
done

if [[ "$COPIED_FROM_EXAMPLE" == "true" ]]; then
  echo "leadv2-init: copied overrides from examples/$EXAMPLE_KEY"
else
  echo "leadv2-init: all override files already present — nothing copied"
fi
```

Note: if `EXAMPLE_KEY=generic`, the copied `deploy.sh` and `verify.sh` will exit non-zero with an actionable error message. This is intentional — silent `exit 0` stubs cause false recovery loops. The user must fill them in before running a leadv2 task with deployment.

#### 4c. Write stack.yaml with detected values (always generated, not copied from example)

Write `stack.yaml` with detected values. Mark unknown fields with `# TODO: fill in`.

#### 4d. Write state-paths.yaml (always generated)

```yaml
# .claude/leadv2-overrides/state-paths.yaml — generated by leadv2-init
# Uncomment and edit any line to override default file locations.
# board_path: docs/BOARD.md
# dialogue_path: docs/agents/product-owner/DIALOGUE.md
# queue_path: docs/agents/product-owner/QUEUE.md
# lead_state_path: docs/LEAD_V2_STATE.md
# handoff_dir: docs/handoff
# leadv2_dir: docs/leadv2
# queue_archive_dir: docs/agents/product-owner/queue/_archive
```

### Step 5. Report to lead

Output summary:
```
leadv2-init complete:
  lang: <detected>
  db: <detected>
  hosting: <detected>
  ci: <detected>
  deploy_method: <detected>
  example used: <typescript-nextjs-vercel | python-supabase-vps | generic>
  files created: stack.yaml, deploy.sh, verify.sh, outcome-watch.sh, codex-policy.yaml, state-paths.yaml, extensions.md
  TODOs: <list unknown fields>
  ACTION REQUIRED if example=generic: deploy.sh and verify.sh are stubs that exit non-zero — fill them in before running tasks
```

Set `LEAD_V2_STATE.md` note: "leadv2-init ran — overrides scaffolded. extensions.md TODOs need fill-in."

## Anti-patterns

- Do NOT delete existing `.claude/leadv2-overrides/` content — only add missing files.
- Do NOT hardcode credentials in generated scripts — use env var references.
- Do NOT block /leadv2 task start because init is incomplete — scaffold with TODOs and proceed.
