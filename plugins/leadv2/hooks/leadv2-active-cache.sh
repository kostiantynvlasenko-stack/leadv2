#!/usr/bin/env bash
# leadv2-active-cache.sh — 5-second cache for active.yaml parsing (PO-064)
#
# Usage (source this file or call the function):
#   source ~/.claude/hooks/leadv2-active-cache.sh
#   leadv2_read_active_yaml "$ACTIVE_YAML_PATH"
#   # Sets global: ACTIVE_TASK_ID, ACTIVE_PHASE
#
# Cache: ~/.claude/state/leadv2/active.cache
#   Format (plain text, 2 lines): task_id\nphase
#
# Invalidation: age > 5s OR active.yaml newer than cache file.
# Thread-safe for concurrent hooks: atomic write via mktemp+mv.

LEADV2_STATE_DIR="${HOME}/.claude/state/leadv2"
LEADV2_ACTIVE_CACHE="${LEADV2_STATE_DIR}/active.cache"
LEADV2_ACTIVE_CACHE_TTL=5   # seconds

leadv2_read_active_yaml() {
  local active_yaml="${1:-}"
  ACTIVE_TASK_ID=""
  ACTIVE_PHASE=""

  [[ -z "$active_yaml" || ! -f "$active_yaml" ]] && return 0

  # ── Check cache validity ────────────────────────────────────────────────────
  local use_cache=0
  if [[ -f "$LEADV2_ACTIVE_CACHE" ]]; then
    local cache_mtime yaml_mtime now
    # macOS stat: -f %m; Linux stat: -c %Y — support both
    if stat --version >/dev/null 2>&1; then
      # GNU stat (Linux)
      cache_mtime=$(stat -c %Y "$LEADV2_ACTIVE_CACHE" 2>/dev/null || echo 0)
      yaml_mtime=$(stat -c %Y "$active_yaml" 2>/dev/null || echo 0)
    else
      # BSD stat (macOS)
      cache_mtime=$(stat -f %m "$LEADV2_ACTIVE_CACHE" 2>/dev/null || echo 0)
      yaml_mtime=$(stat -f %m "$active_yaml" 2>/dev/null || echo 0)
    fi
    now=$(date +%s)
    local age=$(( now - cache_mtime ))
    if [[ "$age" -lt "$LEADV2_ACTIVE_CACHE_TTL" && "$yaml_mtime" -le "$cache_mtime" ]]; then
      use_cache=1
    fi
  fi

  if [[ "$use_cache" -eq 1 ]]; then
    ACTIVE_TASK_ID="$(sed -n '1p' "$LEADV2_ACTIVE_CACHE" 2>/dev/null || echo "")"
    ACTIVE_PHASE="$(sed -n '2p' "$LEADV2_ACTIVE_CACHE" 2>/dev/null || echo "")"
    return 0
  fi

  # ── Cache miss: parse and re-cache ─────────────────────────────────────────
  local parse_out
  parse_out="$(python3 -c "
import yaml, sys, os
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    s = d.get('sessions') or []
    live = []
    for sess in s:
        pid = sess.get('pid')
        if not pid:
            live.append(sess)
            continue
        try:
            os.kill(int(pid), 0)
            live.append(sess)
        except (OSError, ValueError):
            pass
    if live:
        print(live[0].get('task_id', ''))
        print(live[0].get('phase', ''))
    else:
        print('')
        print('')
except Exception:
    print('')
    print('')
" "$active_yaml" 2>/dev/null || printf '\n')"

  ACTIVE_TASK_ID="$(printf '%s' "$parse_out" | sed -n '1p')"
  ACTIVE_PHASE="$(printf '%s' "$parse_out" | sed -n '2p')"

  # Atomic write to cache
  mkdir -p "$LEADV2_STATE_DIR"
  local tmp
  tmp="$(mktemp "${LEADV2_ACTIVE_CACHE}.XXXXXX")"
  printf '%s\n%s\n' "$ACTIVE_TASK_ID" "$ACTIVE_PHASE" > "$tmp"
  mv -f "$tmp" "$LEADV2_ACTIVE_CACHE"

  return 0
}

# If called directly (not sourced), print the cache contents for debugging
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ -f "$LEADV2_ACTIVE_CACHE" ]]; then
    echo "cache_file: $LEADV2_ACTIVE_CACHE"
    echo "task_id: $(sed -n '1p' "$LEADV2_ACTIVE_CACHE")"
    echo "phase: $(sed -n '2p' "$LEADV2_ACTIVE_CACHE")"
  else
    echo "cache_file: not found"
  fi
fi
