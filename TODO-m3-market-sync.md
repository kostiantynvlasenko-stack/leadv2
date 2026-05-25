# TODO: sync m3-market to public leadv2 plugin

> Deferred from session 2026-05-15 — founder was actively working in m3-market and asked to skip it. Persona-engine and respiro-ios were synced.

## Context

The public leadv2 plugin lives at `~/Projects/leadv2/` and is pushed to https://github.com/kostiantynvlasenko-stack/leadv2 (v0.1.0). The user's local plugin `~/.claude/plugins/local/leadv2/plugins/leadv2/` is now a **symlink** to `~/Projects/leadv2/plugins/leadv2/` — edits propagate instantly.

PE-specific extras (telegram, po-queue, hotfix-batch skill, m3-market codex-ban) live in a separate local plugin: `~/.claude/plugins/local/leadv2-pe-extras/`.

Two repos were already synced (project-side `.claude/scripts/leadv2-*.sh` replaced with symlinks to plugin scripts):
- `~/Projects/persona-engine/` — 76 linked, 14 project-only kept, .gitignore updated
- `~/Projects/respiro-ios/` — 76 linked, 2 project-only kept, .gitignore updated

**m3-market was NOT touched.** Do it in this task.

## What to do

Apply the same sync to `~/MythicalGames/m3-market/`.

### Step 1 — sanity check m3-market overrides

```bash
ls ~/MythicalGames/m3-market/.claude/leadv2-overrides/
# expected files: codex-policy.yaml (codex_enabled: false), deploy.sh, extensions.md,
# outcome-watch.sh, stack.yaml, state-paths.yaml, verify.sh
```

All should be present. If missing — stop, surface to founder, don't auto-scaffold.

### Step 2 — inventory of leadv2-*.sh in m3-market

```bash
PLUGIN=~/Projects/leadv2/plugins/leadv2/scripts
PROJ=~/MythicalGames/m3-market/.claude/scripts

for f in "$PROJ"/leadv2-*.sh; do
  [[ -e "$f" ]] || continue
  name=$(basename "$f")
  if [[ -L "$f" ]]; then echo "  ALREADY-LINK: $name"
  elif [[ -e "$PLUGIN/$name" ]]; then echo "  WILL-LINK: $name"
  else echo "  PROJECT-ONLY (keep): $name"
  fi
done
```

Save the inventory output. PROJECT-ONLY files stay as-is. WILL-LINK files get replaced with symlinks.

### Step 3 — replace WILL-LINK files with symlinks

```bash
PLUGIN=~/Projects/leadv2/plugins/leadv2/scripts
PROJ=~/MythicalGames/m3-market/.claude/scripts
count_link=0; count_keep=0

for f in "$PROJ"/leadv2-*.sh; do
  [[ -e "$f" ]] || continue
  [[ -L "$f" ]] && continue
  name=$(basename "$f")
  if [[ -e "$PLUGIN/$name" ]]; then
    rm "$f" && ln -s "$PLUGIN/$name" "$f"
    count_link=$((count_link+1))
  else
    count_keep=$((count_keep+1))
  fi
done
echo "linked: $count_link, kept: $count_keep"
```

Expect ~76 linked, ~2-5 kept (m3-specific project scripts).

### Step 4 — untrack symlinks in git + add .gitignore entries

```bash
cd ~/MythicalGames/m3-market

to_ignore=()
for f in .claude/scripts/leadv2-*.sh; do
  [[ -L "$f" ]] && to_ignore+=("$f")
done

for f in "${to_ignore[@]}"; do
  git rm --cached -q "$f" 2>/dev/null || true
done

if ! grep -q "# leadv2 plugin symlinks" .gitignore 2>/dev/null; then
  printf '\n# leadv2 plugin symlinks (per-machine; points into ~/Projects/leadv2/)\n' >> .gitignore
  for f in "${to_ignore[@]}"; do
    echo "$f" >> .gitignore
  done
fi
```

### Step 5 — verify

```bash
# helpers.sh symlink resolves and parses:
readlink ~/MythicalGames/m3-market/.claude/scripts/leadv2-helpers.sh
bash -n ~/MythicalGames/m3-market/.claude/scripts/leadv2-helpers.sh && echo "ok"

# git status looks right (D for untracked symlinks, M for .gitignore):
cd ~/MythicalGames/m3-market && git status --short .claude/scripts/ .gitignore | head -10
```

### Step 6 — surface git diff for founder review

Don't auto-commit. m3-market is corp repo — founder reviews the .gitignore diff and 76 untracked files BEFORE committing. Output:

```
cd ~/MythicalGames/m3-market && git status .claude/scripts/ .gitignore
```

Then say to founder: "All synced. Ready to commit `git add .gitignore && git commit -m 'chore: untrack leadv2 plugin scripts (now symlinks)'` when you want."

## Reminders

- **NO Codex in m3-market.** Per `~/.claude/CLAUDE.md`: "m3-market: NO Codex / GPT-5 — ever". The new generic block-codex hook (in plugin) + the pe-extras cwd-ban hook both enforce this. Don't disable either.
- **Don't push the public leadv2 plugin** from m3-market context — that's a private corp repo, mixing contexts.
- Backup `~/.claude/plugins/local/leadv2.bak-pre-sync-*` still exists if anything went catastrophically wrong. Don't delete until m3-market sync is verified.

## Expected outcome

- 76 leadv2 plugin scripts in m3-market `.claude/scripts/` now symlinks to `~/Projects/leadv2/plugins/leadv2/scripts/`
- m3-market `.gitignore` has 76 new entries + comment header
- m3-market workflow continues working as before (overrides already present, codex still banned, no other changes)
- Founder commits the `.gitignore` change when ready
