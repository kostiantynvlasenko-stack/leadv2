#!/usr/bin/env bash
# PreToolUse:Read combined gate — replaces three separate hooks:
#   leadv2-force-read-limit.sh
#   leadv2-read-dedup-hard.sh
#   leadv2-lead-read-guard.sh
# All checks run in a single process to eliminate triple posix_spawn overhead.
# PO-064: LEADV2_HOOK_PROFILE=1 enables per-hook timing log.
set -euo pipefail
trap 'echo "[leadv2-read-gate] error at line $LINENO" >&2; exit 0' ERR

# ── PO-064: profiling ───────────────────────────────────────────────────────
_HOOK_START_MS=0
if [[ "${LEADV2_HOOK_PROFILE:-0}" == "1" ]]; then
  _HOOK_START_MS=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo 0)
fi
_hook_profile_end() {
  if [[ "${LEADV2_HOOK_PROFILE:-0}" == "1" && "$_HOOK_START_MS" -gt 0 ]]; then
    local end_ms
    end_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo 0)
    local dur=$(( end_ms - _HOOK_START_MS ))
    mkdir -p "$HOME/.claude/state/leadv2"
    printf '%s,%s\n' "leadv2-read-gate" "$dur" \
      >> "$HOME/.claude/state/leadv2/hook-profile.log"
  fi
}
trap '_hook_profile_end; exit 0' EXIT

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

FPATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")"
[[ -z "$FPATH" ]] && exit 0

LIMIT="$(printf '%s' "$INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null || echo "")"
OFFSET="$(printf '%s' "$INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null || echo "")"

# =============================================================================
# SECTION 1 — force-read-limit
# Block reads of files >100 lines when no limit/offset given.
# =============================================================================
_check_force_read_limit() {
  [[ -n "$LIMIT" ]] && return 0
  [[ -n "$OFFSET" ]] && return 0
  [[ ! -f "$FPATH" ]] && return 0

  case "$FPATH" in
    *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.svg|*.ico|*.webp|*.mp4|*.mp3|*.zip|*.tar*|*.bin|*.so|*.dylib|*.ipynb)
      return 0;;
  esac

  local lines
  lines="$(wc -l < "$FPATH" 2>/dev/null | tr -d ' ')"
  [[ -z "$lines" ]] && return 0
  [[ "$lines" -le 100 ]] && return 0

  case "$(basename "$FPATH")" in
    STATE.md|active.yaml|context.yaml|pulse.md|pr-manifest.yaml)
      [[ "$lines" -le 200 ]] && return 0;;
  esac

  cat >&2 <<MSG
[leadv2-read-gate/force-read-limit] BLOCKED
File: $FPATH ($lines lines)
Reading without limit/offset on a file >100L floods lead context.

Fix one of:
  1. Read with limit=30 if you need the header/summary
  2. Read with offset=N limit=M for a specific section
  3. Delegate full read to Explore-haiku via Agent(subagent_type=Explore, model=haiku, run_in_background=true)
  4. For review/critic deliverables: bash .claude/scripts/lv2 leadv2-critic-tail.sh "$FPATH"

Override (rare): export LEADV2_ALLOW_FULL_READ=1 for this turn.
MSG

  [[ "${LEADV2_ALLOW_FULL_READ:-0}" == "1" ]] && return 0
  return 2
}

# =============================================================================
# SECTION 2 — read-dedup-hard
# Hard-block 3rd same-file no-limit Read in a session.
# =============================================================================
_dedup_persist() {
  local tracker="$1" path="$2" new_count="$3" new_no_limit="$4"
  if [[ -f "$tracker" ]]; then
    awk -F'\t' -v p="$path" -v c="$new_count" -v n="$new_no_limit" '
      BEGIN{found=0; OFS="\t"}
      $1==p {print p, c, n; found=1; next}
      {print}
      END{if (!found) print p, c, n}
    ' "$tracker" > "${tracker}.new" && mv "${tracker}.new" "$tracker"
  else
    printf "%s\t%d\t%d\n" "$path" "$new_count" "$new_no_limit" > "$tracker"
  fi
}

_check_read_dedup() {
  local session_id
  session_id="$(printf '%s' "$INPUT" | jq -r '.session_id // .session.id // empty' 2>/dev/null || echo "default")"
  local tracker="/tmp/.leadv2-read-tracker-${session_id}.tsv"

  local count=0 no_limit_count=0
  if [[ -f "$tracker" ]]; then
    local row
    row="$(awk -F'\t' -v p="$FPATH" '$1==p {print; exit}' "$tracker")"
    if [[ -n "$row" ]]; then
      count="$(printf '%s' "$row" | cut -f2)"
      no_limit_count="$(printf '%s' "$row" | cut -f3)"
    fi
  fi

  local new_count=$((count + 1))
  local new_no_limit=$no_limit_count
  if [[ -z "$LIMIT" && -z "$OFFSET" ]]; then
    new_no_limit=$((no_limit_count + 1))
  fi

  if [[ "$new_no_limit" -ge 3 ]]; then
    cat >&2 <<MSG
[leadv2-read-gate/read-dedup-hard] BLOCKED
File: $FPATH already read ${no_limit_count}x without limit/offset.
3rd full re-read of the same file = pure waste. The content hasn't changed.
You already have it in chat history.

Fix:
  - Skip this read; refer to memory of prior reads
  - If file actually changed: pass limit/offset to read just the changed section
  - If you NEED full content again: export LEADV2_ALLOW_FULL_READ=1 (rare)
MSG
    _dedup_persist "$tracker" "$FPATH" "$new_count" "$new_no_limit"
    [[ "${LEADV2_ALLOW_FULL_READ:-0}" != "1" ]] && return 2
    return 0
  fi

  _dedup_persist "$tracker" "$FPATH" "$new_count" "$new_no_limit"
  return 0
}

# =============================================================================
# SECTION 3 — lead-read-guard
# Block lead from reading code files outside handoff during active /leadv2.
# Only fires when LEADV2_LEAD_GUARD=1 (opt-in).
# =============================================================================
_check_lead_read_guard() {
  # Subagents always exempt — they need raw reads for byte-exact Edit targets.
  local _agent_type
  _agent_type="$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)"
  [[ -n "$_agent_type" ]] && return 0

  [[ "${LEADV2_LEAD_GUARD:-0}" == "1" ]] || return 0

  case "$FPATH" in
    /tmp/*) return 0 ;;
    /private/tmp/*) return 0 ;;
    /var/folders/*) return 0 ;;
    */docs/handoff/*) return 0 ;;
    */docs/leadv2/*) return 0 ;;
    */docs/BOARD.md) return 0 ;;
    */docs/LEAD_V2_STATE.md) return 0 ;;
    */docs/ROADMAP.md) return 0 ;;
    */docs/specs/leadv2-*) return 0 ;;
    */.claude/ref/*) return 0 ;;
    */.claude/leadv2-tasks/*) return 0 ;;
    */.claude/skills/*/SKILL.md) return 0 ;;
    */.claude/scripts/leadv2-*.sh) return 0 ;;
    */.claude/hooks/leadv2-*.sh) return 0 ;;
    */CLAUDE.md) return 0 ;;
    */memory/*.md) return 0 ;;
    *.summary.md) return 0 ;;
    *.full.md) return 0 ;;
    *active.yaml) return 0 ;;
    *context.yaml) return 0 ;;
    *graph-snapshot.yaml) return 0 ;;
    */settings.json) return 0 ;;
    */settings.local.json) return 0 ;;
    */package.json) return 0 ;;
    */tsconfig.json) return 0 ;;
    */.env*) return 0 ;;
  esac

  # Whitelist plugin's own source and cache paths (lead must read its own tooling)
  case "$FPATH" in
    */leadv2/*/hooks/*|*/leadv2/*/scripts/*) return 0 ;;
  esac

  case "$FPATH" in
    *.py|*.ts|*.tsx|*.js|*.jsx|*.sql|*.json|*.go|*.rs|*.swift|*.kt|*.cs|*.sh|*.bash|*.zsh|*.fish|*.rb|*.java|*.c|*.cc|*.cpp|*.h|*.hpp|*.m|*.mm|*.lua|*.pl|*.php)
      cat <<MSG >&2
[leadv2-read-gate/lead-read-guard] Lead reading code file directly is forbidden during /leadv2.
  file: $FPATH

Lead's job: dispatch. Spawn one of:
  - Agent(subagent_type=Explore, model=haiku) for explanation
  - Skill(leadv2-judge-question) for "should I" questions
  - leadv2-phase-advance.sh for state transitions

Override: \`unset LEADV2_LEAD_GUARD\` if this is genuinely a Phase 0 graph-warm read.
MSG
      return 2
      ;;
  esac

  return 0
}

# =============================================================================
# Run all checks in sequence — first non-zero exit wins (blocks the Read).
# =============================================================================
_check_force_read_limit || exit $?
_check_read_dedup       || exit $?
_check_lead_read_guard  || exit $?

exit 0
