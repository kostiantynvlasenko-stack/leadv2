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
#   6  held_by_regression_gate (T10: confirmed negmem match -- proposal NOT applied, status
#      left unchanged so it can be retried once the negmem match no longer holds)
#
# ENV:
#   LEADV2_PROJECT_ROOT              -- required; resolved from git toplevel when absent
#   LEADV2_SHADOW_ON_CLOSE           -- must be "1" to enable shadow ops; absent = skip (D6)
#   LEADV2_EVAL_HARNESS_ON           -- forwarded to eval-harness; "1" to run harness gate (D7)
#   LEADV2_DRY_RUN                   -- "1" = dry-run; skip mutations (D5)
#   LEADV2_REGRESSION_GATE           -- T10: "1" to enable negmem regression gate on --promote;
#                                        default 0 = byte-identical to pre-T10 behavior
#   LEADV2_REGRESSION_GATE_THRESHOLD -- T10: negmem match score (0.0-1.0) required for a
#                                        CONFIRMED match; default 0.5
#
# DECISIONS: D1 D3 D4 D5 D6 D7 D10; R4 flock; R8 snapshot; R9 risk_level

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-temp.sh"

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
log_warn()  { log "WARN: $*"; }

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

  # Run taskbench_gate before promote (T9 SHADOW-PROMOTION-GATE-01): a real quality-benchmark
  # verdict on top of the golden-fixture regression check above (EVAL-HARNESS-01 design section 4).
  # LEADV2_TASKBENCH_ON unset/0 -> this entire block is skipped, byte-identical to pre-diff.
  # STRICT ALLOW-LIST (founder-confirmed, fix-round 1): promote ONLY on a cleanly-parsed
  # verdict=="PROMOTE" (design section 4: "--promote requires verdict==PROMOTE"). Every other
  # outcome -- REJECT, INCONCLUSIVE, empty/unparsable JSON, gate script absent, jq missing,
  # sourcing error, timeout -- HOLDS (does not promote, does not mutate the target). Accepted
  # consequence: with the flag ON and no benchmark feeder producing real PROMOTE verdicts, ALL
  # promotions HOLD (gate intentionally DORMANT until fed) -- flag stays default-OFF so nothing
  # changes unless deliberately enabled. Candidate/proposal data passed via argv only -- never
  # spliced into a shell string / eval / backticks (no injection). `timeout -k` hard-kills a gate
  # that ignores SIGTERM so it can never hang this command substitution.
  if [[ "${LEADV2_TASKBENCH_ON:-0}" == "1" ]]; then
    _taskbench_hold() {
      local reason="$1"
      rm -f "${TB_TMP:-}"
      log_error "taskbench_gate HOLD: held: ${reason}"
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
    }

    TASKBENCH_GATE_SCRIPT="${LEADV2_TASKBENCH_GATE_SCRIPT:-${LEADV2_PROJECT_ROOT}/.claude/scripts/leadv2-taskbench-gate.sh}"

    if ! command -v jq >/dev/null 2>&1; then
      _taskbench_hold "gate misconfigured (jq not found on PATH)"
    fi
    if [[ ! -f "$TASKBENCH_GATE_SCRIPT" ]]; then
      _taskbench_hold "gate misconfigured (script not found: ${TASKBENCH_GATE_SCRIPT})"
    fi

    log "running taskbench_gate before promote..."
    TB_BASE_RUN_ID=$(_prop benchmark_base_run_id)
    TB_CAND_RUN_ID=$(_prop benchmark_cand_run_id)
    : "${TB_BASE_RUN_ID:=baseline}"
    : "${TB_CAND_RUN_ID:=$PROPOSAL_ID}"

    # CRITICAL fix (fix-round 2): do NOT capture gate stdout via $(...) -- `timeout` only tracks
    # its direct child, so a gate that backgrounds a job inheriting fd 1 (e.g. `( sleep 10 ) &`)
    # before returning leaves `$(...)` blocked on the pipe until that orphaned grandchild closes
    # fd 1, potentially forever, even though `timeout`/the gate itself already finished. Redirect
    # to a system-tmp temp file instead (never a proposal-influenced path) and read the file --
    # regular-file reads do not block on lingering pipe writers.
    TB_TMP="$(mktemp 2>/dev/null)" || TB_TMP=""
    if [[ -z "$TB_TMP" ]]; then
      _taskbench_hold "gate misconfigured (mktemp unavailable)"
    fi
    set +e
    timeout -k 5s 30s bash -c 'source "$1"; taskbench_gate "$2" "$3"' _ \
      "$TASKBENCH_GATE_SCRIPT" "$TB_BASE_RUN_ID" "$TB_CAND_RUN_ID" > "$TB_TMP" 2>/dev/null
    TB_GATE_RC=$?
    set -e
    TB_GATE_JSON=$(cat "$TB_TMP" 2>/dev/null || true)
    rm -f "$TB_TMP"

    # `timeout`'s reported exit code for a killed child varies by platform/implementation:
    # 124 (GNU documented default), or 128+signal (137 SIGKILL / 143 SIGTERM) when the child
    # doesn't self-report -- observed 137 in local testing. Treat all three as "timed out".
    if [[ $TB_GATE_RC -eq 124 || $TB_GATE_RC -eq 137 || $TB_GATE_RC -eq 143 ]]; then
      _taskbench_hold "gate misconfigured (timeout -- taskbench_gate did not return within 30s, force-killed via -k)"
    elif [[ $TB_GATE_RC -ne 0 || -z "$TB_GATE_JSON" ]]; then
      _taskbench_hold "gate misconfigured (sourcing/exec error, rc=${TB_GATE_RC})"
    fi

    TB_VERDICT=$(printf -- '%s' "$TB_GATE_JSON" | jq -r '.verdict // empty' 2>/dev/null || true)
    TB_REASON=$(printf -- '%s' "$TB_GATE_JSON" | jq -r '.reason // empty' 2>/dev/null || true)

    case "$TB_VERDICT" in
      PROMOTE)
        log_ok "taskbench_gate PROMOTE (${TB_REASON}) -- promotion allowed"
        ;;
      REJECT)
        _taskbench_hold "verdict=REJECT (measured regression) -- ${TB_REASON}"
        ;;
      INCONCLUSIVE)
        _taskbench_hold "verdict=INCONCLUSIVE (no benchmark result -- gate dormant until fed) -- ${TB_REASON}"
        ;;
      *)
        _taskbench_hold "gate misconfigured (empty/unparsable verdict, raw='${TB_GATE_JSON}')"
        ;;
    esac
  fi

  # T10 PROPOSAL-REGRESSION-GATE-01: THIRD, independent gate on the same apply flow (after
  # T9's taskbench_gate above), keyed on negative-memory (immune-patterns.yaml) instead of a
  # taskbench verdict. Reaching this point already means the high-risk/founder-gate
  # short-circuit above did NOT fire for this proposal (see discovery.md #1) -- i.e. this
  # gate runs strictly AFTER any founder-approval checkpoint the script performs. Fail-mode is
  # therefore the OPPOSITE of T9: fail-OPEN-with-warn, not fail-safe -- a hard-hold on
  # negmem-unavailable would freeze all governance for proposals that are already
  # founder-gated by construction. LEADV2_REGRESSION_GATE unset/0 -> this entire block is
  # skipped, byte-identical to pre-T10 behavior (flag default 0).
  #
  # HOLD (skip the mutation, exit 6) ONLY on a CONFIRMED negmem match (score >= threshold).
  # Every other outcome -- no match, low score, empty/derivable-signature, lookup script
  # missing, timeout, non-zero exit, unparsable YAML -- PROCEEDS with a loud log_warn.
  #
  # No injection: the proposal-derived signature and immune-lookup's YAML output are UNTRUSTED
  # DATA -- passed as argv / read from a tempfile only, never spliced into a shell string /
  # eval / backticks. Bounded with `timeout -k 5s 30s` and the tempfile-capture idiom (NOT
  # `$(...)`) -- see T9's fix-round-2 comment above for why a stdout-inheriting grandchild can
  # wedge a command-substitution pipe. Durable-root resolution is delegated entirely to
  # leadv2-immune-lookup.sh's own resolver (LEADV2_PROJECT_ROOT-aware, never --show-toplevel);
  # this block never re-derives a root itself.
  REGRESSION_GATE_HELD=0
  if [[ "${LEADV2_REGRESSION_GATE:-0}" == "1" ]]; then
    REGRESSION_GATE_THRESHOLD="${LEADV2_REGRESSION_GATE_THRESHOLD:-0.5}"
    IMMUNE_LOOKUP_SCRIPT="${SCRIPT_DIR}/leadv2-immune-lookup.sh"

    # Derive pattern signature from proposal fields (discovery.md #3): representative_summary
    # is the primary signature for cross-repo-pattern proposals; fall back through title /
    # keywords / kind so non-cross-repo kinds (which lack these fields) degrade to an empty
    # signature rather than erroring -- handled as the "no signature" fail-open case below.
    RG_SIG=$(python3 -c "
import sys, json
d = json.loads(sys.argv[1])
candidates = [
    str(d.get('representative_summary') or ''),
    str(d.get('title') or ''),
    ' '.join(d.get('keywords') or []),
    str(d.get('kind') or ''),
]
for c in candidates:
    if c.strip():
        print(c.strip())
        break
" "$PROPOSAL_JSON" 2>/dev/null || true)

    if [[ -z "$RG_SIG" ]]; then
      log_warn "regression-gate: no derivable pattern signature for proposal ${PROPOSAL_ID} -- proceeding"
    elif [[ ! -f "$IMMUNE_LOOKUP_SCRIPT" ]]; then
      log_warn "regression-gate: lookup unavailable (script not found: ${IMMUNE_LOOKUP_SCRIPT}) -- proceeding"
    else
      RG_TMP="$(mktemp 2>/dev/null)" || RG_TMP=""
      if [[ -z "$RG_TMP" ]]; then
        log_warn "regression-gate: lookup unavailable (mktemp failed) -- proceeding"
      else
        set +e
        timeout -k 5s 30s bash "$IMMUNE_LOOKUP_SCRIPT" "$RG_SIG" > "$RG_TMP" 2>/dev/null
        RG_RC=$?
        set -e
        RG_YAML=$(cat "$RG_TMP" 2>/dev/null || true)
        rm -f "$RG_TMP"

        if [[ $RG_RC -eq 124 || $RG_RC -eq 137 || $RG_RC -eq 143 ]]; then
          log_warn "regression-gate: lookup unavailable (timeout -- immune-lookup did not return within 30s, force-killed via -k) -- proceeding"
        elif [[ $RG_RC -ne 0 || -z "$RG_YAML" ]]; then
          log_warn "regression-gate: lookup unavailable (rc=${RG_RC}, empty output) -- proceeding"
        else
          RG_RESULT=$(python3 -c "
import sys, yaml
try:
    d = yaml.safe_load(sys.argv[1]) or {}
    matches = d.get('matches')
    if not isinstance(matches, list) or not matches:
        print('NO_MATCH')
    else:
        top = matches[0]
        print(f\"{top.get('score', 0.0)}|{top.get('id','')}|{top.get('summary','')}\")
except Exception:
    print('UNPARSABLE')
" "$RG_YAML" 2>/dev/null || echo "UNPARSABLE")

          if [[ "$RG_RESULT" == "UNPARSABLE" ]]; then
            log_warn "regression-gate: immune-lookup output unparsable -- proceeding"
          elif [[ "$RG_RESULT" == "NO_MATCH" ]]; then
            log_warn "regression-gate: no negmem match for proposal ${PROPOSAL_ID} -- proceeding"
          else
            RG_SCORE="${RG_RESULT%%|*}"
            RG_REST="${RG_RESULT#*|}"
            RG_MATCH_ID="${RG_REST%%|*}"
            RG_MATCH_SUMMARY="${RG_REST#*|}"
            # Fix-round-1 #2: reject a malformed score (e.g. "0.9junk") BEFORE the numeric
            # compare -- awk's `s+0` would silently coerce it to 0.9 and produce a spurious
            # HOLD, violating fail-open. Strict float regex, optional leading '-'.
            RG_NUM_RE='^-?[0-9]+(\.[0-9]+)?$'
            if ! [[ "$RG_SCORE" =~ $RG_NUM_RE ]]; then
              log_warn "regression-gate: non-numeric score from immune-lookup (${RG_SCORE}) -- proceeding"
            else
              # Fix-round-1 #3: a misconfigured (non-numeric) threshold must fall back to the
              # 0.5 default rather than coerce to 0 (which would HOLD on any non-empty match).
              if ! [[ "$REGRESSION_GATE_THRESHOLD" =~ $RG_NUM_RE ]]; then
                log_warn "regression-gate: non-numeric LEADV2_REGRESSION_GATE_THRESHOLD (${REGRESSION_GATE_THRESHOLD}) -- falling back to default 0.5"
                REGRESSION_GATE_THRESHOLD="0.5"
              fi
              RG_ABOVE=$(awk -v s="$RG_SCORE" -v t="$REGRESSION_GATE_THRESHOLD" 'BEGIN{print (s+0 >= t+0) ? "1" : "0"}' 2>/dev/null || echo "0")
              if [[ "$RG_ABOVE" == "1" ]]; then
                REGRESSION_GATE_HELD=1
                log_error "regression-gate HELD: proposal ${PROPOSAL_ID} matches KNOWN-FAILED negmem pattern ${RG_MATCH_ID} (\"${RG_MATCH_SUMMARY}\", score=${RG_SCORE} >= threshold=${REGRESSION_GATE_THRESHOLD}) -- not applied"
              else
                log_warn "regression-gate: negmem match below threshold (score=${RG_SCORE} < ${REGRESSION_GATE_THRESHOLD}) for proposal ${PROPOSAL_ID} -- proceeding"
              fi
            fi
          fi
        fi
      fi
    fi
  fi

  if [[ "$REGRESSION_GATE_HELD" == "1" ]]; then
    exit 6
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

    # GOVAPPLY-GUARD-01: refuse to apply if target_file drifted since proposal generation
    # (compares live sha256 against the proposal's recorded target_sha256, when present --
    # proposals emitted before this feature have no target_sha256 and fall back to backup-only,
    # never a hard refusal); always writes a timestamped backup before we touch the target.
    # LEADV2_GOVAPPLY_NOGUARD=1 bypasses (guard warns to stderr).
    GOVAPPLY_GUARD="${SCRIPT_DIR}/leadv2-govapply-guard.sh"
    if [[ -f "$GOVAPPLY_GUARD" ]]; then
      PROP_TARGET_SHA256=$(_prop target_sha256)
      GUARD_ARGS=(--target "$TARGET_ABS")
      [[ -n "$PROP_TARGET_SHA256" ]] && GUARD_ARGS+=(--expected-sha256 "$PROP_TARGET_SHA256")
      set +e
      bash "$GOVAPPLY_GUARD" "${GUARD_ARGS[@]}"
      GOVAPPLY_RC=$?
      set -e
      if [[ $GOVAPPLY_RC -ne 0 ]]; then
        log_error "govapply-guard refused apply for proposal ${PROPOSAL_ID} (rc=${GOVAPPLY_RC}) -- target drifted or guard error"
        python3 - "$PROPOSAL_FILE" << 'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    p = yaml.safe_load(f) or {}
p['status'] = 'blocked_by_eval'
with open(path, 'w') as f:
    yaml.dump(p, f, default_flow_style=False, sort_keys=False)
PYEOF
        exit 1
      fi
    else
      log_warn "govapply-guard script not found (${GOVAPPLY_GUARD}) -- skipping drift/backup check"
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
    PATCH_TMP="$(lv2_mktemp_file "shadow-patch" "diff")"
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
