#!/usr/bin/env python3
"""lv2-ledger-last-phase.py — find last committed phase for a task_id

Usage: python3 lv2-ledger-last-phase.py <task_id> [ledger_path]

Reads ledger.jsonl, scans for phase_exit events matching task_id,
returns the phase name of the last one. Prints "NONE" if no exit found.

Exit 0 always (crash-recovery tool — must not itself crash).
"""
import json
import os
import sys


def main() -> None:
    if len(sys.argv) < 2:
        print("NONE")
        return

    task_id = sys.argv[1]
    proj_root = os.environ.get("LEADV2_PROJECT_ROOT", ".")
    ledger_path = sys.argv[2] if len(sys.argv) >= 3 else os.path.join(proj_root, "docs", "leadv2", "ledger.jsonl")

    if not os.path.exists(ledger_path):
        print("NONE")
        return

    last_phase: str | None = None
    try:
        with open(ledger_path) as f:
            for raw_line in f:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    ev = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue
                if ev.get("event") == "phase_exit" and ev.get("task_id") == task_id:
                    last_phase = ev.get("phase", "unknown")
    except OSError:
        print("NONE")
        return

    print(last_phase if last_phase is not None else "NONE")


if __name__ == "__main__":
    main()
