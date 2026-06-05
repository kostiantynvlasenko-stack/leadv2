#!/usr/bin/env python3
"""
leadv2-correction-detect.py — classify user messages as correction/reinforcement/preference/context.

stdin:  JSON {"messages": [{"role": str, "content": str}, ...], "task_id": str, "session_id": str}
stdout: JSON array [{category, confidence, fact, source_error?}, ...] (one item per user message)
        OR [] on error (error logged to stderr)

Environment:
  LEADV2_CORRECTION_DETECT   shadow | 1 | 0  (default: 0 = disabled)
  LEADV2_DETECT_MODEL        Claude model to use (default: claude-haiku-4-5)
  LEADV2_CORRECTION_WINDOW   int, max user messages to classify (default: 6)
  ANTHROPIC_API_KEY          API key (required unless using OAuth fallback)
  CLAUDE_CODE_OAUTH_TOKEN    OAuth token fallback (if no API key)
  CLAUDE_PROJECT_MEMORY_DIR  Override for ~/.claude/projects/.../memory path
  LEADV2_IMMUNE_STORE        Override path for immune-patterns.yaml
                             (default: docs/leadv2/immune-patterns.yaml in project root)
  LEADV2_CANDIDATES_FILE     Override path for correction-detect-candidates.jsonl
                             (default: docs/leadv2/correction-detect-candidates.jsonl)

NOTE: Auto-promote writes to the plugin immune store (docs/leadv2/immune-patterns.yaml),
      NOT to global MEMORY.md. Global MEMORY.md is never touched by this script.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml  # type: ignore[import]
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

DETECT_MODE: str = os.environ.get("LEADV2_CORRECTION_DETECT", "0")
MODEL: str = os.environ.get("LEADV2_DETECT_MODEL", "claude-haiku-4-5")
WINDOW: int = int(os.environ.get("LEADV2_CORRECTION_WINDOW", "6"))

WRITE_THRESHOLD: float = 0.8
AUTO_PROMOTE_THRESHOLD: float = 0.95

_SYSTEM_PROMPT = """\
You are a message classifier for an AI orchestration system. Classify each user message into one of four categories based on what the user is communicating to the AI assistant.

Categories:
- correction: User is correcting a mistake the AI made (factual error, wrong behavior, wrong output). Signals: "не так", "не делай X", "это неправильно", "stop doing X", "wrong", "incorrect", "you should not", "не нужно", "перестань".
- reinforcement: User is confirming the AI is on the right track. Signals: "да, именно", "продолжай", "отлично", "exactly", "yes", "good", "keep going", "правильно", "верно".
- preference: User is expressing a style/format/workflow preference, not correcting an error. Signals: "мне нравится когда", "prefer", "лучше если", "I like", "always do X instead of Y".
- context: User is providing context, background, or information — not feedback on AI behavior.

Rules:
1. Handle bilingual Russian/English mixed messages naturally.
2. If a message could be correction OR reinforcement depending on interpretation, assign the one with higher evidence, but set confidence lower (≤ 0.7).
3. Low confidence on ambiguous messages — do not force a category.
4. Short acknowledgments ("ok", "хорошо", "понял") are context, confidence ≤ 0.5.
5. "не так" alone = correction with confidence 0.85; "не так, как ты думаешь" = context, confidence 0.5.

Output: a JSON array, one object per message, in input order.
Schema per object:
{
  "category": "correction|reinforcement|preference|context",
  "confidence": 0.00,
  "source_error": null,
  "fact": "text (≤40 words, actionable rule being communicated)"
}

Return ONLY the JSON array, no other text."""


def _log(msg: str) -> None:
    print(f"[leadv2-correction-detect] {msg}", file=sys.stderr)


def _get_memory_dir() -> Path:
    """Return the project memory directory, dynamic or overridden."""
    if override := os.environ.get("CLAUDE_PROJECT_MEMORY_DIR"):
        return Path(override)
    cwd = os.getcwd()
    slug = cwd.replace("/", "-").lstrip("-")
    return Path.home() / ".claude" / "projects" / slug / "memory"


def _get_project_root() -> Path:
    """Return the git project root or cwd."""
    import subprocess
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return Path(result.stdout.strip())
    except Exception:
        pass
    return Path(os.getcwd())


def _get_immune_store() -> Path:
    """Return the path to the immune-patterns.yaml store."""
    if override := os.environ.get("LEADV2_IMMUNE_STORE"):
        return Path(override)
    return _get_project_root() / "docs" / "leadv2" / "immune-patterns.yaml"


def _get_candidates_file() -> Path:
    """Return the path to the correction-detect-candidates.jsonl file."""
    if override := os.environ.get("LEADV2_CANDIDATES_FILE"):
        return Path(override)
    return _get_project_root() / "docs" / "leadv2" / "correction-detect-candidates.jsonl"


# ---------------------------------------------------------------------------
# Immune store helpers (mirrors leadv2-immune-aggregate.py schema)
# ---------------------------------------------------------------------------

KEYWORD_STEMS: dict[str, list[str]] = {
    "correction": ["correction", "auto-promoted", "founder corrected"],
    "UTC": ["utc", "timezone", "tz", "timestamptz"],
    "freshness": ["fresh", "stale", "staleness", "is_fresh"],
    ".env": [r"\.env", "env.file", "env var", "environmentfile"],
    "partial-index": ["partial.index", "partial unique", "where predicate"],
    "upsert": ["upsert", "on conflict", "pgrst102"],
    "RLS": [r"\brls\b", "row level security", "policy"],
    "race": [r"\brace\b", "race condition", "concurrent"],
    "retry": ["retry", "backoff", "max_retries"],
    "timeout": ["timeout", "wait_for"],
    "deploy": ["deploy", "deploy-latest", "both vps"],
    "bash-syntax": ["apostrophe", "single.quot", "bash.n", "syntax error", "set -e", "pipefail"],
    "schema": ["migration", "schema", "create table", "alter table", "column"],
    "grep-only": ["grep", "repo grep"],
}


def _tag_keywords(text: str) -> list[str]:
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


def _auto_promote_to_immune(
    candidate: dict,
    task_id: str,
) -> bool:
    """
    Append a high-confidence correction to docs/leadv2/immune-patterns.yaml.
    Uses the same schema as leadv2-immune-aggregate.py.
    Never touches global MEMORY.md.
    """
    if not _YAML_AVAILABLE:
        _log("yaml not installed; cannot write to immune store — skipping auto-promote")
        return False

    fact = candidate.get("fact", "")
    if not fact:
        return False

    immune_store = _get_immune_store()
    pid = _stable_id(fact)
    ts = datetime.now(tz=timezone.utc).date().isoformat()
    confidence = candidate.get("confidence", 0.0)
    keywords = _tag_keywords(fact)

    # Load existing patterns
    if immune_store.exists():
        try:
            data: dict = yaml.safe_load(immune_store.read_text(encoding="utf-8")) or {}
        except Exception as exc:
            _log(f"Failed to read immune store: {exc}")
            data = {}
    else:
        data = {}

    patterns: list[dict] = data.get("patterns") or []
    existing_ids = {p["id"] for p in patterns}

    if pid in existing_ids:
        # Idempotent: already present — increment seen_count only
        for p in patterns:
            if p["id"] == pid:
                p["seen_count"] = p.get("seen_count", 1) + 1
                _log(f"Immune store: idempotent update seen_count for {pid!r}: {fact[:40]!r}")
        immune_store.parent.mkdir(parents=True, exist_ok=True)
        immune_store.write_text(
            yaml.dump({"patterns": patterns}, allow_unicode=True, sort_keys=False, default_flow_style=False),
            encoding="utf-8",
        )
        return False  # Not a new entry

    # Build new entry matching immune-aggregate schema
    # Split fact into summary (first sentence) and action (second sentence or default)
    parts = [s.strip() for s in re.split(r"[.\n]", fact.strip()) if s.strip()]
    summary = parts[0][:100] if parts else fact[:100]
    if len(parts) > 1:
        action = parts[1][:200]
        if not action.lower().startswith(("if ", "when ", "always ", "never ", "check ")):
            action = "Check: " + action
    else:
        action = "Check: " + summary[:200]

    new_entry: dict = {
        "id": pid,
        "task_origin": task_id,
        "keywords": keywords,
        "summary": summary,
        "action": action,
        "created": ts,
        "seen_count": 1,
        "source": "correction",
        "confidence": round(confidence, 2),
    }

    patterns.append(new_entry)
    immune_store.parent.mkdir(parents=True, exist_ok=True)
    immune_store.write_text(
        yaml.dump({"patterns": patterns}, allow_unicode=True, sort_keys=False, default_flow_style=False),
        encoding="utf-8",
    )
    _log(f"Auto-promoted to immune store ({immune_store}): {fact[:60]!r} [confidence={confidence:.2f}]")
    return True


def _build_user_prompt(messages: list[str]) -> str:
    n = len(messages)
    parts = [f"Classify these {n} user messages (oldest first):\n"]
    for msg in messages:
        parts.append(msg)
        parts.append("---")
    return "\n".join(parts).rstrip("\n-").strip()


def _call_haiku(user_messages: list[str]) -> list[dict]:
    """Call the Anthropic API and return parsed classification list."""
    try:
        import anthropic  # type: ignore[import]
    except ImportError:
        _log("anthropic SDK not installed; returning []")
        return []

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        # Try OAuth token as a last resort (may not work for direct SDK calls)
        oauth = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
        if oauth:
            _log("ANTHROPIC_API_KEY not set; CLAUDE_CODE_OAUTH_TOKEN present but may not work for direct SDK calls")
        _log("No ANTHROPIC_API_KEY; returning []")
        return []

    client = anthropic.Anthropic(api_key=api_key)
    user_prompt = _build_user_prompt(user_messages)

    try:
        response = client.messages.create(
            model=MODEL,
            max_tokens=1024,
            system=_SYSTEM_PROMPT,
            messages=[{"role": "user", "content": user_prompt}],
        )
    except Exception as exc:
        _log(f"API call failed: {exc}; returning []")
        return []

    raw_text = response.content[0].text.strip()

    # Strip markdown fences if present
    if raw_text.startswith("```"):
        lines = raw_text.splitlines()
        raw_text = "\n".join(lines[1:-1]) if len(lines) > 2 else raw_text

    try:
        result = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        _log(f"Failed to parse API response as JSON: {exc}; raw: {raw_text[:200]}")
        return []

    if not isinstance(result, list):
        _log(f"API returned non-list JSON: {type(result)}; returning []")
        return []

    return result


def _write_candidates(
    candidates: list[dict],
    task_id: str,
    session_id: str,
    mode: str,
    message_texts: list[str],
    candidates_file: Path,
) -> int:
    """Append candidates to JSONL file. Returns count written."""
    candidates_file.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(tz=timezone.utc).isoformat()
    written = 0

    # Rotate if file exceeds 500 lines
    if candidates_file.exists():
        existing_lines = candidates_file.read_text().splitlines()
        if len(existing_lines) > 500:
            trimmed = "\n".join(existing_lines[-500:]) + "\n"
            candidates_file.write_text(trimmed)

    with candidates_file.open("a") as f:
        for i, candidate in enumerate(candidates):
            record = {
                "task_id": task_id,
                "session_id": session_id,
                "ts": ts,
                "mode": mode,
                "category": candidate.get("category", "context"),
                "confidence": candidate.get("confidence", 0.0),
                "source_error": candidate.get("source_error"),
                "fact": candidate.get("fact", ""),
                "message_text": message_texts[i] if i < len(message_texts) else "",
            }
            f.write(json.dumps(record) + "\n")
            written += 1

    return written


def _auto_promote(
    candidate: dict,
    task_id: str,
    memory_dir: Path,
) -> bool:
    """Write high-confidence correction to MEMORY.md and individual feedback file."""
    fact = candidate.get("fact", "")
    if not fact:
        return False

    memory_file = memory_dir / "MEMORY.md"
    if not memory_file.exists():
        _log(f"MEMORY.md not found at {memory_file}; skipping auto-promote")
        return False

    # Idempotency: check if first 30 chars of fact already present
    fact_snippet = fact[:30]
    existing = memory_file.read_text()
    if fact_snippet in existing:
        _log(f"Fact already in MEMORY.md (idempotent skip): {fact_snippet!r}")
        return False

    ts = datetime.now(tz=timezone.utc).isoformat()

    # Derive a snake_case filename from the fact
    snake_name = "".join(c if c.isalnum() or c == "_" else "_" for c in fact[:40].lower())
    snake_name = "_".join(p for p in snake_name.split("_") if p)
    if not snake_name:
        snake_name = "auto_promoted"
    feedback_filename = f"feedback_{snake_name}.md"
    feedback_file = memory_dir / feedback_filename

    # Write individual feedback file
    feedback_content = (
        f"# {fact[:60]}\n\n"
        f"{fact}\n\n"
        f"Source: auto-promoted by leadv2-correction-detect from task {task_id} "
        f"at {ts}. Confidence: {candidate.get('confidence', 0.0):.2f}.\n"
    )
    feedback_file.write_text(feedback_content)

    # Append to MEMORY.md under Feedback — Tech section
    entry = (
        f"- [{fact[:60]}]({feedback_filename}) — "
        f"{fact} ({task_id} auto-promoted by correction-detect)\n"
    )

    # Insert after "## Feedback — Tech" or at end
    if "## Feedback — Tech" in existing:
        idx = existing.index("## Feedback — Tech")
        # Find end of that line
        eol = existing.index("\n", idx) + 1
        new_content = existing[:eol] + "\n" + entry + existing[eol:]
    else:
        new_content = existing + "\n" + entry

    memory_file.write_text(new_content)
    _log(f"Auto-promoted to MEMORY.md: {fact[:60]!r}")
    return True


def main() -> None:
    if DETECT_MODE in ("0", ""):
        print("[]")
        return

    shadow = DETECT_MODE == "shadow"

    try:
        raw = sys.stdin.read().strip()
        payload: dict = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as exc:
        _log(f"Failed to parse stdin: {exc}")
        print("[]")
        return

    task_id: str = payload.get("task_id", "unknown")
    session_id: str = payload.get("session_id", str(os.getpid()))
    raw_messages: list[dict] = payload.get("messages", [])

    # Extract user messages only, oldest-first, limited to window
    user_messages: list[str] = [
        m["content"]
        for m in raw_messages
        if m.get("role") == "user" and isinstance(m.get("content"), str)
    ]
    user_messages = user_messages[-WINDOW:]  # Keep last N (most recent)

    if not user_messages:
        print("[]")
        return

    # Call haiku classifier
    classifications = _call_haiku(user_messages)

    if not classifications:
        # API unavailable or failed — return empty
        if shadow:
            _log("Shadow mode: API unavailable, no candidates written")
        print("[]")
        return

    # Filter by threshold
    candidates = [c for c in classifications if c.get("confidence", 0.0) >= WRITE_THRESHOLD]
    # Pair candidates back with original messages (classifications are in input order)
    candidate_texts: list[str] = []
    for i, c in enumerate(classifications):
        if c.get("confidence", 0.0) >= WRITE_THRESHOLD:
            candidate_texts.append(user_messages[i] if i < len(user_messages) else "")

    candidates_file = _get_candidates_file()

    written = 0
    auto_promoted = 0

    if candidates:
        if shadow:
            # Shadow: write to candidates.jsonl only, stderr output
            written = _write_candidates(
                candidates, task_id, session_id, "shadow", candidate_texts, candidates_file
            )
            _log(f"Shadow mode: wrote {written} candidate(s) to {candidates_file}")
        else:
            # Live: write to candidates.jsonl
            written = _write_candidates(
                candidates, task_id, session_id, "1", candidate_texts, candidates_file
            )
            # Auto-promote high-confidence corrections to immune store (not MEMORY.md)
            for candidate in candidates:
                if (
                    candidate.get("category") == "correction"
                    and candidate.get("confidence", 0.0) >= AUTO_PROMOTE_THRESHOLD
                ):
                    if _auto_promote_to_immune(candidate, task_id):
                        auto_promoted += 1

    _log(
        f"mode={DETECT_MODE} messages={len(user_messages)} "
        f"candidates={len(candidates)} written={written} auto_promoted={auto_promoted}"
    )

    # Always print full classification results to stdout
    print(json.dumps(classifications))


if __name__ == "__main__":
    main()
