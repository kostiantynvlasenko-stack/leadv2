#!/usr/bin/env python3
"""
Aggregates pattern_for_immune blocks from docs/leadv2/tasks/*/STATE.md
and writes docs/leadv2/immune-patterns.yaml.

Idempotent: stable IDs (sha1 of normalised text), seen_count increments.
"""
from __future__ import annotations

import hashlib
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

# ---------------------------------------------------------------------------
# Keyword stems to tag patterns
# ---------------------------------------------------------------------------
KEYWORD_STEMS: dict[str, list[str]] = {
    "UTC": ["utc", "timezone", "tz", "timestamptz"],
    "freshness": ["fresh", "stale", "staleness", "is_fresh"],
    ".env": [r"\.env", "env.file", "env var", "environmentfile"],
    "partial-index": ["partial.index", "partial unique", "where predicate"],
    "upsert": ["upsert", "on conflict", "pgrst102"],
    "FK": [r"\bfk\b", "foreign key"],
    "RLS": [r"\brls\b", "row level security", "policy"],
    "race": [r"\brace\b", "race condition", "concurrent"],
    "retry": ["retry", "backoff", "max_retries", "max.retries"],
    "timeout": ["timeout", "wait_for"],
    "deploy": ["deploy", "deploy-latest", "both vps"],
    "control-sync": ["control.sync", "control_sync"],
    "bash-syntax": ["apostrophe", "single.quot", "bash.n", "syntax error", "set -e", "pipefail"],
    "schema": ["migration", "schema", "create table", "alter table", "column"],
    "locale": ["locale", "timezone", "tz", "day_utc"],
    "world-context": ["world.context", "freshness", "wc_is_fresh"],
    "source-inject": ["source ", r"source.*\.sh"],
    "grep-only": ["grep", "repo grep"],
}


def _tag(text: str) -> list[str]:
    low = text.lower()
    tags: list[str] = []
    for kw, patterns in KEYWORD_STEMS.items():
        for p in patterns:
            if re.search(p, low):
                tags.append(kw)
                break
    return sorted(set(tags))


def _stable_id(text: str) -> str:
    normalised = re.sub(r"\s+", " ", text.strip().lower())
    return hashlib.sha1(normalised.encode()).hexdigest()[:12]


def _summary(text: str) -> str:
    first = re.split(r"[.\n]", text.strip())[0].strip()
    return first[:100] if len(first) > 100 else first


def _action(text: str) -> str:
    parts = [s.strip() for s in re.split(r"\.\s+", text.strip()) if s.strip()]
    raw = parts[1] if len(parts) > 1 else parts[0]
    if not raw.lower().startswith(("if ", "when ", "always ", "never ", "check ")):
        raw = "Check: " + raw
    return raw[:200]


def _extract_patterns(state_path: Path) -> list[dict[str, str]]:
    """
    Returns list of {text, task_id, mtime} for each pattern_for_immune
    in the given STATE.md file.  Handles:
      - Inline:   pattern_for_immune: "some text"
      - Block |:  pattern_for_immune: |
                    line1
                    line2
      - Repeated top-level dashes: - pattern_for_immune: text
    """
    content = state_path.read_text(encoding="utf-8")
    task_id = state_path.parent.name
    mtime = datetime.fromtimestamp(state_path.stat().st_mtime, tz=timezone.utc).date().isoformat()

    results: list[dict[str, str]] = []

    pattern_re = re.compile(
        r"pattern_for_immune\s*:\s*(?P<inline>[^\n|][^\n]*)|"
        r"pattern_for_immune\s*:\s*\|\s*\n(?P<block>(?:[ \t]+[^\n]*\n?)+)",
        re.MULTILINE,
    )

    for m in pattern_re.finditer(content):
        if m.group("inline"):
            text = m.group("inline").strip().strip('"').strip("'")
        else:
            raw_block = m.group("block")
            lines = raw_block.splitlines()
            indent = min(
                (len(l) - len(l.lstrip()) for l in lines if l.strip()),
                default=0,
            )
            text = "\n".join(l[indent:] for l in lines).strip()
        if text:
            results.append({"text": text, "task_id": task_id, "mtime": mtime})

    return results


def _load_existing(output: Path) -> dict[str, Any]:
    if output.exists():
        data = yaml.safe_load(output.read_text()) or {}
        return {p["id"]: p for p in (data.get("patterns") or [])}
    return {}


def main(tasks_dir: str, output_path: str) -> None:
    tasks = Path(tasks_dir)
    output = Path(output_path)

    existing = _load_existing(output)

    tag_task_map: dict[str, set[str]] = {}
    raw_patterns: list[dict[str, str]] = []

    for state_file in sorted(tasks.glob("*/STATE.md")):
        for entry in _extract_patterns(state_file):
            raw_patterns.append(entry)
            for tag in _tag(entry["text"]):
                tag_task_map.setdefault(tag, set()).add(entry["task_id"])

    new_patterns: dict[str, dict[str, Any]] = {}
    for entry in raw_patterns:
        pid = _stable_id(entry["text"])
        tags = _tag(entry["text"])
        seen: set[str] = set()
        for t in tags:
            seen |= tag_task_map.get(t, set())
        seen_count = len(seen)

        if pid in new_patterns:
            new_patterns[pid]["seen_count"] = max(new_patterns[pid]["seen_count"], seen_count)
            continue

        base = existing.get(pid, {})
        new_patterns[pid] = {
            "id": pid,
            "task_origin": entry["task_id"],
            "keywords": tags,
            "summary": _summary(entry["text"]),
            "action": _action(entry["text"]),
            "created": base.get("created", entry["mtime"]),
            "seen_count": seen_count,
        }

    output.parent.mkdir(parents=True, exist_ok=True)
    result = {"patterns": list(new_patterns.values())}
    output.write_text(yaml.dump(result, allow_unicode=True, sort_keys=False, default_flow_style=False))
    print(f"[immune-aggregate] extracted {len(new_patterns)} patterns")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <tasks_dir> <output_yaml>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
