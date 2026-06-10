#!/usr/bin/env bash
# leadv2-shadow-apply.sh — Shadow A/B proposal apply/revert for leadv2.
#
# MODES:
#   --assign    Write arm to context.yaml at task-init (D4: deterministic hash(task_id)%2).
#   --promote   Apply diff_patch to target_file after snapshot; run eval-harness first.
#   --evaluate  Evaluate whether proposal is ready for promotion (check min_n_per_arm).
#   --revert    Restore before_snapshot; verify sha1; delete snapshot.
#
# USAGE:
#   bash leadv2-shadow-apply.sh --assign  --task-id <id>
#   bash leadv2-shadow-apply.sh --promote --proposal-id <sha1>
#   bash leadv2-shadow-apply.sh --evaluate --proposal-id <sha1>
#   bash leadv2-shadow-apply.sh --revert  --proposal-id <sha1>
#
# EXIT CODES:
#   0  success
#   1  error (I/O, missing file, argument error)
#   2  argument error
#   3  proposal already in terminal state (idempotent skip)
#   4  blocked_by_eval (eval-harness failed -- proposal status set)
#   5  founder_gated (high-risk proposal, status set)
#
# ENV:
#   LEADV2_PROJECT_ROOT       -- required; resolved from git toplevel when absent
#   LEADV2_SHADOW_ON_CLOSE    -- must be "1" to enable shadow ops; absent = skip (D6)
#   LEADV2_EVAL_HARNESS_ON    -- forwarded to eval-harness; "1" to run harness gate (D7)
#   LEADV2_DRY_RUN            -- "1" = dry-run; skip mutations (D5)
#
# DECISIONS: D1 D3 D4 D5 D6 D7 D10; R4 flock; R8 snapshot; R9 risk_level

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}}}"
export LEADV2_PROJECT_ROOT

# Source helpers (leadv2_dry_run_guard, etc.)
# shellcheck source=./leadv2-helpers.sh
if [[ -f "$SCRIPT_DIR/leadv2-helpers.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/leadv2-helpers.sh"
fi

log()       { printf -- '[shadow-apply] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_error() { log "ERROR: $*"; }
log_ok()    { log "OK: $*"; }

SHADOW_DIR="${LEADV2_PROJECT_ROOT}/docs/leadv2/shadow"
PROPOSALS_DIR="${SHADOW_DIR}/proposals"
SNAPSHOTS_DIR="${SHADOW_DIR}/snapshots"
LEARNING_PROPOSALS_DIR="${LEADV2_PROJECT_ROOT}/docs/leadv2/learning-proposals"
EVAL_HARNESS="${SCRIPT_DIR}/leadv2-eval-harness.sh"

MODE=""
TASK_ID=""
PROPOSAL_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assign)      MODE="assign"; shift ;;
    --promote)     MODE="promote"; shift ;;
    --evaluate)    MODE="evaluate"; shift ;;
    --revert)      MODE="revert"; shift ;;
    --task-id)     TASK_ID="$2"; shift 2 ;;
    --proposal-id) PROPOSAL_ID="$2"; shift 2 ;;
    -h|--help)
      printf -- 'Usage: %s --assign  --task-id <id>\n' "$(basename "$0")" >&2
      printf -- '       %s --promote --proposal-id <sha1>\n' "$(basename "$0")" >&2
      printf -- '       %s --evaluate --proposal-id <sha1>\n' "$(basename "$0")" >&2
      printf -- '       %s --revert  --proposal-id <sha1>\n' "$(basename "$0")" >&2
      exit 0
      ;;
    *) log_error "unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  log_error "mode required: --assign | --promote | --evaluate | --revert"
  exit 2
fi

# D6 guard: absent LEADV2_SHADOW_ON_CLOSE leaves existing flow byte-identical.
# --assign is exempt (only writes arm to context.yaml, no mutation side-effect).
if [[ "$MODE" != "assign" && "${LEADV2_SHADOW_ON_CLOSE:-0}" != "1" ]]; then
  log "LEADV2_SHADOW_ON_CLOSE not set -- skipping shadow op (D6)"
  exit 0
fi

# ── ASSIGN mode ───────────────────────────────────────────────────────────────
# Write arm to context.yaml at task-init. Deterministic: hash(task_id)%2 -> A|B.
# Resolves C-critical-5 (R11): provides the join key read back by scorecard-write.
if [[ "$MODE" == "assign" ]]; then
  [[ -z "$TASK_ID" ]] && { log_error "--task-id required for --assign"; exit 2; }

  CONTEXT_YAML="${LEADV2_PROJECT_ROOT}/docs/handoff/${TASK_ID}/context.yaml"
  if [[ ! -f "$CONTEXT_YAML" ]]; then
    log "context.yaml not found: ${CONTEXT_YAML} -- skipping arm assign"
    exit 0
  fi

  ARM=$(python3 -c "
import sys, hashlib
task_id = sys.argv[1]
h = int(hashlib.sha1(task_id.encode()).hexdigest(), 16)
print('A' if h % 2 == 0 else 'B')
" "$TASK_ID")

  # Check if arm already written (idempotent)
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
sys.exit(0 if d.get('arm') else 1)
" "$CONTEXT_YAML" 2>/dev/null; then
    EXISTING_ARM=$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])) or {}; print(d.get('arm',''))" "$CONTEXT_YAML" 2>/dev/null || echo "")
    log "arm already assigned: ${EXISTING_ARM} for task ${TASK_ID} -- skipping (idempotent)"
    exit 0
  fi

  # Append arm field to context.yaml (format-preserving: append, not full yaml.dump)
  TMP_CTX="$(mktemp "${CONTEXT_YAML}.tmp.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$TMP_CTX'" RETURN
  python3 - "$CONTEXT_YAML" "$ARM" "$TMP_CTX" << 'PYEOF'
import sys
ctx_path, arm, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(ctx_path) as f:
    content = f.read()
# Append arm field (preserves existing content, avoids full yaml.dump churn)
if '\narm:' not in content and not content.startswith('arm:'):
    content = content.rstrip('\n') + f'\narm: {arm}\n'
with open(out_path, 'w') as f:
    f.write(content)
PYEOF
  mv -f "$TMP_CTX" "$CONTEXT_YAML"
  log_ok "arm=${ARM} assigned to context.yaml for task=${TASK_ID}"
  exit 0
fi

# ── helpers for proposal-id modes ────────────────────────────────────────────
[[ -z "$PROPOSAL_ID" ]] && { log_error "--proposal-id required for --${MODE}"; exit 2; }

PROPOSAL_FILE="${PROPOSALS_DIR}/${PROPOSAL_ID}.yaml"
PROPOSAL_LOCK="${PROPOSALS_DIR}/${PROPOSAL_ID}.lock"

# Validate proposal id format (sha1)
if ! printf -- '%s' "$PROPOSAL_ID" | grep -qE '^[0-9a-f]{40}$'; then
  log_error "invalid proposal id (must be 40-char hex sha1): ${PROPOSAL_ID}"
  exit 2
fi

[[ ! -f "$PROPOSAL_FILE" ]] && { log_error "proposal file not found: ${PROPOSAL_FILE}"; exit 1; }

# Read proposal JSON via python (single parse pass)
PROPOSAL_JSON=$(python3 -c "
import sys, yaml, json
p = yaml.safe_load(open(sys.argv[1])) or {}
print(json.dumps(p))
" "$PROPOSAL_FILE")

_prop() {
  python3 -c "import sys,json; d=json.loads(sys.argv[1]); v=d.get(sys.argv[2]); print(v if v is not None else '')" \
    "$PROPOSAL_JSON" "$1"
}

PROP_STATUS=$(_prop status)
PROP_RISK=$(_prop risk_level)
PROP_TARGET=$(_prop target_file)
PROP_PATCH=$(_prop diff_patch)
PROP_KIND=$(_prop kind)
PROP_TASK_ID=$(_prop task_id)

# ── EVALUATE mode ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "evaluate" ]]; then
  log "evaluating proposal ${PROPOSAL_ID} (task=${PROP_TASK_ID} kind=${PROP_KIND} risk=${PROP_RISK})"

  if [[ "$PROP_RISK" == "high" ]]; then
    log "high-risk proposal -> founder_gated"
    exit 5
  fi

  SCORECARD_FILE="${LEADV2_PROJECT_ROOT}/docs/leadv2/scorecard.jsonl"
  MIN_N=$(_prop min_n_per_arm)
  : "${MIN_N:=5}"

  if [[ -f "$SCORECARD_FILE" ]]; then
    python3 - "$SCORECARD_FILE" "$MIN_N" << 'PYEOF'
import sys, json
scorecard_path, min_n_str = sys.argv[1], sys.argv[2]
min_n = int(min_n_str)
arm_counts = {'A': 0, 'B': 0}
with open(scorecard_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        arm = obj.get('shadow_arm')
        if arm in arm_counts:
            arm_counts[arm] += 1
min_arm = min(arm_counts.values())
if min_arm < min_n:
    print(f"INCONCLUSIVE: min arm count {min_arm} < min_n={min_n} -- extend, do not promote", file=sys.stderr)
    sys.exit(1)
print(f"OK: arm counts {arm_counts} >= min_n={min_n}")
PYEOF
    EV_RC=$?
    if [[ $EV_RC -ne 0 ]]; then
      log "inconclusive -- min_n_per_arm not met; extend shadow period"
      exit 0
    fi
  fi

  log_ok "proposal ${PROPOSAL_ID} ready for promotion"
  exit 0
fi

# ── PROMOTE mode ──────────────────────────────────────────────────────────────
# Must be called at Phase 8 Close only, after scorecard-write (D4/G3b spec).
if [[ "$MODE" == "promote" ]]; then
  if [[ "$PROP_STATUS" == "promoted" || "$PROP_STATUS" == "reverted" ]]; then
    log "proposal already in terminal state (${PROP_STATUS}) -- skipping (idempotent)"
    exit 3
  fi

  # High-risk: set founder_gated and emit to learning-proposals/ (D3/G3b)
  if [[ "$PROP_RISK" == "high" ]]; then
    log "high-risk proposal -- setting status=founder_gated and emitting to learning-proposals/"
    (
      flock -x 9 || { log_error "could not acquire proposal lock"; exit 1; }
      python3 - "$PROPOSAL_FILE" << 'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    p = yaml.safe_load(f) or {}
p['status'] = 'founder_gated'
with open(path, 'w') as f:
    yaml.dump(p, f, default_flow_style=False, sort_keys=False)
PYEOF
    ) 9>"$PROPOSAL_LOCK"
    mkdir -p "$LEARNING_PROPOSALS_DIR"
    cp "$PROPOSAL_FILE" "${LEARNING_PROPOSALS_DIR}/${PROPOSAL_ID}.yaml"
    log_ok "proposal ${PROPOSAL_ID} -> founder_gated; copied to learning-proposals/"
    exit 5
  fi

  # DRY_RUN guard (D5) -- must be called at a side-effect entrypoint
  if leadv2_dry_run_guard "shadow-apply --promote proposal=${PROPOSAL_ID}" 2>/dev/null; then
    log "DRY_RUN: promote blocked -- no mutations applied"
    exit 0
  fi

  # Run eval-harness first (D7): block if any golden fails
  if [[ "${LEADV2_EVAL_HARNESS_ON:-0}" == "1" && -f "$EVAL_HARNESS" ]]; then
    log "running eval-harness before promote..."
    set +e
    bash "$EVAL_HARNESS"
    HARNESS_RC=$?
    set -e
    if [[ $HARNESS_RC -ne 0 && $HARNESS_RC -ne 4 ]]; then
      log_error "eval-harness FAILED (exit ${HARNESS_RC}) -- blocking promotion"
      (
        flock -x 9 || { log_error "could not acquire proposal lock"; exit 1; }
        python3 - "$PROPOSAL_FILE" << 'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    p = yaml.safe_load(f) or {}
p['status'] = 'blocked_by_eval'
with open(path, 'w') as f:
    yaml.dump(p, f, default_flow_style=False, sort_keys=False)
PYEOF
      ) 9>"$PROPOSAL_LOCK"
      exit 4
    fi
    log_ok "eval-harness passed"
  fi

  # flock -x on proposal file before any state transition (R4)
  (
    flock -x 9 || { log_error "could not acquire proposal lock"; exit 1; }

    # Re-read status inside lock (race protection)
    CURRENT_STATUS=$(python3 -c "import yaml,sys; p=yaml.safe_load(open(sys.argv[1])) or {}; print(p.get('status',''))" "$PROPOSAL_FILE" 2>/dev/null || echo "")
    if [[ "$CURRENT_STATUS" == "promoted" || "$CURRENT_STATUS" == "reverted" ]]; then
      log "proposal reached terminal state concurrently -- skipping"
      exit 3
    fi

    # Resolve absolute target path
    TARGET_ABS="${LEADV2_PROJECT_ROOT}/${PROP_TARGET}"
    if [[ ! -f "$TARGET_ABS" ]]; then
      log_error "target file not found: ${TARGET_ABS}"
      exit 1
    fi

    # Compute snapshot filename from proposal id sha1
    SNAP_SHA=$(python3 -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest())" "$PROPOSAL_ID")
    SNAP_FILE="${SNAPSHOTS_DIR}/${SNAP_SHA}.bak"

    # Write before_snapshot BEFORE any mutation (D7/R8 -- resolves C-critical-1)
    mkdir -p "$SNAPSHOTS_DIR"
    cp -p "$TARGET_ABS" "$SNAP_FILE"
    log "before_snapshot written: ${SNAP_FILE}"

    # Update before_snapshot path + status in proposal
    python3 - "$PROPOSAL_FILE" "$SNAP_FILE" << 'PYEOF'
import sys, yaml
path, snap = sys.argv[1], sys.argv[2]
with open(path) as f:
    p = yaml.safe_load(f) or {}
p['before_snapshot'] = snap
p['status'] = 'shadow_active'
with open(path, 'w') as f:
    yaml.dump(p, f, default_flow_style=False, sort_keys=False)
PYEOF

    # Validate YAML front matter BEFORE apply if target is .md (C-medium-3/R18)
    if [[ "$TARGET_ABS" == *.md ]]; then
      python3 - "$TARGET_ABS" << 'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
if content.startswith('---'):
    m = re.match(r'^---\r?\n(.*?)\r?\n---', content, re.DOTALL)
    if not m:
        print(f"YAML front matter malformed in {sys.argv[1]}", file=sys.stderr)
        sys.exit(1)
    import yaml as _yaml
    try:
        _yaml.safe_load(m.group(1))
    except _yaml.YAMLError as e:
        print(f"YAML front matter invalid: {e}", file=sys.stderr)
        sys.exit(1)
PYEOF
    fi

    # Apply diff_patch
    PATCH_TMP="$(mktemp /tmp/shadow-patch-XXXXXX.diff)"
    printf -- '%s\n' "$PROP_PATCH" > "$PATCH_TMP"

    PATCH_OK=0
    if patch -p1 --dry-run -i "$PATCH_TMP" -d "$LEADV2_PROJECT_ROOT" >/dev/null 2>&1; then
      patch -p1 -i "$PATCH_TMP" -d "$LEADV2_PROJECT_ROOT"
      PATCH_OK=1
    else
      log_error "patch --dry-run failed for proposal ${PROPOSAL_ID}"
    fi
    rm -f "$PATCH_TMP"

    if [[ $PATCH_OK -eq 1 ]]; then
      # Validate YAML front matter post-apply if target is .md
      if [[ "$TARGET_ABS" == *.md ]]; then
        if ! python3 - "$TARGET_ABS" << 'PYEOF' 2>/dev/null
import sys, re, yaml as _yaml
content = open(sys.argv[1]).read()
if content.startswith('---'):
    m = re.match(r'^---\r?\n(.*?)\r?\n---', content, re.DOTALL)
    if not m: sys.exit(1)
    try: _yaml.safe_load(m.group(1))
    except: sys.exit(1)
PYEOF
        then
          log_error "post-apply YAML front matter invalid -- reverting"
          cp -p "$SNAP_FILE" "$TARGET_ABS"
          PATCH_OK=0
        fi
      fi
    fi

    if [[ $PATCH_OK -eq 1 ]]; then
      # Strip shadow marker comments (R5 -- no orphan markers)
      python3 - "$TARGET_ABS" "$PROPOSAL_ID" << 'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()
cleaned = re.sub(r'\n# leadv2-shadow:[^\n]*', '', content)
if cleaned != content:
    open(path, 'w').write(cleaned)
PYEOF

      python3 - "$PROPOSAL_FILE" << 'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    p = yaml.safe_load(f) or {}
p['status'] = 'promoted'
with open(path, 'w') as f:
    yaml.dump(p, f, default_flow_style=False, sort_keys=False)
PYEOF
      log_ok "proposal ${PROPOSAL_ID} promoted -> status=promoted"
    else
      python3 - "$PROPOSAL_FILE" << 'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    p = yaml.safe_load(f) or {}
p['status'] = 'reverted'
with open(path, 'w') as f:
    yaml.dump(p, f, default_flow_style=False, sort_keys=False)
PYEOF
      log_error "patch failed -- proposal ${PROPOSAL_ID} reverted -> status=reverted"
      exit 1
    fi
  ) 9>"$PROPOSAL_LOCK"
  exit 0
fi

# ── REVERT mode ───────────────────────────────────────────────────────────────
# Restore before_snapshot; verify sha1; delete snapshot on success (D7/R8).
if [[ "$MODE" == "revert" ]]; then
  if [[ "$PROP_STATUS" == "reverted" ]]; then
    log "proposal already reverted -- skipping (idempotent)"
    exit 3
  fi

  # DRY_RUN guard (D5)
  if leadv2_dry_run_guard "shadow-apply --revert proposal=${PROPOSAL_ID}" 2>/dev/null; then
    log "DRY_RUN: revert blocked -- no mutations applied"
    exit 0
  fi

  # Run eval-harness before revert (D7: both promote AND revert gated)
  if [[ "${LEADV2_EVAL_HARNESS_ON:-0}" == "1" && -f "$EVAL_HARNESS" ]]; then
    log "running eval-harness before revert..."
    set +e
    bash "$EVAL_HARNESS"
    HARNESS_RC=$?
    set -e
    if [[ $HARNESS_RC -ne 0 && $HARNESS_RC -ne 4 ]]; then
      log_error "eval-harness FAILED (exit ${HARNESS_RC}) -- blocking revert"
      (
        flock -x 9 || { log_error "could not acquire proposal lock"; exit 1; }
        python3 - "$PROPOSAL_FILE" << 'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    p = yaml.safe_load(f) or {}
p['status'] = 'blocked_by_eval'
with open(path, 'w') as f:
    yaml.dump(p, f, default_flow_style=False, sort_keys=False)
PYEOF
      ) 9>"$PROPOSAL_LOCK"
      exit 4
    fi
    log_ok "eval-harness passed (revert)"
  fi

  (
    flock -x 9 || { log_error "could not acquire proposal lock"; exit 1; }

    SNAP_FILE=$(python3 -c "
import sys, yaml
p = yaml.safe_load(open(sys.argv[1])) or {}
print(p.get('before_snapshot', ''))
" "$PROPOSAL_FILE")

    TARGET_ABS="${LEADV2_PROJECT_ROOT}/${PROP_TARGET}"

    if [[ -z "$SNAP_FILE" || ! -f "$SNAP_FILE" ]]; then
      log_error "before_snapshot not found: '${SNAP_FILE}' -- cannot revert ${PROPOSAL_ID}"
      exit 1
    fi

    # sha1 checksum before restore
    SNAP_SHA_ACTUAL=$(shasum -a 1 "$SNAP_FILE" | awk '{print $1}')
    log "restoring from snapshot ${SNAP_FILE} (sha1=${SNAP_SHA_ACTUAL})"

    cp -p "$SNAP_FILE" "$TARGET_ABS"

    # Strip any shadow markers left in target after revert (R5)
    python3 - "$TARGET_ABS" << 'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()
cleaned = re.sub(r'\n# leadv2-shadow:[^\n]*', '', content)
if cleaned != content:
    open(path, 'w').write(cleaned)
PYEOF

    # Verify sha1 matches after restore
    RESTORED_SHA=$(shasum -a 1 "$TARGET_ABS" | awk '{print $1}')
    if [[ "$SNAP_SHA_ACTUAL" != "$RESTORED_SHA" ]]; then
      log_error "sha1 mismatch after restore: snap=${SNAP_SHA_ACTUAL} restored=${RESTORED_SHA}"
      exit 1
    fi

    # Delete snapshot on success (D7)
    rm -f "$SNAP_FILE"
    log "snapshot deleted after successful restore"

    python3 - "$PROPOSAL_FILE" << 'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    p = yaml.safe_load(f) or {}
p['status'] = 'reverted'
with open(path, 'w') as f:
    yaml.dump(p, f, default_flow_style=False, sort_keys=False)
PYEOF
    log_ok "proposal ${PROPOSAL_ID} reverted -> status=reverted"
  ) 9>"$PROPOSAL_LOCK"
  exit 0
fi

log_error "unhandled mode: ${MODE}"
exit 2
