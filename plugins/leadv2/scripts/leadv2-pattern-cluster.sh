#!/usr/bin/env bash
# leadv2-pattern-cluster.sh
# Extracts pattern_for_immune: lines from docs/LEAD_V2_STATE.md (and optional
# LEAD_HISTORY.md), groups them by shared 3-gram tokens, and prints clusters
# with count >= LEADV2_SKILL_SYNTH_THRESHOLD (default 3).
#
# Usage:
#   bash .claude/scripts/leadv2-pattern-cluster.sh
#   LEADV2_SKILL_SYNTH_THRESHOLD=2 bash .claude/scripts/leadv2-pattern-cluster.sh
#
# No external dependencies beyond python3 (stdlib only).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TASKS_DIR="${REPO_ROOT}/docs/leadv2/tasks"
STATE_FILE="${REPO_ROOT}/docs/LEAD_V2_STATE.md"
HISTORY_FILE="${REPO_ROOT}/docs/ops/LEAD_HISTORY.md"
THRESHOLD="${LEADV2_SKILL_SYNTH_THRESHOLD:-3}"

log() { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Collect per-task STATE.md files + top-level state files
# Using find via python for portability (bash find is blocked by hook)
FILES=""
if [[ -d "$TASKS_DIR" ]]; then
  FILES="$(python3 -c "
import os, sys
d = sys.argv[1]
files = []
for root, dirs, names in os.walk(d):
    for n in names:
        if n == 'STATE.md':
            files.append(os.path.join(root, n))
files.sort()
print('\n'.join(files))
" "$TASKS_DIR")"
fi

# Also include top-level state + history if they exist
if [[ -f "$STATE_FILE" ]]; then
  FILES="${FILES}"$'\n'"${STATE_FILE}"
fi
if [[ -f "$HISTORY_FILE" ]]; then
  FILES="${FILES}"$'\n'"${HISTORY_FILE}"
fi

if [[ -z "$FILES" ]]; then
  log "ERROR: no input files found under $TASKS_DIR"
  exit 1
fi

# Pass files as separate arguments to python
readarray -t FILE_ARR <<< "$FILES"

python3 - "$THRESHOLD" "${FILE_ARR[@]}" <<'PYEOF'
import sys
import re
import itertools
from collections import defaultdict

threshold = int(sys.argv[1])
input_files = sys.argv[2:]

# --- 1. Extract all pattern_for_immune values ---
patterns: list[tuple[str, str]] = []  # (task_id, pattern_text)

for fpath in input_files:
    try:
        content = open(fpath).read()
    except OSError:
        continue

    # Derive task_id from directory name when file is docs/leadv2/tasks/<ID>/STATE.md
    path_parts = fpath.replace("\\", "/").split("/")
    file_task_id: str = "unknown"
    if "tasks" in path_parts:
        tasks_idx = path_parts.index("tasks")
        if tasks_idx + 1 < len(path_parts):
            file_task_id = path_parts[tasks_idx + 1]

    # Pattern_for_immune can appear as:
    #   pattern_for_immune: "some text"
    #   pattern_for_immune: some text
    #   pattern_for_immune: | (multiline — skip the "|" sentinel, grab next non-empty line)
    immune_pattern = re.compile(
        r'pattern_for_immune:\s*(?:["\']?([^\n\|"][^\n]*?)["\']?\s*$|\|\s*\n((?:[ \t]+[^\n]+\n?)+))',
        re.MULTILINE
    )

    # Also match task ids from recent-history lines like "- OPS-DEPLOY-..."
    taskid_in_history = re.compile(r'-\s+((?:PO|OPS|BUG|CHORE|FEAT|PO-LEADV2|OPS-LEADV2)-\S+?)\s')
    task_positions: list[tuple[int, str]] = []
    for m in taskid_in_history.finditer(content):
        task_positions.append((m.start(), m.group(1)))
    task_positions.sort(key=lambda x: x[0])

    for m in immune_pattern.finditer(content):
        # Group 1 = inline value; group 2 = block scalar body
        if m.group(1):
            text = m.group(1).strip().strip('"\'')
        else:
            # multiline block — join lines, strip indent
            raw = m.group(2) or ""
            text = " ".join(line.strip() for line in raw.splitlines() if line.strip())

        if not text or text in ('|', '""', "''"):
            continue

        # Use file-path-derived task_id, fallback to nearest preceding id in content
        task_id = file_task_id
        if task_id == "unknown" and task_positions:
            for pos, tid in reversed(task_positions):
                if pos < m.start():
                    task_id = tid
                    break

        patterns.append((task_id, text))

if not patterns:
    print("# leadv2-pattern-cluster: no pattern_for_immune entries found")
    print(f"# searched: {input_files}")
    sys.exit(0)

# --- 2. Tokenize: lowercase, split on non-alphanum, filter stopwords ---
STOPWORDS = {
    'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'could',
    'should', 'may', 'might', 'to', 'of', 'in', 'on', 'at', 'by', 'for',
    'with', 'from', 'as', 'or', 'and', 'not', 'no', 'it', 'its', 'this',
    'that', 'if', 'when', 'than', 'then', 'but', 'so', 'up', 'out', 'all',
    'any', 'can', 'via', 'into',
}

def tokenize(text: str) -> list[str]:
    tokens = re.split(r'[^a-z0-9_]+', text.lower())
    return [t for t in tokens if t and len(t) > 2 and t not in STOPWORDS]

def ngrams(tokens: list[str], n: int) -> set[tuple[str, ...]]:
    return set(tuple(tokens[i:i+n]) for i in range(len(tokens) - n + 1))

# Compute 3-grams for each pattern
pattern_ngrams: list[set[tuple[str, ...]]] = []
for _, text in patterns:
    toks = tokenize(text)
    pattern_ngrams.append(ngrams(toks, 3) if len(toks) >= 3 else set())

# --- 3. Cluster by 3-gram overlap (Jaccard-inspired, greedy) ---
# Two patterns are "similar" if they share >= 1 3-gram OR token overlap > 40%
def similar(i: int, j: int) -> bool:
    a_grams = pattern_ngrams[i]
    b_grams = pattern_ngrams[j]
    if a_grams and b_grams and a_grams & b_grams:
        return True
    # Fallback: check token overlap
    a_tok = set(tokenize(patterns[i][1]))
    b_tok = set(tokenize(patterns[j][1]))
    if not a_tok or not b_tok:
        return False
    overlap = len(a_tok & b_tok) / min(len(a_tok), len(b_tok))
    return overlap >= 0.4

# Union-Find
parent = list(range(len(patterns)))
def find(x: int) -> int:
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x
def union(x: int, y: int) -> None:
    parent[find(x)] = find(y)

for i in range(len(patterns)):
    for j in range(i + 1, len(patterns)):
        if similar(i, j):
            union(i, j)

# Group by root
clusters: dict[int, list[int]] = defaultdict(list)
for i in range(len(patterns)):
    clusters[find(i)].append(i)

# --- 4. Output clusters with count >= threshold ---
significant = [
    (root, idxs) for root, idxs in clusters.items()
    if len(idxs) >= threshold
]
# Sort by count descending
significant.sort(key=lambda x: -len(x[1]))

print(f"# leadv2-pattern-cluster output — threshold={threshold}")
print(f"# total pattern_for_immune entries scanned: {len(patterns)}")
print(f"# clusters with count >= {threshold}: {len(significant)}")
print()

if not significant:
    print("clusters: []")
else:
    print("clusters:")
    for rank, (root, idxs) in enumerate(significant, 1):
        representative = patterns[root][1]
        task_ids = list(dict.fromkeys(patterns[i][0] for i in idxs))  # preserve order, dedup
        print(f"  - rank: {rank}")
        print(f"    count: {len(idxs)}")
        print(f"    representative: \"{representative}\"")
        print(f"    task_ids: {task_ids}")
        print(f"    all_patterns:")
        for idx in idxs:
            tid, text = patterns[idx]
            print(f"      - task: {tid}")
            print(f"        text: \"{text}\"")
        print()

PYEOF
