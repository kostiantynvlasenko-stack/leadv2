#!/usr/bin/env bash
# leadv2-llm-judge-parse.sh — Parse LLM-judge Opus response into llm-judge.yaml.
# Called by lead after Agent(architect) completes, passing the response file.
#
# Usage:
#   leadv2-llm-judge-parse.sh --task-id <id> --response-file <path>
#                              [--model <opus|sonnet>] [--project-root <path>]
#
# Writes: docs/handoff/<task-id>/llm-judge.yaml
#
# Exit codes:
#   0 = verdict go or go-with-caveats
#   1 = verdict no-go
#   3 = parse error (treated as go-with-caveats, parse error logged)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly SCRIPT_DIR PROJECT_ROOT

log()       { printf '[leadv2-judge-parse] %s\n' "$*" >&2; }
log_error() { printf '[leadv2-judge-parse] ERROR: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: leadv2-llm-judge-parse.sh --task-id <id> --response-file <path>
                                  [--model <model>]
                                  [--project-root <path>]
EOF
  exit 1
}

TASK_ID=""
RESPONSE_FILE=""
MODEL_USED="opus"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)       TASK_ID="$2";       shift 2 ;;
    --response-file) RESPONSE_FILE="$2"; shift 2 ;;
    --model)         MODEL_USED="$2";    shift 2 ;;
    --project-root)  PROJECT_ROOT="$2";  shift 2 ;;
    -h|--help)       usage ;;
    *) log_error "unknown arg: $1"; usage ;;
  esac
done

[[ -z "$TASK_ID" ]]       && { log_error "--task-id required"; usage; }
[[ -z "$RESPONSE_FILE" ]] && { log_error "--response-file required"; usage; }
[[ ! -f "$RESPONSE_FILE" ]] && { log_error "response file not found: $RESPONSE_FILE"; exit 1; }

HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff/${TASK_ID}"
OUTPUT_FILE="${HANDOFF_DIR}/llm-judge.yaml"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Source helpers for atomic write validation (PO-057).
# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh" 2>/dev/null || true

python3 - "$RESPONSE_FILE" "$OUTPUT_FILE" "$TASK_ID" "$MODEL_USED" "$NOW" <<'PYEOF'
import sys
import re
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: pyyaml not installed", file=sys.stderr)
    sys.exit(1)

response_file = Path(sys.argv[1])
output_file   = Path(sys.argv[2])
task_id       = sys.argv[3]
model_used    = sys.argv[4]
now           = sys.argv[5]

raw = response_file.read_text().strip()

# Strip markdown code fences if present
raw = re.sub(r'^```(?:yaml)?\s*', '', raw, flags=re.MULTILINE)
raw = re.sub(r'^```\s*$', '', raw, flags=re.MULTILINE)
raw = raw.strip()

parse_error = None
parsed: dict = {}

try:
    parsed = yaml.safe_load(raw) or {}
    if not isinstance(parsed, dict):
        raise ValueError("Response is not a YAML dict")
except Exception as e:
    parse_error = str(e)

def safe_float(v, default: float = 5.0) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return default

def safe_int(v, default: int = 5) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return default

if parse_error:
    # Graceful fallback: go-with-caveats, parse error logged
    output = {
        "llm_judge": {
            "task_id":     task_id,
            "judged_at":   now,
            "model_used":  model_used,
            "verdict":     "go-with-caveats",
            "overall_risk": 5.0,
            "confidence":  0.5,
            "axes":        {},
            "blockers":    [],
            "caveats":     ["LLM-judge response parse error — review manually"],
            "reasoning":   f"Parse error: {parse_error[:100]}",
            "skipped":     False,
            "skip_reason": "",
            "parse_error": parse_error,
        }
    }
    output_file.parent.mkdir(parents=True, exist_ok=True)
    with open(output_file, "w") as fh:
        yaml.dump(output, fh, default_flow_style=False, sort_keys=False, allow_unicode=True)
    print(f"verdict=go-with-caveats")
    print(f"parse_error={parse_error[:80]}")
    sys.exit(3)

# Parse fields
verdict      = str(parsed.get("verdict", "go-with-caveats")).strip().lower()
overall_risk = safe_float(parsed.get("overall_risk"), 5.0)
confidence   = safe_float(parsed.get("confidence"), 0.5)
axes_raw     = parsed.get("axes", {}) or {}
blockers     = parsed.get("blockers", []) or []
caveats      = parsed.get("caveats", []) or []
reasoning    = str(parsed.get("reasoning", ""))[:200]

# Normalise verdict
if verdict not in ("go", "no-go", "go-with-caveats"):
    verdict = "go-with-caveats"

# Apply risk override: go + risk 5-7 → go-with-caveats
if verdict == "go" and 5.0 <= overall_risk <= 7.0:
    verdict = "go-with-caveats"
    if not caveats:
        caveats = [f"Risk score {overall_risk:.1f} — borderline; proceed with monitoring"]

axes = {
    "reversibility":     safe_int(axes_raw.get("reversibility"), 5),
    "blast_radius":      safe_int(axes_raw.get("blast_radius"), 5),
    "durability_of_fix": safe_int(axes_raw.get("durability_of_fix"), 5),
    "test_coverage":     safe_int(axes_raw.get("test_coverage"), 5),
    "context_consensus": safe_int(axes_raw.get("context_consensus"), 5),
}

output = {
    "llm_judge": {
        "task_id":     task_id,
        "judged_at":   now,
        "model_used":  model_used,
        "verdict":     verdict,
        "overall_risk": round(overall_risk, 2),
        "confidence":  round(confidence, 2),
        "axes":        axes,
        "blockers":    [str(b) for b in blockers],
        "caveats":     [str(c) for c in caveats],
        "reasoning":   reasoning,
        "skipped":     False,
        "skip_reason": "",
    }
}

output_file.parent.mkdir(parents=True, exist_ok=True)
with open(output_file, "w") as fh:
    yaml.dump(output, fh, default_flow_style=False, sort_keys=False, allow_unicode=True)

print(f"verdict={verdict}")
print(f"overall_risk={overall_risk:.2f}")
print(f"confidence={confidence:.2f}")
print(f"blockers_count={len(blockers)}")
PYEOF

# Re-read output file for verdict (python block above ran inline via heredoc).
if [[ ! -f "$OUTPUT_FILE" ]]; then
  log_error "Output file not written — python block failed"
  exit 1
fi

verdict=$(python3 -c "
import yaml, sys
with open('$OUTPUT_FILE') as fh:
    d = yaml.safe_load(fh) or {}
print(d.get('llm_judge', d).get('verdict', 'go-with-caveats'))
" 2>/dev/null || echo "go-with-caveats")

overall_risk=$(python3 -c "
import yaml, sys
with open('$OUTPUT_FILE') as fh:
    d = yaml.safe_load(fh) or {}
print(d.get('llm_judge', d).get('overall_risk', 5.0))
" 2>/dev/null || echo "5.0")

log "Parsed verdict: $verdict (risk=$overall_risk)"

# PO-057: validate + atomic re-flush.
if declare -f leadv2_validate_yaml >/dev/null 2>&1; then
  if ! leadv2_validate_yaml "$OUTPUT_FILE" >/dev/null 2>&1; then
    log_error "YAML validation failed: $OUTPUT_FILE"
    exit 1
  fi
  _content=$(cat "$OUTPUT_FILE")
  _tmp="$(mktemp "$(dirname "$OUTPUT_FILE")/.parse_XXXXXX.yaml")"
  printf -- '%s\n' "$_content" > "$_tmp"
  sync "$_tmp" 2>/dev/null || true
  mv -f "$_tmp" "$OUTPUT_FILE"
  unset _content _tmp
fi
log "Written (atomic): $OUTPUT_FILE"

case "$verdict" in
  "no-go")          exit 1 ;;
  "go-with-caveats") exit 0 ;;
  "go")              exit 0 ;;
  *)                 exit 0 ;;
esac
