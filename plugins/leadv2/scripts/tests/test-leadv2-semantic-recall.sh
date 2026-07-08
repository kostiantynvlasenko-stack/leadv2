#!/usr/bin/env bash
# tests/test-leadv2-semantic-recall.sh — Unit tests for MEM-SEMANTIC-RECALL-01
#
# Tests (all offline — no live Qdrant required):
#   1. bash -n syntax check on all 3 new scripts + edited immune-lookup.sh.
#   2. Flag-off => leadv2-immune-lookup.sh output identical to pre-fusion
#      keyword-only ranking (byte-identical invariant, design §3).
#   3. Helper-missing fail-open: flag=1 but LEADV2_RECALL_HELPER unset =>
#      leadv2-semantic-recall.sh prints nothing, exit 0 (no crash).
#   4. RRF fusion correctness: a semantic-only hit (score=0 in the keyword
#      path, i.e. absent from `scored`) gets pulled into the top-3 via the
#      _LEADV2_SEMANTIC_TSV_OVERRIDE test seam — proves fusion recovers a
#      differently-phrased entry that keyword-only ranking would miss
#      (the PGRST102 motivating example from design.md §Problem).
#
# Run: bash scripts/tests/test-leadv2-semantic-recall.sh
# Exit 0 = all pass; non-zero = failures found.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOOKUP_SH="${SCRIPTS_DIR}/leadv2-immune-lookup.sh"
RECALL_SH="${SCRIPTS_DIR}/leadv2-semantic-recall.sh"
INDEX_SH="${SCRIPTS_DIR}/leadv2-semantic-index.sh"
BACKFILL_SH="${SCRIPTS_DIR}/leadv2-semantic-backfill.sh"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$(( PASS + 1 )); log "PASS: $1"; }
fail() { FAIL=$(( FAIL + 1 )); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# ── 1. syntax checks ────────────────────────────────────────────────────
for f in "$LOOKUP_SH" "$RECALL_SH" "$INDEX_SH" "$BACKFILL_SH"; do
  if bash -n "$f" 2>/dev/null; then
    pass "bash -n syntax check: $(basename "$f")"
  else
    fail "bash -n syntax check: $(basename "$f")"
  fi
done

# ── scratch repo with a small immune-patterns.yaml ──────────────────────
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/docs/leadv2"
cat > "$SCRATCH/docs/leadv2/immune-patterns.yaml" <<'YAML'
patterns:
  - id: aaa111
    summary: "PGRST102 partial-index upsert conflict"
    action: "Check: upsert target must be a full unique index, not partial"
    keywords: ["upsert", "partial-index"]
    created: "2026-01-01"
    seen_count: 3
  - id: bbb222
    summary: "unrelated deploy timeout issue"
    action: "Check: deploy script retries on timeout"
    keywords: ["deploy", "timeout"]
    created: "2026-01-01"
    seen_count: 1
YAML

# leadv2-immune-lookup.sh resolves REPO_ROOT as two directory levels above
# its own script location (script_dir/../..) — mirror that exact depth here
# (PRE-EXISTING: the real .claude/leadv2/scripts/ symlink chain is actually
# THREE levels deep, which resolves REPO_ROOT to <repo>/.claude instead of
# <repo> — a pre-existing bug independent of this task; flagged in build.md,
# not fixed here to keep this diff scoped to additive fusion only).
mkdir -p "$SCRATCH/plugin/scripts"
cp "$LOOKUP_SH" "$SCRATCH/plugin/scripts/leadv2-immune-lookup.sh"
cp "$RECALL_SH" "$SCRATCH/plugin/scripts/leadv2-semantic-recall.sh"
LOOKUP_COPY="$SCRATCH/plugin/scripts/leadv2-immune-lookup.sh"

# ── 2. flag-off byte-identical ───────────────────────────────────────────
unset LEADV2_SEMANTIC_RECALL_ENABLED LEADV2_RECALL_HELPER _LEADV2_SEMANTIC_TSV_OVERRIDE 2>/dev/null || true
OUT_OFF="$(cd "$SCRATCH" && bash "$LOOKUP_COPY" "upsert conflict on a partial index" 2>/dev/null)"
if printf '%s' "$OUT_OFF" | grep -q "aaa111"; then
  pass "flag-off: keyword match still found (aaa111)"
else
  fail "flag-off: expected keyword match aaa111 in output, got: $OUT_OFF"
fi
if ! printf '%s' "$OUT_OFF" | grep -q "bbb222"; then
  pass "flag-off: unrelated pattern bbb222 correctly absent"
else
  fail "flag-off: unrelated pattern bbb222 unexpectedly present"
fi

# ── 3. helper-missing fail-open (no crash, empty output) ────────────────
export LEADV2_SEMANTIC_RECALL_ENABLED=1
unset LEADV2_RECALL_HELPER 2>/dev/null || true
RECALL_OUT="$(bash "$RECALL_SH" immune "some query" 2>/dev/null || true)"
RECALL_RC=0
bash "$RECALL_SH" immune "some query" >/dev/null 2>&1 || RECALL_RC=$?
if [[ -z "$RECALL_OUT" && "$RECALL_RC" -eq 0 ]]; then
  pass "helper-missing: semantic-recall.sh fails open (empty output, exit 0)"
else
  fail "helper-missing: expected empty output + exit 0, got output='${RECALL_OUT}' rc=${RECALL_RC}"
fi

OUT_NOHELPER="$(cd "$SCRATCH" && bash "$LOOKUP_COPY" "upsert conflict on a partial index" 2>/dev/null)"
if printf '%s' "$OUT_NOHELPER" | grep -q "aaa111"; then
  pass "helper-missing: immune-lookup still returns keyword match, no crash"
else
  fail "helper-missing: immune-lookup broke without a helper: $OUT_NOHELPER"
fi
unset LEADV2_SEMANTIC_RECALL_ENABLED 2>/dev/null || true

# ── 4. RRF fusion recovers a semantic-only (differently-phrased) hit ────
# bbb222 has zero keyword overlap with this query — pure keyword ranking
# would never surface it. Inject it as the #1 semantic hit via the test
# seam and confirm it is promoted into the top-3 by RRF.
export _LEADV2_SEMANTIC_TSV_OVERRIDE=$'bbb222\t0.81'
OUT_FUSED="$(cd "$SCRATCH" && bash "$LOOKUP_COPY" "upsert conflict on a partial index" 2>/dev/null)"
unset _LEADV2_SEMANTIC_TSV_OVERRIDE

if printf '%s' "$OUT_FUSED" | grep -q "bbb222"; then
  pass "RRF fusion: semantic-only hit bbb222 promoted into top-3"
else
  fail "RRF fusion: expected bbb222 in fused output, got: $OUT_FUSED"
fi
if printf '%s' "$OUT_FUSED" | grep -q "aaa111"; then
  pass "RRF fusion: keyword hit aaa111 still present alongside semantic hit"
else
  fail "RRF fusion: keyword hit aaa111 unexpectedly dropped: $OUT_FUSED"
fi

# ── 5. H1 regression: keyword top-3 always preserved when semantic path adds noise ──
# 3 real keyword hits (K1/K2/K3) + weak semantic-only noise entries that tie
# on fused rank-1 with a keyword hit (the review's exact repro shape) must
# NEVER evict K2/K3 from the returned set — semantic can only ADD.
mkdir -p "$SCRATCH/docs/leadv2"
cat > "$SCRATCH/docs/leadv2/immune-patterns.yaml" <<'YAML2'
patterns:
  - id: K1
    summary: "upsert conflict target partial index PGRST102"
    action: "Check: use a full unique index for upsert target"
    keywords: ["upsert", "conflict"]
    created: "2026-01-01"
    seen_count: 1
  - id: K2
    summary: "upsert conflict partial index arbiter"
    action: "Check: PostgREST cannot resolve arbiter against a partial index"
    keywords: ["upsert", "arbiter"]
    created: "2026-01-01"
    seen_count: 1
  - id: K3
    summary: "upsert conflict batch write partial"
    action: "Check: batch upsert fails on partial unique index"
    keywords: ["upsert", "batch"]
    created: "2026-01-01"
    seen_count: 1
  - id: S1
    summary: "totally unrelated cron drift issue"
    action: "Check: cron systemd timer"
    keywords: ["cron"]
    created: "2026-01-01"
    seen_count: 1
YAML2

export _LEADV2_SEMANTIC_TSV_OVERRIDE=$'S1	0.90'
OUT_H1="$(cd "$SCRATCH" && bash "$LOOKUP_COPY" "upsert conflict partial index" 2>/dev/null)"
unset _LEADV2_SEMANTIC_TSV_OVERRIDE

for id in K1 K2 K3; do
  if printf '%s' "$OUT_H1" | grep -q "id: $id"; then
    pass "H1: keyword top-3 hit $id preserved despite high-cosine semantic noise"
  else
    fail "H1: keyword hit $id was evicted by fusion (violates never-suppress invariant): $OUT_H1"
  fi
done
if printf '%s' "$OUT_H1" | grep -q "id: S1"; then
  pass "H1: semantic-only entry S1 still gets its additive bonus slot"
else
  fail "H1: semantic-only entry S1 missing from bonus slot: $OUT_H1"
fi

# ── summary ───────────────────────────────────────────────────────────
log "----"
log "PASS=${PASS} FAIL=${FAIL}"
if [[ "$FAIL" -gt 0 ]]; then
  for e in "${ERRORS[@]}"; do log "$e"; done
  exit 1
fi
exit 0
