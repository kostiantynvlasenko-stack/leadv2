---
name: leadv2-skill-synthesize
description: [internal] Auto-generates SKILL.md when pattern_for_immune repeats >=5x in history; first activation…
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
---

# Lead v2 Skill Synthesize — Self-Learning

**Threshold:** `LEADV2_SKILL_SYNTH_THRESHOLD` env (default `5`).
For bootstrap (sparse history): set to `3` until at least 10 patterns have promoted.
Trigger condition: same `pattern_for_immune` text appears in ≥ threshold reflections.

## When: Close phase, after lead-reflect, if same pattern_for_immune text ≥ threshold in history.
## When NOT: < threshold confirmations, or pattern already promoted to lead-patterns.md (CR-XX).

## Protocol

### 1. Cluster detection with normalization

After `lead-reflect` writes history entry, scan `LEAD_V2_STATE.md history:` for clusters. Normalize text before counting to catch near-duplicates:

```bash
# Extract, normalize (lowercase, collapse whitespace, strip punctuation),
# then count clusters.
python3 - <<'PY' docs/LEAD_V2_STATE.md
import sys, re, os, yaml
from collections import Counter

THRESHOLD = int(os.environ.get("LEADV2_SKILL_SYNTH_THRESHOLD", "5"))

with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
texts = []
for h in (d.get('history') or []):
    p = (h.get('reflect') or {}).get('pattern_for_immune')
    if p:
        norm = re.sub(r'[^\w\s]', '', p.lower())
        norm = re.sub(r'\s+', ' ', norm).strip()
        texts.append(norm)

for text, count in Counter(texts).most_common(10):
    if count >= THRESHOLD:
        print(f"{count}\t{text}")
PY
```

Threshold (configurable via env):
- **3-4 confirmations** → promote to `.claude/ref/lead-patterns.md` (CR-XX / MD-XX) via `lead-reflect`. No skill synthesis yet (unless `LEADV2_SKILL_SYNTH_THRESHOLD` ≤ 4).
- **≥ `LEADV2_SKILL_SYNTH_THRESHOLD` confirmations** → candidate for skill synthesis (continue this skill).

### 2. Compose distillation brief

Write `/tmp/distill-brief-<slug>.md`:

```
Task: distill a repeated pattern into a new executable SKILL.md.

Pattern text (confirmed <N> times): "<the pattern_for_immune text>"

Source tasks (from LEAD_V2_STATE history):
- <task-id 1>: <reflect context>
- <task-id 2>: ...
- ... (all 5+ occurrences)

Your deliverable — write a new file at .claude/skills/leadv2-<slug>/SKILL.md following this structure:

---
name: leadv2-<slug>
description: |
  <one-sentence what it does>. <one-sentence when to use>.
  Triggers: <specific situations>.
allowed-tools:
  - <minimal set>
---

# <Human name>

## When: <specific condition>
## When NOT: <explicit exclusion>

## Protocol

<numbered steps, concrete>

## Output format

<if the skill produces output>

## Rules

<3-7 bullets — hard constraints>

## Anti-patterns

<3-5 bullets — what NOT to do>
---

Constraints:
- Skill must be invocable — don't write philosophy, write executable steps.
- Cite source task-ids in a comment inside the skill for traceability.
- Keep total ≤100 lines.
- End file with no trailing text after anti-patterns section.

DELIVERABLE_COMPLETE must be the last line of the SKILL.md you create.
```

### 3. Spawn developer subsession

Write the distillation brief to `/tmp/distill-brief-<slug>.md` (see §2 for format), but update the deliverable path to the shadow location:

```
Your deliverable — write a new file at .claude/skills/_shadow/leadv2-<slug>/SKILL.md
```

Then spawn:

```bash
.claude/scripts/claude-subsession.sh --role developer --model sonnet \
  --task-id skill-synth-<slug>-<ts> \
  --mission-file /tmp/distill-brief-<slug>.md \
  --wait
```

### 4. Shadow mode — write to _shadow/, not skills/

After the subsession completes, verify the file exists at `.claude/skills/_shadow/leadv2-<slug>/SKILL.md`.

Open the file and prepend shadow frontmatter fields. The final frontmatter must include:
```yaml
shadow: true
shadow_since: <iso-date>
```

Shadow skills are NOT auto-loaded by Claude Code (they live outside `.claude/skills/`). This is intentional — they are inert until promoted.

**Do NOT write to `.claude/skills/leadv2-<slug>/` at this stage.** The direct-to-skills path is retired.

### 5. Register shadow skill for observation

Append to `.claude/ref/lead-patterns.md#shadow-log`:

```
| <date> | leadv2-<slug> | shadow_started | pending 5 observations |
```

Notify founder via `PushNotification`:
```
"Shadow skill created: leadv2-<slug> (pattern: '<pattern text>'). Observing next 5 matching tasks before promotion."
```

### 6. Shadow observation protocol (5-task window)

On each subsequent task where the skill's trigger would have matched:

1. Execute the actual task using current rules (without the shadow skill — it is inert).
2. After close, read the shadow skill and ask: "Would following this skill have changed routing or classification?" Answer yes/no with one sentence of reason.
3. Append one row to `.claude/ref/lead-patterns.md#shadow-log`:
   ```
   | <date> | leadv2-<slug> | would-have-changed: y/n | actual-outcome: <outcome> |
   ```

After 5 shadow observations, evaluate:
- **≥4 "would-not-have-hurt"** (shadow decision matched reality OR shadow suggested same path) → promote (§7)
- **≥2 "would-have-hurt"** (shadow would have caused rollback or wrong class) → auto-reject (§8)
- Neither threshold met yet → continue observing

### 7. Promotion — shadow → active skill

On promotion trigger:
1. Move `.claude/skills/_shadow/leadv2-<slug>/SKILL.md` → `.claude/skills/leadv2-<slug>/SKILL.md`
2. In the frontmatter, remove `shadow: true` and `shadow_since:`; add `promoted_from_shadow: <iso-date>`
3. Invoke `/reload-skills` so the promoted skill is discoverable in the **current** session (Claude Code ≥ 2.1.152). Without this, the freshly-promoted skill only loads at the next SessionStart — meaning the self-learning loop's payoff is delayed a full session.
4. Append to `.claude/ref/lead-patterns.md#promotion-log`:
   ```
   | <date> | <slug> | <source task-ids> | shadow-promoted (5 observations) |
   ```
5. Append to `.claude/ref/lead-patterns.md#synthesis-log`:
   ```
   | <date> | <slug> | shadow-promoted | <N-th auto-skill> |
   ```
6. Notify founder via `PushNotification`: "Скилл leadv2-<slug> прошёл shadow проверку и добавлен в .claude/skills/. Можешь ревьюнуть."
7. Founder can still revert via `/leadv2 skill-revert <slug>` (see §9).

### 8. Auto-reject — shadow regression

If ≥2 "would-have-hurt" observations:
1. Delete `.claude/skills/_shadow/leadv2-<slug>/` directory
2. Append to `.claude/ref/lead-patterns.md#synthesis-log`:
   ```
   | <date> | <slug> | auto-rejected: shadow-regression | <N hurt observations> |
   ```
3. Restore the original 5 `pattern_for_immune:` entries to `LEAD_V2_STATE history:` (they were NOT deleted — see §3 note below)
4. Log the rejection; no founder approval needed.

**Note on source entries:** Do NOT delete the 5 source `pattern_for_immune:` entries during synthesis — keep them in history until promotion is confirmed. Only delete them at promotion time (§7 does not include this step; they decay naturally via TTL).

### 9. Rollback mechanism (promoted skills)

If a promoted skill turns out bad:
- Founder invokes `/leadv2 skill-revert <slug>`
- That deletes `.claude/skills/leadv2-<slug>/SKILL.md` + appends to synthesis-log: `reverted: <reason>`
- The original source patterns return to `.claude/ref/lead-patterns.md#immune` manually

### 10. Founder override commands

- `/leadv2 skill-activate <slug>` — force promote shadow skill immediately (skip remaining observations)
- `/leadv2 skill-shadow-reject <slug>` — manually reject shadow skill (same as auto-reject flow)
- `/leadv2 skill-revert <slug>` — revert a promoted skill

Track accept count in `.claude/ref/lead-patterns.md#synthesis-log`.

## Rules

- **Threshold is `LEADV2_SKILL_SYNTH_THRESHOLD` env (default 5)**, not hardcoded. 3-4 = pattern in ref/lead-patterns.md. ≥ threshold = skill synthesis candidate. Bootstrap: set both SYNTH and REFLECT to 3 until 10 patterns promoted.
- **All new skills start in shadow mode.** Write to `.claude/skills/_shadow/`, never directly to `.claude/skills/`. Founder approval happens at promotion time (after 5 shadow observations), not at creation time.
- **Shadow skills are inert.** They live outside `.claude/skills/` intentionally — Claude Code does not auto-load them.
- **Name is `leadv2-<slug>`** — keeps lead-v2-specific skills grouped.
- **Never auto-synthesize a skill from a single task** — might be task-specific, not a reusable pattern.
- **Distiller runs in Sonnet subsession, not Opus.** Opus here is overkill.
- **Keep frontmatter spec consistent**: fields `name`, `description`, `allowed-tools` are required. Shadow skills add `shadow: true` + `shadow_since: <iso>`. Promoted skills add `promoted_from_shadow: <iso>`.
- **Do not delete source pattern_for_immune entries during synthesis** — keep them until shadow promotion is confirmed; they provide a rollback path.

## Anti-patterns

- Writing directly to `.claude/skills/leadv2-<slug>/` at synthesis time — shadow mode replaced this path.
- Asking founder for approval at creation time — shadow observation window is the gate now.
- Synthesizing at threshold of 3 in steady-state — only acceptable during bootstrap (sparse history, explicit env set); revert to default 5 once ≥10 patterns promoted.
- Allowing the skill to replace fundamental manual checks — the skill augments, doesn't replace lead-gate-check.
- Not logging rejections — loses signal about what pattern was miscategorized.
- Skipping the shadow-log append — without it the observation counter can't be tracked.
