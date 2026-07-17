#!/usr/bin/env python3
"""leadv2-drift-only-vendored-check.py — classify a leadv2-drift-guard.sh
--json report (PLUGIN-CACHE-THIRD-COPY-REVERTS-FIXES-01 fix1, C1).

Usage:
    leadv2-drift-only-vendored-check.py '<drift-guard --json output>'

Prints "1" (stdout) if drift exists AND every drifted entry belongs to the
leadv2-repo-vendored copy (the lowest-blast-radius copy, off-limits-protected
SUPERVISE-V2-01 WIP, which leadv2-fanout.sh does not read scripts from).
Prints "0" otherwise (no drift, malformed input, or drift touches any other
copy) — callers must hard-block in that case.

Extracted into its own file (rather than an inline heredoc in
leadv2-fanout.sh) so it can be unit-tested directly against synthetic
drift-guard JSON without invoking the full fanout.sh apparatus
(worktrees/tmux/active-registry) — see
tests/test-drift-guard-safety-fixes.sh.
"""
from __future__ import annotations

import json
import sys


def only_vendored_drift(raw_json: str) -> bool:
    try:
        data = json.loads(raw_json)
    except (json.JSONDecodeError, TypeError):
        return False
    entries = data.get("entries") or []
    if not entries:
        return False
    return all(e.startswith("leadv2-repo-vendored:") for e in entries)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: leadv2-drift-only-vendored-check.py '<json>'", file=sys.stderr)
        return 2
    print(1 if only_vendored_drift(sys.argv[1]) else 0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
