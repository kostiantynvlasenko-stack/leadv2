#!/usr/bin/env bash
# leadv2-token-watch.sh — show recent model burn against your daily/weekly cap.
# Reads ~/.claude/burn/ if present (claude-burn telemetry).
# Helps decide: continue on Opus or switch lead to Sonnet for this task.
#
# Ported from m3-market/.claude/scripts/leadv2-token-watch.sh
# No m3-specific content — ported as-is.
# Complements leadv2-budget-check.sh (per-task gate) — this shows global model burn.
set -euo pipefail

BURN="$HOME/.claude/burn"
if [[ ! -d "$BURN" ]]; then
  echo "no burn telemetry at $BURN"
  echo "tip: install claude-burn (https://github.com/anthropics/claude-burn) or run \`claude-burn dashboard\`"
  exit 1
fi

# 24h window
echo "=== Model burn (24h) ==="
find "$BURN" -name '*.jsonl' -mtime -1 2>/dev/null | head -50 | xargs cat 2>/dev/null \
  | python3 -c "
import sys, json, collections
totals = collections.defaultdict(int)
for line in sys.stdin:
    try:
        r = json.loads(line)
        m = r.get('model','?')
        t = r.get('input_tokens',0) + r.get('output_tokens',0)
        totals[m] += t
    except Exception: pass
for m, t in sorted(totals.items(), key=lambda x: -x[1]):
    print(f'  {m:<28} {t:>12,} tokens')
" 2>/dev/null || echo "(no recent activity)"

echo ""
echo "=== Daily cap heuristic ==="
echo "  Opus 1M context (Max plan): ~50M tokens/day before throttle"
echo "  Sonnet:                      ~200M tokens/day"
echo ""
echo "If Opus 24h > 30M → consider switching lead to Sonnet for next task:"
echo "  unset FORCE_OPUS_LEAD; export LEADV2_MAIN_MODEL=sonnet"
