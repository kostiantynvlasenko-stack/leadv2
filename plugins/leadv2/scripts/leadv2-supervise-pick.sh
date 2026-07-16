#!/usr/bin/env bash
# leadv2-supervise-pick.sh — SUPERVISE-V2-01 F1 (batch-2 item 2): read-only
# task picker. Input: docs/tasks.yaml top-N queued candidates (via the
# existing leadv2-tasks-lib.sh shared-lock reader — never a second tasks
# store, never a hand-edit) + a cached truth-probe breach snapshot (item 3's
# output, if present). Output: ranked JSON of <=10 candidates
# {id, title, priority, lane, recommend, reason} for the LEAD to present via
# AskUserQuestion. This script NEVER dispatches/claims/launches anything —
# read-only, no side effects, safe to call every reconciliation cycle.
#
# Usage:
#   leadv2-supervise-pick.sh [N]     # N defaults to 10, capped at 10
#
# A RED truth breach ranks its linked work item first (codex-plan step 5:
# "A RED breach already reconciled to a work item is ranked ahead of
# ordinary queued work"); this script does NOT create the work item itself —
# that's existing truth-reconciliation's job, out of scope here. If the
# breach snapshot is missing/stale/malformed, truth_probe reports
# "unavailable" and ranking degrades to plain queue order — never silently
# treated as "no breaches" being asserted as fact.
#
# Env overrides (test sandboxing): LEADV2_PROJECT_ROOT / CLAUDE_PROJECT_DIR /
# PROJECT_ROOT — repo root (same fail-closed order as leadv2-supervise.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

N="${1:-10}"
if [[ "$N" -gt 10 ]]; then
  N=10
fi

PROJECT_ROOT=""
if [[ -n "${LEADV2_PROJECT_ROOT:-}" ]]; then
  PROJECT_ROOT="$LEADV2_PROJECT_ROOT"
elif [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_ROOT="$CLAUDE_PROJECT_DIR"
elif _lv2p_top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
  PROJECT_ROOT="$_lv2p_top"
fi
if [[ -z "$PROJECT_ROOT" ]]; then
  printf -- '{"error":"root_error","message":"could not resolve project root"}\n'
  exit 1
fi
export LEADV2_PROJECT_ROOT="$PROJECT_ROOT"
export PROJECT_ROOT

# shellcheck source=leadv2-tasks-lib.sh
source "${SCRIPT_DIR}/leadv2-tasks-lib.sh"

BREACH_FILE="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" truth-breaches-last.json)"

RAW="$(leadv2_tasks_top_n "$N" || true)"

python3 - "$RAW" "$BREACH_FILE" "$N" <<'PY'
import sys, json, os

raw, breach_file, n_str = sys.argv[1], sys.argv[2], sys.argv[3]
n = int(n_str)

candidates = []
for line in raw.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 4:
        continue
    lane, priority, iid, title = parts[0], parts[1], parts[2], "\t".join(parts[3:])
    candidates.append({
        "id": iid, "title": title, "priority": priority, "lane": lane,
        "recommend": False, "reason": f"queued {lane}/{priority}",
    })

breach_ids = set()
truth_probe_status = "unavailable"
if os.path.isfile(breach_file):
    try:
        with open(breach_file, encoding="utf-8") as fh:
            bd = json.load(fh) or {}
        truth_probe_status = "checked"
        for b in (bd.get("breaches") or []):
            wid = b.get("work_item_id") or b.get("id")
            if wid:
                breach_ids.add(str(wid))
    except Exception:
        truth_probe_status = "unavailable"

by_id = {c["id"]: c for c in candidates}
for wid in breach_ids:
    if wid in by_id:
        by_id[wid]["recommend"] = True
        by_id[wid]["reason"] = f"truth-breach RED linked: {wid}"

# Breach-linked candidates first; queue order preserved (stable sort) within
# each recommend bucket — top_n already ranked by lane/priority/created_at.
ranked = sorted(candidates, key=lambda c: 0 if c["recommend"] else 1)
ranked = ranked[:n]

print(json.dumps({"candidates": ranked, "truth_probe": truth_probe_status}, indent=2))
PY
