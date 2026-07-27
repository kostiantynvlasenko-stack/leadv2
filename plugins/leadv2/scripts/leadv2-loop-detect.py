#!/usr/bin/env python3
"""
leadv2-loop-detect.py — subagent tool-call loop detector.

stdin:  JSON line {"tool_name": str, "args_canonical_json": str,
                   "session_id": str, "task_id": str,
                   "hook_event_name": "PreToolUse" | "PostToolUse" (default PreToolUse),
                   "agent_id": str (optional, namespaces the counter per child agent)}
stdout: exactly one line — CLEAR | WARN <reason> | BLOCK <reason>

BLOCKING FIX (fix-round-2, task 6d0c93f4a7b2, item 6): this detector used to
mutate its persisted counters from the PreToolUse path, so every call denied
by ANY hook -- including this detector's own BLOCK and every other hook's deny
-- still incremented tool_counts/hash_counts, because PreToolUse fires before
the harness knows whether the call will actually run. That inflated counter
was also keyed only on session_id, so a freshly-spawned child agent inherited
its parent's tool-cap budget outright. Both are fixed here:
  - PreToolUse (hook_event_name absent or "PreToolUse") is now READ-ONLY: it
    computes what the counts WOULD become if this call executes, decides
    CLEAR/WARN/BLOCK against that hypothetical, and persists nothing.
  - PostToolUse only fires for calls that actually executed (never for one
    denied by this hook or a sibling hook), so counters are only ever
    incremented there.
  - The state file is now keyed by session_id PLUS a sanitized agent_id when
    present (same extraction convention as leadv2-tool-counter.sh: agent_id,
    else tool_input.agent_id, else the subagent transcript-path basename), so
    a child agent gets its own counter namespace instead of inheriting the
    parent's.

Environment:
  LEADV2_LOOP_DETECT   shadow | 1 | 0  (default: on — matches hook wrapper default)
  LEADV2_LOOP_WARN_AT  int (default 3)
  LEADV2_LOOP_HARD_AT  int (default 5)
  LEADV2_TOOL_FREQ_WARN  int (default 30)
  LEADV2_TOOL_HARD_LIMIT int (default 50)
  LEADV2_UNCAPPED_TOOLS  comma-separated tool names (default "Agent") — exempt from
                          the per-tool-type frequency checks (TOOL_FREQ_WARN/
                          TOOL_HARD_LIMIT) ONLY. A supervisor's job is spawning
                          subagents, so the generic anti-loop tool-count cap must
                          not collateral-damage the Agent tool (2026-07-27 defect:
                          a single global TOOL_HARD_LIMIT applied per tool_name gave
                          Agent the same 50-call ceiling as Bash). The identical-
                          call-signature loop detector (WARN_AT/HARD_AT above) is
                          NOT affected by this exemption — a genuinely looping
                          identical Agent call is still caught.

Python 3.9+, stdlib only.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

LOOP_DETECT = os.environ.get("LEADV2_LOOP_DETECT", "1")
WARN_AT = int(os.environ.get("LEADV2_LOOP_WARN_AT", "3"))
HARD_AT = int(os.environ.get("LEADV2_LOOP_HARD_AT", "5"))
TOOL_FREQ_WARN = int(os.environ.get("LEADV2_TOOL_FREQ_WARN", "30"))
TOOL_HARD_LIMIT = int(os.environ.get("LEADV2_TOOL_HARD_LIMIT", "50"))
UNCAPPED_TOOLS = {
    t.strip() for t in os.environ.get("LEADV2_UNCAPPED_TOOLS", "Agent").split(",") if t.strip()
}

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


def _sanitize_key(raw: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "", raw)


def _state_key(session_id: str, agent_id: str = "") -> str:
    # Child agents get their own counter namespace instead of inheriting the
    # parent session's budget (fix-round-2, task 6d0c93f4a7b2, item 6).
    safe_session = _sanitize_key(session_id)
    if not agent_id:
        return safe_session
    safe_agent = _sanitize_key(agent_id)
    if not safe_agent:
        return safe_session
    return f"{safe_session}-{safe_agent}"


def _state_path(state_key: str) -> Path:
    return Path(f"/tmp/leadv2-loop-detect-{state_key}.json")


def _load_state(path: Path) -> dict:
    try:
        text = path.read_text()
        return json.loads(text)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"window": [], "tool_counts": {}, "hash_counts": {}}


def _save_state(path: Path, state: dict) -> None:
    # Atomic write: write to a sibling .tmp file then rename to avoid partial reads
    # from concurrent parallel subagent invocations.
    tmp_fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".tmp")
    try:
        with os.fdopen(tmp_fd, "w") as fh:
            fh.write(json.dumps(state))
        os.replace(tmp_name, str(path))
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def _peek_counts(state_key: str, tool_name: str, h: str, file_path: str = "") -> tuple[int, int, int]:
    """Read-only: return (hash_count_after, tool_count_after, read_seen_before) as
    if this call were to execute, WITHOUT persisting anything. Used exclusively
    from the PreToolUse (decision-only) path so a denied call never inflates the
    counters (fix-round-2, task 6d0c93f4a7b2, item 6)."""
    path = _state_path(state_key)
    state = _load_state(path)
    hash_count_after = state.get("hash_counts", {}).get(h, 0) + 1
    tool_count_after = state.get("tool_counts", {}).get(tool_name, 0) + 1
    read_seen_before = state.get("read_paths", {}).get(file_path, 0) if file_path else 0
    return hash_count_after, tool_count_after, read_seen_before


def _locked_update(state_key: str, tool_name: str, h: str, file_path: str = "") -> dict:
    """Read state, update, write back — all under flock -x. Called ONLY from the
    PostToolUse path (fix-round-2, task 6d0c93f4a7b2, item 6): PostToolUse fires
    only for calls that actually executed, so this is the sole place counters get
    incremented -- a call denied by this hook or any sibling hook never reaches
    here and never inflates the counter."""
    path = _state_path(state_key)
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

        # Track seen Read file_paths to narrow paging exemption (L2 fix):
        # a file_path is only "paging" if it was seen before with a different offset.
        if tool_name == "Read" and file_path:
            read_paths: dict = state.get("read_paths", {})
            read_paths[file_path] = read_paths.get(file_path, 0) + 1
            state["read_paths"] = read_paths

        _save_state(path, state)
        return state
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# Decision
# ---------------------------------------------------------------------------


def decide_from_counts(
    tool_name: str,
    hash_count_after: int,
    tool_count_after: int,
    file_path: str,
    read_seen_before: int,
) -> tuple[str, str]:
    """Return (verdict, reason) given the counts THIS call would produce if it
    executes (fix-round-2, task 6d0c93f4a7b2, item 6: caller computes these
    read-only via _peek_counts for PreToolUse -- nothing is persisted here)."""
    # Per-call-signature checks (highest priority)
    if hash_count_after >= HARD_AT:
        return "BLOCK", f"{tool_name} identical call repeated {hash_count_after}x (limit {HARD_AT})"
    if hash_count_after >= WARN_AT:
        return "WARN", f"{tool_name} identical call repeated {hash_count_after}x (warn threshold {WARN_AT})"

    # Per-tool-type frequency checks. Tools in UNCAPPED_TOOLS (default: Agent) are
    # exempt from this cap entirely -- a supervisor's whole job is spawning
    # subagents, so the generic anti-loop tool-count cap must not collateral-damage
    # the Agent tool. The identical-call-signature check above still applies.
    if tool_name in UNCAPPED_TOOLS:
        return "CLEAR", ""

    # Paging exemption (narrow, L2 fix): exempt only when the SAME file_path was seen
    # before (i.e. it is a genuine incremental read of one large file, not 200 distinct
    # files each read once). A novel file_path with count==1 is NOT a paging read.
    is_paging_read = (
        tool_name == "Read"
        and hash_count_after == 1
        and file_path != ""
        and read_seen_before > 0  # path was visited before this call
    )
    if not is_paging_read:
        if tool_count_after >= TOOL_HARD_LIMIT:
            return "BLOCK", f"{tool_name} called {tool_count_after}x total (limit {TOOL_HARD_LIMIT})"
        if tool_count_after >= TOOL_FREQ_WARN:
            return "WARN", f"{tool_name} called {tool_count_after}x total (warn at {TOOL_FREQ_WARN})"

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
        hook_event: str = payload.get("hook_event_name") or "PreToolUse"
        agent_id: str = payload.get("agent_id") or ""
    except (json.JSONDecodeError, KeyError) as exc:
        print(f"[LOOP-DETECT] bad input: {exc}", file=sys.stderr)
        print("CLEAR")
        return

    state_key = _state_key(session_id, agent_id)

    # Extract file_path for the narrow paging exemption (Read tool only)
    file_path = ""
    if tool_name == "Read":
        try:
            file_path = json.loads(args_canonical_json).get("file_path", "")
        except (json.JSONDecodeError, AttributeError):
            pass

    try:
        canon = canonicalize(tool_name, args_canonical_json, task_id)
        h = make_hash(canon)

        if hook_event == "PostToolUse":
            # The call actually executed (PostToolUse never fires for a call
            # denied by this hook or any sibling hook) -- this is the ONLY
            # place counters get persisted (fix-round-2, task 6d0c93f4a7b2,
            # item 6). No verdict is computed or possible after the fact.
            _locked_update(state_key, tool_name, h, file_path=file_path)
            print("CLEAR")
            return

        # PreToolUse (or unspecified, back-compat): read-only decision. Never
        # mutate state here -- see _peek_counts docstring.
        hash_count_after, tool_count_after, read_seen_before = _peek_counts(
            state_key, tool_name, h, file_path=file_path
        )
        verdict, reason = decide_from_counts(
            tool_name, hash_count_after, tool_count_after, file_path, read_seen_before
        )
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
