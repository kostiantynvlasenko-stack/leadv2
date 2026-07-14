#!/usr/bin/env bash
# scripts/task-mortality-check.sh — LEAD-COMPACT-SURVIVAL-01 verifiability probe.
#
# This IS the proof that the compact-freeze/reground pair works. It answers:
# "of the task-ids frozen before the last compact, how many resurfaced in the
# transcript AFTER that compact?"
#
# Usage:
#   task-mortality-check.sh <transcript.jsonl> <compact-freeze.md>
#
# Extracts open task-ids from the "## OPEN TASK IDS" section of
# <compact-freeze.md> (lines "- <id> [<status>] ..."), then checks how many
# of them appear anywhere in <transcript.jsonl> AFTER the last detected
# compact boundary (a line containing Claude Code's standard
# compact-continuation preamble, "this session is being continued", matched
# case-insensitively). If no boundary is found, the whole transcript is
# scanned (best-effort — the script never crashes on an unfamiliar format).
#
# Exit 0 + "survival: N/N" — every frozen id resurfaced post-compact.
# Exit 1 + "missing: <ids>" — at least one frozen id never resurfaced.
# Exit 2 — bad usage / missing input file (this script's own errors are NOT
#          fail-open: it exists to report a true/false verdict, not to hide one).
#
# stdlib-only (bash + python3), zero network.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <transcript.jsonl> <compact-freeze.md>" >&2
  exit 2
fi

TRANSCRIPT="$1"
FREEZE="$2"

if [[ ! -f "$TRANSCRIPT" ]]; then
  echo "ERROR: transcript not found: $TRANSCRIPT" >&2
  exit 2
fi
if [[ ! -f "$FREEZE" ]]; then
  echo "ERROR: freeze file not found: $FREEZE" >&2
  exit 2
fi

set +e
python3 - "$TRANSCRIPT" "$FREEZE" <<'PYEOF'
import sys, re


def extract_frozen_ids(freeze_path):
    ids = []
    in_section = False
    with open(freeze_path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("## "):
                in_section = line.startswith("## OPEN TASK IDS")
                continue
            if in_section:
                m = re.match(r"^-\s+(\S+)\s+\[", line)
                if m:
                    ids.append(m.group(1))
    return ids


def find_compact_boundary(lines):
    preamble = "this session is being continued"
    boundary = -1
    for i, line in enumerate(lines):
        if preamble in line.lower():
            boundary = i
    return boundary


def main():
    transcript_path, freeze_path = sys.argv[1], sys.argv[2]

    ids = extract_frozen_ids(freeze_path)
    if not ids:
        print("survival: 0/0 (no open task-ids found in freeze file)")
        sys.exit(0)

    with open(transcript_path, encoding="utf-8") as f:
        t_lines = f.readlines()

    boundary = find_compact_boundary(t_lines)
    post_lines = t_lines[boundary + 1:] if boundary >= 0 else t_lines
    post_text = "".join(post_lines)

    missing = [tid for tid in ids if tid not in post_text]
    survived = len(ids) - len(missing)
    print(f"survival: {survived}/{len(ids)}")
    if missing:
        print("missing: " + ", ".join(missing))
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
PYEOF
RC=$?
set -e
exit "$RC"
