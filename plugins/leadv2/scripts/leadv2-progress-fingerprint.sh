#!/usr/bin/env bash
# leadv2-progress-fingerprint.sh — deterministic evidence fingerprint for one
# task. Used by provider runners to distinguish real phase/code/artifact
# progress from a model merely appending another successful turn to its log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_ID="${1:-${LEADV2_TASK_ID:-}}"
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
[[ -n "$TASK_ID" ]] || { printf -- 'task id required\n' >&2; exit 2; }

if [[ -n "${LEADV2_STATE_ROOT:-}" ]]; then
  ACTIVE_YAML="$LEADV2_STATE_ROOT/active.yaml"
else
  ACTIVE_YAML="$(env PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/leadv2-state-path.sh" --no-link active.yaml)"
fi

python3 - "$PROJECT_ROOT" "$ACTIVE_YAML" "$TASK_ID" <<'PYEOF'
import hashlib, json, os, subprocess, sys

project_root, active_yaml, task_id = sys.argv[1:]
evidence = {"task_id": task_id, "registry": {}, "roots": {}}
worktree = ""

try:
    import yaml
    data = yaml.safe_load(open(active_yaml, encoding="utf-8")) or {}
    row = next(
        (item for item in data.get("sessions", [])
         if isinstance(item, dict) and item.get("task_id") == task_id),
        {},
    )
    worktree = str(row.get("worktree") or "")
    evidence["registry"] = {
        key: row.get(key)
        for key in ("task_id", "phase", "class", "worktree", "branch", "stale")
    }
except Exception:
    pass

roots = []
for value in (project_root, worktree):
    if value:
        real = os.path.realpath(value)
        if os.path.isdir(real) and real not in roots:
            roots.append(real)

def file_digest(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            while True:
                chunk = fh.read(1024 * 1024)
                if not chunk:
                    break
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return "unreadable"

ignored_names = {
    ".session-runner.lock",
    ".session-runner.pid",
    ".session-runner.session-id",
    ".session-runner.codex-thread-id",
    "session-runner.log",
    "codex-session-runner.log",
}

for root in roots:
    item = {"git_head": "", "git_status": "", "artifacts": {}}
    try:
        item["git_head"] = subprocess.run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=3,
        ).stdout.strip()
        item["git_status"] = subprocess.run(
            ["git", "-C", root, "status", "--porcelain", "--untracked-files=normal"],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        pass

    artifact_dirs = (
        os.path.join(root, "docs", "handoff", task_id),
        os.path.join(root, "docs", "leadv2", "tasks", task_id),
    )
    for directory in artifact_dirs:
        if not os.path.isdir(directory):
            continue
        for base, dirs, names in os.walk(directory):
            dirs[:] = [d for d in dirs if not d.startswith(".git")]
            for name in sorted(names):
                if name in ignored_names or name.endswith(".log"):
                    continue
                path = os.path.join(base, name)
                rel = os.path.relpath(path, root)
                item["artifacts"][rel] = file_digest(path)
    evidence["roots"][root] = item

encoded = json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode()
print(hashlib.sha256(encoded).hexdigest())
PYEOF
