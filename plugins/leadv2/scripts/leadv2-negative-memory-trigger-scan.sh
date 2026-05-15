#!/bin/bash
# leadv2-negative-memory-trigger-scan.sh — Phase-4 pre-commit regex scan against negative memory.
# Inspired by jcode `Negative Memories trigger_patterns`: when a memory entry has a regex trigger,
# auto-surface it whenever the diff matches — independent of keyword-overlap heuristic.
#
# Schema extension to docs/leadv2-negative-memory.yaml entries[]:
#   trigger_pattern: "<extended-regex>"   # optional; when present, scans `git diff` instead of approach text
#   trigger_scope:   "diff" | "files"     # diff = -G regex; files = file paths in change set
#
# Usage: leadv2-negative-memory-trigger-scan.sh [--base main] [--task-id <id>]
# Exit 0 = no triggers fired. Exit 2 = trigger fired, stdout describes.

set -euo pipefail

BASE="${LEADV2_TRIGGER_BASE:-main}"
TASK_ID="${LEADV2_TASK_ID:-}"
NM_FILE="docs/leadv2-negative-memory.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    *) echo "[trigger-scan] unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$NM_FILE" ]] || exit 0   # no memory yet, nothing to scan

python3 - "$NM_FILE" "$BASE" "$TASK_ID" <<'PYEOF'
import subprocess, sys, yaml, re

nm_path, base, task_id = sys.argv[1], sys.argv[2], sys.argv[3]
data = yaml.safe_load(open(nm_path)) or {}
entries = [e for e in (data.get("entries") or []) if e.get("status") == "active" and e.get("trigger_pattern")]

if not entries:
    sys.exit(0)

# Diff body and file list
try:
    diff_body = subprocess.check_output(["git", "diff", f"{base}...HEAD"], text=True, stderr=subprocess.DEVNULL)
except subprocess.CalledProcessError:
    diff_body = ""
try:
    files = subprocess.check_output(["git", "diff", "--name-only", f"{base}...HEAD"], text=True, stderr=subprocess.DEVNULL).splitlines()
except subprocess.CalledProcessError:
    files = []

violations = []
for e in entries:
    pat = e["trigger_pattern"]
    scope = e.get("trigger_scope", "diff")
    haystack = diff_body if scope == "diff" else "\n".join(files)
    try:
        rx = re.compile(pat, re.MULTILINE)
    except re.error as ex:
        print(f"[trigger-scan] WARN bad regex in {e.get('id')}: {ex}", file=sys.stderr)
        continue
    matches = rx.findall(haystack)
    if matches:
        violations.append({
            "nm_id": e.get("id"),
            "pattern": pat,
            "scope": scope,
            "match_count": len(matches),
            "failure_mode": e.get("failure_mode", ""),
            "first_match": str(matches[0])[:120],
        })

if not violations:
    sys.exit(0)

print(f"NEGATIVE_MEMORY_TRIGGER_HIT task={task_id} count={len(violations)}")
for v in violations:
    print(f"  {v['nm_id']} ({v['scope']}, x{v['match_count']}) — {v['failure_mode']}")
    print(f"    pattern: {v['pattern']}")
    print(f"    first:   {v['first_match']}")

sys.exit(2)
PYEOF
