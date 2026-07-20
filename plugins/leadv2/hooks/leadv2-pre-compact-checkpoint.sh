#!/usr/bin/env bash
# PreCompact hook: write per-task pre-compact-resume.md (+ .json) before compaction, for
# EVERY task in active.yaml sessions[] (not just the first). Legacy checkpoint.md path is
# unchanged for tasks that have one; tasks with no checkpoint.md but a journal.md/STATE.md
# get a composed resume instead. Resolves tasks from active.yaml (same logic as
# leadv2-user-prompt-context.sh).
# Always exits 0 — never blocks compaction; a single task's failure never aborts the loop.
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

# Resolve leadv2_dir from state-paths.yaml (mirrors user-prompt-context.sh logic)
_lv2_sp_yaml="${CWD}/.claude/leadv2-overrides/state-paths.yaml"
_lv2_leadv2_dir=$(grep -E "^[[:space:]]*leadv2_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*leadv2_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"']//; s/['\"'][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_leadv2_dir" || "$_lv2_leadv2_dir" == "null" || "$_lv2_leadv2_dir" == "~" ]] && _lv2_leadv2_dir="docs/leadv2"

_lv2_handoff_dir=$(grep -E "^[[:space:]]*handoff_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*handoff_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"']//; s/['\"'][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_handoff_dir" || "$_lv2_handoff_dir" == "null" || "$_lv2_handoff_dir" == "~" ]] && _lv2_handoff_dir="docs/handoff"

# Find active.yaml
ACTIVE_FILE=""
for f in "${CWD}/.claude/leadv2-tasks/active.yaml" "${CWD}/${_lv2_leadv2_dir}/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE_FILE="$f" && break
done
[[ -z "$ACTIVE_FILE" ]] && exit 0

# Emit ALL sessions[] rows as "task_id<TAB>phase", deduped keeping first-seen order.
TASK_ROWS="$(python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    sessions = d.get('sessions') or []
    seen = {}
    for s in sessions:
        tid = (s.get('task_id') or '').strip()
        if not tid or tid in seen:
            continue
        seen[tid] = s.get('phase', '?')
    for tid, phase in seen.items():
        print(f'{tid}\t{phase}')
except Exception:
    pass
" "$ACTIVE_FILE" 2>/dev/null || true)"

[[ -z "$TASK_ROWS" ]] && exit 0

while IFS=$'\t' read -r TID PHASE_NOW; do
  [[ -z "$TID" ]] && continue

  (
    set -e
    TASK_DIR="${CWD}/${_lv2_leadv2_dir}/tasks/${TID}"
    CHECKPOINT="${TASK_DIR}/checkpoint.md"
    STATE_FILE="${TASK_DIR}/STATE.md"
    JOURNAL_FILE="${TASK_DIR}/journal.md"
    RESUME="${TASK_DIR}/pre-compact-resume.md"

    # Compose cache: short-circuit recomposition when task sources are unchanged.
    # Key = sha256(task_id|journal_mtime|state_mtime)[:12]. Fail-soft: any cache
    # error falls through to normal composition below (never breaks the hook).
    RESUME_JSON="${TASK_DIR}/pre-compact-resume.json"
    CACHE_DIR="${CWD}/${_lv2_leadv2_dir}/cache/summaries"
    JOURNAL_MTIME=""
    STATE_MTIME=""
    CHECKPOINT_MTIME=""
    [[ -f "$JOURNAL_FILE" ]] && JOURNAL_MTIME="$(stat -c %Y "$JOURNAL_FILE" 2>/dev/null || stat -f %m "$JOURNAL_FILE" 2>/dev/null || echo "")"
    [[ -f "$STATE_FILE" ]] && STATE_MTIME="$(stat -c %Y "$STATE_FILE" 2>/dev/null || stat -f %m "$STATE_FILE" 2>/dev/null || echo "")"
    [[ -f "$CHECKPOINT" ]] && CHECKPOINT_MTIME="$(stat -c %Y "$CHECKPOINT" 2>/dev/null || stat -f %m "$CHECKPOINT" 2>/dev/null || echo "")"
    CACHE_INPUT="${TID}|${JOURNAL_MTIME}|${STATE_MTIME}|${CHECKPOINT_MTIME}"
    CACHE_KEY="$(printf '%s' "$CACHE_INPUT" | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null || true; } | cut -c1-12)"
    if [[ -n "$CACHE_KEY" \
           && -f "${CACHE_DIR}/${CACHE_KEY}.md" \
           && -f "${CACHE_DIR}/${CACHE_KEY}.json" ]] \
       && mkdir -p "$TASK_DIR" 2>/dev/null \
       && cp "${CACHE_DIR}/${CACHE_KEY}.md" "$RESUME" 2>/dev/null \
       && cp "${CACHE_DIR}/${CACHE_KEY}.json" "$RESUME_JSON" 2>/dev/null; then
      exit 0  # cache hit — reuse composed pair, skip recomposition
    fi
    if [[ -f "$CHECKPOINT" ]]; then
      # (a) legacy path — unchanged: copy checkpoint.md + standard instruction block
      mkdir -p "$TASK_DIR" 2>/dev/null || true
      {
        cat "$CHECKPOINT"
        printf -- '\n---\n'
        printf -- 'After /compact: read %s/tasks/%s/STATE.md limit=20 and %s/%s/context.yaml limit=30.\n' \
          "$_lv2_leadv2_dir" "$TID" "$_lv2_handoff_dir" "$TID"
        printf -- 'NEVER write .py/.sh/.ts/.tsx/.sql directly. Delegate ALL code changes to developer subagents.\n'
      } > "$RESUME" 2>/dev/null
    elif [[ -f "$JOURNAL_FILE" || -f "$STATE_FILE" ]]; then
      # (b) composed path — no checkpoint.md, but journal.md and/or STATE.md exist
      mkdir -p "$TASK_DIR" 2>/dev/null || true
      GOAL_LINE=""
      if [[ -f "$STATE_FILE" ]]; then
        GOAL_LINE="$(grep -m1 -E '^goal:[[:space:]]*' "$STATE_FILE" 2>/dev/null | sed -E 's/^goal:[[:space:]]*//' || true)"
      fi
      {
        printf -- 'task: %s / phase: %s\n' "$TID" "$PHASE_NOW"
        [[ -n "$GOAL_LINE" ]] && printf -- 'goal: %s\n' "$GOAL_LINE"
        printf -- '\n## Journal tail\n'
        [[ -f "$JOURNAL_FILE" ]] && tail -n 15 "$JOURNAL_FILE" 2>/dev/null
        printf -- '\n---\n'
        printf -- 'After /compact: read %s/tasks/%s/STATE.md limit=20 and %s/%s/context.yaml limit=30.\n' \
          "$_lv2_leadv2_dir" "$TID" "$_lv2_handoff_dir" "$TID"
        printf -- 'NEVER write .py/.sh/.ts/.tsx/.sql directly. Delegate ALL code changes to developer subagents.\n'
      } > "$RESUME" 2>/dev/null
    else
      # Neither checkpoint.md, journal.md nor STATE.md exist — skip this task silently.
      exit 0
    fi

    # session_summary = last journal line (empty if no journal) — no fabrication of other fields.
    LAST_JOURNAL_LINE=""
    [[ -f "$JOURNAL_FILE" ]] && LAST_JOURNAL_LINE="$(tail -n 1 "$JOURNAL_FILE" 2>/dev/null || true)"

    python3 -c "
import json, sys
d = {
  'task_id': sys.argv[1],
  'phase': sys.argv[2],
  'latest_handoff': sys.argv[3],
  'written': sys.argv[4],
  'session_summary': sys.argv[5],
  'key_decisions': [],
  'blockers': [],
  'next_actions': [],
}
print(json.dumps(d, indent=2))
" "$TID" "$PHASE_NOW" "$(basename "$CHECKPOINT" 2>/dev/null || echo "checkpoint.md")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LAST_JOURNAL_LINE" \
      > "${TASK_DIR}/pre-compact-resume.json" 2>/dev/null

    # Cache miss: composition finished — persist pair atomically, prune to newest ~20.
    if [[ -n "$CACHE_KEY" && -f "$RESUME" && -f "$RESUME_JSON" ]]; then
      mkdir -p "$CACHE_DIR" 2>/dev/null || true
      _tmp_md="$(mktemp 2>/dev/null || echo "")"
      _tmp_json="$(mktemp 2>/dev/null || echo "")"
      if [[ -n "$_tmp_md" && -n "$_tmp_json" ]] \
         && cp "$RESUME" "$_tmp_md" 2>/dev/null \
         && cp "$RESUME_JSON" "$_tmp_json" 2>/dev/null; then
        mv -f "$_tmp_md" "${CACHE_DIR}/${CACHE_KEY}.md" 2>/dev/null || true
        mv -f "$_tmp_json" "${CACHE_DIR}/${CACHE_KEY}.json" 2>/dev/null || true
      fi
      rm -f "$_tmp_md" "$_tmp_json" 2>/dev/null || true
      (
        cd "$CACHE_DIR" 2>/dev/null || exit 0
        ls -t *.md 2>/dev/null | tail -n +21 | while IFS= read -r stale; do
          [[ -n "$stale" ]] && rm -f "$stale" "${stale%.md}.json" 2>/dev/null || true
        done
      ) || true
    fi
  ) || true
done <<<"$TASK_ROWS"

exit 0
