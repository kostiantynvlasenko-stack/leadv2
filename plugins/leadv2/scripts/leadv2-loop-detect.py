#!/usr/bin/env python3
"""
leadv2-loop-detect.py — subagent tool-call loop detector.

stdin:  JSON line {"tool_name": str, "args_canonical_json": str,
                   "session_id": str, "task_id": str}
stdout: exactly one line — CLEAR | WARN <reason> | BLOCK <reason>

Environment:
  LEADV2_LOOP_DETECT   shadow | 1 | 0  (default: off)
  LEADV2_LOOP_WARN_AT  int (default 3)
  LEADV2_LOOP_HARD_AT  int (default 5)
  LEADV2_TOOL_FREQ_WARN  int (default 30)
  LEADV2_TOOL_HARD_LIMIT int (default 50)

Python 3.9+, stdlib only.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

LOOP_DETECT = os.environ.get("LEADV2_LOOP_DETECT", "0")
WARN_AT = int(os.environ.get("LEADV2_LOOP_WARN_AT", "3"))
HARD_AT = int(os.environ.get("LEADV2_LOOP_HARD_AT", "5"))
TOOL_FREQ_WARN = int(os.environ.get("LEADV2_TOOL_FREQ_WARN", "30"))
TOOL_HARD_LIMIT = int(os.environ.get("LEADV2_TOOL_HARD_LIMIT", "50"))

WINDOW_SIZE = 10

# Regex for ISO-8601 datetimes and Unix epoch integers (10-13 digits)
_TS_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?"
    r"|\b\d{10,13}\b"
)

# ---------------------------------------------------------------------------
# Canonicalization
# ---------------------------------------------------------------------------


def _detect_worktree_prefix() -> str:
    """Return the absolute worktree root to strip from paths."""
    # Prefer the script's own location hierarchy
    script_dir = Path(__file__).resolve()
    for parent in script_dir.parents:
        if (parent / ".git").exists() or (parent / ".git").is_file():
            return str(parent) + "/"
    return ""


_WORKTREE_PREFIX = _detect_worktree_prefix()


def _strip_worktree(path: str) -> str:
    if _WORKTREE_PREFIX and path.startswith(_WORKTREE_PREFIX):
        return path[len(_WORKTREE_PREFIX):]
    return path


def _normalize_tmp(text: str, task_id: str) -> str:
    pattern = re.compile(
        r"/tmp/leadv2-" + re.escape(task_id) + r"-[^\s\"']*"
    )
    return pattern.sub("/tmp/leadv2-TASKID-PLACEHOLDER", text)


def _normalize_timestamps(text: str) -> str:
    return _TS_RE.sub("TIMESTAMP_PLACEHOLDER", text)


def canonicalize(tool_name: str, args_canonical_json: str, task_id: str) -> str:
    """Return a stable string to hash for loop detection."""
    try:
        args: dict = json.loads(args_canonical_json)
    except json.JSONDecodeError:
        # Unparseable args — treat the raw string as canonical
        args = {"_raw": args_canonical_json}

    canon: dict = {}

    if tool_name == "Read":
        # Retain offset so reads at different offsets produce distinct hashes
        # (paging the same file is not a loop). Drop limit only (cosmetic variation).
        for k, v in args.items():
            if k == "limit":
                continue
            if isinstance(v, str):
                v = _strip_worktree(v)
            canon[k] = v

    elif tool_name in ("Edit", "Write"):
        for k, v in args.items():
            if isinstance(v, str):
                v = _strip_worktree(v)
            # Keep old_string/new_string as-is so different patches → different hash
            canon[k] = v

    else:
        # Bash and everything else
        for k, v in args.items():
            if isinstance(v, str):
                v = _strip_worktree(v)
            canon[k] = v

    # Serialize deterministically
    canon_str = json.dumps(canon, sort_keys=True)

    # Normalize volatile parts
    canon_str = _normalize_tmp(canon_str, task_id)
    canon_str = _normalize_timestamps(canon_str)

    return tool_name + ":" + canon_str


def make_hash(canon_str: str) -> str:
    return hashlib.sha256(canon_str.encode()).hexdigest()[:16]


# ---------------------------------------------------------------------------
# State file I/O
# ---------------------------------------------------------------------------


def _state_path(session_id: str) -> Path:
    return Path(f"/tmp/leadv2-loop-detect-{session_id}.json")


def _load_state(path: Path) -> dict:
    try:
        text = path.read_text()
        return json.loads(text)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"window": [], "tool_counts": {}, "hash_counts": {}}


def _save_state(path: Path, state: dict) -> None:
    path.write_text(json.dumps(state))


def _locked_update(session_id: str, tool_name: str, h: str) -> dict:
    """Read state, update, write back — all under flock -x."""
    path = _state_path(session_id)
    # Open or create
    fd = os.open(str(path), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError:
            print("[LOOP-DETECT] flock unavailable, proceeding without lock", file=sys.stderr)

        # Read current state from file (fd just gives us the lock)
        state = _load_state(path)

        # Update window
        window: list = state.get("window", [])
        window.append(h)
        if len(window) > WINDOW_SIZE:
            window = window[-WINDOW_SIZE:]
        state["window"] = window

        # Update hash counts
        hash_counts: dict = state.get("hash_counts", {})
        hash_counts[h] = hash_counts.get(h, 0) + 1
        state["hash_counts"] = hash_counts

        # Update tool counts
        tool_counts: dict = state.get("tool_counts", {})
        tool_counts[tool_name] = tool_counts.get(tool_name, 0) + 1
        state["tool_counts"] = tool_counts

        _save_state(path, state)
        return state
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# Decision
# ---------------------------------------------------------------------------


def decide(tool_name: str, h: str, state: dict) -> tuple[str, str]:
    """Return (verdict, reason). verdict in {CLEAR, WARN, BLOCK}."""
    hash_counts: dict = state.get("hash_counts", {})
    tool_counts: dict = state.get("tool_counts", {})

    count = hash_counts.get(h, 0)
    tool_count = tool_counts.get(tool_name, 0)

    # Per-call-signature checks (highest priority)
    if count >= HARD_AT:
        return "BLOCK", f"{tool_name} identical call repeated {count}x (limit {HARD_AT})"
    if count >= WARN_AT:
        return "WARN", f"{tool_name} identical call repeated {count}x (warn threshold {WARN_AT})"

    # Per-tool-type frequency checks
    # Skip the per-tool hard limit for Read calls that are paging (unique hash, count == 1).
    # Paging = same file_path with distinct (offset, limit) pairs — each call has hash_count == 1.
    is_paging_read = tool_name == "Read" and count == 1
    if not is_paging_read:
        if tool_count >= TOOL_HARD_LIMIT:
            return "BLOCK", f"{tool_name} called {tool_count}x total (limit {TOOL_HARD_LIMIT})"
        if tool_count >= TOOL_FREQ_WARN:
            return "WARN", f"{tool_name} called {tool_count}x total (warn at {TOOL_FREQ_WARN})"

    return "CLEAR", ""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    if LOOP_DETECT == "0" or LOOP_DETECT == "":
        print("CLEAR")
        return

    shadow = LOOP_DETECT == "shadow"

    try:
        raw = sys.stdin.read().strip()
        payload: dict = json.loads(raw)
        tool_name: str = payload["tool_name"]
        args_canonical_json: str = payload["args_canonical_json"]
        session_id: str = payload["session_id"]
        task_id: str = payload["task_id"]
    except (json.JSONDecodeError, KeyError) as exc:
        print(f"[LOOP-DETECT] bad input: {exc}", file=sys.stderr)
        print("CLEAR")
        return

    try:
        canon = canonicalize(tool_name, args_canonical_json, task_id)
        h = make_hash(canon)
        state = _locked_update(session_id, tool_name, h)
        verdict, reason = decide(tool_name, h, state)
    except Exception as exc:  # noqa: BLE001
        print(f"[LOOP-DETECT] unhandled exception: {exc}", file=sys.stderr)
        print("CLEAR")
        return

    if shadow:
        if verdict != "CLEAR":
            print(f"[LOOP-DETECT shadow] would emit {verdict}: {reason}", file=sys.stderr)
        print("CLEAR")
        return

    if verdict == "CLEAR":
        print("CLEAR")
    elif verdict == "WARN":
        print(f"WARN {reason}")
    else:
        print(f"BLOCK {reason}")


if __name__ == "__main__":
    main()
