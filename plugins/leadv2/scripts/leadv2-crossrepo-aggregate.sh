#!/usr/bin/env bash
# leadv2-crossrepo-aggregate.sh — Cross-repo immune-pattern aggregator shell driver.
#
# Reads immune-patterns.yaml + lead-reflect STATE.md signatures from each repo
# listed in cross-repo-paths.yaml, then invokes leadv2-crossrepo-aggregate.py
# for stem-intersection analysis.  Emits shadow proposals into
# docs/leadv2/shadow/proposals/<sha1>.yaml (risk_level=high, founder-gated).
#
# Usage:
#   leadv2-crossrepo-aggregate.sh [OPTIONS]
#
# Options:
#   --plugin-root <path>   Plugin root (default: ~/Projects/leadv2/plugins/leadv2/)
#   --config <path>        cross-repo-paths.yaml (default: ~/.claude/leadv2-shared/cross-repo-paths.yaml)
#   --dry-run              Print proposal YAML to stdout; do NOT write to disk
#
# Off-limits (D7, D20):
#   - Never writes plugin source files
#   - Never auto-triggered at Phase 8 Close
#   - Only on explicit /leadv2 cross-repo-reflect or manual invocation
#
# Exit codes:
#   0  success (may have been dry-run or zero repos present)
#   1  fatal config / python error
#
# DECISIONS: D7 D13 D16 D20 D21 D9

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()       { printf -- '[crossrepo-aggregate] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_warn()  { printf -- '[crossrepo-aggregate] WARN: %s\n' "$*" >&2; }
log_error() { printf -- '[crossrepo-aggregate] ERROR: %s\n' "$*" >&2; }

# ── Defaults ──────────────────────────────────────────────────────────────────
PLUGIN_ROOT="${LEADV2_CROSSREPO_PLUGIN_ROOT:-${SCRIPT_DIR%/scripts}}"
CONFIG_FILE="${LEADV2_CROSSREPO_CONFIG:-${HOME}/.claude/leadv2-shared/cross-repo-paths.yaml}"
DRY_RUN=0
PYTHON_SCRIPT="${SCRIPT_DIR}/leadv2-crossrepo-aggregate.py"

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin-root) PLUGIN_ROOT="$2"; shift 2 ;;
    --config)      CONFIG_FILE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)
      printf 'Usage: %s [--plugin-root PATH] [--config PATH] [--dry-run]\n' "$(basename "$0")" >&2
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# ── Validate prerequisites ────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  log_error "Config not found: $CONFIG_FILE"
  exit 1
fi

if [[ ! -f "$PYTHON_SCRIPT" ]]; then
  log_error "Python analysis script not found: $PYTHON_SCRIPT"
  exit 1
fi

# Resolve project root for shadow/proposals output (use the calling repo root)
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PROPOSALS_DIR="${PROJECT_ROOT}/docs/leadv2/shadow/proposals"

# ── Read config + collect per-repo patterns as JSON ──────────────────────────
# Build the JSON payload for the python script via python3 (safe, no jq required)
PAYLOAD_JSON=$(python3 - "$CONFIG_FILE" <<'PYEOF'
import sys, yaml, json, os, re
from pathlib import Path

config_file = sys.argv[1]

with open(config_file) as f:
    config = yaml.safe_load(f) or {}

repos_cfg = config.get("repos") or {}
payload = []

for repo_name, entry in repos_cfg.items():
    raw_path = entry.get("path", "")
    # Expand ~ and env vars
    repo_path = os.path.expandvars(os.path.expanduser(raw_path))

    if not os.path.isdir(repo_path):
        print(f"[crossrepo-aggregate] WARN: repo '{repo_name}' not found at {repo_path} — skipping", file=sys.stderr)
        continue

    immune_rel = entry.get("immune_patterns_rel", "docs/leadv2/immune-patterns.yaml")
    reflect_rel = entry.get("reflect_signatures_rel", "docs/leadv2/tasks")

    immune_path = os.path.join(repo_path, immune_rel)
    reflect_path = os.path.join(repo_path, reflect_rel)

    patterns = []

    # Load immune-patterns.yaml
    if os.path.isfile(immune_path):
        with open(immune_path) as f:
            data = yaml.safe_load(f) or {}
        for p in (data.get("patterns") or []):
            patterns.append({
                "id": p.get("id", ""),
                "source": "immune_patterns",
                "summary": p.get("summary", ""),
                "action": p.get("action", ""),
                "keywords": p.get("keywords") or [],
                "seen_count": p.get("seen_count", 1),
            })
    else:
        print(f"[crossrepo-aggregate] WARN: immune-patterns not found at {immune_path}", file=sys.stderr)

    # Load pattern_for_immune from STATE.md files
    if os.path.isdir(reflect_path):
        pattern_re = re.compile(
            r"pattern_for_immune\s*:\s*(?P<inline>[^\n|][^\n]*)|"
            r"pattern_for_immune\s*:\s*\|\s*\n(?P<block>(?:[ \t]+[^\n]*\n?)+)",
            re.MULTILINE,
        )
        for state_file in sorted(Path(reflect_path).glob("*/STATE.md")):
            try:
                content = state_file.read_text(encoding="utf-8")
                for m in pattern_re.finditer(content):
                    if m.group("inline"):
                        text = m.group("inline").strip().strip('"').strip("'")
                    else:
                        raw_block = m.group("block")
                        lines = raw_block.splitlines()
                        indent = min(
                            (len(l) - len(l.lstrip()) for l in lines if l.strip()),
                            default=0,
                        )
                        text = "\n".join(l[indent:] for l in lines).strip()
                    if text:
                        patterns.append({
                            "id": "",
                            "source": "reflect_signature",
                            "summary": text[:100],
                            "action": text[:200],
                            "keywords": [],
                            "seen_count": 1,
                        })
            except Exception as e:
                print(f"[crossrepo-aggregate] WARN: could not read {state_file}: {e}", file=sys.stderr)

    payload.append({
        "repo_name": repo_name,
        "repo_path": repo_path,
        "patterns": patterns,
    })

print(json.dumps(payload))
PYEOF
)

if [[ -z "$PAYLOAD_JSON" || "$PAYLOAD_JSON" == "[]" ]]; then
  log_warn "No repos found or no patterns collected — nothing to aggregate"
  exit 0
fi

log "Collected patterns from repos; invoking analysis core..."

# ── Invoke python analysis core ───────────────────────────────────────────────
DRY_RUN_FLAG=""
[[ "$DRY_RUN" -eq 1 ]] && DRY_RUN_FLAG="--dry-run"

python3 "$PYTHON_SCRIPT" \
  --plugin-root "$PLUGIN_ROOT" \
  --proposals-dir "$PROPOSALS_DIR" \
  ${DRY_RUN_FLAG} \
  --payload-json "$PAYLOAD_JSON"

log "Cross-repo aggregate complete"
