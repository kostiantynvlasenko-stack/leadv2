#!/usr/bin/env bash
# leadv2-thinking-audit.sh — Detect extended-thinking overuse in subagent missions.
#
# Usage:
#   leadv2-thinking-audit.sh <task-id>
#
# Reads per-repo config via _lv2_load_quality_engine_config().
# Config keys used (l_d block):
#   mission_glob      — glob template with {task_id} (default: docs/handoff/{task_id}/*mission*.md)
#   warning_threshold — flag if ultrathink_share > this (default: 0.50)
#
# Counting heuristic (per spec R5 / false-positive guard):
#   - Count a mission file as "using extended thinking" if it contains a DIRECTIVE line:
#     a line that STARTS with one of the markers (after stripping whitespace):
#       ultrathink
#       think hard | think harder | think deeply | think step by step
#       extended thinking (as a directive)
#   - Lines inside fenced code blocks (```) or blockquotes (>) are excluded.
#   - Case-insensitive match.
#
# Output (stdout, JSON):
#   { "task_id": "X", "missions_total": N, "missions_with_extended_thinking": M,
#     "ultrathink_share": 0.625 | null, "warning": null | "extended_thinking_overuse",
#     "missions_flagged": ["file.md", ...] }
#
# Side effect: merges extensions.ultrathink_share into score.json if it exists
#
# Exit codes:
#   0 = ok
#   2 = usage error
#   4 = disabled

set -euo pipefail

log()       { printf -- '[leadv2-thinking-audit] %s\n' "$*" >&2; }
log_warn()  { printf -- '[leadv2-thinking-audit] WARN: %s\n' "$*" >&2; }

# ── --gate mode: handle BEFORE sourcing helpers / config check ────────────────
# PreToolUse gate mode — exits non-zero if file contains thinking directives
# AND no explicit_reason_required: true in context.yaml.
# Runs standalone — does not need quality-engine.yaml to be present.
if [[ "${1:-}" == "--gate" ]]; then
  GATE_FILE="${2:-}"
  if [[ -z "$GATE_FILE" ]]; then
    printf -- 'Usage: leadv2-thinking-audit.sh --gate <mission-file>\n' >&2
    exit 2
  fi
  if [[ ! -f "$GATE_FILE" ]]; then
    # File doesn't exist — nothing to gate
    exit 0
  fi

  # Resolve context.yaml from the mission file's task directory (walk up to find it)
  _gate_root="${LEADV2_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  _gate_context=""
  # Prefer task-specific context.yaml derived from mission path
  # Walk from mission file's directory upward looking for context.yaml
  _walk_dir="$(dirname "$(readlink -f "$GATE_FILE" 2>/dev/null || echo "$GATE_FILE")")"
  while [[ "$_walk_dir" != "/" && "$_walk_dir" != "$_gate_root" ]]; do
    if [[ -f "$_walk_dir/context.yaml" ]]; then
      _gate_context="$_walk_dir/context.yaml"
      break
    fi
    _walk_dir="$(dirname "$_walk_dir")"
  done
  # Fallback: use LEADV2_TASK_ID env var if set
  if [[ -z "$_gate_context" && -n "${LEADV2_TASK_ID:-}" ]]; then
    _cand="$_gate_root/docs/handoff/${LEADV2_TASK_ID}/context.yaml"
    [[ -f "$_cand" ]] && _gate_context="$_cand"
  fi

  python3 - "$GATE_FILE" "${_gate_context:-}" <<'GATE_PYEOF'
import sys, re, os

mission_file = sys.argv[1]
context_yaml = sys.argv[2] if len(sys.argv) > 2 else ""

THINKING_DIRECTIVES = re.compile(
    r'(?:^|\b)(ultrathink|think\s+hard(?:er)?|think\s+deeply|think\s+step\s+by\s+step|extended\s+thinking)',
    re.IGNORECASE
)

def strip_fenced_and_quotes(text):
    lines = []
    in_fence = False
    fence_marker = ""
    for line in text.splitlines():
        stripped = line.strip()
        if not in_fence:
            if stripped.startswith("```") or stripped.startswith("~~~"):
                in_fence = True
                fence_marker = stripped[:3]
                continue
        else:
            if stripped.startswith(fence_marker):
                in_fence = False
            continue
        if stripped.startswith(">"):
            continue
        lines.append(stripped)
    return lines

try:
    with open(mission_file, encoding="utf-8", errors="replace") as fh:
        content = fh.read()
except OSError:
    sys.exit(0)

clean_lines = strip_fenced_and_quotes(content)
has_directive = any(THINKING_DIRECTIVES.search(line) for line in clean_lines)

if not has_directive:
    sys.exit(0)

# Check for explicit_reason_required: true in context.yaml
explicit_ok = False
if context_yaml and os.path.isfile(context_yaml):
    try:
        ctx_text = open(context_yaml, encoding="utf-8", errors="replace").read()
        if re.search(r'explicit_reason_required\s*:\s*true', ctx_text, re.IGNORECASE):
            explicit_ok = True
    except OSError:
        pass

if explicit_ok:
    sys.exit(0)

# Directive found, no explicit permission — gate blocks
print(f"[leadv2-thinking-audit] GATE BLOCKED: mission file '{os.path.basename(mission_file)}' "
      f"contains a thinking directive (ultrathink/think hard/etc) but context.yaml does not have "
      f"explicit_reason_required: true. Remove the directive or add explicit_reason_required: true "
      f"to context.yaml.", file=sys.stderr)
sys.exit(1)
GATE_PYEOF
  exit $?
fi

# ── aggregate audit mode: source helpers + check config ──────────────────────
# shellcheck source=./leadv2-helpers.sh
source "$(dirname "$(readlink -f "$0")")/leadv2-helpers.sh"

_lv2_load_quality_engine_config "l_d" || exit 4

TASK_ID="${1:-}"
if [[ -z "$TASK_ID" ]]; then
  printf -- 'Usage: leadv2-thinking-audit.sh <task-id>\n  OR:  leadv2-thinking-audit.sh --gate <mission-file>\n' >&2
  exit 2
fi

# ── config ────────────────────────────────────────────────────────────────────
MISSION_GLOB_TMPL="${LV2_QE_L_D_MISSION_GLOB:-docs/handoff/{task_id}/*mission*.md}"
WARNING_THRESHOLD="${LV2_QE_L_D_WARNING_THRESHOLD:-0.50}"

# Resolve glob
MISSION_GLOB="${MISSION_GLOB_TMPL//\{task_id\}/$TASK_ID}"
if [[ "${MISSION_GLOB}" != /* ]]; then
  MISSION_GLOB="${LEADV2_PROJECT_ROOT}/${MISSION_GLOB}"
fi

# Score output for merge
SCORE_OUTPUT_TMPL="${LV2_QE_L_B_SCORE_OUTPUT_TMPL:-docs/leadv2/tasks/{task_id}/score.json}"
SCORE_OUTPUT="${SCORE_OUTPUT_TMPL//\{task_id\}/$TASK_ID}"
if [[ "${SCORE_OUTPUT}" != /* ]]; then
  SCORE_OUTPUT="${LEADV2_PROJECT_ROOT}/${SCORE_OUTPUT}"
fi

python3 - "$TASK_ID" "$MISSION_GLOB" "$WARNING_THRESHOLD" "$SCORE_OUTPUT" \
          <<'PYEOF'
import sys
import os
import json
import re
import glob

task_id           = sys.argv[1]
mission_glob      = sys.argv[2]
warning_threshold = float(sys.argv[3])
score_output      = sys.argv[4]

THINKING_DIRECTIVES = re.compile(
    r'^(ultrathink|think\s+hard(?:er)?|think\s+deeply|think\s+step\s+by\s+step|extended\s+thinking)',
    re.IGNORECASE
)

def strip_fenced_and_quotes(text: str) -> list[str]:
    """Return lines from text with fenced code blocks and blockquote lines removed."""
    lines = []
    in_fence = False
    fence_marker = ""
    for line in text.splitlines():
        stripped = line.strip()
        # Detect fence open/close
        if not in_fence:
            if stripped.startswith("```") or stripped.startswith("~~~"):
                in_fence = True
                fence_marker = stripped[:3]
                continue
        else:
            if stripped.startswith(fence_marker):
                in_fence = False
            continue  # skip lines inside fences
        # Skip blockquotes
        if stripped.startswith(">"):
            continue
        lines.append(stripped)
    return lines

def has_extended_thinking_directive(filepath: str) -> bool:
    """Return True if the file contains an extended-thinking directive line."""
    try:
        with open(filepath, encoding="utf-8", errors="replace") as fh:
            content = fh.read()
    except OSError:
        return False
    clean_lines = strip_fenced_and_quotes(content)
    for line in clean_lines:
        if THINKING_DIRECTIVES.match(line):
            return True
    return False

# Glob mission files
files = sorted(glob.glob(mission_glob))

missions_total = len(files)
flagged = []

for f in files:
    if has_extended_thinking_directive(f):
        flagged.append(os.path.basename(f))

missions_with_thinking = len(flagged)

# Compute share
ultrathink_share = None
warning = None
if missions_total > 0:
    ultrathink_share = round(missions_with_thinking / missions_total, 4)
    if ultrathink_share > warning_threshold:
        warning = "extended_thinking_overuse"

result = {
    "task_id":                         task_id,
    "missions_total":                  missions_total,
    "missions_with_extended_thinking": missions_with_thinking,
    "ultrathink_share":                ultrathink_share,
    "warning":                         warning,
    "missions_flagged":                flagged
}
print(json.dumps(result))

# Merge into score.json
if os.path.isfile(score_output):
    try:
        with open(score_output) as fh:
            score_data = json.load(fh)
        exts = score_data.setdefault("extensions", {})
        exts["ultrathink_share"] = ultrathink_share
        with open(score_output, "w") as fh:
            json.dump(score_data, fh)
        print(f"[leadv2-thinking-audit] merged ultrathink_share={ultrathink_share} into {score_output}", file=sys.stderr)
    except Exception as e:
        print(f"[leadv2-thinking-audit] WARN: could not merge into score.json: {e}", file=sys.stderr)

sys.exit(0)
PYEOF
