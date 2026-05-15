# Development

## Repo structure

```
leadv2/
├── .claude-plugin/
│   └── marketplace.json          # marketplace manifest (one entry: leadv2 plugin)
├── plugins/
│   └── leadv2/
│       ├── .claude-plugin/
│       │   └── plugin.json       # plugin manifest
│       ├── commands/
│       │   └── leadv2.md         # /leadv2 entry-point command
│       ├── agents/               # subagent definitions
│       │   ├── architect.md
│       │   ├── critic.md
│       │   ├── security-auditor.md
│       │   └── SCHEMA.md
│       ├── hooks/
│       │   ├── hooks.json        # hook registration (PreToolUse, PostToolUse, ...)
│       │   └── *.sh              # hook scripts
│       ├── scripts/              # helper scripts the lead and skills call
│       │   ├── leadv2-helpers.sh # shared library — sourced by many other scripts
│       │   ├── leadv2-state-compact.sh
│       │   └── ...
│       └── skills/               # skills the lead invokes via Skill tool
│           ├── leadv2-init/
│           │   └── SKILL.md
│           ├── leadv2-plan/
│           ├── leadv2-build/
│           ├── ...
├── docs/
├── examples/overrides/
├── README.md
├── CHANGELOG.md
├── LICENSE
└── .gitignore
```

## Local development

To develop on the plugin while using it:

```sh
# Clone
gh repo clone kostiantynvlasenko-stack/leadv2 ~/Projects/leadv2

# Install locally (overrides any installed copy)
# In Claude Code:
/plugin marketplace add file:///Users/$USER/Projects/leadv2
/plugin install leadv2
```

Edits to files in `~/Projects/leadv2/plugins/leadv2/` take effect on the next Claude Code session start.

## Adding a skill

1. Create `plugins/leadv2/skills/<your-skill>/SKILL.md`
2. Frontmatter:
   ```markdown
   ---
   name: your-skill
   description: One-line trigger description — when the lead should invoke this
   allowed-tools:
     - Read
     - Bash
   ---
   ```
3. Body: instructions for the LLM. Be concrete — write the bash commands, paths, decision tables.
4. If the skill needs a helper script, add it to `plugins/leadv2/scripts/` and reference via `${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh`.
5. Update `docs/ARCHITECTURE.md` if the skill changes the phase model.

## Adding a hook

1. Create `plugins/leadv2/hooks/<your-hook>.sh`
2. Make it executable: `chmod +x`
3. Register in `plugins/leadv2/hooks/hooks.json` under the relevant lifecycle event (`PreToolUse`, `PostToolUse`, `SessionStart`, `UserPromptSubmit`, ...)
4. Use a tight timeout (5-10s). Hooks block the main loop.
5. Exit codes: `0` = allow, non-zero = block (or pass-through with warning, depending on event).

## Conventions

- **Bash**: `set -euo pipefail` at the top of every script. Defensive flag parsing. No heredocs (use file refs).
- **Markdown**: H2 sections for major concepts. Tables for decision matrices. Code blocks fenced with explicit language.
- **Skill frontmatter**: `name`, `description`, `allowed-tools` (minimum), and any opt-in flags.
- **State files**: write via `leadv2-state-atomic-write.sh` — never raw `cat > file`. Drift between STATE.md and pulse.md was the root cause of two prod incidents.
- **No persona-engine references**: the public plugin must be project-agnostic. Add anything project-specific to `.claude/leadv2-overrides/extensions.md` instead.

## Testing changes

There's no formal test suite yet. To smoke-test:

```sh
# 1. Fresh test dir
mkdir -p /tmp/leadv2-test && cd /tmp/leadv2-test && git init

# 2. In Claude Code (with the plugin pointing at your local clone):
/leadv2

# Expected: leadv2-init scaffolds .claude/leadv2-overrides/
# Verify the files were created and contain TODO markers
```

For deeper testing, fill in deploy.sh/verify.sh with no-op scripts (`echo done; exit 0`) and run `/leadv2 add a comment to README.md` — should run through all phases without hitting external systems.

## Releasing

```sh
# In ~/Projects/leadv2:
# 1. Update CHANGELOG.md with the version + changes
# 2. Bump version in:
#    - .claude-plugin/marketplace.json
#    - plugins/leadv2/.claude-plugin/plugin.json
# 3. Commit
git commit -am "release: vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

Users get the new version via `/plugin update leadv2`.

## Code reviews

PRs welcome. Please:

- Run `bash -n` on any new shell scripts before pushing
- Verify no `persona-engine|/home/persona|Timbre|PO QUEUE` references slipped in: `grep -ri ...`
- If you change phase mechanics, update `docs/ARCHITECTURE.md`
- If you change overrides, update `docs/OVERRIDES.md`

## Style

- English in code, docs, and prose
- Concise > verbose
- Concrete commands > "and then you would..."
- Comments only when WHY is non-obvious; never just restate WHAT the code does
