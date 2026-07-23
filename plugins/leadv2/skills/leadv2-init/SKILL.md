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

Scan project root for fingerprint files (has_pyproject, has_gomod, has_package_json,
has_swift, has_dockerfile, has_k8s, has_supabase, has_postgres, has_migrations,
has_circleci, has_gha, has_vercel). Run the full detection script from
[REFERENCE.md](./REFERENCE.md) §Step 1.

### Step 2. Determine lang, db, hosting, ci, deploy_method

Resolve each field from the detection signals using the resolution tables in
[REFERENCE.md](./REFERENCE.md) §Step 2. Every field resolves to a concrete value or `unknown`
(or `mixed` for lang when both go.mod and package.json are present).

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

Map detected stack to a working example under `examples/overrides/` (typescript+vercel →
`typescript-nextjs-vercel`, python+hetzner-vps → `python-supabase-vps`, else → `generic`).
Copy files from the matched example when found; fall back to the `generic/` stub set (which
exits non-zero so failures are loud) when no match exists. Full mapping table + the
`EXAMPLE_SRC` resolution bash: [REFERENCE.md](./REFERENCE.md) §Step 4a.

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

Static boilerplate template, always written verbatim: [TEMPLATES.md](./TEMPLATES.md) §Step 4d.

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
