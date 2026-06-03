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

# shellcheck source=./leadv2-helpers.sh
source "$(dirname "$(readlink -f "$0")")/leadv2-helpers.sh"

_lv2_load_quality_engine_config "l_d" || exit 4

log()       { printf -- '[leadv2-thinking-audit] %s\n' "$*" >&2; }
log_warn()  { printf -- '[leadv2-thinking-audit] WARN: %s\n' "$*" >&2; }

# ── argument parsing ──────────────────────────────────────────────────────────
TASK_ID="${1:-}"
if [[ -z "$TASK_ID" ]]; then
  printf -- 'Usage: leadv2-thinking-audit.sh <task-id>\n' >&2
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
