#!/usr/bin/env bash
set -euo pipefail
# leadv2-decide.sh — Founder answers a pending /leadv2 decision.
#
# Usage:
#   leadv2-decide.sh <decision-id-or-file> <option-id> [--notes "..."]
#   leadv2-decide.sh --list
#   leadv2-decide.sh --show <id>
#
# Writes answer.selected, answer.selected_at, status: answered to the decision
# file (atomic: tmp → mv). Emits _signal file for daemon pickup within one poll.
#
# Self-test:
#   # Write a fake decision
#   bash -c 'cat > docs/leadv2-decisions/test.yaml <<EOF
#   id: test
#   status: pending
#   options:
#     - {id: A, label: "opt A", action: retry_task}
#     - {id: B, label: "opt B", action: skip_task}
#   answer: {selected: null, selected_at: null, notes: null}
#   EOF'
#   bash .claude/scripts/leadv2-decide.sh test A
#   # Should print "answered" and file should now have status: answered, answer.selected: A

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
DECISIONS_DIR="${PROJECT_ROOT}/docs/leadv2-decisions"
SIGNAL_FILE="${DECISIONS_DIR}/_signal"

usage() {
  cat >&2 <<EOF
Usage:
  leadv2-decide.sh --list
  leadv2-decide.sh --show <decision-id>
  leadv2-decide.sh --tier <decision-id>
  leadv2-decide.sh <decision-id> <option-id> [--notes "..."]
EOF
  exit 1
}

[[ $# -eq 0 ]] && usage

# ── Sub-commands ───────────────────────────────────────────────────────────────

if [[ "$1" == "--tier" ]]; then
  [[ $# -lt 2 ]] && { echo "Usage: leadv2-decide.sh --tier <id>" >&2; exit 1; }
  TIER_ID="$2"
  TIER_FILE=""
  if [[ -f "$TIER_ID" ]]; then
    TIER_FILE="$TIER_ID"
  elif [[ -f "${DECISIONS_DIR}/${TIER_ID}.yaml" ]]; then
    TIER_FILE="${DECISIONS_DIR}/${TIER_ID}.yaml"
  elif [[ -f "${DECISIONS_DIR}/${TIER_ID}" ]]; then
    TIER_FILE="${DECISIONS_DIR}/${TIER_ID}"
  else
    TIER_FILE=$(find "$DECISIONS_DIR" -maxdepth 1 -name "*${TIER_ID}*" ! -name '_*' 2>/dev/null | head -1 || true)
  fi
  if [[ -z "$TIER_FILE" ]]; then
    echo "[leadv2-decide] decision not found: $TIER_ID" >&2; exit 1
  fi
  python3 - "$TIER_FILE" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
tier       = doc.get("tier", "unknown")
status     = doc.get("status", "unknown")
recommended = doc.get("recommended", "?")
reasoning  = doc.get("reasoning", "")
auto_apply = doc.get("escalation", {}).get("auto_apply_at", None)
print(f"Tier:        {tier}")
print(f"Status:      {status}")
print(f"Recommended: {recommended}")
if auto_apply:
    print(f"Auto-apply:  {auto_apply}")
print(f"Reasoning:   {reasoning}")
options = doc.get("options") or []
for o in options:
    fq = o.get("fix_quality", "MISSING")
    marker = " ← recommended" if str(o.get("id","")).upper() == str(recommended).upper() else ""
    print(f"  [{o.get('id')}] {o.get('label','')} (fix_quality={fq}){marker}")
PY
  exit 0
fi

if [[ "$1" == "--list" ]]; then
  echo "Pending decisions:"
  found=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if grep -q 'status: pending' "$f" 2>/dev/null; then
      id=$(grep -m1 '^id:' "$f" | sed "s/id: //;s/['\"]//g" | xargs)
      question=$(grep -m1 '^question:' "$f" | sed "s/question: //;s/['\"]//g" | xargs)
      trigger=$(grep -m1 '^trigger:' "$f" | sed "s/trigger: //;s/['\"]//g" | xargs)
      tier=$(grep -m1 '^tier:' "$f" | sed "s/tier: //;s/['\"]//g" | xargs)
      recommended=$(grep -m1 '^recommended:' "$f" | sed "s/recommended: //;s/['\"]//g" | xargs)
      printf '  [%s] Tier=%s trigger=%s recommended=%s\n    %s\n' "$id" "${tier:-?}" "$trigger" "${recommended:-?}" "$question"
      found=$((found+1))
    fi
  done < <(find "$DECISIONS_DIR" -maxdepth 1 -name '*.yaml' ! -name '_*' 2>/dev/null | sort)
  [[ "$found" -eq 0 ]] && echo "  (none)"
  exit 0
fi

if [[ "$1" == "--show" ]]; then
  [[ $# -lt 2 ]] && { echo "Usage: leadv2-decide.sh --show <id>" >&2; exit 1; }
  SHOW_ID="$2"
  SHOW_FILE=""
  # Accept full path, bare filename, or id prefix
  if [[ -f "$SHOW_ID" ]]; then
    SHOW_FILE="$SHOW_ID"
  elif [[ -f "${DECISIONS_DIR}/${SHOW_ID}.yaml" ]]; then
    SHOW_FILE="${DECISIONS_DIR}/${SHOW_ID}.yaml"
  elif [[ -f "${DECISIONS_DIR}/${SHOW_ID}" ]]; then
    SHOW_FILE="${DECISIONS_DIR}/${SHOW_ID}"
  else
    # fuzzy: find file whose name contains the id
    SHOW_FILE=$(find "$DECISIONS_DIR" -maxdepth 1 -name "*${SHOW_ID}*" ! -name '_*' 2>/dev/null | head -1 || true)
  fi
  if [[ -z "$SHOW_FILE" ]]; then
    echo "[leadv2-decide] decision not found: $SHOW_ID" >&2; exit 1
  fi
  cat "$SHOW_FILE"
  exit 0
fi

# ── Answer a decision ──────────────────────────────────────────────────────────

[[ $# -lt 2 ]] && usage

DEC_ID="$1"
OPTION_ID="${2^^}"  # uppercase
shift 2

NOTES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    *) echo "[leadv2-decide] unknown arg: $1" >&2; usage ;;
  esac
done

# Resolve file path
DEC_FILE=""
if [[ -f "$DEC_ID" ]]; then
  DEC_FILE="$DEC_ID"
elif [[ -f "${DECISIONS_DIR}/${DEC_ID}.yaml" ]]; then
  DEC_FILE="${DECISIONS_DIR}/${DEC_ID}.yaml"
elif [[ -f "${DECISIONS_DIR}/${DEC_ID}" ]]; then
  DEC_FILE="${DECISIONS_DIR}/${DEC_ID}"
else
  DEC_FILE=$(find "$DECISIONS_DIR" -maxdepth 1 -name "*${DEC_ID}*" ! -name '_*' 2>/dev/null | head -1 || true)
fi

if [[ -z "$DEC_FILE" ]]; then
  echo "[leadv2-decide] decision not found: $DEC_ID" >&2
  echo "Run 'leadv2-decide.sh --list' to see pending decisions." >&2
  exit 1
fi

# Validate + apply via python3 (atomic write)
python3 - "$DEC_FILE" "$OPTION_ID" "$NOTES" <<'PY'
import sys, yaml, os, datetime

dec_file  = sys.argv[1]
option_id = sys.argv[2]
notes     = sys.argv[3] if len(sys.argv) > 3 else ""

with open(dec_file) as f:
    doc = yaml.safe_load(f) or {}

# Validate status
status = doc.get("status", "")
if status == "answered":
    print(f"[leadv2-decide] already answered (selected={doc.get('answer', {}).get('selected')})", file=sys.stderr)
    sys.exit(1)
if status == "expired":
    print(f"[leadv2-decide] decision is expired", file=sys.stderr)
    sys.exit(1)

# Validate option
options = doc.get("options") or []
valid_ids = [str(o.get("id", "")).upper() for o in options]
if option_id not in valid_ids:
    print(f"[leadv2-decide] invalid option '{option_id}'. Valid: {', '.join(valid_ids)}", file=sys.stderr)
    sys.exit(1)

# Find the chosen option
chosen = next(o for o in options if str(o.get("id", "")).upper() == option_id)

# Apply
doc["status"] = "answered"
if not isinstance(doc.get("answer"), dict):
    doc["answer"] = {}
doc["answer"]["selected"] = option_id
doc["answer"]["selected_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
doc["answer"]["notes"] = notes if notes else None

# Atomic write
tmp_file = dec_file + ".tmp"
with open(tmp_file, "w") as f:
    yaml.dump(doc, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
os.replace(tmp_file, dec_file)

print(f"answered: [{option_id}] {chosen.get('label', '')} → action={chosen.get('action', '')}")
PY

# Emit signal file so daemon picks it up within one poll cycle
touch "$SIGNAL_FILE"
echo "[leadv2-decide] signal written → daemon will pick up at next poll"
