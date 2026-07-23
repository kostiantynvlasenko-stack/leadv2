# Occasional / gated reference

Referenced from `SKILL.md` §6.5 and §7.5. These are low-frequency or flag-gated steps — read
this file when the pointer in SKILL.md fires, not on every run.

## Correction-detect

Before immune memory integration (SKILL.md §7), invoke correction-detect on the session:

```bash
# Check feature flag
detect_mode="${LEADV2_CORRECTION_DETECT:-0}"

if [[ "$detect_mode" != "0" ]]; then
  source "$(bash .claude/scripts/lv2 --path leadv2-helpers.sh)" 2>/dev/null || true
  # leadv2-correction-detect reads last 6 user messages from session
  # and classifies corrections vs reinforcements vs preferences
  # Results are written to immune memory (live)
  # See leadv2-correction-detect/SKILL.md for full protocol
  echo "[lead-reflect] invoking leadv2-correction-detect (mode=$detect_mode)"
fi
```

This step is non-blocking: if correction-detect fails or returns no candidates, continue to §7 without error.

## Weekly skill-usage tally

Once per ISO week, append a snapshot of skill wiring/usage to the log so dormant
skills get surfaced. Cheap — runs ~7 grep passes, no network.

```bash
LOG=docs/leadv2/skill-usage.log
week_now=$(date +%G-W%V)
last_week=$(grep -E '^# week=' "$LOG" 2>/dev/null | tail -1 | sed 's/^# week=//')
if [[ "$week_now" != "$last_week" ]]; then
  echo "# week=$week_now ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  bash .claude/scripts/lv2 leadv2-skill-usage-tally.sh >> "$LOG"
fi
```

Non-blocking — log file may not exist on first run; script creates it.
