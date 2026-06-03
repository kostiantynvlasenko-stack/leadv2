#!/usr/bin/env bash
# leadv2-rag-intake.sh — Embed task description, cosine-rank past LEAD_V2_STATE
# history entries, emit top-K similar tasks as YAML.
#
# Usage:
#   leadv2-rag-intake.sh --task-description "<text>" [--top-k 3] \
#                        [--history-path docs/LEAD_V2_STATE.md]
#
# Output: YAML list of top-K matching past tasks on stdout.
# Exit 0 always (embedding failures fall through to keyword similarity).

set -euo pipefail

SHELL=/bin/bash

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

# ── Defaults ────────────────────────────────────────────────────────────────
TASK_DESC=""
TOP_K=3
HISTORY_PATH="${PROJECT_ROOT}/docs/LEAD_V2_STATE.md"

# ── Arg parse ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-description) TASK_DESC="$2"; shift 2 ;;
    --top-k)            TOP_K="$2";     shift 2 ;;
    --history-path)     HISTORY_PATH="$2"; shift 2 ;;
    -h|--help)
      printf -- 'Usage: leadv2-rag-intake.sh --task-description "<text>" [--top-k 3] [--history-path <path>]\n' >&2
      exit 0
      ;;
    *) printf -- '[leadv2-rag-intake] unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TASK_DESC" ]]; then
  printf -- '[leadv2-rag-intake] --task-description is required\n' >&2
  exit 1
fi

if [[ ! -f "$HISTORY_PATH" ]]; then
  printf -- '[leadv2-rag-intake] history file not found: %s\n' "$HISTORY_PATH" >&2
  printf -- '[]\n'
  exit 0
fi

# ── Delegate to Python ────────────────────────────────────────────────────────
python3 - "$TASK_DESC" "$TOP_K" "$HISTORY_PATH" "$PROJECT_ROOT" <<'PYEOF'
#!/usr/bin/env python3
"""Embed + cosine-rank past leadv2 history entries against a new task description."""
from __future__ import annotations

import sys
import os
import math
import re
import warnings
from typing import Any

import yaml  # PyYAML ships with supabase-py env

warnings.filterwarnings("ignore")

TASK_DESC: str     = sys.argv[1]
TOP_K: int         = int(sys.argv[2])
HISTORY_PATH: str  = sys.argv[3]
PROJECT_ROOT: str  = sys.argv[4]

CACHE_DIR  = os.environ.get("PE_EMBED_CACHE", os.path.expanduser("~/.cache/fastembed"))
MODEL_NAME = os.environ.get("PE_EMBED_MODEL", "BAAI/bge-large-en-v1.5")

# ─────────────────────────────────────────────────────────────────────────────
# 1. Parse history from LEAD_V2_STATE.md
# ─────────────────────────────────────────────────────────────────────────────

def load_history(path: str) -> list[dict[str, Any]]:
    with open(path) as fh:
        raw = fh.read()

    # Extract the history: block as a nested YAML substring
    m = re.search(r'^history:\s*\n((?:[ \t].*\n|\n)*)', raw, re.MULTILINE)
    if not m:
        return []

    block = "history:\n" + m.group(1)
    try:
        data = yaml.safe_load(block)
        entries: list[dict[str, Any]] = data.get("history") or []
        return entries
    except yaml.YAMLError:
        return []


# ─────────────────────────────────────────────────────────────────────────────
# 2. Build document string for each history entry
# ─────────────────────────────────────────────────────────────────────────────

def entry_to_doc(entry: dict[str, Any]) -> str:
    task_id  = str(entry.get("task", ""))
    reflect  = entry.get("reflect", {}) or {}
    sig      = reflect.get("signature", {}) or {}
    gf       = reflect.get("graph_footprint", {}) or {}

    title       = reflect.get("title", task_id)
    description = reflect.get("description", reflect.get("almost_missed", ""))
    cls         = sig.get("task_class", "")
    outcome_raw = sig.get("outcome", "")
    outcome     = f"completed_{outcome_raw}" if outcome_raw and "completed" not in outcome_raw else outcome_raw
    change_kind = gf.get("change_kind", "")
    duration    = reflect.get("duration_min", "")

    parts = [p for p in [title, description] if p]
    if cls:
        parts.append(f"class={cls}")
    if outcome:
        parts.append(f"outcome={outcome}")
    if change_kind:
        parts.append(f"change_kind={change_kind}")
    return ". ".join(parts)


# ─────────────────────────────────────────────────────────────────────────────
# 3. Embedding helpers
# ─────────────────────────────────────────────────────────────────────────────

def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na  = math.sqrt(sum(x * x for x in a))
    nb  = math.sqrt(sum(x * x for x in b))
    if na == 0.0 or nb == 0.0:
        return 0.0
    return dot / (na * nb)


def embed_batch_fastembed(texts: list[str]) -> list[list[float]]:
    from fastembed import TextEmbedding  # type: ignore[import]
    model = TextEmbedding(model_name=MODEL_NAME, cache_dir=CACHE_DIR)
    return [e.tolist() for e in model.embed(texts)]


# Fallback: word-overlap TF-IDF-like score (no extra deps beyond stdlib)
def _token_set(text: str) -> dict[str, int]:
    tokens = re.findall(r"[a-z0-9_]+", text.lower())
    freq: dict[str, int] = {}
    for t in tokens:
        freq[t] = freq.get(t, 0) + 1
    return freq


def keyword_similarity(query: str, doc: str) -> float:
    q_tokens = _token_set(query)
    d_tokens = _token_set(doc)
    if not q_tokens or not d_tokens:
        return 0.0
    # Jaccard on token sets
    q_set = set(q_tokens)
    d_set = set(d_tokens)
    intersection = len(q_set & d_set)
    union = len(q_set | d_set)
    return intersection / union if union else 0.0


def embed_batch_fallback(texts: list[str]) -> list[list[float]]:
    """Thin shim: produce a 'vector' that is just token frequencies (sparse).
    Cosine on these vectors = weighted word overlap. Not great but safe."""
    vocab: list[str] = []
    freqs: list[dict[str, int]] = [_token_set(t) for t in texts]
    for f in freqs:
        for tok in f:
            if tok not in vocab:
                vocab.append(tok)
    dim = len(vocab)
    out: list[list[float]] = []
    for f in freqs:
        vec = [float(f.get(v, 0)) for v in vocab]
        out.append(vec)
    return out


def embed_batch(texts: list[str]) -> tuple[list[list[float]], str]:
    """Returns (vectors, method_used)."""
    try:
        vecs = embed_batch_fastembed(texts)
        return vecs, "fastembed"
    except ImportError:
        print("[leadv2-rag-intake] WARN: fastembed not available, falling back to keyword similarity", file=sys.stderr)
    except Exception as exc:
        print(f"[leadv2-rag-intake] WARN: fastembed error ({exc}), falling back to keyword similarity", file=sys.stderr)

    # Try sklearn TF-IDF
    try:
        from sklearn.feature_extraction.text import TfidfVectorizer  # type: ignore[import]
        vectorizer = TfidfVectorizer()
        matrix = vectorizer.fit_transform(texts).toarray().tolist()
        return matrix, "tfidf"
    except ImportError:
        pass
    except Exception as exc:
        print(f"[leadv2-rag-intake] WARN: sklearn error ({exc}), falling back to word overlap", file=sys.stderr)

    return embed_batch_fallback(texts), "word-overlap"


# ─────────────────────────────────────────────────────────────────────────────
# 4. Main
# ─────────────────────────────────────────────────────────────────────────────

def main() -> None:
    history = load_history(HISTORY_PATH)

    if not history:
        print("[]")
        return

    if len(history) < 5:
        print(f"[leadv2-rag-intake] WARN: only {len(history)} history entries (recommend ≥5 for reliable ranking)", file=sys.stderr)

    docs  = [entry_to_doc(e) for e in history]
    texts = [TASK_DESC] + docs

    vectors, method = embed_batch(texts)
    query_vec = vectors[0]
    doc_vecs  = vectors[1:]

    scored: list[tuple[float, dict[str, Any]]] = []
    for vec, entry in zip(doc_vecs, history):
        sim = cosine(query_vec, vec)
        scored.append((sim, entry))

    scored.sort(key=lambda x: x[0], reverse=True)
    top = scored[:TOP_K]

    results: list[dict[str, Any]] = []
    for sim, entry in top:
        reflect   = entry.get("reflect", {}) or {}
        sig       = reflect.get("signature", {}) or {}
        gf        = reflect.get("graph_footprint", {}) or {}

        outcome_raw = sig.get("outcome", "")
        outcome = f"completed_{outcome_raw}" if outcome_raw and "completed" not in outcome_raw else outcome_raw

        rec: dict[str, Any] = {
            "task_id":        str(entry.get("task", "")),
            "title":          reflect.get("title", str(entry.get("task", ""))),
            "similarity":     round(sim, 4),
            "classification": sig.get("task_class", ""),
            "outcome":        outcome,
            "duration_min":   reflect.get("duration_min", None),
            "signature": {
                "phase":         sig.get("phase", ""),
                "failure_class": sig.get("failure_class", "none"),
            },
            "graph_footprint": {
                "change_kind": gf.get("change_kind", ""),
                "risk_score":  gf.get("risk_score", ""),
            },
            "key_lessons": (
                [reflect["pattern_for_immune"]]
                if reflect.get("pattern_for_immune")
                else []
            ),
        }
        results.append(rec)

    print(yaml.dump(results, default_flow_style=False, allow_unicode=True, sort_keys=False).rstrip())

    if method != "fastembed":
        print(f"[leadv2-rag-intake] method={method}", file=sys.stderr)


main()
PYEOF
