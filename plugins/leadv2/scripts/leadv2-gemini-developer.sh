#!/bin/bash
# leadv2-gemini-developer.sh — Gemini 3.5 Flash developer subagent for /leadv2.
# Extends agent mode with: mission file contract, dedicated workspace, handoff dir,
# and DELIVERABLE_COMPLETE marker detection.
#
# Usage:
#   leadv2-gemini-developer.sh \
#     --mission-file /path/to/mission.md \
#     --workspace    /path/to/scratch/  \
#     --handoff-dir  /path/to/handoff/  \
#     --out          /path/to/output.log \
#     [--timeout 300]
#
# Contract with Gemini:
#   1. Mission file describes the task + target file paths inside WORKSPACE
#   2. Gemini writes deliverables to WORKSPACE using built-in file-write tool
#   3. Gemini writes 5-line summary to HANDOFF/gemini-result.md via file-write
#   4. Gemini ends its final message with EXACTLY: DELIVERABLE_COMPLETE
#
# Exit codes:
#   0   — DELIVERABLE_COMPLETE detected, files written
#   1   — usage error
#   2   — agy not available
#   3   — completed but DELIVERABLE_COMPLETE not in output (partial / failed task)
#   124 — timeout (shell timeout kills agy)

set -uo pipefail

# ── locate agy ──────────────────────────────────────────────────────────────
if command -v agy >/dev/null 2>&1; then
  AGY_BIN="$(command -v agy)"
elif [[ -x "$HOME/.local/bin/agy" ]]; then
  AGY_BIN="$HOME/.local/bin/agy"
else
  echo "[gemini-dev] agy not found. Install: curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
  exit 2
fi

# ── parse args ───────────────────────────────────────────────────────────────
MISSION_FILE=""
WORKSPACE=""
HANDOFF_DIR=""
OUT_FILE=""
TIMEOUT_SEC=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-file) MISSION_FILE="$2"; shift 2;;
    --workspace)    WORKSPACE="$2";    shift 2;;
    --handoff-dir)  HANDOFF_DIR="$2";  shift 2;;
    --out)          OUT_FILE="$2";     shift 2;;
    --timeout)      TIMEOUT_SEC="$2";  shift 2;;
    *) echo "[gemini-dev] unknown flag: $1" >&2; exit 1;;
  esac
done

[[ -z "$MISSION_FILE" ]]  && { echo "[gemini-dev] --mission-file required" >&2; exit 1; }
[[ -z "$WORKSPACE" ]]     && { echo "[gemini-dev] --workspace required"    >&2; exit 1; }
[[ -z "$HANDOFF_DIR" ]]   && { echo "[gemini-dev] --handoff-dir required"  >&2; exit 1; }
[[ -z "$OUT_FILE" ]]      && { echo "[gemini-dev] --out required"          >&2; exit 1; }
[[ ! -f "$MISSION_FILE" ]] && { echo "[gemini-dev] mission file not found: $MISSION_FILE" >&2; exit 1; }

mkdir -p "$WORKSPACE" "$HANDOFF_DIR" "$(dirname "$OUT_FILE")"

# Result file goes inside workspace (single --add-dir); we copy to HANDOFF_DIR after.
RESULT_FILE="$WORKSPACE/gemini-result.md"

# ── build prompt ─────────────────────────────────────────────────────────────
# Use printf + cat to a temp file — avoids bash heredoc re-interpreting backticks
# from expanded $MISSION_CONTENT as command substitution.
PROMPT_TMP=$(mktemp /tmp/gemini-dev-prompt.XXXXXX)
trap 'rm -f "$PROMPT_TMP"' EXIT

# Substitute "WORKSPACE" placeholder with the actual absolute path in mission.
# Gemini needs exact absolute paths — "WORKSPACE/foo.py" confuses it into asking
# for clarification instead of writing.
MISSION_EXPANDED="$(sed "s|WORKSPACE|$WORKSPACE|g" "$MISSION_FILE")"

# Prompt: must start with "Use your built-in file-write tool to create" — this
# exact phrasing prevents agy 1.0.1 from entering meta-mode (explaining flags,
# asking what to do) on an empty workspace. Verified 2026-05-23.
# Mission file must follow the format:
#   Create file WORKSPACE/foo.py with exact content:
#   [content lines]
#   Create file WORKSPACE/bar.py with exact content:
#   [content lines]
# WORKSPACE placeholder is replaced with the actual absolute path by this script.
{
  printf 'Use your built-in file-write tool to create these files with exact content:\n\n'
  printf '%s\n' "$MISSION_EXPANDED"
  printf '\nAlso create %s with exact content:\n' "$RESULT_FILE"
  printf 'STATUS: done\n'
  printf 'FILES_WRITTEN: <comma-separated filenames you wrote>\n'
  printf 'NOTES: <one-line summary>\n'
  printf '\nAfter creating all files, reply with ONLY this word: DELIVERABLE_COMPLETE\n'
} > "$PROMPT_TMP"

PROMPT="$(cat "$PROMPT_TMP")"

# ── run agy ──────────────────────────────────────────────────────────────────
# agy 1.0.1 caveats (verified 2026-05-23):
#   - Two --add-dir flags hang at startup: use ONE (workspace only).
#   - Running from empty scratch dir also hangs: run from HOME.
#   - Running from real repo cwd with --add-dir pointing elsewhere: works fine.
#   - --print + --dangerously-skip-permissions + --add-dir <scratch>: the confirmed
#     working incantation for file writes (verified in smoke test 2026-05-23).
{
  echo "# Gemini 3.5 Flash — developer — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# CLI: $AGY_BIN"
  echo "# Timeout: ${TIMEOUT_SEC}s"
  echo "# Workspace: $WORKSPACE"
  echo "# Handoff: $HANDOFF_DIR"
  echo "# Mission: $MISSION_FILE"
  echo "---"
  (
    # agy 1.0.1 caveat (verified 2026-05-23): --dangerously-skip-permissions +
    # --add-dir works ONLY from a real git repo cwd. From $HOME or an empty scratch
    # dir, agy hangs ("Error: timed out waiting for response"). Run from whatever
    # cwd the caller has (which is typically the project dir). The --add-dir flag
    # points to a DIFFERENT dir (workspace), so agy doesn't explore the project.
    # Flag order matters: --print takes the NEXT argument as its value (the prompt).
    # So --print must be LAST, immediately before "$PROMPT". Placing --print before
    # --dangerously-skip-permissions causes agy to use the flag text as the prompt.
    # Also: agy hangs reading stdin from bash scripts; < /dev/null prevents that.
    timeout "$TIMEOUT_SEC" "$AGY_BIN" \
      --dangerously-skip-permissions \
      --add-dir "$WORKSPACE" \
      --print "$PROMPT" < /dev/null 2>&1
  )
  RC=$?
  echo "---"
  echo "# exit=$RC"
} | tee "$OUT_FILE"

# ── detect DELIVERABLE_COMPLETE ───────────────────────────────────────────────
if grep -q "DELIVERABLE_COMPLETE" "$OUT_FILE"; then
  # Copy result summary to handoff dir so leadv2 can read it from there.
  [[ -f "$RESULT_FILE" ]] && cp "$RESULT_FILE" "$HANDOFF_DIR/gemini-result.md"
  exit 0
else
  echo "[gemini-dev] DELIVERABLE_COMPLETE not found in output. Task may be incomplete." >&2
  exit 3
fi
