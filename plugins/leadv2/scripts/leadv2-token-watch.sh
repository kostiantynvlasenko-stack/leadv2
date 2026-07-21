#!/usr/bin/env bash
# leadv2-token-watch.sh — provider headroom plus observed Claude token/cache
# telemetry. It deliberately does not invent token/day subscription caps:
# Claude Code and Codex subscriptions are windowed, model/context dependent,
# and provider-owned live percentages are the only routing-safe signal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUOTA_LIVE="${LEADV2_QUOTA_LIVE:-$SCRIPT_DIR/leadv2-quota-live.sh}"
BURN_DIR="${LEADV2_CLAUDE_BURN_DIR:-$HOME/.claude/burn}"

printf -- '=== Live provider headroom ===\n'
if [[ -x "$QUOTA_LIVE" ]]; then
  "$QUOTA_LIVE" report || printf -- 'quota endpoints unavailable; routing must treat them as unknown\n'
else
  printf -- 'quota reader unavailable: %s\n' "$QUOTA_LIVE"
fi

printf -- '\n=== Claude telemetry (last 24h, if available) ===\n'
if [[ ! -d "$BURN_DIR" ]]; then
  printf -- 'no local burn telemetry at %s\n' "$BURN_DIR"
  printf -- 'routing still uses provider-owned live quota above; no allowance is inferred from missing logs\n'
  exit 0
fi

python3 - "$BURN_DIR" <<'PYEOF'
import collections, json, os, sys, time

root = sys.argv[1]
cutoff = time.time() - 86400
totals = collections.defaultdict(lambda: collections.Counter())
files = 0
for base, _, names in os.walk(root):
    for name in names:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(base, name)
        try:
            if os.path.getmtime(path) < cutoff:
                continue
            fh = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        files += 1
        with fh:
            for raw in fh:
                try:
                    row = json.loads(raw)
                except Exception:
                    continue
                model = str(row.get("model") or "unknown")
                usage = row.get("usage") if isinstance(row.get("usage"), dict) else row
                for key in (
                    "input_tokens",
                    "output_tokens",
                    "cache_read_input_tokens",
                    "cache_creation_input_tokens",
                ):
                    value = usage.get(key, 0)
                    if isinstance(value, (int, float)):
                        totals[model][key] += int(value)

if not totals:
    print(f"no parseable activity in {files} recent telemetry file(s)")
    raise SystemExit(0)

print(f"{'model':<30} {'input':>12} {'output':>12} {'cache-read':>14} {'cache-write':>14}")
for model, values in sorted(
    totals.items(), key=lambda item: -(item[1]["input_tokens"] + item[1]["output_tokens"])
):
    print(
        f"{model[:29]:<30} "
        f"{values['input_tokens']:>12,} "
        f"{values['output_tokens']:>12,} "
        f"{values['cache_read_input_tokens']:>14,} "
        f"{values['cache_creation_input_tokens']:>14,}"
    )
PYEOF

printf -- '\nRaw token totals diagnose context growth; they are not subscription limits.\n'
printf -- 'For cache truth, use cache-read/cache-write telemetry—not a standalone warm-up call.\n'
