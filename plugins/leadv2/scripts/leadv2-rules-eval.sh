#!/usr/bin/env bash
# leadv2-rules-eval.sh — Evaluate quality rules against task context.
#
# Usage:
#   leadv2-rules-eval.sh <task-id> [--phase <name>] [--severity-floor <level>]
#                        [--diff-file <path>]
#
# Reads per-repo config via _lv2_load_quality_engine_config().
# Config keys used (l_a block):
#   rules_dir        — directory of *.rule.md files
#   rule_glob        — file glob (default: *.rule.md)
#   severity_floor   — skip rules below this level (default: medium)
#   default_action   — fallback action for rules without explicit action (default: warn)
#
# Output (stdout, JSON):
#   {
#     "task_id": "...",
#     "evaluated_at": "ISO",
#     "phase": "...",
#     "rules_evaluated": N,
#     "triggered": [
#       { "rule_id": "R-001", "severity": "high", "action": "block_deploy",
#         "matches": 3, "summary": "...", "remediation": "..." }
#     ],
#     "deploy_block": true|false
#   }
#
# Exit codes:
#   0 = clean (may have warnings)
#   2 = deploy_block=true
#   3 = config/runtime error
#   4 = quality_engine disabled or missing (no-op)

set -euo pipefail

# shellcheck source=./leadv2-helpers.sh
source "$(dirname "$(readlink -f "$0")")/leadv2-helpers.sh"

_lv2_load_quality_engine_config "l_a" || exit 4

log()       { printf -- '[leadv2-rules-eval] %s\n' "$*" >&2; }
log_warn()  { printf -- '[leadv2-rules-eval] WARN: %s\n' "$*" >&2; }
log_error() { printf -- '[leadv2-rules-eval] ERROR: %s\n' "$*" >&2; }

# ── argument parsing ──────────────────────────────────────────────────────────
TASK_ID=""
PHASE="generic"
SEVERITY_FLOOR="${LV2_QE_L_A_SEVERITY_FLOOR:-medium}"
DIFF_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)           PHASE="$2";          shift 2 ;;
    --severity-floor)  SEVERITY_FLOOR="$2"; shift 2 ;;
    --diff-file)       DIFF_FILE="$2";      shift 2 ;;
    -h|--help)
      printf -- 'Usage: leadv2-rules-eval.sh <task-id> [--phase <name>] [--severity-floor <level>] [--diff-file <path>]\n' >&2
      exit 0
      ;;
    -*)
      log_error "unknown flag: $1"; exit 2
      ;;
    *)
      if [[ -z "$TASK_ID" ]]; then
        TASK_ID="$1"
      else
        log_error "unexpected argument: $1"; exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$TASK_ID" ]]; then
  log_error "task-id is required"
  exit 2
fi

# ── load rules ────────────────────────────────────────────────────────────────
RULES_DIR="${LV2_QE_L_A_RULES_DIR:-}"
if [[ -z "$RULES_DIR" ]]; then
  RULES_DIR="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/rules"
fi
if [[ "${RULES_DIR}" != /* ]]; then
  RULES_DIR="${LEADV2_PROJECT_ROOT}/${RULES_DIR}"
fi

RULES_LOAD_SCRIPT="$(dirname "$(readlink -f "$0")")/leadv2-rules-load.sh"

RULES_JSON=""
if [[ -f "$RULES_LOAD_SCRIPT" ]]; then
  RULES_JSON=$("$RULES_LOAD_SCRIPT" 2>/dev/null || true)
else
  RULES_JSON='{"rules":[],"count":0,"warnings":["rules_load_script_missing"]}'
fi

if [[ -z "$RULES_JSON" ]]; then
  RULES_JSON='{"rules":[],"count":0,"warnings":[]}'
fi

# ── build diff context ────────────────────────────────────────────────────────
# If no diff file provided, attempt to generate one from git
if [[ -z "$DIFF_FILE" ]]; then
  DIFF_TMPFILE=$(mktemp /tmp/leadv2-rules-eval-diff-XXXXXX.txt)
  trap 'rm -f "$DIFF_TMPFILE"' EXIT
  cd "$LEADV2_PROJECT_ROOT"
  git diff HEAD 2>/dev/null > "$DIFF_TMPFILE" || true
  DIFF_FILE="$DIFF_TMPFILE"
fi

# ── evaluate rules via Python ────────────────────────────────────────────────
EVALUATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 - "$TASK_ID" "$PHASE" "$SEVERITY_FLOOR" "$DIFF_FILE" \
         "${LV2_QE_L_A_DEFAULT_ACTION:-warn}" \
         "$LEADV2_PROJECT_ROOT" \
         <<PYEOF
import sys
import os
import json
import re
import subprocess
import datetime

task_id        = sys.argv[1]
phase          = sys.argv[2]
severity_floor = sys.argv[3]
diff_file      = sys.argv[4]
default_action = sys.argv[5]
project_root   = sys.argv[6]

SEVERITY_ORDER = {"low": 0, "medium": 1, "high": 2, "critical": 3}
floor_level = SEVERITY_ORDER.get(severity_floor, 1)

# Parse rules from stdin (passed as env via bash)
rules_json_str = r"""${RULES_JSON}"""
try:
    rules_data = json.loads(rules_json_str)
    rules = rules_data.get("rules", [])
except json.JSONDecodeError as e:
    print(json.dumps({
        "task_id": task_id, "evaluated_at": "${EVALUATED_AT}",
        "phase": phase, "rules_evaluated": 0,
        "triggered": [], "deploy_block": False,
        "error": f"rules_json_parse_error: {e}"
    }))
    sys.exit(3)

# Read diff content
diff_content = ""
if diff_file and os.path.exists(diff_file):
    try:
        with open(diff_file) as fh:
            diff_content = fh.read()
    except OSError:
        pass

def get_changed_files(diff_text: str) -> list[str]:
    """Extract changed file paths from git diff --name-only style or unified diff."""
    files = []
    for line in diff_text.splitlines():
        if line.startswith("+++ b/") or line.startswith("--- a/"):
            p = line[6:] if line.startswith("+++ b/") else line[6:]
            if p != "/dev/null" and p not in files:
                files.append(p)
        elif line.startswith("diff --git "):
            # "diff --git a/foo b/foo"
            parts = line.split(" ")
            if len(parts) >= 4:
                p = parts[3][2:]  # strip "b/"
                if p not in files:
                    files.append(p)
    return files

def run_regex_match(expr: str, content: str, file_pattern: str | None) -> list[dict]:
    """Run regex match against content."""
    results = []
    try:
        pattern = re.compile(expr, re.MULTILINE | re.IGNORECASE)
        for i, line in enumerate(content.splitlines(), 1):
            if pattern.search(line):
                results.append({"file": "diff", "line": i, "snippet": line[:120]})
    except re.error as e:
        print(f"[rules-eval] WARN: invalid regex '{expr}': {e}", file=sys.stderr)
    return results

def run_grep_match(expr: str, content: str, file_list: list[str], project_root: str, file_pattern: str | None) -> list[dict]:
    """Run grep over files in project_root filtered by file_pattern."""
    results = []
    if not file_list:
        return results
    for rel_path in file_list:
        if file_pattern and not re.match(file_pattern.replace("*", ".*").replace("?", "."), os.path.basename(rel_path)):
            continue
        abs_path = os.path.join(project_root, rel_path)
        if not os.path.isfile(abs_path):
            continue
        try:
            out = subprocess.run(
                ["grep", "-nE", expr, abs_path],
                capture_output=True, text=True
            )
            for line in out.stdout.splitlines():
                parts = line.split(":", 2)
                lineno = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0
                snippet = parts[2][:120] if len(parts) >= 3 else line[:120]
                results.append({"file": rel_path, "line": lineno, "snippet": snippet})
        except Exception as e:
            print(f"[rules-eval] WARN: grep failed on {abs_path}: {e}", file=sys.stderr)
    return results

def run_shellcheck_match(expr: str, file_list: list[str], project_root: str, file_pattern: str | None) -> list[dict]:
    """Run shellcheck looking for specific SC codes."""
    if not shutil.which("shellcheck"):
        print("[rules-eval] WARN: shellcheck not in PATH — skipping shellcheck rule", file=sys.stderr)
        return []
    sc_codes = [c.strip() for c in expr.split(",") if c.strip()]
    pattern_str = "|".join(re.escape(c) for c in sc_codes)
    results = []
    for rel_path in file_list:
        if file_pattern and not re.match(file_pattern.replace("*", ".*").replace("?", "."), os.path.basename(rel_path)):
            continue
        abs_path = os.path.join(project_root, rel_path)
        if not os.path.isfile(abs_path):
            continue
        try:
            out = subprocess.run(
                ["shellcheck", "--format=json", abs_path],
                capture_output=True, text=True
            )
            findings = json.loads(out.stdout) if out.stdout.strip() else []
            for f in findings:
                code = f"SC{f.get('code', '')}"
                if code in sc_codes:
                    results.append({
                        "file": rel_path,
                        "line": f.get("line", 0),
                        "snippet": f.get("message", "")[:120]
                    })
        except Exception as e:
            print(f"[rules-eval] WARN: shellcheck failed on {abs_path}: {e}", file=sys.stderr)
    return results

def run_jq_match(expr: str, content: str) -> list[dict]:
    """Run jq expression against diff/content (treated as JSON if possible)."""
    results = []
    try:
        import subprocess
        out = subprocess.run(
            ["jq", "-r", expr],
            input=content, capture_output=True, text=True
        )
        if out.stdout.strip() and out.stdout.strip() not in ("null", "false"):
            results.append({"file": "content", "line": 0, "snippet": out.stdout.strip()[:120]})
    except Exception as e:
        print(f"[rules-eval] WARN: jq match failed: {e}", file=sys.stderr)
    return results

import shutil

changed_files = get_changed_files(diff_content)

triggered = []
rules_evaluated = 0

for rule in rules:
    rule_id       = rule.get("id", "?")
    severity      = rule.get("severity", "medium")
    action        = rule.get("action", default_action)
    scan          = rule.get("scan", {})
    match_cfg     = rule.get("match", {})
    aggregate_cfg = rule.get("aggregate", {})
    check_cfg     = rule.get("check", {})
    remediation   = rule.get("_remediation", "")

    # Skip if below severity floor
    if SEVERITY_ORDER.get(severity, 0) < floor_level:
        continue

    # Skip rules targeting diff if no diff available
    scan_target = scan.get("target", "diff")
    if scan_target == "diff" and not diff_content.strip():
        print(f"[rules-eval] INFO: rule {rule_id} skipped — no diff content at phase={phase}", file=sys.stderr)
        continue

    rules_evaluated += 1
    file_pattern = scan.get("file_pattern")

    match_type = match_cfg.get("type", "regex")
    expr       = match_cfg.get("expr", "")

    matches = []
    if match_type == "regex":
        matches = run_regex_match(expr, diff_content, file_pattern)
    elif match_type == "grep":
        matches = run_grep_match(expr, diff_content, changed_files, project_root, file_pattern)
    elif match_type == "shellcheck":
        matches = run_shellcheck_match(expr, changed_files, project_root, file_pattern)
    elif match_type == "jq":
        matches = run_jq_match(expr, diff_content)
    else:
        print(f"[rules-eval] WARN: unknown match type '{match_type}' for rule {rule_id}", file=sys.stderr)
        continue

    # Aggregate
    agg_op  = aggregate_cfg.get("op", "count")
    agg_val = len(matches) if agg_op in ("count", "sum") else (1 if matches else 0)

    # Check
    threshold  = check_cfg.get("threshold", 0)
    comparator = check_cfg.get("comparator", "gt")
    triggered_flag = False
    if comparator == "gt":
        triggered_flag = agg_val > threshold
    elif comparator == "gte":
        triggered_flag = agg_val >= threshold
    elif comparator == "lt":
        triggered_flag = agg_val < threshold
    elif comparator == "lte":
        triggered_flag = agg_val <= threshold
    elif comparator == "eq":
        triggered_flag = agg_val == threshold
    elif comparator == "ne":
        triggered_flag = agg_val != threshold

    if triggered_flag:
        triggered.append({
            "rule_id":     rule_id,
            "severity":    severity,
            "action":      action,
            "matches":     agg_val,
            "match_detail": matches[:5],  # first 5 samples
            "summary":     rule.get("description", ""),
            "remediation": remediation[:500] if remediation else ""
        })

deploy_block = any(t["action"] == "block_deploy" for t in triggered)

result = {
    "task_id":          task_id,
    "evaluated_at":     "${EVALUATED_AT}",
    "phase":            phase,
    "rules_evaluated":  rules_evaluated,
    "triggered":        triggered,
    "deploy_block":     deploy_block
}
print(json.dumps(result))
sys.exit(2 if deploy_block else 0)
PYEOF
