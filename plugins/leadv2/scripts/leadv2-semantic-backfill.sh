#!/usr/bin/env bash
# leadv2-semantic-backfill.sh — one-time backfill of the leadv2_memory Qdrant
# collection from existing immune-patterns.yaml + negative-memory.yaml active
# entries (MEM-SEMANTIC-RECALL-01 §1). Re-runnable: content_hash-gated
# idempotent upsert (leadv2-semantic-index.sh) makes repeat runs a no-op for
# unchanged entries.
#
# Usage: leadv2-semantic-backfill.sh <repo_root>
# Prints one "active-entries / qdrant-points" parity line per store to stdout.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
LEADV2_SEMANTIC_COLLECTION="${LEADV2_SEMANTIC_COLLECTION:-leadv2_memory}"
# Fix round (H2): bounded curl timeout, same rationale as leadv2-semantic-index.sh.
QDRANT_CURL_MAX_TIME="${LEADV2_QDRANT_CURL_MAX_TIME:-5}"

REPO_ROOT"${1:?usage: leadv2-semantic-backfill.sh <repo_root>}"
REPO_NAME="$(basename "$REPO_ROOT")"

if [[ "${LEADV2_SEMANTIC_RECALL_ENABLED:-0}" != "1" || -z "${LEADV2_RECALL_HELPER:-}" ]]; then
  echo "[semantic-backfill] disabled (flag off or LEADV2_RECALL_HELPER unset) — nothing to do" >&2
  exit 0
fi

IMMUNE_FILE="${REPO_ROOT}/docs/leadv2/immune-patterns.yaml"
NEGMEM_FILE="${REPO_ROOT}/docs/leadv2-negative-memory.yaml"

_count_points() {
  local store="$1"
  curl -sf --max-time "$QDRANT_CURL_MAX_TIME" -X POST "${QDRANT_URL}/collections/${LEADV2_SEMANTIC_COLLECTION}/points/scroll" \
    -H 'content-type: application/json' \
    -d "{\"filter\":{\"must\":[{\"key\":\"store\",\"match\":{\"value\":\"${store}\"}}]},\"limit\":1000,\"with_payload\":false}" \
    2>/dev/null | jq '.result.points | length' 2>/dev/null || echo 0
}

_backfill_immune() {
  if [[ ! -f "$IMMUNE_FILE" ]]; then
    echo "immune: 0 active-entries / 0 qdrant-points (no immune-patterns.yaml)"
    return
  fi
  local n=0
  while IFS=$'\t' read -r pid summary action kw; do
    [[ -z "$pid" ]] && continue
    local text="${summary} ${action} ${kw}"
    local chash
    chash=$(printf '%s' "$text" | shasum -a 1 | awk '{print $1}')
    bash "${_SCRIPT_DIR}/leadv2-semantic-index.sh" immune "$pid" "" "$chash" "$text" "$REPO_NAME" || true
    n=$(( n + 1 ))
  done < <(python3 -c "
import yaml
data = yaml.safe_load(open('${IMMUNE_FILE}')) or {}
for p in data.get('patterns') or []:
    kw = ' '.join(p.get('keywords') or [])
    print(f\"{p.get('id','')}\t{p.get('summary','')}\t{p.get('action','')}\t{kw}\")
" 2>/dev/null)
  echo "immune: ${n} active-entries / $(_count_points immune) qdrant-points"
}

_backfill_negmem() {
  if [[ ! -f "$NEGMEM_FILE" ]]; then
    echo "negmem: 0 active-entries / 0 qdrant-points (no negative-memory.yaml)"
    return
  fi
  local n=0
  while IFS=$'\t' read -r nid approach failure phase; do
    [[ -z "$nid" ]] && continue
    local text="${approach} ${failure}"
    local chash
    chash=$(printf '%s' "$text" | shasum -a 1 | awk '{print $1}')
    bash "${_SCRIPT_DIR}/leadv2-semantic-index.sh" negmem "$nid" "$phase" "$chash" "$text" "$REPO_NAME" || true
    n=$(( n + 1 ))
  done < <(python3 -c "
import yaml
data = yaml.safe_load(open('${NEGMEM_FILE}')) or {}
for e in data.get('entries') or []:
    if e.get('status') != 'active':
        continue
    sig = e.get('signature') or {}
    print(f\"{e.get('id','')}\t{sig.get('approach','')}\t{sig.get('failure_mode','')}\t{sig.get('phase') or ''}\")
" 2>/dev/null)
  echo "negmem: ${n} active-entries / $(_count_points negmem) qdrant-points"
}

_backfill_immune
_backfill_negmem
