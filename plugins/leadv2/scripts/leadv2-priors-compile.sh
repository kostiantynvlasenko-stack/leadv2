#!/usr/bin/env bash
# leadv2-priors-compile.sh — Compile unified operator priors from all memory sources.
# Reads: history, lead-patterns, negative-memory, causal-log, agent-stats, signatures-aggregate.
# Writes: docs/leadv2-priors.yaml (atomic tmp+mv).
#
# Usage:
#   leadv2-priors-compile.sh [--output <path>] [--dry-run] [--validate]
#
# Exit codes:
#   0 — compiled OK
#   1 — validation failed (--validate mode)
#   2 — source parse error (output not written)

SHELL=/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly PROJECT_ROOT

# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh" || { echo "FATAL: cannot source leadv2-helpers.sh" >&2; exit 1; }

OUTPUT_FILE="${PROJECT_ROOT}/docs/leadv2-priors.yaml"
DRY_RUN=0
VALIDATE_ONLY=0

log()       { printf '[leadv2-priors-compile] %s\n' "$*" >&2; }
log_warn()  { printf '[leadv2-priors-compile] WARN: %s\n' "$*" >&2; }
log_error() { printf '[leadv2-priors-compile] ERROR: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)    OUTPUT_FILE="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --validate)  VALIDATE_ONLY=1; shift ;;
    -h|--help)
      printf 'Usage: leadv2-priors-compile.sh [--output <path>] [--dry-run] [--validate]\n' >&2
      exit 0
      ;;
    *) log_error "unknown arg: $1"; exit 2 ;;
  esac
done

# Source files (some may be absent — handled gracefully)
STATE_FILE="${PROJECT_ROOT}/docs/LEAD_V2_STATE.md"
HISTORY_FILE="${PROJECT_ROOT}/docs/LEAD_HISTORY.md"
PATTERNS_FILE="${PROJECT_ROOT}/.claude/ref/lead-patterns.md"
NEG_MEM_FILE="${PROJECT_ROOT}/docs/leadv2-negative-memory.yaml"
CAUSAL_LOG="${PROJECT_ROOT}/docs/leadv2-causal-log.yaml"
AGENT_STATS="${PROJECT_ROOT}/docs/agents/agent-stats.yaml"
SIGNATURES_SCRIPT="${SCRIPT_DIR}/leadv2-signatures-aggregate.sh"
AGENT_STATS_SCRIPT="${SCRIPT_DIR}/leadv2-agent-stats.sh"

# ---------------------------------------------------------------------------
# Step 0: --validate mode — check existing priors.yaml for sanity
# ---------------------------------------------------------------------------
if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
  if [[ ! -f "$OUTPUT_FILE" ]]; then
    log_error "priors.yaml not found at $OUTPUT_FILE — run compile first"
    exit 1
  fi
  python3 - "$OUTPUT_FILE" <<'PYEOF'
import sys
import yaml
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = yaml.safe_load(path.read_text()) or {}
except Exception as e:
    print(f"FAIL: YAML parse error: {e}", file=sys.stderr)
    sys.exit(1)

errors: list[str] = []

# Required top-level fields
for field in ("compiled_at", "compiled_from", "phase_priors", "agent_priors",
              "risk_priors", "active_blocks", "routing_priors", "fix_quality_priors"):
    if field not in data:
        errors.append(f"missing required field: {field}")

# Ratio sanity checks
fq = data.get("fix_quality_priors", {}) or {}
for key in ("band_aid_ratio_30d", "durable_success_rate", "reasonable_success_rate",
            "band_aid_success_rate"):
    val = fq.get(key)
    if val is not None and val != "insufficient_data":
        try:
            f = float(val)
            if not (0.0 <= f <= 1.0):
                errors.append(f"fix_quality_priors.{key}={f} outside [0,1]")
        except (TypeError, ValueError):
            errors.append(f"fix_quality_priors.{key} is not a float: {val}")

# Alert threshold
alert = fq.get("alert_threshold")
if alert is not None:
    try:
        if not (0.0 <= float(alert) <= 1.0):
            errors.append(f"fix_quality_priors.alert_threshold={alert} outside [0,1]")
    except (TypeError, ValueError):
        pass

if errors:
    print("VALIDATION FAILED:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"OK: priors.yaml valid ({len(data)} top-level keys)")
PYEOF
  exit $?
fi

# ---------------------------------------------------------------------------
# Step 1: Refresh agent-stats if script available
# ---------------------------------------------------------------------------
if [[ -x "$AGENT_STATS_SCRIPT" || -f "$AGENT_STATS_SCRIPT" ]]; then
  log "Refreshing agent-stats.yaml ..."
  bash "$AGENT_STATS_SCRIPT" --out "$AGENT_STATS" 2>/dev/null || log_warn "agent-stats refresh failed — using cached"
fi

# ---------------------------------------------------------------------------
# Step 2: Collect signatures aggregate (to stdout)
# ---------------------------------------------------------------------------
if [[ -f "$SIGNATURES_SCRIPT" ]]; then
  log "Running signatures-aggregate ..."
  bash "$SIGNATURES_SCRIPT" > /dev/null 2>&1 || log_warn "signatures-aggregate failed — using cached"
fi

# ---------------------------------------------------------------------------
# Step 3: Python compiler — reads all sources, emits priors YAML
# ---------------------------------------------------------------------------
start_ts=$(date -u +%s)

priors_yaml=$(python3 - \
  "$STATE_FILE" \
  "${HISTORY_FILE:-}" \
  "$PATTERNS_FILE" \
  "$NEG_MEM_FILE" \
  "$CAUSAL_LOG" \
  "$AGENT_STATS" \
  <<'PYEOF'
import sys
import re
import yaml
import math
from datetime import datetime, timezone, timedelta
from collections import defaultdict
from pathlib import Path
from typing import Optional

(state_file, history_file, patterns_file,
 neg_mem_file, causal_log_file, agent_stats_file) = sys.argv[1:7]

now_utc = datetime.now(timezone.utc)
cutoff_30d = now_utc - timedelta(days=30)
cutoff_7d  = now_utc - timedelta(days=7)

# ── Helpers ──────────────────────────────────────────────────────────────────

def safe_yaml(path: str) -> object:
    p = Path(path)
    if not p.is_file() or not path:
        return None
    try:
        return yaml.safe_load(p.read_text(errors="replace"))
    except Exception:
        return None

def read_text_safe(path: str) -> str:
    p = Path(path)
    if not p.is_file() or not path:
        return ""
    try:
        return p.read_text(errors="replace")
    except Exception:
        return ""

def parse_date(s: str) -> Optional[datetime]:
    if not s:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            d = datetime.strptime(s[:19], fmt[:len(s[:19])])
            return d.replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None

# ── 1. Parse history entries ─────────────────────────────────────────────────
# LEAD_V2_STATE.md is a YAML file with a top-level `history:` list.
# Each entry has: task, closed_at, reflect.signature (nested dict).
# LEAD_HISTORY.md (if present) has the same format for older entries.

def extract_history_from_yaml(path: str) -> list[dict]:
    """Parse history entries from a LEAD_V2_STATE.md / LEAD_HISTORY.md file."""
    data = safe_yaml(path)
    if not isinstance(data, dict):
        return []
    raw_history = data.get("history") or []
    entries: list[dict] = []
    for item in raw_history:
        if not isinstance(item, dict):
            continue
        task_id = str(item.get("task") or item.get("task_id") or "unknown")
        closed_at_raw = str(item.get("closed_at") or item.get("date") or "")
        task_date = parse_date(closed_at_raw)
        reflect = item.get("reflect") or {}
        sig = reflect.get("signature") if isinstance(reflect, dict) else None
        if not isinstance(sig, dict):
            continue
        entries.append({
            "task_id": task_id,
            "date": task_date,
            "signature": sig,
        })
    return entries

history_entries: list[dict] = extract_history_from_yaml(state_file)
if history_file and Path(history_file).is_file():
    history_entries.extend(extract_history_from_yaml(history_file))

# ── 2. Parse active patterns ──────────────────────────────────────────────────

patterns_text = read_text_safe(patterns_file)
# Count active rules: CR-XX, MD-XX, PS-XX, CX-XX (not in retired/empty rows)
active_rule_ids: list[str] = re.findall(r'\|\s*((?:CR|MD|PS|CX)-\d+)', patterns_text)
active_rules_count = len(active_rule_ids)

# ── 3. Parse negative memory ──────────────────────────────────────────────────

nm_data = safe_yaml(neg_mem_file) or {}
nm_entries = nm_data.get("entries", []) if isinstance(nm_data, dict) else []
active_nm = [e for e in nm_entries if isinstance(e, dict) and e.get("status") == "active"]
active_nm_ids = [e.get("id", "") for e in active_nm]

# ── 4. Parse causal log ───────────────────────────────────────────────────────

causal_data = safe_yaml(causal_log_file)
causal_entries: list[dict] = causal_data if isinstance(causal_data, list) else []

# Causal entries in last 30 days
causal_30d = []
for ce in causal_entries:
    ts = parse_date(str(ce.get("timestamp", "")))
    if ts and ts >= cutoff_30d:
        causal_30d.append(ce)

# High-latent-risk files: cause_task origin appearing 2+ times in 30d
cause_task_file_counts: dict[str, int] = defaultdict(int)
for ce in causal_30d:
    mech = ce.get("mechanism", "")
    # Try to extract file from mechanism text (format: "<cause task> modified <symbol/file>; ...")
    file_match = re.search(r'modified\s+([\w./\-]+\.py)', mech)
    if file_match:
        cause_task_file_counts[file_match.group(1)] += 1

high_latent_risk_files = [
    f"{f}  # causal origin {n}x in last 30d"
    for f, n in sorted(cause_task_file_counts.items(), key=lambda x: -x[1])
    if n >= 2
][:5]

# Induced regression rate 30d
induced_regression_rate_30d = 0.0
known_cause_count = sum(1 for ce in causal_30d if not ce.get("cause_unknown", True))
if len(causal_30d) > 0:
    induced_regression_rate_30d = round(known_cause_count / max(len(history_entries), 1), 4)

# Most recent induced regression
most_recent_regression: Optional[str] = None
if causal_30d:
    last = causal_30d[-1]
    most_recent_regression = (
        f"{last.get('effect_task', '?')} <- {last.get('cause_task', 'unknown')} "
        f"(score={last.get('causality_score', 0):.2f})"
    )

# ── 5. Parse agent stats ──────────────────────────────────────────────────────

stats_data = safe_yaml(agent_stats_file) or {}
stats_rows: list[dict] = (
    (stats_data.get("agents") or []) if isinstance(stats_data, dict) else []
)

# Build per-agent best_on/avoid_on from success_rate
agent_perf: dict[str, dict] = {}
for row in stats_rows:
    agent = str(row.get("agent", ""))
    ck = str(row.get("change_kind", "unknown"))
    rate = float(row.get("success_rate_30d", 0.0))
    if not agent:
        continue
    if agent not in agent_perf:
        agent_perf[agent] = {"best_on": [], "avoid_on": [], "rows": []}
    agent_perf[agent]["rows"].append({"change_kind": ck, "rate": rate})

agent_priors: dict = {}
known_agents = [
    "developer", "architect", "critic", "security-auditor",
    "postgres-pro", "frontend-developer", "devops-engineer", "product-owner"
]
# Static baseline model recommendations (enriched from stats below)
base_model_recs: dict[str, dict] = {
    "developer": {
        "refactor-internal": "sonnet",
        "bugfix-pure": "sonnet",
        "cross-service": "sonnet",
        "new-route": "sonnet",
    },
    "architect": {
        "new-route": "opus",
        "cross-service": "opus",
        "strategic": "opus",
        "refactor-internal": "sonnet",
        "ui-only": "sonnet",
    },
    "critic": {"default": "opus"},
    "security-auditor": {"default": "sonnet"},
    "postgres-pro": {"default": "sonnet"},
    "frontend-developer": {"default": "sonnet"},
    "devops-engineer": {"default": "sonnet"},
    "product-owner": {"default": "sonnet"},
}

for agent in known_agents:
    rows = agent_perf.get(agent, {}).get("rows", [])
    best = sorted(rows, key=lambda r: r["rate"], reverse=True)
    avoid = [r["change_kind"] for r in rows if r["rate"] < 0.6]
    best_on = [r["change_kind"] for r in best if r["rate"] >= 0.80][:4]
    # Fallback static best_on if no stats
    static_best: dict[str, list] = {
        "developer": ["refactor-internal", "bugfix-pure"],
        "architect": ["new-route", "cross-service", "strategic"],
        "critic": ["new-route", "cross-service"],
        "security-auditor": ["new-route", "cross-service"],
        "postgres-pro": ["new-migration", "refactor-internal"],
        "frontend-developer": ["ui-only"],
        "devops-engineer": ["config-only", "docs-only"],
        "product-owner": ["strategic"],
    }
    agent_priors[agent] = {
        "best_on": best_on if best_on else static_best.get(agent, []),
        "avoid_on": avoid[:3],
        "model_recommendation": base_model_recs.get(agent, {"default": "sonnet"}),
    }

# ── 6. Phase priors from history ─────────────────────────────────────────────

# Group by change_kind
ck_buckets: dict[str, list] = defaultdict(list)
for entry in history_entries:
    sig = entry.get("signature", {})
    ck = str(sig.get("change_kind", "unknown"))
    date = entry.get("date")
    in_30d = (date and date >= cutoff_30d)
    ck_buckets[ck].append({
        "task_class": sig.get("task_class", "Standard"),
        "outcome": sig.get("outcome", "unknown"),
        "failure_class": sig.get("failure_class", "none"),
        "involved_agents": sig.get("involved_agents", []),
        "fix_quality": sig.get("fix_quality", "reasonable"),
        "in_30d": in_30d,
        "date": date,
    })

CHANGE_KINDS = [
    "new-route", "new-migration", "refactor-internal", "bugfix-pure",
    "cross-service", "ui-only", "config-only", "docs-only"
]
# Defaults when no history
DEFAULT_DURATION: dict[str, int] = {
    "new-route": 45, "new-migration": 30, "refactor-internal": 18,
    "bugfix-pure": 20, "cross-service": 60, "ui-only": 25,
    "config-only": 10, "docs-only": 8,
}
DEFAULT_CLASS: dict[str, str] = {
    "new-route": "Standard", "new-migration": "Standard",
    "refactor-internal": "Light", "bugfix-pure": "Standard",
    "cross-service": "Heavy", "ui-only": "Light",
    "config-only": "Light", "docs-only": "Trivial",
}
DEFAULT_AGENTS: dict[str, list] = {
    "new-route": ["architect", "developer", "security-auditor", "critic"],
    "new-migration": ["postgres-pro", "developer", "critic"],
    "refactor-internal": ["developer", "critic"],
    "bugfix-pure": ["developer", "critic"],
    "cross-service": ["architect", "developer", "security-auditor", "critic"],
    "ui-only": ["frontend-developer", "critic"],
    "config-only": ["devops-engineer"],
    "docs-only": ["developer"],
}

phase_priors: dict = {}
for ck in CHANGE_KINDS:
    bucket = ck_buckets.get(ck, [])
    total = len(bucket)
    total_30d = sum(1 for e in bucket if e["in_30d"])
    success_30d = sum(1 for e in bucket if e["in_30d"] and e["outcome"] == "success")
    success_rate = round(success_30d / total_30d, 2) if total_30d > 0 else None

    # Most common failure classes
    fail_counter: dict[str, int] = defaultdict(int)
    for e in bucket:
        fc = e["failure_class"]
        if fc and fc != "none":
            fail_counter[fc] += 1
    common_failures = [k for k, _ in sorted(fail_counter.items(), key=lambda x: -x[1])][:3]

    # Most common agent order from history (most frequent involvement)
    agent_counter: dict[str, int] = defaultdict(int)
    for e in bucket:
        agents = e["involved_agents"]
        if isinstance(agents, list):
            for a in agents:
                agent_counter[str(a)] += 1
        elif isinstance(agents, str):
            for a in re.split(r'[,\s]+', agents):
                if a:
                    agent_counter[a] += 1
    recommended_agents = [a for a, _ in sorted(agent_counter.items(), key=lambda x: -x[1])][:4]
    if not recommended_agents:
        recommended_agents = DEFAULT_AGENTS.get(ck, ["developer"])

    # Most common class
    class_counter: dict[str, int] = defaultdict(int)
    for e in bucket:
        tc = e["task_class"]
        if tc:
            class_counter[str(tc)] += 1
    avg_class = max(class_counter, key=lambda k: class_counter[k]) if class_counter else DEFAULT_CLASS.get(ck, "Standard")

    entry: dict = {
        "avg_class": avg_class,
        "avg_duration_min": DEFAULT_DURATION.get(ck, 30),
        "success_rate_30d": success_rate if success_rate is not None else "insufficient_data",
        "common_failure_modes": common_failures,
        "recommended_agent_order": recommended_agents,
        "required_gates": ["test-synthesis", "llm-judge"] if ck in ("new-route", "cross-service", "new-migration") else ["llm-judge"],
    }
    if ck in ("refactor-internal", "config-only", "docs-only", "ui-only"):
        entry["skip_review_eligible"] = True

    phase_priors[ck] = entry

# ── 7. fix_quality priors ────────────────────────────────────────────────────

total_30d_all = sum(1 for e in history_entries if e.get("date") and e["date"] >= cutoff_30d)
band_aid_30d = sum(
    1 for e in history_entries
    if e.get("date") and e["date"] >= cutoff_30d
    and e.get("signature", {}).get("fix_quality") == "band-aid"
)
durable_success_rate = None
reasonable_success_rate = None
band_aid_success_rate = None

for quality, target in [("durable", "durable_success_rate"),
                         ("reasonable", "reasonable_success_rate"),
                         ("band-aid", "band_aid_success_rate")]:
    q_entries = [
        e for e in history_entries
        if e.get("signature", {}).get("fix_quality") == quality
    ]
    q_success = [e for e in q_entries if e.get("signature", {}).get("outcome") == "success"]
    rate = round(len(q_success) / len(q_entries), 2) if q_entries else None
    if quality == "durable":
        durable_success_rate = rate
    elif quality == "reasonable":
        reasonable_success_rate = rate
    else:
        band_aid_success_rate = rate

band_aid_ratio_30d = round(band_aid_30d / total_30d_all, 4) if total_30d_all > 0 else 0.0

fix_quality_priors: dict = {
    "band_aid_ratio_30d": band_aid_ratio_30d,
    "alert_threshold": 0.30,
    "durable_success_rate": durable_success_rate if durable_success_rate is not None else "insufficient_data",
    "reasonable_success_rate": reasonable_success_rate if reasonable_success_rate is not None else "insufficient_data",
    "band_aid_success_rate": band_aid_success_rate if band_aid_success_rate is not None else "insufficient_data",
}

# ── 8. routing_priors ────────────────────────────────────────────────────────

routing_priors = {
    "opus_justified_for": ["heavy", "cross-service-with-risk", "strategic"],
    "sonnet_sufficient_for": ["light-low-risk", "refactor-internal", "ui-only"],
    "skip_llm_for": ["docs-only", "config-only"],
}

# ── 9. Compute high-frequency signatures (>3 in last 30d) ───────────────────

sig_counts: dict[tuple, int] = defaultdict(int)
for entry in history_entries:
    if entry.get("date") and entry["date"] >= cutoff_30d:
        sig = entry.get("signature", {})
        key = (
            sig.get("phase", ""),
            sig.get("failure_class", "none"),
            sig.get("change_kind", ""),
        )
        sig_counts[key] += 1

high_freq_sigs = [
    f"phase={k[0]},failure={k[1]},change_kind={k[2]} (n={n})"
    for k, n in sorted(sig_counts.items(), key=lambda x: -x[1])
    if n >= 3
][:5]

# ── 10. Assemble compiled_from metadata ─────────────────────────────────────

compiled_from = {
    "history_entries": len(history_entries),
    "active_rules": active_rules_count,
    "negative_entries": len(active_nm),
    "causal_links": len(causal_entries),
    "agent_stats_agents": len([a for a in agent_perf if agent_perf[a]["rows"]]),
}

# ── 11. Assemble final document ──────────────────────────────────────────────

compiled_at = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")

doc: dict = {
    "compiled_at": compiled_at,
    "compiled_from": compiled_from,
    "phase_priors": {
        "by_change_kind": phase_priors,
    },
    "agent_priors": agent_priors,
    "risk_priors": {
        "high_latent_risk_files": high_latent_risk_files,
        "cross_service_tasks_recent": sum(
            1 for e in history_entries
            if e.get("date") and e["date"] >= cutoff_30d
            and e.get("signature", {}).get("change_kind") == "cross-service"
        ),
        "induced_regression_rate_30d": induced_regression_rate_30d,
        "most_recent_regression": most_recent_regression,
    },
    "active_blocks": {
        "negative_memory_ids": active_nm_ids,
        "high_frequency_signatures": high_freq_sigs,
        "patterns_near_promotion": [],  # filled by signatures-aggregate --update-patterns
    },
    "routing_priors": routing_priors,
    "fix_quality_priors": fix_quality_priors,
}

# Write output to stdout (bash caller uses _atomic_write_yaml)
import io as _io
_buf = _io.StringIO()
_buf.write("# Compiled nightly. Authoritative source for runtime decisions.\n")
_buf.write("# DO NOT edit manually — regenerated by leadv2-priors-compile.sh\n")
yaml.dump(doc, _buf, default_flow_style=False, sort_keys=False, allow_unicode=True,
          indent=2, width=120)
sys.stdout.write(_buf.getvalue())
print(f"OK compiled_at={compiled_at} history={compiled_from['history_entries']} "
      f"rules={compiled_from['active_rules']} neg={compiled_from['negative_entries']} "
      f"causal={compiled_from['causal_links']}", file=sys.stderr)
PYEOF
)

end_ts=$(date -u +%s)
elapsed=$(( end_ts - start_ts ))
log "Compile took ${elapsed}s"

# ---------------------------------------------------------------------------
# Step 4: Atomic write (or dry-run preview)
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: skipping write to $OUTPUT_FILE"
  printf '%s\n' "$priors_yaml"
  exit 0
fi

_atomic_write_yaml "$OUTPUT_FILE" "$priors_yaml"
log "Written: $OUTPUT_FILE"

# ---------------------------------------------------------------------------
# Step 5: Auto-validate after compile
# ---------------------------------------------------------------------------
bash "${BASH_SOURCE[0]}" --validate --output "$OUTPUT_FILE" || {
  log_warn "post-compile validation found issues — priors still written, check manually"
}
