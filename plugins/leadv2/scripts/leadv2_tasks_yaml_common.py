"""Shared tolerant loader for docs/tasks.yaml (GATE-A2-FIX-01, 2026-07-15).

docs/tasks.yaml can legitimately be either:
  - a bare top-level list of task dicts (the classic tasks-lib.sh /
    lane-yaml shape), or
  - a mapping with a list-bearing key, e.g. {"total_open": N, "tasks": [...]}
    -- this is what persona-engine's scripts/task-sync-yaml.sh writes
    (a Supabase work_items projection; see leadv2-fanout.sh for a prior,
    already-correct reference implementation of this same tolerance).

Every script that reads docs/tasks.yaml (or an equivalent lane yaml) MUST
route through load_tasks_items() instead of re-deriving the
`isinstance(x, list) else []` check inline. A bare `yaml.safe_load(f) or []`
silently drops every task when the file is mapping-shaped (a truthy dict
never falls back to `[]`), and the resulting `for it in <dict>` iterates
the dict's string KEYS -- `it.get(...)` on a str then raises AttributeError,
which most callers swallow via `2>/dev/null` or a bare `except Exception`,
turning a real task lookup into a false "not found" / false "empty queue"
signal. Proven incident: leadv2-phase8-assert.sh A2 reported "task not
found" for a task that was actually `status: done` in a mapping-shaped
docs/tasks.yaml.

Import contract: callers that are `python3 -` heredoc scripts (no
`__file__`) must pass the scripts directory as an extra argv element and do
`sys.path.insert(0, sys.argv[N])` before `from leadv2_tasks_yaml_common
import load_tasks_items`. Callers that are real .py files under this same
directory can just `sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))`.
"""
from __future__ import annotations

import yaml

# Keys checked in priority order when the top-level document is a mapping.
# "tasks" is persona-engine's Truth-Surface projection key; "items"/"queues"
# are tolerated in case another repo's generator uses those names -- neither
# is currently emitted by any script in this plugin, verified by grep before
# adding them (GATE-A2-FIX-01 scope).
LIST_KEYS = ("tasks", "items", "queues")


def load_tasks_items(path: str) -> list:
    """Return the list of task dicts found in *path*, tolerant of shape.

    - Missing file -> [].
    - Bare top-level list -> returned as-is.
    - Mapping -> the first list found under LIST_KEYS; [] if none match.
    - Anything else (scalar, empty file, None) -> [].
    """
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f)
    except FileNotFoundError:
        return []
    if doc is None:
        return []
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict):
        for key in LIST_KEYS:
            value = doc.get(key)
            if isinstance(value, list):
                return value
        return []
    return []


def detect_wrapper(doc) -> tuple[str | None, dict]:
    """Given an already-loaded top-level doc, return (list_key, extra_keys).

    list_key is the LIST_KEYS entry the list was found under, or None if
    doc was a bare list / not a mapping. extra_keys are the sibling keys of
    the mapping (e.g. {"total_open": N}) that must be preserved on
    write-back so a tolerant reader never collapses a generated projection
    file's shape out from under its owning writer.
    """
    if isinstance(doc, dict):
        for key in LIST_KEYS:
            value = doc.get(key)
            if isinstance(value, list):
                extra = {k: v for k, v in doc.items() if k != key}
                return key, extra
    return None, {}
