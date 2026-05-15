#!/bin/bash
# leadv2-known-quirks-inject.sh — Phase 6 helper.
# Reads docs/leadv2/known-quirks.yaml, filters by scope tags relevant to the task,
# and prints `instruction:` lines for lead to paste into devops mission file.
#
# Usage: leadv2-known-quirks-inject.sh [scope1] [scope2] ...
# Scopes: vps:nik-wellness, vps:respiro-brand, tool:deploy-latest.sh, tool:codex-task.sh, tool:bash
# If no scopes given → prints all instructions (caller should narrow).

set -euo pipefail

QUIRKS_FILE="docs/leadv2/known-quirks.yaml"
[[ -f "$QUIRKS_FILE" ]] || { echo "[known-quirks] file missing: $QUIRKS_FILE" >&2; exit 0; }

scopes=("$@")
python3 - "$QUIRKS_FILE" "${scopes[@]:-}" <<'PYEOF'
import sys, yaml

path = sys.argv[1]
wanted_scopes = [s for s in sys.argv[2:] if s]
data = yaml.safe_load(open(path)) or {}
quirks = (data.get("quirks") or {})

if not quirks:
    sys.exit(0)

matched = []
for qid, q in quirks.items():
    scope = q.get("scope", "")
    if not wanted_scopes or any(scope == w or scope.startswith(w + ":") or w == scope.split(":")[0] for w in wanted_scopes):
        matched.append((qid, q))

if not matched:
    sys.exit(0)

print("# Known quirks (inject into devops mission §discipline):")
for qid, q in matched:
    print(f"- [{qid}] ({q.get('scope', '?')}) {q.get('instruction', '')}")
PYEOF
