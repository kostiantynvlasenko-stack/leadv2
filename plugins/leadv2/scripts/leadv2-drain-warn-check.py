#!/usr/bin/env python3
"""leadv2-drain-warn-check.py — helper for SYS-DRAIN-FOLLOWUPS-AT-CLOSE-01.

Usage:
  python3 leadv2-drain-warn-check.py extract_items <followup_file>
      Prints high-importance lines from followup_file to stdout.

  python3 leadv2-drain-warn-check.py check_tasks <tasks_yaml> <key>
      Exit 0 if key found in tasks.yaml titles/ids, 1 otherwise.

  python3 leadv2-drain-warn-check.py check_board <board_md> <key>
      Exit 0 if key found in BOARD.md content, 1 otherwise.
"""
import re
import sys

IMPORTANCE_RE = re.compile(
    r"(?i)(CRITICAL|HIGH|TODO|FOLLOWUP|follow.?up|action.?item|decision|!!?)",
)


def extract_items(path: str) -> None:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                s = line.strip()
                if len(s) > 5 and IMPORTANCE_RE.search(s):
                    print(s)
    except OSError:
        pass


def check_tasks(tasks_yaml: str, key: str) -> int:
    try:
        import yaml  # pyyaml is a project dependency
        with open(tasks_yaml, encoding="utf-8") as fh:
            items = yaml.safe_load(fh) or []
        key_lower = key.lower()
        for it in items:
            if key_lower in str(it.get("title", "")).lower():
                return 0
            if key_lower in str(it.get("id", "")).lower():
                return 0
        return 1
    except Exception:
        return 1


def check_board(board_md: str, key: str) -> int:
    try:
        with open(board_md, encoding="utf-8", errors="replace") as fh:
            content = fh.read().lower()
        return 0 if key.lower() in content else 1
    except Exception:
        return 1


def main() -> None:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    cmd = sys.argv[1]
    if cmd == "extract_items":
        extract_items(sys.argv[2])
    elif cmd == "check_tasks":
        sys.exit(check_tasks(sys.argv[2], sys.argv[3]))
    elif cmd == "check_board":
        sys.exit(check_board(sys.argv[2], sys.argv[3]))
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
