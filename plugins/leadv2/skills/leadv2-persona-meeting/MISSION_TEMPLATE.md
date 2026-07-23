# Mission Template for Persona Meetings

This file contains the complete mission file template and detailed instructions for composing the meeting task sent to a persona via claude-subsession.

Write the mission file to `/tmp/meeting-<persona>-<date>.md` with the following structure and all deliverables:

```
Persona meeting: <persona>
Purpose: refresh STATE.md, append DIALOGUE.md, [update docs/tasks.yaml for PO via lib]

Current STATE:
<paste docs/agents/<persona>/STATE.md>

Last 5 DIALOGUE entries:
<paste>

Context inputs:
<paste BOARD HEAD, RECOVERY open, relevant metrics>

Your deliverable — write ALL of these:

1. docs/agents/<persona>/STATE.md — fully rewritten. Keep it ≤100 lines. Sections:
   - Current view: 1-2 paragraphs, what's true right now
   - Priorities: top 3-5 items with rationale
   - Off-limits / decisions made: locked choices (numbered Dn)
   - Open questions for next meeting
   - Last updated: <ISO timestamp>

2. docs/agents/<persona>/DIALOGUE.md — APPEND a new entry:
   ## <ISO timestamp> — Meeting
   - Triggered by: <staleness | user force | recovery | ...>
   - Decided: <3-5 bullet points>
   - Changed in STATE: <what shifted vs last meeting>
   - Follow-ups for lead: <if any>

3. docs/agents/<persona>/LAST_MEETING.md — overwrite with just:
   timestamp: <ISO>
   sessions_since: 0
   triggered_by: <reason>

4. (PO only) Add/update tasks in docs/tasks.yaml via lib — do NOT rewrite QUEUE.md (it is frozen with a redirect banner).
   For each new PO task identified during the meeting:
   ```bash
   source "$(bash .claude/scripts/lv2 --path leadv2-tasks-lib.sh)"
   leadv2_tasks_add "<task-id>" action <priority> \
     --title "<one-sentence mission>" \
     --origin po
   ```
   For tasks that should be blocked-on-human:
   ```bash
   leadv2_tasks_add "<task-id>" human-needed high \
     --title "<what's blocking>" \
     --origin po
   ```
   Keep total new tasks ≤15 per meeting. Anything deferred → note in DIALOGUE.md only.

Constraints:
- No UUIDs, no internal jargon in dialogue (founder-readable).
- Every "decision" must have rationale.
- If you (persona) disagree with prior DIALOGUE entry — note the shift explicitly.
DELIVERABLE_COMPLETE
```

## Key guidance

- **Persona independence**: The meeting is the persona's own view refresh, not a hand-off from the lead. Subsession memory is isolated — it will see only what you pass in the mission file.
- **STATE.md is the working view**: Keep it concise (≤100 lines), organized by Current view → Priorities → Off-limits → Open questions. This is the persona's canvas for next task.
- **DIALOGUE.md is the decision log**: Append (never rewrite), so the history of the persona's view shifts is preserved. Next meeting will reference this to see what changed.
- **LAST_MEETING.md is the staleness trigger**: Keep it accurate. The lead checks `sessions_since` to decide if the persona's view is stale enough to re-trigger a meeting.
- **PO tasks via lib, not QUEUE.md**: Use `leadv2-tasks-lib.sh` to add new actions to docs/tasks.yaml. QUEUE.md is deprecated (frozen with a banner redirect). Never touch QUEUE.md during a meeting.
- **Task ceiling**: ≤15 new tasks per meeting. If the PO identifies more, note them in DIALOGUE.md as deferred; they go into next month's meeting or a separate planning cycle.

## Context to include

When composing the mission file's "Context inputs" section:
- **For PO**: BOARD.md HEAD (top 10-15 lines), current RECOVERY TRACKER entries (if any), past 10 lines of LEAD_V2_STATE.md persona section, timbre/Threads metrics dashboard state (if available).
- **For Architect**: Past 3-5 context.yaml files from recent tasks (headings + key decisions only), current docs/agents/architect/STATE.md, index of docs/specs/* files (list + 1-line desc).
- **For Strategist**: Last week of Threads metrics (post count, engagement, discovery rate), diff of voice-dna.md from past 2 weeks, last 5 DIALOGUE.md entries.

Keep the inputs lean — subsession has finite context. Summarize, don't paste entire files.
