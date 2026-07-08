#!/usr/bin/env bash
# leadv2-immune-lookup.sh — query immune-patterns.yaml for an intent string
# Usage: bash leadv2-immune-lookup.sh "<intent text>"
# Output: YAML list of top matching patterns (score >0.0), keyword-top-3
# always preserved, plus at most one additive semantic-only bonus slot.
#
# MEM-SEMANTIC-RECALL-01 §2/§3: additive semantic+keyword fusion (RRF, k=60).
# Flag LEADV2_SEMANTIC_RECALL_ENABLED=1 (default 0) + LEADV2_RECALL_HELPER set
# turns on a semantic recall pass (leadv2-semantic-recall.sh) whose ranked
# hits are fused with the keyword ranking below before the top-3 cut. Flag
# off, or helper missing/Qdrant down (fail-open empty semantic list) => this
# script is byte-identical to pre-fusion behavior.
#
# Fix round (C1): REPO_ROOT is no longer derived from this script's own
# location (fragile — depends on exactly which symlink/rsync depth it's
# reached through). Resolved from the durable git-common-dir of whatever
# repo the caller's cwd is in (never --show-toplevel — see project CLAUDE.md
# T1 incident: that returns the ephemeral worktree, not the durable root).
set -euo pipefail
trap 'echo "[$(basename "$0")] err line $LINENO" >&2; exit 0' ERR

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${LEADV2_PROJECT_ROOT:-$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || pwd)}"
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

# ── semantic recall pass (additive; fail-open) ──────────────────────────
# Test seam: _LEADV2_SEMANTIC_TSV_OVERRIDE lets tests inject a canned ranked
# list without a live Qdrant. Unset in production — the real recall script
# runs (and itself fail-opens to empty on flag-off/helper-missing/Qdrant-down).
SEMANTIC_TSV=""
if [[ -n "${_LEADV2_SEMANTIC_TSV_OVERRIDE+x}" ]]; then
    SEMANTIC_TSV="$_LEADV2_SEMANTIC_TSV_OVERRIDE"
elif [[ "${LEADV2_SEMANTIC_RECALL_ENABLED:-0}" == "1" ]]; then
    SEMANTIC_TSV="$(bash "${_SCRIPT_DIR}/leadv2-semantic-recall.sh" immune "$INTENT" 10 "$(basename "$REPO_ROOT")" 2>/dev/null || true)"
fi

python3 - "$PATTERNS_FILE" "$INTENT" "$SEMANTIC_TSV" <<'PYEOF'
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

def _rrf_fuse(kw_ranked_ids: list[str], sem_ranked_ids: list[str], k: int = 60) -> dict[str, float]:
    """Reciprocal Rank Fusion: fused(e) = 1/(k+r_kw) + 1/(k+r_sem).
    Missing rank on either side contributes 0."""
    kw_rank = {pid: i + 1 for i, pid in enumerate(kw_ranked_ids)}
    sem_rank = {pid: i + 1 for i, pid in enumerate(sem_ranked_ids)}
    fused: dict[str, float] = {}
    for pid in set(kw_rank) | set(sem_rank):
        term_kw = 1.0 / (k + kw_rank[pid]) if pid in kw_rank else 0.0
        term_sem = 1.0 / (k + sem_rank[pid]) if pid in sem_rank else 0.0
        fused[pid] = term_kw + term_sem
    return fused

def main(patterns_file: str, intent: str, semantic_tsv: str = "") -> None:
    data = yaml.safe_load(Path(patterns_file).read_text()) or {}
    patterns = data.get("patterns") or []
    patterns_by_id = {p["id"]: p for p in patterns}
    intent_tokens = _tokenize(intent)
    scored = []
    for p in patterns:
        s = score_pattern(intent_tokens, p)
        if s > 0.0:
            scored.append((s, p))
    scored.sort(key=lambda x: x[0], reverse=True)
    kw_ranked_ids = [p["id"] for _, p in scored]
    kw_score_by_id = {p["id"]: s for s, p in scored}

    # Parse the semantic ranked list ("id\tcosine" lines, already sorted desc
    # by leadv2-semantic-recall.sh; empty on flag-off/helper-missing/Qdrant-down).
    sem_ranked_ids: list[str] = []
    sem_cosine_by_id: dict[str, float] = {}
    for line in semantic_tsv.splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[0] in patterns_by_id:
            sem_ranked_ids.append(parts[0])
            try:
                sem_cosine_by_id[parts[0]] = float(parts[1])
            except ValueError:
                continue

    if sem_ranked_ids:
        # Fix round (H1): RRF is rank-only, so a real keyword hit can tie
        # with — and lose the cosine tie-break to — unrelated semantic noise,
        # silently evicting it from the returned set. Guarantee the ORIGINAL
        # keyword top-3 is always present; semantic entries can only ADD
        # beyond that (design's "never suppress a keyword hit" invariant).
        # When the keyword top-3 is already full, grant exactly one bonus
        # slot so a genuinely qualifying semantic-only hit still surfaces
        # instead of being crowded out entirely.
        kw_top3_ids = kw_ranked_ids[:3]
        fused = _rrf_fuse(kw_ranked_ids, sem_ranked_ids)
        budget = 3 if len(kw_top3_ids) < 3 else 4
        ranked_by_fused = sorted(
            fused,
            key=lambda pid: (fused[pid], sem_cosine_by_id.get(pid, 0.0)),
            reverse=True,
        )
        remaining_ids = [pid for pid in ranked_by_fused if pid not in kw_top3_ids]
        extra_slots = max(budget - len(kw_top3_ids), 0)
        final_ids = list(kw_top3_ids) + remaining_ids[:extra_slots]
        matches = [
            {
                "id": pid,
                "summary": patterns_by_id[pid]["summary"],
                "action": patterns_by_id[pid]["action"],
                "score": kw_score_by_id.get(pid, 0.0),
                "sem_cosine": sem_cosine_by_id.get(pid, 0.0),
            }
            for pid in final_ids
        ]
    else:
        # Byte-identical to pre-fusion behavior when semantic list is empty
        # (flag off, helper missing, or Qdrant down) — no new fields either.
        top3 = scored[:3]
        matches = [
            {"id": p["id"], "summary": p["summary"], "action": p["action"], "score": s}
            for s, p in top3
        ]
    print(yaml.dump({"matches": matches}, allow_unicode=True, sort_keys=False, default_flow_style=False), end="")

if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        print(f"Usage: {sys.argv[0]} <patterns_yaml> <intent> [semantic_tsv]", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else "")
PYEOF
