#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-temp.sh"
# leadv2-cost-flush.sh — post-hoc cost recorder for async subsessions.
# W6-fix: when claude-subsession.sh runs in async mode (no --wait), the inline
# cost-recorder subshell may not fire if the parent process exits first.
# This script finds any .cost-pending.yaml marker files left by async sessions,
# recomputes costs from the stream file, appends to costs.yaml, then removes marker.
#
# Usage:
#   bash .claude/scripts/leadv2-cost-flush.sh [<handoff_dir>]
#
# Without args: scans ALL docs/handoff/ subdirs for pending markers.
# With arg: scans only that specific handoff dir.
#
# Call from daemon after each task completes:
#   bash .claude/scripts/leadv2-cost-flush.sh "docs/handoff/$TASK_ID"

readonly PRICE_OPUS_INPUT=15
readonly PRICE_OPUS_OUTPUT=75
readonly PRICE_SONNET_INPUT=3
readonly PRICE_SONNET_OUTPUT=15
# G1c: Haiku and Fable pricing tiers (resolves D8 / C-low-1)
readonly PRICE_HAIKU_INPUT=0.80
readonly PRICE_HAIKU_OUTPUT=4.00
# Fable 5 (claude-fable-5) — priced at Sonnet tier until official pricing confirmed
readonly PRICE_FABLE_INPUT=3
readonly PRICE_FABLE_OUTPUT=15

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

log() { printf -- '[%s] leadv2-cost-flush: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

flush_marker() {
  local marker_file="$1"
  [[ -f "$marker_file" ]] || return 0

  local session_id role model stream_file start_epoch handoff_dir
  session_id=$(grep '^session_id:' "$marker_file" | awk '{print $2}' | xargs)
  role=$(grep '^role:' "$marker_file" | awk '{print $2}' | xargs)
  model=$(grep '^model:' "$marker_file" | awk '{print $2}' | xargs)
  stream_file=$(grep '^stream_file:' "$marker_file" | awk '{print $2}' | xargs)
  start_epoch=$(grep '^start_epoch:' "$marker_file" | awk '{print $2}' | xargs)
  handoff_dir=$(grep '^handoff_dir:' "$marker_file" | awk '{print $2}' | xargs)

  if [[ -z "$session_id" || -z "$stream_file" || -z "$handoff_dir" ]]; then
    log "WARN: malformed marker $marker_file — skipping"
    return 0
  fi

  if [[ ! -f "$stream_file" ]]; then
    log "WARN: stream file not found for $role/$session_id — skipping"
    rm -f "$marker_file"
    return 0
  fi

  log "flushing cost for $role/$model session=$session_id"

  local py_helper
  py_helper=$(lv2_mktemp_file "cost-flush" "py")
  # shellcheck disable=SC2064
  trap "rm -f '$py_helper'" RETURN

  cat > "$py_helper" <<'PYEOF'
import sys, json, math
from datetime import datetime, timezone

stream_file, model, role, session_id, start_epoch = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
price_opus_in,  price_opus_out  = float(sys.argv[6]),  float(sys.argv[7])
price_son_in,   price_son_out   = float(sys.argv[8]),  float(sys.argv[9])
price_haiku_in, price_haiku_out = float(sys.argv[10]), float(sys.argv[11])
price_fable_in, price_fable_out = float(sys.argv[12]), float(sys.argv[13])

total_in = total_out = 0
try:
    with open(stream_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            usage = obj.get("usage") or (obj.get("message", {}) or {}).get("usage") or {}
            if not usage and "input_tokens" in obj:
                usage = obj
            in_t  = int(usage.get("input_tokens", 0))
            out_t = int(usage.get("output_tokens", 0))
            if in_t  > total_in:  total_in  = in_t
            if out_t > total_out: total_out = out_t
except Exception as e:
    print(f"PARSE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)

m = model.lower()
if "opus" in m:
    p_in, p_out = price_opus_in, price_opus_out
elif "haiku" in m:
    p_in, p_out = price_haiku_in, price_haiku_out
elif "fable" in m:
    p_in, p_out = price_fable_in, price_fable_out
else:
    p_in, p_out = price_son_in, price_son_out
cost = (total_in * p_in + total_out * p_out) / 1_000_000
duration = int(math.floor(datetime.now(timezone.utc).timestamp() - start_epoch))
ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(f"OK {total_in} {total_out} {cost:.6f} {duration} {ts}")
PYEOF

  local result
  result=$(python3 "$py_helper" \
    "$stream_file" "$model" "$role" "$session_id" "$start_epoch" \
    "$PRICE_OPUS_INPUT"   "$PRICE_OPUS_OUTPUT" \
    "$PRICE_SONNET_INPUT" "$PRICE_SONNET_OUTPUT" \
    "$PRICE_HAIKU_INPUT"  "$PRICE_HAIKU_OUTPUT" \
    "$PRICE_FABLE_INPUT"  "$PRICE_FABLE_OUTPUT" 2>/dev/null) || result="PARSE_ERROR"

  if [[ "$result" == "PARSE_ERROR"* ]] || [[ -z "$result" ]]; then
    log "WARN: cost parse failed for $role — marker kept for retry"
    return 0
  fi

  local _ok input_tokens output_tokens cost_usd duration_sec timestamp
  read -r _ok input_tokens output_tokens cost_usd duration_sec timestamp <<< "$result"

  local costs_file="$handoff_dir/costs.yaml"
  local lock_file="$handoff_dir/.cost-flush.lock"

  # H5 fix: acquire exclusive lock before append + marker-delete.
  # This makes the operation idempotent: if session_id already exists in
  # costs_file we skip the append. Marker is deleted inside the same lock
  # so concurrent retries see a consistent state.
  # F-E fix-round-2: bounded wait (was unbounded flock -x 9 — the third
  # costs.yaml writer missed the H1/H4 timeout treatment). On timeout,
  # log-and-skip — marker file is left in place for the next flush pass,
  # never a corrupting unlocked write.
  (
    flock -w "${LEADV2_LOCK_WAIT_SEC:-10}" -x 9 || { log "WARN: could not acquire flush lock for $handoff_dir within ${LEADV2_LOCK_WAIT_SEC:-10}s — skipping (marker kept for retry)"; exit 0; }

    # Idempotency check: skip if session_id already recorded
    if [[ -f "$costs_file" ]] && python3 -c "
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or []
rows = data if isinstance(data, list) else []
sid = sys.argv[2]
sys.exit(0 if any(str(r.get('session_id','')) == sid for r in rows) else 1)
" "$costs_file" "$session_id" 2>/dev/null; then
      log "session $session_id already in costs.yaml — skipping duplicate flush"
      rm -f "$marker_file"
    else
      if [[ ! -f "$costs_file" ]]; then
        printf -- '# leadv2 cost telemetry — appended by leadv2-cost-flush.sh\n' > "$costs_file"
      fi

      printf -- '- role: %s\n  model: %s\n  session_id: %s\n  input_tokens: %s\n  output_tokens: %s\n  cost_usd: %s\n  duration_sec: %s\n  timestamp: %s\n  flushed_post_hoc: true\n' \
        "$role" "$model" "$session_id" \
        "$input_tokens" "$output_tokens" "$cost_usd" \
        "$duration_sec" "$timestamp" >> "$costs_file"

      log "cost flushed: ${role}/${model} in=${input_tokens} out=${output_tokens} usd=${cost_usd}"
      rm -f "$marker_file"
    fi
  ) 9>"$lock_file"
}

if [[ $# -ge 1 ]]; then
  # Scan specific handoff dir
  TARGET_DIR="$1"
  for m in "$TARGET_DIR"/*.cost-pending.yaml; do
    [[ -f "$m" ]] && flush_marker "$m"
  done
else
  # Scan all handoff dirs
  HANDOFF_ROOT="$PROJECT_ROOT/docs/handoff"
  if [[ -d "$HANDOFF_ROOT" ]]; then
    for m in "$HANDOFF_ROOT"/*/*.cost-pending.yaml; do
      [[ -f "$m" ]] && flush_marker "$m"
    done
  fi
fi

# ── Append real actual_usd to leadv2-cost-accuracy.yaml ─────────────────────
# When called with a specific handoff dir, sum costs.yaml and append to
# docs/leadv2-cost-accuracy.yaml so the feedback loop has real numbers.
if [[ $# -ge 1 ]]; then
  TARGET_DIR="$1"
  COSTS_FILE="$TARGET_DIR/costs.yaml"
  ACCURACY_FILE="$PROJECT_ROOT/docs/leadv2-cost-accuracy.yaml"

  # Derive task_id from dir name
  TASK_ID="$(basename "$TARGET_DIR")"

  # Sum actual_usd from costs.yaml (or 0 if missing/empty)
  # G1c: read cost_estimate.usd from context.yaml for error_usd computation (D8)
  CONTEXT_YAML_PATH="${LEADV2_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/docs/handoff/${TASK_ID}/context.yaml"
  ESTIMATE_USD="null"
  ERROR_USD="null"
  if [[ -f "$CONTEXT_YAML_PATH" ]]; then
    ESTIMATE_USD=$(python3 -c "
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    est = (d.get('cost_estimate') or {}).get('usd')
    print(float(est) if est is not None else 'null')
except Exception:
    print('null')
" "$CONTEXT_YAML_PATH" 2>/dev/null || printf -- 'null')
  fi

  ACTUAL_USD="0.0"
  NOTE_FIELD=""
  if [[ -f "$COSTS_FILE" ]]; then
    ACTUAL_USD=$(python3 - <<PYEOF
import sys, yaml
from pathlib import Path
try:
    rows = yaml.safe_load(Path("$COSTS_FILE").read_text()) or []
    if isinstance(rows, list):
        total = sum(float(r.get("cost_usd", 0)) for r in rows if isinstance(r, dict))
        print(f"{total:.6f}")
    else:
        print("0.0")
except Exception as e:
    print("0.0", file=sys.stderr)
    print("0.0")
PYEOF
) || ACTUAL_USD="0.0"
  else
    NOTE_FIELD='  note: "cost data unavailable — costs.yaml missing"'
  fi

  # Only append if accuracy file exists and task_id not already recorded
  if [[ -f "$ACCURACY_FILE" ]]; then
    if ! grep -q "task_id: $TASK_ID" "$ACCURACY_FILE" 2>/dev/null; then
      TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      {
        printf -- '\n- task_id: %s\n' "$TASK_ID"
        printf -- '  actual_usd: %s\n' "$ACTUAL_USD"
        # G1c: use real estimate + compute error_usd (D8)
        printf -- '  estimated_usd: %s\n' "$ESTIMATE_USD"
        if [[ "$ESTIMATE_USD" != "null" && "$ACTUAL_USD" != "0.0" ]]; then
          ERROR_USD=$(python3 -c "print(round(${ACTUAL_USD} - ${ESTIMATE_USD}, 6))" 2>/dev/null || printf -- 'null')
        fi
        printf -- '  error_usd: %s\n' "$ERROR_USD"
        printf -- '  timestamp: '"'"'%s'"'"'\n' "$TS"
        printf -- '  source: cost_aggregator\n'
        if [[ -n "${NOTE_FIELD:-}" ]]; then
          printf -- '%s\n' "$NOTE_FIELD"
        fi
      } >> "$ACCURACY_FILE"
      log "appended actual_usd=${ACTUAL_USD} for task=${TASK_ID} to cost-accuracy.yaml"
    else
      log "task=${TASK_ID} already in cost-accuracy.yaml — skipping append"
    fi
  fi
fi

log "done"
