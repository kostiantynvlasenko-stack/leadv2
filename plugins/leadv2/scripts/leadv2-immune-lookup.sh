#!/usr/bin/env bash
# leadv2-immune-lookup.sh — query immune-patterns.yaml for an intent string
# Usage: bash leadv2-immune-lookup.sh "<intent text>"
# Output: YAML list of top-3 matching patterns (score >0.0)
set -euo pipefail
trap 'echo "[$(basename "$0")] err line $LINENO" >&2; exit 0' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATTERNS_FILE="$REPO_ROOT/docs/leadv2/immune-patterns.yaml"
INTENT="${1:-}"

if [[ -z "$INTENT" ]]; then
    printf -- 'Usage: %s "<intent text>"\n' "$(basename "$0")" >&2
    exit 1
fi

if [[ ! -f "$PATTERNS_FILE" ]]; then
    printf -- 'matches: []\n'
    exit 0
fi

python3 - "$PATTERNS_FILE" "$INTENT" <<'PYEOF'
from __future__ import annotations
import re, sys
from pathlib import Path
from typing import Any
import yaml

def _tokenize(text: str) -> set[str]:
    """Lower-case word tokens, min length 3."""
    return {w for w in re.findall(r"[a-z0-9_.]+", text.lower()) if len(w) >= 3}

def _jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0

def _bm25_boost(intent_tokens: set[str], kw_tokens: set[str], summary_tokens: set[str]) -> float:
    """Small title-field boost: extra weight for keyword/summary token hits."""
    kw_hits = len(intent_tokens & kw_tokens)
    sum_hits = len(intent_tokens & summary_tokens)
    # each keyword hit worth 0.1 extra; summary hit 0.05
    return min(kw_hits * 0.10 + sum_hits * 0.05, 0.30)

def score_pattern(intent_tokens: set[str], pattern: dict[str, Any]) -> float:
    kw_tokens = _tokenize(" ".join(pattern.get("keywords") or []))
    summary_tokens = _tokenize(pattern.get("summary", ""))
    action_tokens = _tokenize(pattern.get("action", ""))
    body_tokens = summary_tokens | action_tokens
    base = _jaccard(intent_tokens, body_tokens)
    boost = _bm25_boost(intent_tokens, kw_tokens, summary_tokens)
    return round(min(base + boost, 1.0), 3)

def main(patterns_file: str, intent: str) -> None:
    data = yaml.safe_load(Path(patterns_file).read_text()) or {}
    patterns = data.get("patterns") or []
    intent_tokens = _tokenize(intent)
    scored = []
    for p in patterns:
        s = score_pattern(intent_tokens, p)
        if s > 0.0:
            scored.append((s, p))
    scored.sort(key=lambda x: x[0], reverse=True)
    top3 = scored[:3]
    matches = [
        {"id": p["id"], "summary": p["summary"], "action": p["action"], "score": s}
        for s, p in top3
    ]
    print(yaml.dump({"matches": matches}, allow_unicode=True, sort_keys=False, default_flow_style=False), end="")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <patterns_yaml> <intent>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
PYEOF
