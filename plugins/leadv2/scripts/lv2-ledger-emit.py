#!/usr/bin/env python3
"""lv2-ledger-emit.py — append one event to docs/leadv2/ledger.jsonl

Usage: python3 lv2-ledger-emit.py '<json_event_object>'

The JSON object must contain at minimum: {"event": "<type>"}
Optional fields (auto-filled if absent): ts, task_id (from LEADV2_TASK_ID env), phase.

Event types: phase_enter, phase_exit, agent_spawn, decision_made, skill_promoted, task_close

Never raises — on error, silently exits 0 (fire-and-forget semantics).
"""
import datetime
import json
import os
import sys


def main() -> None:
    if len(sys.argv) < 2:
        return
    try:
        ev: dict = json.loads(sys.argv[1])
    except (json.JSONDecodeError, ValueError):
        return

    # Auto-populate standard fields
    ev.setdefault("ts", datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None).isoformat() + "Z")
    ev.setdefault("task_id", os.environ.get("LEADV2_TASK_ID", "unknown"))
    ev.setdefault("phase", os.environ.get("LEADV2_CURRENT_PHASE", "unknown"))

    line = json.dumps(ev, separators=(",", ":")) + "\n"

    proj_root = os.environ.get("LEADV2_PROJECT_ROOT", ".")
    ledger_path = os.path.join(proj_root, "docs", "leadv2", "ledger.jsonl")
    os.makedirs(os.path.dirname(ledger_path), exist_ok=True)

    try:
        with open(ledger_path, "a") as f:
            f.write(line)
    except OSError:
        pass  # fire-and-forget — never block workflow on ledger failure


if __name__ == "__main__":
    main()
