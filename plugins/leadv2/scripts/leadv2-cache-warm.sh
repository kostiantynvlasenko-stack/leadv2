#!/usr/bin/env bash
set -euo pipefail
# leadv2-cache-warm.sh — materialise Anthropic prompt-cache entry for a role/model prefix
# before a chain of spawns so all downstream spawns hit cache instead of paying creation cost.
#
# Usage:
#   leadv2-cache-warm.sh --role <critic|developer|architect|...> --model <sonnet|opus|haiku>
#
# Reads:  /tmp/leadv2-cache/<role>-<model>.prefix.md
# Writes: /tmp/leadv2-cache/.warm-log.json (tracks last-warm-ts per role-model)
# Stdout: YAML warm_result block
#
# Idempotent: skips if last warm was <4 min ago (Anthropic TTL=5 min).
# Graceful: exits 0 on missing prefix file or missing ANTHROPIC_API_KEY.

readonly CACHE_DIR="/tmp/leadv2-cache"
readonly WARM_LOG="${CACHE_DIR}/.warm-log.json"
readonly WARM_WINDOW_SEC=240   # 4 min (1 min buffer before 5-min TTL)

log()      { printf '[leadv2-cache-warm] %s\n' "$*" >&2; }
log_warn() { printf '[leadv2-cache-warm] WARN: %s\n' "$*" >&2; }

usage() {
  printf 'Usage: leadv2-cache-warm.sh --role <role> --model <sonnet|opus|haiku>\n' >&2
  exit 1
}

ROLE=""; MODEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)  ROLE="$2";  shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) log_warn "unknown arg: $1"; usage ;;
  esac
done

[[ -z "$ROLE" || -z "$MODEL" ]] && usage

mkdir -p "$CACHE_DIR"

# Idempotency check: skip if warmed <4min ago
KEY="${ROLE}-${MODEL}"
NOW=$(date +%s)

if [[ -f "$WARM_LOG" ]]; then
  LAST_TS=$(python3 - "$WARM_LOG" "$KEY" 2>/dev/null <<'PY' || printf '0'
import sys, json
log_file, key = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(log_file))
    print(int(data.get(key, {}).get("ts", 0)))
except Exception:
    print(0)
PY
)
  AGE=$(( NOW - LAST_TS ))
  if [[ "$AGE" -lt "$WARM_WINDOW_SEC" ]]; then
    log "skip: ${KEY} warmed ${AGE}s ago (< ${WARM_WINDOW_SEC}s window)"
    printf -- 'warm_result:\n  role: %s\n  model: %s\n  prefix_bytes: 0\n  status: skipped_recent\n  ttl_seconds: 300\n  next_spawn_cache_hit_expected: true\n' "$ROLE" "$MODEL"
    exit 0
  fi
fi

# Locate prefix file: new convention <role>-<model>.prefix.md; fallback to claude-subsession legacy
PREFIX_FILE="${CACHE_DIR}/${ROLE}-${MODEL}.prefix.md"

if [[ ! -f "$PREFIX_FILE" ]]; then
  LEGACY_PREFIX=$(find "$CACHE_DIR" -maxdepth 1 -name "prefix-${ROLE}.*.md" 2>/dev/null | sort | tail -1 || true)
  if [[ -n "$LEGACY_PREFIX" ]]; then
    PREFIX_FILE="$LEGACY_PREFIX"
  fi
fi

if [[ ! -f "$PREFIX_FILE" ]]; then
  log_warn "prefix file missing for ${ROLE}/${MODEL} — skipping warm"
  printf -- 'warm_result:\n  role: %s\n  model: %s\n  prefix_bytes: 0\n  status: failed\n  ttl_seconds: 0\n  next_spawn_cache_hit_expected: false\n  reason: prefix_file_missing\n' "$ROLE" "$MODEL"
  exit 0
fi

PREFIX_BYTES=$(wc -c < "$PREFIX_FILE" | tr -d ' ')

# Check ANTHROPIC_API_KEY
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  log "ANTHROPIC_API_KEY not set — warm is no-op (production uses OAuth)"
  printf -- 'warm_result:\n  role: %s\n  model: %s\n  prefix_bytes: %s\n  status: skipped_no_key\n  ttl_seconds: 0\n  next_spawn_cache_hit_expected: false\n  reason: no_anthropic_api_key\n' "$ROLE" "$MODEL" "$PREFIX_BYTES"
  exit 0
fi

# Map model alias to full model ID
case "$MODEL" in
  opus)   MODEL_ID="claude-opus-4-5" ;;
  sonnet) MODEL_ID="claude-sonnet-4-5" ;;
  haiku)  MODEL_ID="claude-haiku-4-5" ;;
  *)      MODEL_ID="$MODEL" ;;
esac

# Issue minimal Anthropic API call: system=prefix (cache_control: ephemeral), user "OK", max_tokens=1
WARM_START=$(date +%s)

RESPONSE=$(python3 - "$MODEL_ID" "$PREFIX_FILE" 2>/tmp/leadv2-warm-err.log <<'PY'
import sys, json, urllib.request, urllib.error, os

model_id  = sys.argv[1]
pfile     = sys.argv[2]
api_key   = os.environ["ANTHROPIC_API_KEY"]

with open(pfile) as fh:
    prefix_text = fh.read()

payload = {
    "model": model_id,
    "max_tokens": 1,
    "system": [
        {
            "type": "text",
            "text": prefix_text,
            "cache_control": {"type": "ephemeral"},
        }
    ],
    "messages": [{"role": "user", "content": "OK"}],
}

req = urllib.request.Request(
    "https://api.anthropic.com/v1/messages",
    data=json.dumps(payload).encode("utf-8"),
    headers={
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    },
    method="POST",
)

try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = json.loads(resp.read())
    usage = body.get("usage", {})
    cc = usage.get("cache_creation_input_tokens", 0)
    cr = usage.get("cache_read_input_tokens", 0)
    status = "cached" if (cc > 0 or cr > 0) else "warm_sent"
    print(f"OK {status} {cc} {cr}")
except urllib.error.HTTPError as e:
    detail = e.read().decode("utf-8", errors="replace")[:200]
    print(f"HTTP_ERROR {e.code} {detail}", file=sys.stderr)
    sys.exit(1)
except Exception as ex:
    print(f"ERROR {ex}", file=sys.stderr)
    sys.exit(1)
PY
) || {
  ERR_DETAIL=$(python3 -c "import sys; print(open('/tmp/leadv2-warm-err.log').read()[:200])" 2>/dev/null || printf 'see /tmp/leadv2-warm-err.log') # bash-guard: allow
  log_warn "API call failed: ${ERR_DETAIL}"
  printf -- 'warm_result:\n  role: %s\n  model: %s\n  prefix_bytes: %s\n  status: failed\n  ttl_seconds: 0\n  next_spawn_cache_hit_expected: false\n  reason: api_error\n' "$ROLE" "$MODEL" "$PREFIX_BYTES"
  exit 0
}

WARM_END=$(date +%s)
WARM_ELAPSED=$(( WARM_END - WARM_START ))

read -r _ok WARM_STATUS CACHE_CREATE CACHE_READ <<< "$RESPONSE"

log "warm done: ${ROLE}/${MODEL} status=${WARM_STATUS} cache_create=${CACHE_CREATE} cache_read=${CACHE_READ} elapsed=${WARM_ELAPSED}s"

# Update warm log (atomic write)
python3 - "$WARM_LOG" "$KEY" "$NOW" 2>/dev/null <<'PY' || true
import sys, json, os
log_file, key, ts = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    data = json.load(open(log_file)) if os.path.exists(log_file) else {}
except Exception:
    data = {}
data[key] = {"ts": ts}
tmp = log_file + ".tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh)
os.replace(tmp, log_file)
PY

printf -- 'warm_result:\n  role: %s\n  model: %s\n  prefix_bytes: %s\n  status: %s\n  ttl_seconds: 300\n  next_spawn_cache_hit_expected: true\n' \
  "$ROLE" "$MODEL" "$PREFIX_BYTES" "$WARM_STATUS"
