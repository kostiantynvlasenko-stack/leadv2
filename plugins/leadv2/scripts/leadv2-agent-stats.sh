#!/usr/bin/env bash
# leadv2-agent-stats.sh — Per-agent success rate tracking over the last 30 days.
# Scans docs/LEAD_V2_STATE.md (and archived LEAD_HISTORY.md) for subagent invocations
# and their outcomes, then writes docs/agents/agent-stats.yaml atomically.
#
# Usage:
#   leadv2-agent-stats.sh [--state-file <path>] [--history-file <path>] [--out <path>]
#                         [--days <N>]  # default: 30
#
# Output table (stdout + written to agent-stats.yaml):
#   agent | change_kind | attempts | success_rate_30d
#   developer | new-route | 12 | 0.92
#
# Exit codes: 0 — ok, 1 — parse error, no change to output file.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly PROJECT_ROOT

STATE_FILE="$PROJECT_ROOT/docs/LEAD_V2_STATE.md"
HISTORY_FILE="$PROJECT_ROOT/docs/LEAD_HISTORY.md"
OUT_FILE="$PROJECT_ROOT/docs/agents/agent-stats.yaml"
DAYS=30

log()       { printf '[leadv2-agent-stats] %s\n' "$*" >&2; }
log_warn()  { printf '[leadv2-agent-stats] WARN: %s\n' "$*" >&2; }
log_error() { printf '[leadv2-agent-stats] ERROR: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-file)   STATE_FILE="$2";   shift 2 ;;
    --history-file) HISTORY_FILE="$2"; shift 2 ;;
    --out)          OUT_FILE="$2";     shift 2 ;;
    --days)         DAYS="$2";         shift 2 ;;
    *) log_error "unknown arg: $1"; exit 1 ;;
  esac
done

# Create output dir if needed
mkdir -p "$(dirname "$OUT_FILE")"

# Build combined input: current state + history (if present)
COMBINED_INPUT=$(lv2_mktemp_file "leadv2-agent-stats-input" "md")
trap 'lv2_rmtemp_file "$COMBINED_INPUT"' EXIT

{
  [[ -f "$STATE_FILE" ]]   && cat "$STATE_FILE"
  [[ -f "$HISTORY_FILE" ]] && cat "$HISTORY_FILE"
} > "$COMBINED_INPUT" 2>/dev/null || true

if [[ ! -s "$COMBINED_INPUT" ]]; then
  log_warn "no state/history data found — skipping stats update"
  exit 0
fi

# ---------------------------------------------------------------------------
# Python: parse markdown for agent invocations + outcomes, compute stats.
#
# Patterns we recognise in LEAD_V2_STATE.md / LEAD_HISTORY.md:
#   - "Agent(developer, sonnet, ...)" lines near "outcome: shipped|rolled_back|..."
#   - "agent: developer" under history entries
#   - "change_kind: refactor-internal" or "classification: standard/new-route"
#   - Lines matching "DELIVERABLE_COMPLETE" (success) vs "circuit_break" / "rolled_back"
#
# We extract per-task records and accumulate per (agent, change_kind) buckets.
# ---------------------------------------------------------------------------
PY_HELPER=$(lv2_mktemp_file "leadv2-agent-stats" "py")
trap 'lv2_rmtemp_file "$COMBINED_INPUT"; lv2_rmtemp_file "$PY_HELPER"' EXIT

python3 -c "import sys; print(open(sys.argv[1]).read())" /dev/stdin > "$PY_HELPER" <<'PYEOF'
import sys
import re
import json
import math
from datetime import datetime, timezone, timedelta
from collections import defaultdict
from pathlib import Path
from typing import Optional

combined_file = sys.argv[1]
days_lookback = int(sys.argv[2])
out_file = sys.argv[3]

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

content = Path(combined_file).read_text(errors="replace")

cutoff = datetime.now(timezone.utc) - timedelta(days=days_lookback)

# ---------------------------------------------------------------------------
# Parse task blocks from LEAD_V2_STATE.md history section.
# Each history entry looks like:
#   ## <task-id>
#   - date: 2026-04-20
#   - outcome: shipped
#   - agents: developer(sonnet), architect(opus)
#   - change_kind: new-route
#   OR inline in phase logs:
#   Agent(developer, sonnet, ...)   → developer attempt
#   DELIVERABLE_COMPLETE            → success marker
# ---------------------------------------------------------------------------

# Match history block headers (## <id>)
# and extract structured fields within each block
BLOCK_RE = re.compile(
    r'##\s+(?P<task_id>[^\n]+)\n(?P<body>.*?)(?=\n## |\Z)',
    re.DOTALL
)
DATE_RE         = re.compile(r'[-\s]date:\s*(\d{4}-\d{2}-\d{2})', re.IGNORECASE)
OUTCOME_RE      = re.compile(r'[-\s]outcome:\s*(\w[\w_-]*)', re.IGNORECASE)
AGENT_RE        = re.compile(r'[-\s]agents?:\s*([^\n]+)', re.IGNORECASE)
CHANGE_KIND_RE  = re.compile(r'[-\s]change_kind:\s*(\S+)', re.IGNORECASE)
AGENT_CALL_RE   = re.compile(r'Agent\((\w[\w-]*),\s*(?:sonnet|opus|haiku)', re.IGNORECASE)
DELIVERABLE_RE  = re.compile(r'DELIVERABLE_COMPLETE')
CIRCUIT_RE      = re.compile(r'circuit.?break|rolled.?back|escalate_tier_B', re.IGNORECASE)
CLASS_RE        = re.compile(r'[-\s]class(?:ification)?:\s*(\w[\w-]*)', re.IGNORECASE)

# Known agent names
KNOWN_AGENTS = {
    "developer", "architect", "critic", "product-owner", "strategist",
    "postgres-pro", "frontend-developer", "devops-engineer", "security-auditor"
}

# Infer change_kind from classification and task description heuristics
def infer_change_kind(task_id: str, body: str, classification: str) -> str:
    body_lower = body.lower()
    if "route" in body_lower or "endpoint" in body_lower:
        return "new-route"
    if "refactor" in body_lower:
        return "refactor-internal"
    if "schema" in body_lower or "migration" in body_lower:
        return "schema-change"
    if "deploy" in body_lower or "vps" in body_lower:
        return "deploy-ops"
    if "agent" in body_lower or "prompt" in body_lower:
        return "agent-prompt"
    if "test" in body_lower:
        return "test-only"
    # Fall back to task class
    c = classification.lower()
    if c in ("light", "trivial"):
        return "light-edit"
    if c in ("heavy", "strategic"):
        return "cross-service"
    return "standard-feature"

# (agent, change_kind) → {attempts: int, successes: int}
buckets: dict[tuple[str, str], dict[str, int]] = defaultdict(lambda: {"attempts": 0, "successes": 0})

for m in BLOCK_RE.finditer(content):
    task_id = m.group("task_id").strip()
    body = m.group("body")

    # Date check
    date_m = DATE_RE.search(body)
    if date_m:
        try:
            task_date = datetime.strptime(date_m.group(1), "%Y-%m-%d").replace(tzinfo=timezone.utc)
            if task_date < cutoff:
                continue
        except ValueError:
            pass

    # Outcome
    outcome_m = OUTCOME_RE.search(body)
    outcome = outcome_m.group(1).lower() if outcome_m else "unknown"
    success = outcome in ("shipped", "verified", "complete", "done")
    failure = outcome in ("rolled_back", "circuit_break", "abandoned", "failed")
    if not success and not failure:
        # Infer from markers
        success = bool(DELIVERABLE_RE.search(body))
        failure = bool(CIRCUIT_RE.search(body)) and not success

    # change_kind
    ck_m = CHANGE_KIND_RE.search(body)
    cls_m = CLASS_RE.search(body)
    classification = cls_m.group(1) if cls_m else "standard"
    change_kind = ck_m.group(1) if ck_m else infer_change_kind(task_id, body, classification)

    # Agents — from explicit "agents:" line first
    agents_in_task: set[str] = set()
    agent_line_m = AGENT_RE.search(body)
    if agent_line_m:
        line = agent_line_m.group(1)
        for token in re.split(r'[,\s]+', line):
            base = token.split("(")[0].strip().lower()
            if base in KNOWN_AGENTS:
                agents_in_task.add(base)
    # Supplement with Agent() call sites in the body
    for call_m in AGENT_CALL_RE.finditer(body):
        a = call_m.group(1).lower()
        if a in KNOWN_AGENTS:
            agents_in_task.add(a)
    # Default: developer always present if we have any outcome
    if not agents_in_task and (success or failure):
        agents_in_task.add("developer")

    for agent in agents_in_task:
        key = (agent, change_kind)
        buckets[key]["attempts"] += 1
        if success:
            buckets[key]["successes"] += 1

# ---------------------------------------------------------------------------
# Format results
# ---------------------------------------------------------------------------
rows = []
for (agent, change_kind), counts in sorted(buckets.items()):
    attempts = counts["attempts"]
    successes = counts["successes"]
    rate = round(successes / attempts, 4) if attempts > 0 else 0.0
    rows.append({
        "agent": agent,
        "change_kind": change_kind,
        "attempts": attempts,
        "success_rate_30d": rate,
    })

# Print table to stdout
print(f"{'agent':<22} {'change_kind':<25} {'attempts':>8} {'success_rate_30d':>16}")
print("-" * 75)
for r in rows:
    flag = " *** LOW" if r["success_rate_30d"] < 0.60 else ""
    print(f"{r['agent']:<22} {r['change_kind']:<25} {r['attempts']:>8} {r['success_rate_30d']:>16.2f}{flag}")

# Write YAML atomically
tmp_out = out_file + ".tmp"
ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(tmp_out, "w") as f:
    f.write(f"# leadv2 agent stats — generated {ts}\n")
    f.write(f"# window: last {days_lookback} days\n")
    f.write(f"generated_at: {ts}\n")
    f.write(f"window_days: {days_lookback}\n")
    f.write("agents:\n")
    for r in rows:
        f.write(f"  - agent: {r['agent']}\n")
        f.write(f"    change_kind: {r['change_kind']}\n")
        f.write(f"    attempts: {r['attempts']}\n")
        f.write(f"    success_rate_30d: {r['success_rate_30d']}\n")

import os, shutil
shutil.move(tmp_out, out_file)
print(f"\nWritten: {out_file}", file=sys.stderr)
PYEOF

result_code=0
python3 "$PY_HELPER" "$COMBINED_INPUT" "$DAYS" "$OUT_FILE" || result_code=$?

if [[ $result_code -ne 0 ]]; then
  log_error "stats parse failed (exit $result_code)"
  exit 1
fi

log "agent-stats.yaml updated: $OUT_FILE"
