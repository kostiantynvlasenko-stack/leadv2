#!/usr/bin/env bash
# PreToolUse hook for Read: block reads of files >100 lines when no limit/offset given.
# Forces lead to either delegate to Explore-haiku OR pass `limit=30`.
#
# SCOPE: only enforces during an active leadv2 task.
# Detection: LEADV2_TASK_ID env set, OR active.yaml present with non-empty sessions[].
# Mirrors the detection used by leadv2-tool-counter.sh (canonical active-session signal).
# If no active task -> exit 0 immediately; generic repos are never blocked.
#
# LEADV2_READ_LIMIT env var overrides the 100-line threshold (e.g. export LEADV2_READ_LIMIT=200).
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# ── Active-task guard ────────────────────────────────────────────────────────
# If LEADV2_TASK_ID is set, a task is active. Otherwise probe active.yaml.
_is_leadv2_active() {
  [[ -n "${LEADV2_TASK_ID:-}" ]] && return 0
  local cwd
  cwd="$(printf -- '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
  [[ -z "$cwd" ]] && cwd="$PWD"
  local f
  for f in "$cwd/docs/leadv2/active.yaml" "$cwd/.claude/leadv2-tasks/active.yaml"; do
    if [[ -f "$f" ]]; then
      # Check that sessions list is non-empty (same logic as tool-counter)
      python3 - "$f" <<'PYEOF' 2>/dev/null && return 0
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    sessions = d.get('sessions') or []
    sys.exit(0 if sessions else 1)
except Exception:
    sys.exit(1)
PYEOF
    fi
  done
  return 1
}

if ! _is_leadv2_active; then
  exit 0
fi
# ─────────────────────────────────────────────────────────────────────────────

FPATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")"
LIMIT="$(echo "$INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null || echo "")"
OFFSET="$(echo "$INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null || echo "")"

[[ -z "$FPATH" ]] && exit 0
[[ -n "$LIMIT" ]] && exit 0
[[ -n "$OFFSET" ]] && exit 0
[[ ! -f "$FPATH" ]] && exit 0

# Skip binary / image / pdf — Read handles those specially
case "$FPATH" in
  *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.svg|*.ico|*.webp|*.mp4|*.mp3|*.zip|*.tar*|*.bin|*.so|*.dylib|*.ipynb)
    exit 0;;
esac

LINES="$(wc -l < "$FPATH" 2>/dev/null | tr -d ' ')"
[[ -z "$LINES" ]] && exit 0

# Honor LEADV2_READ_LIMIT env override; default 100
THRESHOLD="${LEADV2_READ_LIMIT:-100}"
[[ "$LINES" -le "$THRESHOLD" ]] && exit 0

# Whitelist: tiny config / state files we always read fully (under 200 lines exempt for these)
case "$(basename "$FPATH")" in
  STATE.md|active.yaml|context.yaml|pulse.md|pr-manifest.yaml)
    [[ "$LINES" -le 200 ]] && exit 0;;
esac

cat >&2 <<MSG
[leadv2-force-read-limit] BLOCKED
File: $FPATH ($LINES lines)
Reading without limit/offset on a file >100L floods lead context.

Fix one of:
  1. Read with limit=30 if you need the header/summary
  2. Read with offset=N limit=M for a specific section
  3. Delegate full read to Explore-haiku via Agent(subagent_type=Explore, model=haiku, run_in_background=true)
  4. For review/critic deliverables: bash .claude/scripts/leadv2-critic-tail.sh "$FPATH"

Override (rare): export LEADV2_ALLOW_FULL_READ=1 for this turn.
MSG

[[ "${LEADV2_ALLOW_FULL_READ:-0}" == "1" ]] && exit 0
exit 2
