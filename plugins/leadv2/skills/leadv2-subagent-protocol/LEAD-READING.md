## 10. Lead reading discipline — context-hygiene rules for the orchestrator

These rules apply to the **lead** (Sonnet/Opus orchestrator chat), not the subagent. They exist because each turn re-sends the entire lead history; any KB read into chat compounds per turn until compaction kicks in.

**Hard rules for lead when consuming subagent output:**

1. **Default = read `.summary.md` only, with `Read offset=0 limit=30`.** Never read full deliverables in chat unless the summary flagged a conflict, ambiguity, or block.
2. **`.full.md` reads are bounded.** If you must inspect the full deliverable, use `Read offset=0 limit=30` first (header + DELIVERABLE_COMPLETE check). Read the body only if the header doesn't answer your question.
3. **Mission/prompt files: write to disk via Write, never inline-paste in chat.** Templates live at `~/.claude/prompts/leadv2-<role>.md`. Spawn scripts read them by path. The body never enters lead transcript.
4. **SSH / journal / log output: filter at source.** Never `journalctl ...` raw — always pipe through `grep -E '<signal>'` and `tail -50` or `head -50` on the remote side. Use `~/.claude/scripts/ssh-grep.sh <host> <unit> <pattern>` (see helper).
5. **Bash output that exceeds 100 lines: pre-truncate at the source command.** Never `cmd | head -50` from lead — always `cmd --limit 50` or remote `head/tail/grep` flags.
6. **No polling.** Never re-check `git status` between edits, never `wc -c` background output files, never `codex-task.sh status`. Wait for `<task-notification>` and read the deliverable.
7. **Effort routing:** spawn `--effort max` only when classification is Heavy or Strategic. Standard/Light → `--effort high`. Trivial → no subsession (use Agent tool).
8. **Pre-compute heavy data outside subagents.** If a subagent needs aggregates (action_log fingerprint, follower deltas, action counts), compute in bash via `sb_get` + `jq` and embed the *result* in the mission file. Don't make Opus burn 30k tokens reading 200 raw rows.
9. **Don't re-paraphrase deliverables to founder.** If founder asks "what did architect say?", quote the `.summary.md` (≤50 words) directly — don't re-narrate.

**Failure modes this prevents:** see `ref/lead-reading-failure-modes.md` for the 3 concrete
token-burn examples (30k-token full reads, raw journalctl dumps, inline mission writes).

When you violate one of these, save a `feedback` memory the same turn so the next session learns. Don't just apologize — document.

## 3-tier read protocol (jcode-inspired)

Lead reads subagent output at three explicit tiers — never the full file by default. This is mandatory; deliverable-format below MUST support all three.

| Tier | What | When | How |
|---|---|---|---|
| **Status snapshot** | Lifecycle event only — task-notification | Always | Auto: spawn returns `task-notification` with output path; lead does NOT Read yet |
| **Summary read** | Verdict + summary_for_lead + severity counts | Default after notification | `bash .claude/scripts/critic-tail.sh <file>` OR `Read limit=10` |
| **Full context read** | Whole deliverable | ONLY when summary signals REVISE / no-ship / NEEDS-INFO | `Read offset=X limit=Y` — never unbounded |

**Subagent obligations:**
- First line: `Verdict: APPROVE | REVISE | NEEDS-INFO | BLOCK`
- Second line: `summary_for_lead: <≤30 words>`
- Severity-tagged findings use predictable labels (`critical:`, `c1:`, `severity: critical`, etc.) so `critic-tail.sh` can count them.
- Last line literally: `DELIVERABLE_COMPLETE`

**Lead obligations:**
- After task-notification: `bash .claude/scripts/critic-tail.sh <file>` for review-class deliverables, `Read limit=10` for build-class.
- Full read ONLY when tier-2 signals action required.
- Never `TaskOutput` a subsession stream file — overflow risk.

## Handoff-file compression (M5)

Subagent produces `<role>.summary.md` (≤50 words for chat) + `<role>.full.md` (full content, ends with `DELIVERABLE_COMPLETE`). Lead may automatically emit `<role>.compressed.md` after detecting `DELIVERABLE_COMPLETE` — **do not generate the compressed file yourself**. The compression runs on the lead side via `leadv2_compress_handoff` and is transparent to the subagent.
