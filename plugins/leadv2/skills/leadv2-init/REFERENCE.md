# leadv2-init — Stack Detection Reference

Full detail for Step 1 (fingerprint scan) and Step 2 (resolution tables) of
the leadv2-init protocol. SKILL.md's Step 1/Step 2 headers point here.

## Step 1. Detect stack — fingerprint files

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

## Step 2. Determine lang, db, hosting, ci, deploy_method

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

## Step 4a. Resolve example source directory

Map detected stack to a working example under `examples/overrides/`. Copy files from the
example when a match exists; fall back to the `generic/` stub set (which exits non-zero so
failures are loud) when no match is found.

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
