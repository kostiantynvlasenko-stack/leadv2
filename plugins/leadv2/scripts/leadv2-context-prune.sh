#!/usr/bin/env bash
# leadv2-context-prune.sh — Reduce context.yaml size between /leadv2 phase transitions.
#
# Modes:
#   between_rounds (default ~40%)  — strip stale round findings, keep file:line refs
#   pre_deploy     (~60%)           — drop plan.raw_reasoning, keep decisions + deploy_packet
#   aggressive     (~80%)           — for chain spawns, keep only current-phase essentials
#
# Idempotent. Backup always written. Safe on missing file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh" || { echo "FATAL: cannot source leadv2-helpers.sh" >&2; exit 1; }

TASK_ID=""
MODE="between_rounds"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) TASK_ID="$2"; shift 2 ;;
    --mode)    MODE="$2";    shift 2 ;;
    -h|--help) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$TASK_ID" ]] && { echo "--task-id required" >&2; exit 2; }

CTX="docs/handoff/${TASK_ID}/context.yaml"
if [[ ! -f "$CTX" ]]; then
  echo "WARN: $CTX not found — no-op" >&2
  exit 0
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BAK="${CTX}.bak-pre-prune-${TS}"
cp "$CTX" "$BAK"

IN_BYTES=$(wc -c < "$CTX" | tr -d ' ')

if ! command -v python3 >/dev/null; then
  echo "WARN: python3 missing — skip prune" >&2
  exit 0
fi

prune_yaml=$(python3 - "$CTX" "$MODE" <<'PY'
import sys, os
try:
    import yaml
except ImportError:
    print("WARN: pyyaml missing — no-op", file=sys.stderr)
    sys.exit(0)

path, mode = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = yaml.safe_load(f) or {}

def strip_round(r):
    # keep only summary + disposition + severity refs; drop full_context/code blobs
    keep = {}
    for k in ("round","disposition","summary","timestamp","findings_count"):
        if k in r: keep[k] = r[k]
    fnds = r.get("raw_findings") or r.get("findings") or []
    compact = []
    for f in fnds:
        if not isinstance(f, dict): continue
        compact.append({
            "file": f.get("file"),
            "line": f.get("line") or f.get("line_start"),
            "severity": f.get("severity"),
            "summary": (f.get("summary") or f.get("message") or "")[:160],
        })
    keep["findings_compact"] = compact
    return keep

reviews = d.get("reviews") or {}
if isinstance(reviews, dict):
    rounds = sorted([k for k in reviews if k.startswith("round_")])
    if len(rounds) > 1:
        # keep latest round full, compact the rest
        for rk in rounds[:-1]:
            if isinstance(reviews[rk], dict):
                reviews[rk] = strip_round(reviews[rk])

# Replace inline code blocks in plan.steps with code_refs pointers
plan = d.get("plan") or {}
steps = plan.get("steps") or []
if isinstance(steps, list):
    for s in steps:
        if isinstance(s, dict) and "example_code" in s:
            refs = s.get("code_refs") or []
            s.pop("example_code", None)
            if not refs and "file" in s:
                refs.append({"file": s["file"], "note": "see Read tool"})
            s["code_refs"] = refs

if mode in ("pre_deploy","aggressive"):
    plan.pop("raw_reasoning", None)
    plan.pop("codex_output_full", None)
    plan.pop("architect_output_full", None)
    plan.pop("critic_output_full", None)

if mode == "aggressive":
    keep_top = {"task_id","classification","decisions","off_limits","current_phase",
                "plan","deploy_packet","reviews"}
    d = {k: v for k, v in d.items() if k in keep_top}
    if "plan" in d and isinstance(d["plan"], dict):
        d["plan"] = {kk: vv for kk, vv in d["plan"].items()
                     if kk in ("steps","parallel_groups","decisions")}

d["_prune_log"] = d.get("_prune_log", [])
d["_prune_log"].append({"mode": mode, "ts": os.environ.get("PRUNE_TS","")})

import io as _io
_buf = _io.StringIO()
yaml.safe_dump(d, _buf, sort_keys=False, allow_unicode=True, width=120)
sys.stdout.write(_buf.getvalue())
PY
)
if [[ -z "$prune_yaml" ]]; then
  echo "WARN: prune produced empty output, skipping write" >&2
  exit 0
fi
_atomic_write_yaml "$CTX" "$prune_yaml"

OUT_BYTES=$(wc -c < "$CTX" | tr -d ' ')
REDUCTION=0
if [[ "$IN_BYTES" -gt 0 ]]; then
  REDUCTION=$(( (IN_BYTES - OUT_BYTES) * 100 / IN_BYTES ))
fi

echo "pruned: input_bytes=${IN_BYTES} output_bytes=${OUT_BYTES} reduction_pct=${REDUCTION} mode=${MODE}"

TOK="docs/handoff/${TASK_ID}/tokens.yaml"
mkdir -p "$(dirname "$TOK")"
if [[ ! -f "$TOK" ]]; then
  printf "task_id: %s\nspawns: []\nprunes: []\n" "$TASK_ID" > "$TOK"
fi
cat >> "$TOK" <<EOF
prunes_append:
  - ts: $(date -u +%Y-%m-%dT%H:%M:%SZ)
    mode: ${MODE}
    input_bytes: ${IN_BYTES}
    output_bytes: ${OUT_BYTES}
    reduction_pct: ${REDUCTION}
EOF
