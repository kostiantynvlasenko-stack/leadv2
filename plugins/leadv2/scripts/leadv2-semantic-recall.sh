#!/usr/bin/env bash
# leadv2-semantic-recall.sh — semantic query against the shared "leadv2_memory"
# Qdrant collection (MEM-SEMANTIC-RECALL-01 §2 step 1).
#
# Usage: leadv2-semantic-recall.sh <store> "<query text>" [limit=10] [repo]
# Output: one line per hit, tab-separated "<entry_id>\t<cosine>", sorted by
#         cosine desc, filtered to cosine >= TAU_SEM.
#
# Fail-open (flag off / LEADV2_RECALL_HELPER missing / Qdrant unreachable /
# malformed response) => prints nothing, exit 0. Callers MUST treat empty
# output as "fall back to keyword-only" — never as an error.
#
# Fix round (H2): every Qdrant curl now has a bounded --max-time so a
# stalled/hung Qdrant fails open instead of blocking the caller indefinitely.
# Fix round (H4): the "leadv2_memory" collection is SHARED across 3 repos
# (persona-engine/m3/respiro) — results are now also filtered by the `repo`
# payload field so one repo never sees another repo's cross-repo bleed.
set -euo pipefail

QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
LEADV2_SEMANTIC_COLLECTION="${LEADV2_SEMANTIC_COLLECTION:-leadv2_memory}"
# lean: single global tau, no per-store override — upgrade when a store needs
# a different recall floor than 0.35 (design §2/§5).
TAU_SEM="${LEADV2_SEMANTIC_TAU:-0.35}"
# Bounded per-curl network timeout (H2) — Qdrant is local/fast; a stall past
# this must fail open, never block the caller.
QDRANT_CURL_MAX_TIME="${LEADV2_QDRANT_CURL_MAX_TIME:-5}"

_sem_enabled() {
  [[ "${LEADV2_SEMANTIC_RECALL_ENABLED:-0}" == "1" ]] || return 1
  [[ -n "${LEADV2_RECALL_HELPER:-}" && -f "${LEADV2_RECALL_HELPER}" ]] || return 1
  return 0
}

main() {
  local store="${1:?store required}"
  local query="${2:?query text required}"
  local limit="${3:-10}"
  local repo="${4:-$(basename "$PWD")}"

  _sem_enabled || exit 0

  local vector
  vector=$(timeout 60 python3 "$LEADV2_RECALL_HELPER" --query "$query" 2>/dev/null) || exit 0
  echo "$vector" | jq -e 'type=="array"' >/dev/null 2>&1 || exit 0

  local vec_file body
  vec_file=$(mktemp)
  trap 'rm -f "$vec_file"' RETURN
  echo "$vector" > "$vec_file"

  body=$(jq -n --slurpfile vec "$vec_file" --argjson lim "$limit" --arg s "$store" --arg r "$repo" \
    '{vector:$vec[0], limit:$lim, filter:{must:[{key:"store", match:{value:$s}}, {key:"repo", match:{value:$r}}]}, with_payload:true}')

  local response
  response=$(curl -sf --max-time "$QDRANT_CURL_MAX_TIME" -X POST "${QDRANT_URL}/collections/${LEADV2_SEMANTIC_COLLECTION}/points/search" \
    -H 'content-type: application/json' -d "$body" 2>/dev/null) || exit 0

  echo "$response" | jq -r --argjson tau "$TAU_SEM" \
    '.result[]? | select(.score >= $tau) | [.payload.entry_id, .score] | @tsv' 2>/dev/null \
    | sort -t $'\t' -k2 -rn || true
}

main "$@"
