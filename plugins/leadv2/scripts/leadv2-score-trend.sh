#!/usr/bin/env bash
# leadv2-score-trend.sh — Compute score trend across last N closed tasks.
#
# Usage:
#   leadv2-score-trend.sh
#
# Reads per-repo config via _lv2_load_quality_engine_config().
# Config keys used (l_b block):
#   closed_yaml_tmpl    — path template with {task_id}
#   score_output_tmpl   — score.json path template
#   history_window      — N for last-N vs prior-N comparison (default: 10)
#   min_tasks_for_trend — minimum closed tasks before trend is meaningful (default: 20)
#
# Output (stdout, JSON): trend block
# Exit codes:
#   0 = ok
#   4 = quality_engine disabled or missing (no-op)

set -euo pipefail

# shellcheck source=./leadv2-helpers.sh
source "$(dirname "$(readlink -f "$0")")/leadv2-helpers.sh"

_lv2_load_quality_engine_config "l_b" || exit 4

log()       { printf -- '[leadv2-score-trend] %s\n' "$*" >&2; }
log_warn()  { printf -- '[leadv2-score-trend] WARN: %s\n' "$*" >&2; }

# ── config ────────────────────────────────────────────────────────────────────
CLOSED_YAML_TMPL="${LV2_QE_L_B_CLOSED_YAML_TMPL:-docs/leadv2/closed/{task_id}.yaml}"
SCORE_OUTPUT_TMPL="${LV2_QE_L_B_SCORE_OUTPUT_TMPL:-docs/leadv2/tasks/{task_id}/score.json}"
HISTORY_WINDOW="${LV2_QE_L_B_HISTORY_WINDOW:-10}"
MIN_TASKS="${LV2_QE_L_B_MIN_TASKS_FOR_TREND:-20}"

# Derive closed dir from template
CLOSED_DIR=$(dirname "${CLOSED_YAML_TMPL//\{task_id\}/placeholder}")
if [[ "${CLOSED_DIR}" != /* ]]; then
  CLOSED_DIR="${LEADV2_PROJECT_ROOT}/${CLOSED_DIR}"
fi

COMPUTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── gather closed tasks ────────────────────────────────────────────────────────
# Collect all closed YAML files, sort by closed_at (or mtime fallback)
python3 - "$CLOSED_DIR" "$SCORE_OUTPUT_TMPL" "$LEADV2_PROJECT_ROOT" \
          "$HISTORY_WINDOW" "$MIN_TASKS" "$COMPUTED_AT" \
          <<'PYEOF'
import sys
import os
import json
import glob
import re

closed_dir         = sys.argv[1]
score_output_tmpl  = sys.argv[2]
project_root       = sys.argv[3]
window_size        = int(sys.argv[4])
min_tasks          = int(sys.argv[5])
computed_at        = sys.argv[6]

try:
    import yaml
    has_yaml = True
except ImportError:
    has_yaml = False

def resolve_tmpl(tmpl: str, task_id: str, root: str) -> str:
    p = tmpl.replace("{task_id}", task_id)
    if not p.startswith("/"):
        p = os.path.join(root, p)
    return p

def get_closed_at(yaml_path: str) -> str:
    """Read closed_at from YAML or fall back to mtime ISO string."""
    if has_yaml:
        try:
            with open(yaml_path) as fh:
                d = yaml.safe_load(fh) or {}
            return d.get("closed_at") or d.get("completed_at") or ""
        except Exception:
            pass
    # fallback: mtime
    try:
        mtime = os.path.getmtime(yaml_path)
        import datetime
        return datetime.datetime.utcfromtimestamp(mtime).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return ""

def get_score(task_id: str) -> int | None:
    """Return score for task_id, computing on the fly if score.json missing."""
    score_path = resolve_tmpl(score_output_tmpl, task_id, project_root)
    if os.path.exists(score_path):
        try:
            with open(score_path) as fh:
                d = json.load(fh)
            s = d.get("score")
            return int(s) if s is not None else None
        except Exception:
            pass
    return None

# Collect all closed YAML files
if not os.path.isdir(closed_dir):
    print(json.dumps({
        "computed_at": computed_at,
        "window_size": window_size,
        "error": f"closed_dir_not_found: {closed_dir}",
        "direction": "insufficient_data"
    }))
    sys.exit(0)

yaml_files = glob.glob(os.path.join(closed_dir, "*.yaml"))
if not yaml_files:
    print(json.dumps({
        "computed_at": computed_at,
        "window_size": window_size,
        "last_10": {"count": 0, "tasks": [], "avg_score": None, "median": None},
        "prior_10": {"count": 0, "tasks": [], "avg_score": None, "median": None},
        "delta": None,
        "direction": "insufficient_data"
    }))
    sys.exit(0)

# Build list of (closed_at, task_id)
tasks_by_time = []
for yf in yaml_files:
    task_id = os.path.basename(yf).replace(".yaml", "")
    closed_at = get_closed_at(yf)
    tasks_by_time.append((closed_at, task_id))

# Sort descending by closed_at (most recent first)
tasks_by_time.sort(key=lambda x: x[0] or "", reverse=True)
total_tasks = len(tasks_by_time)

if total_tasks < min_tasks:
    print(json.dumps({
        "computed_at": computed_at,
        "window_size": window_size,
        "total_closed_tasks": total_tasks,
        "min_tasks_for_trend": min_tasks,
        "direction": "insufficient_data"
    }))
    sys.exit(0)

# last_N = most recent window_size tasks
# prior_N = the window_size tasks before that
last_n_tasks  = [t[1] for t in tasks_by_time[:window_size]]
prior_n_tasks = [t[1] for t in tasks_by_time[window_size: window_size * 2]]

def window_stats(task_ids: list[str]) -> dict:
    scores = []
    for tid in task_ids:
        s = get_score(tid)
        if s is not None:
            scores.append(s)
    if not scores:
        return {"count": len(task_ids), "tasks": task_ids, "avg_score": None, "median": None}
    avg = round(sum(scores) / len(scores), 1)
    sorted_s = sorted(scores)
    n = len(sorted_s)
    if n % 2 == 0:
        median = (sorted_s[n // 2 - 1] + sorted_s[n // 2]) / 2.0
    else:
        median = sorted_s[n // 2]
    return {
        "count":     len(task_ids),
        "tasks":     task_ids,
        "avg_score": avg,
        "median":    median
    }

last_stats  = window_stats(last_n_tasks)
prior_stats = window_stats(prior_n_tasks)

# Direction
direction = "insufficient_data"
delta = None
la = last_stats.get("avg_score")
pa = prior_stats.get("avg_score")
if la is not None and pa is not None:
    delta = round(la - pa, 1)
    if delta > 3.0:
        direction = "improving"
    elif delta < -3.0:
        direction = "degrading"
    else:
        direction = "stable"

result = {
    "computed_at":         computed_at,
    "window_size":         window_size,
    "total_closed_tasks":  total_tasks,
    "last_10":             last_stats,
    "prior_10":            prior_stats,
    "delta":               delta,
    "direction":           direction
}
print(json.dumps(result))
sys.exit(0)
PYEOF
