#!/usr/bin/env bash
# SessionStart hook: drop active.yaml sessions whose pid is no longer alive.
# Stops stale `claimed` entries from firing pulse/prose guards in unrelated chats.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

ACTIVE_YAML=""
for candidate in \
  "/Users/kostiantyn.vlasenko/Projects/persona-engine/docs/leadv2/active.yaml" \
  "/Users/kostiantyn.vlasenko/MythicalGames/m3-market/docs/leadv2/active.yaml"; do
  [[ -f "$candidate" ]] && ACTIVE_YAML="$candidate"
  [[ -z "$ACTIVE_YAML" ]] || python3 - "$ACTIVE_YAML" <<'PYEOF'
import yaml, sys, os
path = sys.argv[1]
try:
    d = yaml.safe_load(open(path)) or {}
except Exception:
    sys.exit(0)
sessions = d.get('sessions') or []
live = []
dropped = []
for sess in sessions:
    pid = sess.get('pid')
    if not pid:
        dropped.append(sess.get('task_id', '?'))
        continue
    try:
        os.kill(int(pid), 0)
        live.append(sess)
    except (OSError, ValueError):
        dropped.append(sess.get('task_id', '?'))
if dropped:
    d['sessions'] = live
    with open(path, 'w') as f:
        yaml.safe_dump(d, f, default_flow_style=False)
    print(f'[leadv2-stale-pid-sweep] dropped {dropped} from {path}', file=sys.stderr)
PYEOF
  ACTIVE_YAML=""
done
exit 0
