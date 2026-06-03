#!/usr/bin/env python3
"""leadv2-backfill-entry.py — parse one handoff dir and emit a YAML history entry.

Usage: python3 leadv2-backfill-entry.py <handoff_dir> <state_file>

Prints a YAML list-item block (indented for insertion under `history:`) to stdout,
or exits 0 with no output if the directory should be skipped (already in history,
not a task dir, etc.).

Called by leadv2-backfill-history.sh for each handoff directory.
"""

from __future__ import annotations

import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SKIP_PREFIXES = (
    "IMPROVEMENTS-",
    "SESSION-",
    "ARCHIVE",
    "QUESTIONS",
    "NEXTLEVEL-",
    "SMOKE-",
    "MEETING-",
    "ANTI-",
    "MISSIONS",
    "MCP-CACHE",
    "SDK-",
    "PATH-",
    "PO-014-",
    "PO-018-",
    "PO-019-",
    "LEADV2-",
    "DEEPEVAL-",
    "PYDANTIC-",
    "TOOL-",
    "AGENTEVALS-",
    "CODEX-",
    "DEVELOPER",
    "SMOKE-COMPRESS-",
)

KNOWN_AGENTS: frozenset[str] = frozenset(
    {
        "architect",
        "developer",
        "frontend-developer",
        "postgres-pro",
        "devops-engineer",
        "critic",
        "security-auditor",
        "product-owner",
    }
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_existing_task_ids(state_file: Path) -> set[str]:
    if not state_file.is_file():
        return set()
    text = state_file.read_text()
    return {m.group(1).strip() for m in re.finditer(r"^\s*-\s+task:\s+(\S+)", text, re.MULTILINE)}


def _load_context(handoff_dir: Path) -> dict:
    ctx_path = handoff_dir / "context.yaml"
    if not ctx_path.is_file():
        return {}
    try:
        payload = yaml.safe_load(ctx_path.read_text())
        # H2: yaml.safe_load may return a list, scalar, or None — normalize to dict.
        if not isinstance(payload, dict):
            print(
                f"WARN F-LEARN: context.yaml for {handoff_dir.name} is not a mapping "
                f"(got {type(payload).__name__}) — using empty dict",
                file=sys.stderr,
            )
            payload = {}
        return payload
    except Exception as exc:
        print(
            f"WARN F-LEARN: context.yaml parse failed for {handoff_dir} — {exc}",
            file=sys.stderr,
        )
        return {}


def _task_class(ctx: dict, path: Path | None = None) -> str:
    try:
        raw = (
            ctx.get("class")
            or ctx.get("classification")
            or (ctx.get("task") or {}).get("class")
            or "Standard"
        )
        if isinstance(raw, dict):
            raw = raw.get("class", "Standard")
        val = str(raw).strip()
        return val if val in ("Light", "Standard", "Heavy", "Strategic") else "Standard"
    except Exception as exc:
        print(
            f"WARN F-LEARN: task_class extraction failed for {path} — {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return "Standard"


def _involved_agents(ctx: dict, combined_text: str, path: Path | None = None) -> list[str]:
    try:
        spawned_raw = ctx.get("spawned") or ctx.get("forced_spawns") or {}
        agents: list[str] = []

        if isinstance(spawned_raw, dict):
            for k in spawned_raw:
                if k in KNOWN_AGENTS:
                    agents.append(k)
        elif isinstance(spawned_raw, list):
            for item in spawned_raw:
                s = str(item).lower()
                for a in KNOWN_AGENTS:
                    if a in s and a not in agents:
                        agents.append(a)

        # Supplement from summary text
        for a in sorted(KNOWN_AGENTS):
            if a not in agents and re.search(rf"\b{re.escape(a)}\b", combined_text, re.I):
                agents.append(a)

        if "developer" not in agents:
            agents.append("developer")
        return agents
    except Exception as exc:
        print(
            f"WARN F-LEARN: involved_agents extraction failed for {path} — {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return ["developer"]


def _codex_rounds(combined_text: str) -> int:
    count = len(re.findall(r"(?i)codex\s+round\s+\d+|round\s+\d+.*codex", combined_text))
    if count == 0:
        m = re.search(r"(?i)codex_rounds[:\s]+(\d+)", combined_text)
        if m:
            count = int(m.group(1))
    return count


def _parallel_win(combined_text: str) -> str:
    if re.search(
        r"(?i)(parallel|spawned in one message|one message.*parallel|two.*parallel)",
        combined_text,
    ):
        return "parallel spawn detected in summary"
    return "no parallel opportunity recorded"


def _change_kind(combined_text: str, has_summaries: bool) -> str:
    checks = [
        (r"(?i)migration", "new-migration"),
        (r"(?i)new route|new endpoint|fastapi|router\.", "new-route"),
        (r"(?i)refactor", "refactor-internal"),
        (r"(?i)bug.?fix|fix.*bug|regression", "bugfix-pure"),
        (r"(?i)cross.?service|cross service", "cross-service"),
        (r"(?i)\bui\b|frontend|next\.?js", "ui-only"),
        (r"(?i)test|pytest|spec", "bugfix-pure"),
        (r"(?i)docs.?only|documentation", "docs-only"),
    ]
    for pattern, kind in checks:
        if re.search(pattern, combined_text):
            return kind
    return "bugfix-pure" if has_summaries else "config-only"


def _pattern_for_immune(combined_text: str) -> str:
    pm = re.search(r"(?i)pattern[_\s]for[_\s]immune[:\s]+(.+?)(?:\n|$)", combined_text)
    if pm:
        return pm.group(1).strip()
    wm = re.search(r"(?i)(when\s+.{10,80}\s+[→\-]+\s+.{5,60})", combined_text)
    if wm:
        return wm.group(1).strip()
    return "(skipped — pattern not extractable from backfilled summary)"


def _closed_at(handoff_dir: Path, ctx_path: Path) -> str:
    source = ctx_path if ctx_path.is_file() else next(
        (p for p in handoff_dir.iterdir()), None
    )
    try:
        mtime = os.path.getmtime(str(source)) if source else None
        if mtime:
            dt = datetime.fromtimestamp(mtime, tz=timezone.utc)
            return dt.strftime("%Y-%m-%dT%H:%M+02:00")
    except Exception:
        pass
    return "2026-01-01T00:00+02:00"


def _load_summaries(handoff_dir: Path) -> list[str]:
    texts: list[str] = []
    summary_names = {"developer.md", "architect.md", "critic.md", "verification.md"}
    for p in handoff_dir.iterdir():
        if not p.is_file():
            continue
        if p.name.endswith(".summary.md") or p.name in summary_names:
            try:
                texts.append(p.read_text())
            except Exception:
                pass
    return texts


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def _task_present_in_state(task_id: str, state_file: Path) -> bool:
    """Return True if task_id already exists in state_file (case-insensitive exact match).

    Uses the same normalized set built by _load_existing_task_ids so the
    in-lock re-check (H1) is identical to the pre-check idempotency logic.
    """
    existing = _load_existing_task_ids(state_file)
    task_upper = task_id.upper()
    return task_upper in {t.upper() for t in existing}


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(0)

    # H1/H3: --check-only mode for in-lock idempotency from bash.
    # Usage: python3 leadv2-backfill-entry.py --check-only <task_id> <state_file>
    # Exit 0 = task PRESENT (skip append)
    # Exit 1 = task ABSENT  (safe to append)
    # Exit 2 = MATCHER ERROR (file read failure, encoding error, etc.) — caller must NOT append
    if sys.argv[1] == "--check-only":
        if len(sys.argv) < 4:
            sys.exit(1)
        task_id = sys.argv[2].upper()
        state_file = Path(sys.argv[3])
        try:
            result = _task_present_in_state(task_id, state_file)
        except Exception as exc:
            print(
                f"WARN F-LEARN: --check-only matcher error for {task_id} — {type(exc).__name__}: {exc}",
                file=sys.stderr,
            )
            sys.exit(2)
        sys.exit(0 if result else 1)

    handoff_dir = Path(sys.argv[1])
    state_file = Path(sys.argv[2])

    if not handoff_dir.is_dir():
        sys.exit(0)

    # Normalize task ID
    task_id = handoff_dir.name.upper()

    # Skip dirs that are not task handoffs
    for prefix in SKIP_PREFIXES:
        if task_id.startswith(prefix):
            sys.exit(0)

    # Only process PO-NNN, RECOVERY-*, NEXTLEVEL-* dirs
    if not (
        re.match(r"^PO-\d+", task_id)
        or re.match(r"^RECOVERY-", task_id)
        or re.match(r"^NEXTLEVEL-", task_id)
    ):
        sys.exit(0)

    # Idempotency: skip if already in history
    existing = _load_existing_task_ids(state_file)
    if task_id in existing or task_id.lower() in {t.lower() for t in existing}:
        sys.exit(0)

    # Load data
    ctx = _load_context(handoff_dir)
    summary_texts = _load_summaries(handoff_dir)
    combined_text = "\n".join(summary_texts)
    ctx_path = handoff_dir / "context.yaml"

    agents = _involved_agents(ctx, combined_text, path=ctx_path)

    opus_needed = (
        "opus spawn likely (architect/critic in involved_agents)"
        if any(a in agents for a in ("architect", "critic"))
        else "no opus spawn (backfilled — not extractable)"
    )

    entry = {
        "task": task_id,
        "closed_at": _closed_at(handoff_dir, ctx_path),
        "backfilled": True,
        "reflect": {
            "almost_missed": "(backfilled — no original reflection)",
            "opus_needed_for": opus_needed,
            "parallel_win": _parallel_win(combined_text),
            "codex_rounds": _codex_rounds(combined_text),
            "pattern_for_immune": _pattern_for_immune(combined_text),
            "fix_quality": "reasonable",
            "signature": {
                "phase": "close",
                "task_class": _task_class(ctx, path=ctx_path),
                "failure_class": "none",
                "recovery_decision": "none",
                "outcome": "success",
                "involved_agents": agents,
                "change_kind": _change_kind(combined_text, bool(summary_texts)),
            },
        },
    }

    # Emit as indented YAML list item
    raw = yaml.dump(entry, default_flow_style=False, allow_unicode=True, sort_keys=False)
    lines = raw.splitlines()
    out_lines = ["  - " + lines[0]]
    for line in lines[1:]:
        out_lines.append("    " + line)
    print("\n".join(out_lines))


if __name__ == "__main__":
    main()
