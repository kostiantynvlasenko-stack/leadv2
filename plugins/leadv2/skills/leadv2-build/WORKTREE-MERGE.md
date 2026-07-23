# leadv2-build — worktree merge protocol

Referenced from SKILL.md §2b ("Worktree isolation — when and how"). Run this
after all isolated agents in a group complete — it is the exact merge/conflict
procedure to follow whenever the group used `isolation: "worktree"`.

## Merge protocol

```bash
# Record the base SHA the lead session started from (do this ONCE before spawning agents,
# NOT mid-merge). The worktree's branch was forked off this commit, so it's the right diff base
# for any branch — even if `main` has moved or the lead is working off a feature branch.
TASK_START_SHA="${TASK_START_SHA:?must be set in Phase 0 intake}"   # e.g. $(git rev-parse HEAD)

# Each agent returns its worktree path + branch in the Agent result.
MERGED=()
CONFLICTED=()
for entry in "${WORKTREE_ENTRIES[@]}"; do
  branch="${entry%%::*}"
  worktree_path="${entry#*::}"
  patch_file="/tmp/leadv2-${TASK_ID}-$(echo "$branch" | tr '/' '_').patch"

  if git merge --no-ff --no-edit "$branch"; then
    MERGED+=("$entry")
    continue
  fi

  # Conflict → fall back to 3-way patch from the recorded base SHA, NOT `main..HEAD`
  (cd "$worktree_path" && git diff "$TASK_START_SHA"..HEAD) > "$patch_file"
  if git apply --3way --reject "$patch_file"; then
    MERGED+=("$entry")
    _leadv2_log "[build] soft 3-way merge ok for $branch"
  else
    # Reject files present — DO NOT touch worktree or branch yet, lead needs them for inspection
    CONFLICTED+=("$entry::$patch_file")
    _leadv2_log "[build] manual merge needed for $branch — patch=$patch_file, see *.rej"
  fi
done

# Cleanup ONLY for cleanly-merged branches. Conflicted ones stay on disk for recovery.
for entry in "${MERGED[@]}"; do
  branch="${entry%%::*}"
  worktree_path="${entry#*::}"
  git worktree remove "$worktree_path" --force 2>/dev/null
  git branch -D "$branch" 2>/dev/null
done

# Conflicted branches are passed to recovery as a structured list:
if (( ${#CONFLICTED[@]} > 0 )); then
  printf '%s\n' "${CONFLICTED[@]}" > "docs/handoff/${TASK_ID}/merge-rejects.md"
  # Recovery decides whether to keep worktrees, drop them, or hand-merge.
  # DO NOT auto-cleanup conflicted worktrees here.
fi
```

**Conflict policy:**
- Clean `git merge` → MERGED, cleanup worktree + branch
- `git apply --3way` succeeds (no `.rej`) → MERGED, cleanup, log soft conflict
- `.rej` files present → CONFLICTED, **keep worktree + branch on disk**, write `docs/handoff/<task-id>/merge-rejects.md` listing branch::patch_file pairs, escalate to recovery (do NOT re-spawn the same agent, do NOT cleanup until human or recovery decides)

**Token cost:** worktree creation is git-only, no LLM tokens. Agents in worktrees see exactly the same repo state — no extra context cost.
