#!/usr/bin/env python3
"""leadv2-direction-safety-check.py — one-file-at-a-time safety gate for
leadv2-plugin-sync.sh's --delete rsync pushes (PLUGIN-CACHE-THIRD-COPY-
REVERTS-FIXES-01).

Usage:
    leadv2-direction-safety-check.py <git_root> <relpath> <dst_file>

<git_root>  the top of the canonical git repo (~/Projects/leadv2)
<relpath>   the path of the file AS TRACKED in that repo, e.g.
            plugins/leadv2/scripts/leadv2-session-runner.sh
<dst_file>  the on-disk file about to be overwritten by rsync

Exit 0 (SAFE)   — dst_file's content byte-matches some blob canonical's own
                  git history ever held for relpath. Canonical has seen this
                  content before (it is not a stray un-landed fix); rsync
                  may proceed to overwrite it.
Exit 1 (UNSAFE) — dst_file's content does not match ANY historical blob for
                  relpath in canonical's history. Treat as a possible
                  un-landed fix living only on this copy; caller must
                  exclude this file from the sync instead of overwriting.

Kept deliberately simple: shells out to `git log --all` + `git show` per
historical commit touching the path, hashes with sha256, no attempt at
smarter diffing. This is a safety NET, not a merge tool.
"""
from __future__ import annotations

import hashlib
import subprocess
import sys


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} <git_root> <relpath> <dst_file>", file=sys.stderr)
        return 2
    git_root, relpath, dst_file = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        with open(dst_file, "rb") as f:
            dst_hash = sha256_bytes(f.read())
    except OSError as exc:
        print(f"[direction-safety] cannot read dst_file {dst_file}: {exc}", file=sys.stderr)
        # Can't read target content — fail SAFE (allow) since there is
        # nothing on disk to clobber/lose.
        return 0

    log_proc = subprocess.run(
        ["git", "-C", git_root, "log", "--all", "--format=%H", "--", relpath],
        capture_output=True,
        text=True,
        check=False,
    )
    if log_proc.returncode != 0:
        print(
            f"[direction-safety] git log failed for {relpath} in {git_root}: "
            f"{log_proc.stderr.strip()}",
            file=sys.stderr,
        )
        # Can't determine history — fail UNSAFE (refuse), never guess.
        return 1

    shas = [line.strip() for line in log_proc.stdout.splitlines() if line.strip()]
    if not shas:
        # relpath has no history at all in canonical — nothing to compare
        # against; treat as unsafe (refuse) rather than assume it's fine.
        return 1

    for sha in shas:
        show_proc = subprocess.run(
            ["git", "-C", git_root, "show", f"{sha}:{relpath}"],
            capture_output=True,
            check=False,
        )
        if show_proc.returncode != 0:
            # File didn't exist at this commit (renamed/added later elsewhere
            # in history) — skip, try next commit.
            continue
        if sha256_bytes(show_proc.stdout) == dst_hash:
            return 0  # SAFE — found a matching historical blob.

    return 1  # UNSAFE — content never appeared in canonical's history.


if __name__ == "__main__":
    sys.exit(main())
