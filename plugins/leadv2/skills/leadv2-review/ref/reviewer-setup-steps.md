# Reviewer setup steps 1b-1e (leadv2-review)

Referenced from `leadv2-review/SKILL.md` §1b-1e. These run before spawning any reviewer.

## 1b. Ensure question-proxy Monitor is running

If not already started in Phase 2 (because Trivial task skipped Plan), start it now:

```
Monitor:
  command: while true; do
    for sig in docs/handoff/*/questions/_signal; do
      [[ -f "$sig" ]] && {
        task_id=$(echo "$sig" | awk -F/ '{print $(NF-2)}')
        echo "QUESTION_PENDING:$task_id"
        rm -f "$sig"
      }
    done
    sleep 5
  done
  description: "subagent question mailbox"
  persistent: true
  timeout_ms: 3600000
```

## 1c. Prepare diff for reviewers

Before spawning any reviewer, generate and store the diff:

```bash
# Generate diff from task start SHA to current HEAD
git diff "${TASK_START_SHA}..HEAD" > "/tmp/leadv2-review-${TASK_ID}.diff"
# Also write to handoff dir for persistence
cp "/tmp/leadv2-review-${TASK_ID}.diff" "docs/handoff/${TASK_ID}/diff.patch"
```

Reviewer mission files MUST include a `## Diff` section embedding the path to the diff file:
```
## Diff
File: /tmp/leadv2-review-<task-id>.diff
Read this diff first. Review diff, not full files.
Budget: spend <15% of tokens on file-context lookups (allowed when diff lacks context).
```

**Security-auditor exception:** may always read full files in security-sensitive paths without the 15% budget constraint:
- `platform/safety/`
- `platform/auth/`
- Any file matching `*crypto*`, `*auth*`, `*token*`, `*secret*`, `*webhook*`, `*billing*`

## 1d. Prompt-cache discipline

Never issue standalone API warm calls before Review. Their prefix differs from
Claude Code's system/tool prefix, so they add spend without guaranteeing a
cache hit. Keep model/cwd/tool definitions stable across reviewer spawns and
use `cache_read_input_tokens` telemetry as the only cache-hit truth.

## 1e. Compress Build outputs before reading

Before reading developer.md / diff.md produced by the Build phase, compress them if large:

```bash
source .claude/scripts/lv2 leadv2-helpers.sh
leadv2_compress_handoff "docs/handoff/${TASK_ID}/developer.md"
leadv2_compress_handoff "docs/handoff/${TASK_ID}/diff.md"
# Then read via helper (falls back to original when no twin exists)
dev_output=$(leadv2_read_handoff "docs/handoff/${TASK_ID}/developer.md")
```

Files ≤8KB or YAML → no-op. Saves ~50-70% Opus tokens on large developer deliverables.
