#!/usr/bin/env bash
# leadv2-signatures-aggregate.sh
# Scans LEAD_V2_STATE.md + LEAD_HISTORY.md for signature blocks,
# computes (phase, failure_class) tuple counts with 90-day half-life decay,
# and emits YAML to stdout: active promotion candidates + retired candidates.
#
# Usage:
#   bash .claude/scripts/leadv2-signatures-aggregate.sh
#   bash .claude/scripts/leadv2-signatures-aggregate.sh --update-patterns   # also writes candidates to lead-patterns.md
#
# Dependencies: python3 with pyyaml (pip install pyyaml; already in repo requirements)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="${REPO_ROOT}/docs/LEAD_V2_STATE.md"
HISTORY_FILE="${REPO_ROOT}/docs/ops/LEAD_HISTORY.md"
PATTERNS_FILE="${REPO_ROOT}/.claude/ref/lead-patterns.md"
UPDATE_PATTERNS=false

log() { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Parse args
for arg in "$@"; do
  case "$arg" in
    --update-patterns) UPDATE_PATTERNS=true ;;
    *) log "Unknown arg: $arg"; exit 1 ;;
  esac
done

# Verify required files exist
for f in "$STATE_FILE"; do
  if [[ ! -f "$f" ]]; then
    log "ERROR: required file not found: $f"
    exit 1
  fi
done

# Concatenate history sources (state + archive if exists)
COMBINED_INPUT="${REPO_ROOT}/docs/LEAD_V2_STATE.md"
if [[ -f "$HISTORY_FILE" ]]; then
  COMBINED_INPUT="${STATE_FILE} ${HISTORY_FILE}"
fi

UPDATE_FLAG="$UPDATE_PATTERNS"

python3 - "$STATE_FILE" "${HISTORY_FILE:-}" "$PATTERNS_FILE" "$UPDATE_FLAG" <<'PYEOF'
import sys
import re
import math
import os
from datetime import date, datetime
from collections import defaultdict

state_path = sys.argv[1]
history_path = sys.argv[2] if sys.argv[2] else None
patterns_path = sys.argv[3]
update_patterns = sys.argv[4].lower() == "true"

today = date.today()

PROMOTION_RAW_THRESHOLD = int(os.environ.get("LEADV2_SKILL_SYNTH_THRESHOLD", "3"))
RETIREMENT_WEIGHTED_THRESHOLD = 1.0

# Per-failure-class half-life (days) — jcode-inspired memory typing.
# Corrections last longest (founder-explicit); inferred patterns decay fast.
HALF_LIFE_BY_CLASS = {
    "user_correction": 365,
    "safety_violation": 365,
    "spec_drift": 180,
    "schema_mismatch": 180,
    "build_failure": 60,
    "test_regression": 60,
    "review_finding": 90,
    "deploy_failure": 90,
    "verify_timeout": 90,
    "rollback": 90,
    "perf_regression": 90,
    "config_drift": 60,
    "inferred": 14,
    "none": 90,
}
DEFAULT_HALF_LIFE_DAYS = 90

def parse_yaml_block(text: str) -> dict:
    # W6-fix: pyyaml upgrade (was hand-rolled parser that silently skipped malformed entries)
    import yaml as _yaml
    try:
        parsed = _yaml.safe_load(text)
        if isinstance(parsed, dict):
            return parsed
    except _yaml.YAMLError:
        pass
    return {}

def extract_signatures(path: str) -> list[dict]:
    if not path or not __import__("os").path.isfile(path):
        return []
    with open(path) as f:
        content = f.read()

    sigs = []
    # Find all history entries with signature blocks
    # Pattern: find `signature:` blocks inside history yaml entries
    sig_pattern = re.compile(
        r'signature:\s*\n((?:[ \t]+\S.*\n?)+)',
        re.MULTILINE
    )
    # Also capture task id context
    task_pattern = re.compile(r'- task:\s*(\S+)')
    task_positions = [(m.start(), m.group(1)) for m in task_pattern.finditer(content)]

    for m in sig_pattern.finditer(content):
        block_text = m.group(1)
        sig = parse_yaml_block(block_text)

        # Find nearest preceding task id
        task_id = "unknown"
        for pos, tid in reversed(task_positions):
            if pos < m.start():
                task_id = tid
                break

        sig["_task_id"] = task_id
        sig["_raw_pos"] = m.start()

        # Resolve dates
        first_seen_str = sig.get("first_seen", str(today))
        last_seen_str = sig.get("last_seen", str(today))
        try:
            sig["_first_seen"] = date.fromisoformat(first_seen_str)
            sig["_last_seen"] = date.fromisoformat(last_seen_str)
        except ValueError:
            sig["_first_seen"] = today
            sig["_last_seen"] = today

        sig["_usage_count"] = int(sig.get("usage_count", 1))
        sigs.append(sig)

    return sigs

# Collect all signatures
all_sigs = extract_signatures(state_path)
if history_path:
    all_sigs += extract_signatures(history_path)

if not all_sigs:
    print("# leadv2-signatures-aggregate: no signature blocks found in history")
    print("active_candidates: []")
    print("retired_candidates: []")
    sys.exit(0)

# Aggregate by (phase, failure_class, change_kind) triple.
# Entries without change_kind (older history) use change_kind=None.
TupleKey = tuple[str, str, str | None]
raw_counts: dict[TupleKey, int] = defaultdict(int)
weighted_counts: dict[TupleKey, float] = defaultdict(float)
task_ids: dict[TupleKey, set[str]] = defaultdict(set)

for sig in all_sigs:
    phase = sig.get("phase", "unknown")
    fc = sig.get("failure_class", "none")
    # change_kind absent in pre-graph-reflect entries → None (excluded from change_kind-aware output)
    ck: str | None = sig.get("change_kind") or None
    key: TupleKey = (phase, fc, ck)
    usage = sig["_usage_count"]
    age_days = (today - sig["_last_seen"]).days
    half_life = HALF_LIFE_BY_CLASS.get(fc, DEFAULT_HALF_LIFE_DAYS)
    weight = usage * pow(0.5, age_days / half_life)

    raw_counts[key] += usage
    weighted_counts[key] += weight
    task_ids[key].add(sig["_task_id"])

active_candidates = []
retired_candidates = []

for key in sorted(raw_counts.keys(), key=lambda k: (k[0], k[1], k[2] or "")):
    phase, fc, ck = key
    raw = raw_counts[key]
    weighted = weighted_counts[key]
    tasks = sorted(task_ids[key])
    distinct_tasks = len(tasks)
    tuple_label = f"({phase}, {fc}, {ck})" if ck is not None else f"({phase}, {fc}, null)"

    if weighted < RETIREMENT_WEIGHTED_THRESHOLD and raw >= PROMOTION_RAW_THRESHOLD:
        retired_candidates.append({
            "tuple": tuple_label,
            "change_kind": ck,
            "raw_count": raw,
            "weighted_count": round(weighted, 3),
            "task_ids": tasks,
            "reason": f"decay: weighted_count={round(weighted, 3)} on {today}"
        })
    elif raw >= PROMOTION_RAW_THRESHOLD and distinct_tasks >= 2:
        ck_clause = f" and change_kind={ck}" if ck is not None else ""
        active_candidates.append({
            "tuple": tuple_label,
            "change_kind": ck,
            "raw_count": raw,
            "weighted_count": round(weighted, 3),
            "task_ids": tasks,
            "candidate_rule": f"when phase={phase} and failure={fc}{ck_clause} → [review guard needed]"
        })

# Output YAML
print("# leadv2-signatures-aggregate output")
print(f"# generated: {today.isoformat()}")
print(f"# total signatures scanned: {len(all_sigs)}")
print()
print("active_candidates:")
if active_candidates:
    for c in active_candidates:
        print(f"  - tuple: \"{c['tuple']}\"")
        ck_val = f"\"{c['change_kind']}\"" if c['change_kind'] is not None else "null"
        print(f"    change_kind: {ck_val}")
        print(f"    raw_count: {c['raw_count']}")
        print(f"    weighted_count: {c['weighted_count']}")
        print(f"    task_ids: {c['task_ids']}")
        print(f"    candidate_rule: \"{c['candidate_rule']}\"")
else:
    print("  []")

print()
print("retired_candidates:")
if retired_candidates:
    for c in retired_candidates:
        print(f"  - tuple: \"{c['tuple']}\"")
        ck_val = f"\"{c['change_kind']}\"" if c['change_kind'] is not None else "null"
        print(f"    change_kind: {ck_val}")
        print(f"    raw_count: {c['raw_count']}")
        print(f"    weighted_count: {c['weighted_count']}")
        print(f"    task_ids: {c['task_ids']}")
        print(f"    reason: \"{c['reason']}\"")
else:
    print("  []")

# Optional: write candidates to lead-patterns.md
if update_patterns and (active_candidates or retired_candidates):
    import os
    if os.path.isfile(patterns_path):
        with open(patterns_path) as f:
            patterns_content = f.read()

        # Build candidate table rows
        candidate_rows = []
        for c in active_candidates:
            ck_val = c['change_kind'] if c['change_kind'] is not None else "null"
            row = f"| {c['tuple']} | {ck_val} | {c['raw_count']} | {c['weighted_count']} | {', '.join(c['task_ids'])} | {c['candidate_rule']} |"
            candidate_rows.append(row)

        retired_rows = []
        for c in retired_candidates:
            ck_val = c['change_kind'] if c['change_kind'] is not None else "null"
            row = f"| {c['tuple']} | {ck_val} | {c['raw_count']} | {c['weighted_count']} | {', '.join(c['task_ids'])} | {c['reason']} |"
            retired_rows.append(row)

        # Inject or update #signature-promotion-candidates section
        candidate_section = (
            "\n## #signature-promotion-candidates\n\n"
            f"*Last updated: {today.isoformat()}*\n\n"
            "| tuple | change_kind | raw_count | weighted_count | task_ids | candidate_rule |\n"
            "|---|---|---|---|---|---|\n"
        )
        if candidate_rows:
            candidate_section += "\n".join(candidate_rows) + "\n"
        else:
            candidate_section += "| *(none)* | — | — | — | — |\n"

        retired_section = (
            "\n## #retired\n\n"
            f"*Last updated: {today.isoformat()}*\n\n"
            "| tuple | change_kind | raw_count | weighted_count | task_ids | reason |\n"
            "|---|---|---|---|---|---|\n"
        )
        if retired_rows:
            retired_section += "\n".join(retired_rows) + "\n"
        else:
            retired_section += "| *(none)* | — | — | — | — |\n"

        # Replace or append sections
        CAND_MARKER = "## #signature-promotion-candidates"
        RETIRED_MARKER = "## #retired"

        if CAND_MARKER in patterns_content:
            # Replace from marker to next ## or end
            patterns_content = re.sub(
                r'## #signature-promotion-candidates.*?(?=\n## |\Z)',
                candidate_section.lstrip('\n'),
                patterns_content,
                flags=re.DOTALL
            )
        else:
            patterns_content += candidate_section

        if RETIRED_MARKER in patterns_content:
            patterns_content = re.sub(
                r'## #retired.*?(?=\n## |\Z)',
                retired_section.lstrip('\n'),
                patterns_content,
                flags=re.DOTALL
            )
        else:
            patterns_content += retired_section

        with open(patterns_path, "w") as f:
            f.write(patterns_content)

        print(file=sys.stderr)
        print(f"[update] wrote candidates to {patterns_path}", file=sys.stderr)

PYEOF
