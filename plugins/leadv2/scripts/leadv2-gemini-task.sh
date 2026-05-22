#!/bin/bash
# leadv2-gemini-task.sh — Gemini 3.5 Flash wrapper for /leadv2 (Antigravity CLI).
# Default model = Gemini 3.5 Flash. Switch Flash↔Pro in Antigravity.app GUI; the CLI
# inherits whatever the IDE is set to.
#
# Modes:
#   consult   — short Q&A. Use for: knowledge questions, classifications, short lookups.
#               Bound by --timeout, default 60s. Bare --print, no workspace.
#   summarize — long-context digest. Use for: log/post-batch/PR/spec digests >20K tokens.
#               Reads --input-file, embeds inline, sends with structured-output prompt.
#               Default timeout 180s.
#   research  — web research via Gemini's browser tool. Use for: docs lookup, CVE check,
#               industry reference. Uses agent workspace + browser. Default timeout 180s.
#   agent     — full agy agent with workspace + auto-approved tool use. Use for:
#               browser-driven UI checks, multi-step file ops, anything where Gemini
#               needs to do real work in a scratch dir. Default timeout 300s.
#
# Output is captured to --out and tee'd to stdout. Caller reads --out.
#
# Exit codes:
#   0   — success
#   1   — usage error
#   2   — agy not available (caller uses fallback)
#   124 — timeout

set -uo pipefail

MODE="${1:-}"
shift || true

# Locate agy
if command -v agy >/dev/null 2>&1; then
  AGY_BIN="$(command -v agy)"
elif [[ -x "$HOME/.local/bin/agy" ]]; then
  AGY_BIN="$HOME/.local/bin/agy"
else
  echo "[gemini-task] agy not found. Install: curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
  exit 2
fi

PROMPT_TEXT=""
OUT_FILE=""
CWD_DIR=""
TIMEOUT_SEC=""
INPUT_FILE=""
EXTRA_DIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)     PROMPT_TEXT="$2"; shift 2;;
    --out)        OUT_FILE="$2"; shift 2;;
    --cwd)        CWD_DIR="$2"; shift 2;;
    --timeout)    TIMEOUT_SEC="$2"; shift 2;;
    --add-dir)    EXTRA_DIRS+=("$2"); shift 2;;
    --input-file) INPUT_FILE="$2"; shift 2;;
    *) echo "[gemini-task] unknown flag: $1" >&2; exit 1;;
  esac
done

[[ -z "$PROMPT_TEXT" ]] && { echo "[gemini-task] --prompt required" >&2; exit 1; }
[[ -z "$OUT_FILE" ]] && { echo "[gemini-task] --out required" >&2; exit 1; }
mkdir -p "$(dirname "$OUT_FILE")"

# summarize mode reads --input-file and inlines into prompt (agy 1.0.1 @file is broken in --print).
if [[ -n "$INPUT_FILE" ]]; then
  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "[gemini-task] --input-file not found: $INPUT_FILE" >&2; exit 1
  fi
  INPUT_BYTES="$(wc -c <"$INPUT_FILE")"
  if [[ "$INPUT_BYTES" -gt 500000 ]]; then
    echo "[gemini-task] --input-file is ${INPUT_BYTES} bytes; >500KB risks agy hang in --print. Chunk it." >&2
  fi
  PROMPT_TEXT="$PROMPT_TEXT"$'\n\n---INPUT START---\n'"$(cat "$INPUT_FILE")"$'\n---INPUT END---'
fi

# Flag discipline (agy 1.0.1, verified 2026-05-22):
#   --print-timeout flag → triggers tool-use exploration, NEVER use. Use shell `timeout`.
#   --dangerously-skip-permissions without workspace → meta-mode about the flag itself.
#   --add-dir <project> on a real repo → agy ignores prompt, explores the repo.
case "$MODE" in
  consult)
    TIMEOUT_SEC="${TIMEOUT_SEC:-60}"
    AGY_ARGS=(--print)
    ;;
  summarize)
    # Long-context digest. Bare --print like consult, but longer timeout (large inline content).
    TIMEOUT_SEC="${TIMEOUT_SEC:-180}"
    AGY_ARGS=(--print)
    ;;
  research|agent)
    # Both modes need agy's agentic capabilities (browser for research, full toolbelt for agent).
    TIMEOUT_SEC="${TIMEOUT_SEC:-180}"
    [[ "$MODE" == "agent" ]] && TIMEOUT_SEC="${TIMEOUT_SEC:-300}"
    # Persistent workspace; fresh mktemp dirs trigger meta-mode in agy 1.0.1.
    if [[ -z "$CWD_DIR" ]]; then
      CWD_DIR="${LEADV2_GEMINI_WORKSPACE:-$HOME/.gemini/antigravity-cli/scratch/leadv2}"
      mkdir -p "$CWD_DIR"
      [[ ! -f "$CWD_DIR/.leadv2-marker" ]] && echo "leadv2 gemini agent workspace — safe to delete contents" > "$CWD_DIR/.leadv2-marker"
    fi
    AGY_ARGS=(--print --dangerously-skip-permissions --add-dir "$CWD_DIR")
    for d in "${EXTRA_DIRS[@]}"; do AGY_ARGS+=(--add-dir "$d"); done
    ;;
  *)
    echo "[gemini-task] usage: $0 {consult|summarize|research|agent} --prompt <text> --out <file> [--input-file <path>] [--timeout N] [--cwd <dir>] [--add-dir <dir>]" >&2
    exit 1
    ;;
esac

# agy inherits cwd and may auto-attach codebase-memory-mcp / repo-aware MCP servers
# to whatever dir we run from. For consult/agent we want a clean shell — cd to
# scratch (agent) or HOME (consult) so MCP discovery doesn't compete with the prompt.
RUN_DIR="$HOME"
[[ "$MODE" == "agent" ]] && RUN_DIR="$CWD_DIR"

{
  echo "# Gemini 3.5 Flash — $MODE — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# CLI: $AGY_BIN"
  echo "# Timeout: ${TIMEOUT_SEC}s"
  echo "# Run dir: $RUN_DIR"
  [[ "$MODE" == "agent" ]] && echo "# Workspace: $CWD_DIR"
  echo "---"
  (cd "$RUN_DIR" && timeout "$TIMEOUT_SEC" "$AGY_BIN" "${AGY_ARGS[@]}" "$PROMPT_TEXT" 2>&1)
  RC=$?
  echo "---"
  echo "# exit=$RC"
  exit "$RC"
} | tee "$OUT_FILE"
exit "${PIPESTATUS[0]}"
