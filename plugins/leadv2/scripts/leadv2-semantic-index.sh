#!/usr/bin/env bash
# leadv2-semantic-index.sh — idempotent embed+upsert into the shared
# "leadv2_memory" Qdrant collection (MEM-SEMANTIC-RECALL-01 §1).
#
# Usage:
#   leadv2-semantic-index.sh <store> <entry_id> <phase> <content_hash> <embed_text> [repo]
#
#   store        immune | negmem | solutions
#   entry_id     stable id of the source entry (immune pattern id / NM-id / ...)
#   phase        phase this entry applies to, or "" for any-phase
#   content_hash hash of the entry's free-text fields (caller-computed). Used to
#                skip re-embedding when the source entry hasn't changed.
#   embed_text   the free-text to embed (assembled by caller per design §1 rule
#                — free-text fields only, never the regex trigger_pattern)
#   repo         repo namespace for the point id (default: basename of $PWD)
#
# Flag: LEADV2_SEMANTIC_RECALL_ENABLED=1 (default 0 — off => no-op, exit 0).
# Helper: LEADV2_RECALL_HELPER must point at a FastEmbed embed script with the
#         persona-engine scripts/embed.py CLI contract (stdin text -> JSON
#         float array on stdout; --query flag for query-side asymmetric embed).
#         Missing/unset helper => no-op, exit 0 (fail-open, never blocks the
#         caller's YAML write — this script is always invoked post-write,
#         best-effort).
set -euo pipefail

QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
LEADV2_SEMANTIC_COLLECTION="${LEADV2_SEMANTIC_COLLECTION:-leadv2_memory}"
# Fix round (H2): bounded per-curl network timeout — a stalled Qdrant must
# fail open (best-effort indexing), never hang the caller's write path.
QDRANT_CURL_MAX_TIME="${LEADV2_QDRANT_CURL_MAX_TIME:-5}"

_sem_enabled() {
  [[ "${LEADV2_SEMANTIC_RECALL_ENABLED:-0}" == "1" ]] || return 1
  [[ -n "${LEADV2_RECALL_HELPER:-}" && -f "${LEADV2_RECALL_HELPER}" ]] || return 1
  return 0
}

# sha1(repo|store|entry_id) -> UUID-formatted point id (Qdrant requires UUID/int ids).
_sem_point_id() {
  local repo="$1" store="$2" entry_id="$3"
  local hex
  hex=$(printf '%s|%s|%s' "$repo" "$store" "$entry_id" | shasum -a 1 | awk '{print $1}' | cut -c1-32)
  printf '%s-%s-%s-%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

# Idempotent upsert on write (design §1): ensure collection exists at the
# actual embed dim (never hardcoded — read from the live embed output).
_sem_ensure_collection() {
  local dim="$1"
  # BUGFIX: under `set -e`, a bare failing command aborts the function
  # immediately — the `return 0` below never ran, so every upsert after the
  # first into an already-existing collection silently killed the whole
  # script (Qdrant's PUT on an existing collection returns non-2xx here).
  # `|| true` on the curl itself is required, not just a trailing return 0.
  curl -sf --max-time "$QDRANT_CURL_MAX_TIME" -X PUT "${QDRANT_URL}/collections/${LEADV2_SEMANTIC_COLLECTION}" \
    -H 'content-type: application/json' \
    -d "{\"vectors\":{\"size\":${dim},\"distance\":\"Cosine\"}}" >/dev/null 2>&1 || true
  return 0
}

_sem_existing_hash() {
  local point_id="$1"
  curl -sf --max-time "$QDRANT_CURL_MAX_TIME" "${QDRANT_URL}/collections/${LEADV2_SEMANTIC_COLLECTION}/points/${point_id}" 2>/dev/null \
    | jq -r '.result.payload.content_hash // empty' 2>/dev/null || true
}

main() {
  local store="${1:?store required}"
  local entry_id="${2:?entry_id required}"
  local phase="${3:-}"
  local content_hash="${4:?content_hash required}"
  local embed_text="${5:?embed_text required}"
  local repo="${6:-$(basename "$PWD")}"

  _sem_enabled || { echo "[semantic-index] disabled (flag off or LEADV2_RECALL_HELPER missing) — no-op" >&2; exit 0; }

  local point_id
  point_id=$(_sem_point_id "$repo" "$store" "$entry_id")

  local prev_hash
  prev_hash=$(_sem_existing_hash "$point_id")
  if [[ -n "$prev_hash" && "$prev_hash" == "$content_hash" ]]; then
    echo "[semantic-index] ${store}/${entry_id} unchanged (content_hash match) — skip" >&2
    exit 0
  fi

  local vector
  vector=$(printf '%s' "$embed_text" | timeout 60 python3 "$LEADV2_RECALL_HELPER" 2>/dev/null) || {
    echo "[semantic-index] embed failed for ${store}/${entry_id} — fail-open no-op" >&2
    exit 0
  }
  echo "$vector" | jq -e 'type=="array"' >/dev/null 2>&1 || {
    echo "[semantic-index] embed returned non-array for ${store}/${entry_id} — no-op" >&2
    exit 0
  }

  local dim
  dim=$(echo "$vector" | jq 'length')
  _sem_ensure_collection "$dim"

  local vec_file pay_file body
  vec_file=$(mktemp)
  pay_file=$(mktemp)
  trap 'rm -f "$vec_file" "$pay_file"' RETURN
  echo "$vector" > "$vec_file"
  jq -n --arg s "$store" --arg e "$entry_id" --arg p "$phase" --arg h "$content_hash" --arg r "$repo" \
    '{store:$s, entry_id:$e, phase:$p, content_hash:$h, repo:$r}' > "$pay_file"

  body=$(jq -n --arg id "$point_id" --slurpfile vec "$vec_file" --slurpfile pay "$pay_file" \
    '{points:[{id:$id, vector:$vec[0], payload:$pay[0]}]}')

  curl -sf --max-time "$QDRANT_CURL_MAX_TIME" -X PUT "${QDRANT_URL}/collections/${LEADV2_SEMANTIC_COLLECTION}/points" \
    -H 'content-type: application/json' -d "$body" >/dev/null 2>&1 || {
    echo "[semantic-index] upsert failed for ${store}/${entry_id} — fail-open no-op" >&2
    exit 0
  }
  echo "[semantic-index] upserted ${store}/${entry_id} -> ${point_id}" >&2
}

main "$@"
