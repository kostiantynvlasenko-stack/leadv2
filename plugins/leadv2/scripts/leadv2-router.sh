#!/usr/bin/env bash
# leadv2-router.sh — Marginal-value router for /leadv2 phases.
# Reads leadv2-routing.yaml, applies signal conditions, outputs selected model + command template.
# No LLM calls — pure bash + python.
#
# Usage:
#   leadv2-router.sh --phase <phase> --step <step> [--signals '{"risk":"high","total_lines":600}']
#                    [--task-id <id>] [--class <Light|Standard|Heavy|Strategic>]
#
# Output (on stdout):
#   model=sonnet
#   tool=claude-subsession
#   command_template=bash .claude/scripts/claude-subsession.sh --role {{role}} --model sonnet --task-id {{task_id}} --mission-file {{mission}}
#   expected_cost_usd=0.08
#   expected_tokens=15000
#   ceiling_status=ok          # ok | warn_60pct | hard_stop_95pct
#   downgrade_applied=false    # true if model was downgraded due to cost/empty-session
#
# Exit codes:
#   0 — model selected, proceed
#   1 — hard stop (burn > 95% ceiling, or no valid model after stop rules)
#   2 — routing.yaml missing (caller should fall back to class-based routing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly PROJECT_ROOT
readonly ROUTING_YAML="$PROJECT_ROOT/.claude/ref/leadv2-routing.yaml"
readonly AGENT_STATS_YAML="$PROJECT_ROOT/docs/agents/agent-stats.yaml"
# LEADV2_PRIORS_YAML: optional override path; defaults to docs/leadv2-priors.yaml
PRIORS_YAML="${LEADV2_PRIORS_YAML:-${PROJECT_ROOT}/docs/leadv2-priors.yaml}"

log() { printf '[leadv2-router] %s\n' "$*" >&2; }
log_warn() { printf '[leadv2-router] WARN: %s\n' "$*" >&2; }
log_error() { printf '[leadv2-router] ERROR: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: leadv2-router.sh --phase <phase> --step <step>
                        [--signals '{"risk":"high","total_lines":600}']
                        [--task-id <id>]
                        [--class <Light|Standard|Heavy|Strategic>]
EOF
  exit 1
}

PHASE=""
STEP=""
SIGNALS="{}"
TASK_ID=""
TASK_CLASS="Standard"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)   PHASE="$2";      shift 2 ;;
    --step)    STEP="$2";       shift 2 ;;
    --signals) SIGNALS="$2";    shift 2 ;;
    --task-id) TASK_ID="$2";    shift 2 ;;
    --class)   TASK_CLASS="$2"; shift 2 ;;
    *) log_error "unknown arg: $1"; usage ;;
  esac
done

[[ -z "$PHASE" || -z "$STEP" ]] && { log_error "--phase and --step required"; usage; }

# ---------------------------------------------------------------------------
# Fallback: routing.yaml missing → exit 2 so caller uses class-based routing
# ---------------------------------------------------------------------------
if [[ ! -f "$ROUTING_YAML" ]]; then
  log_warn "routing.yaml not found at $ROUTING_YAML — caller should use class-based fallback"
  exit 2
fi

# ---------------------------------------------------------------------------
# Python helper: reads routing.yaml, evaluates signals, applies stop rules,
# checks cost ceiling, outputs key=value pairs for bash to consume.
# ---------------------------------------------------------------------------
# SD-31 fix: BSD/macOS mktemp requires the X-run to be TRAILING — a literal
# suffix after it (".py") is taken as-is, so the "random" name collapses to
# the SAME literal filename on every call and concurrent callers collide
# (`mkstemp failed ... File exists`). Fix: mktemp with a trailing-X template
# (portable on BSD + GNU), then rename to add the .py suffix.
PY_HELPER_BASE=$(mktemp /tmp/leadv2-router-XXXXXX) || {
  log_error "mktemp failed to create PY_HELPER_BASE — cannot proceed"
  exit 1
}
PY_HELPER="${PY_HELPER_BASE}.py"
mv "$PY_HELPER_BASE" "$PY_HELPER" || {
  log_error "failed to rename temp helper $PY_HELPER_BASE -> $PY_HELPER"
  rm -f "$PY_HELPER_BASE"
  exit 1
}
trap 'rm -f "$PY_HELPER_BASE" "$PY_HELPER"' EXIT

python3 -c "import sys; print(open(sys.argv[1]).read())" /dev/stdin > "$PY_HELPER" 2>/dev/null <<'PYEOF'
import sys
import json
import math
import os
from pathlib import Path

try:
    import yaml
except ImportError:
    # Minimal YAML subset parser for our simple routing.yaml structure
    # (no anchors, no complex types beyond str/int/float/bool/dict/list)
    yaml = None

def load_yaml_file(path: str) -> dict:
    """Load YAML using PyYAML if available, else fallback to json (not ideal but safe for our format)."""
    content = Path(path).read_text()
    if yaml:
        return yaml.safe_load(content)
    # Last-resort: try to import ruamel or tomllib as alternatives
    try:
        import tomllib  # 3.11+
    except ImportError:
        pass
    # If nothing works, raise so the bash script exits 2
    raise RuntimeError("PyYAML not available — install pyyaml")

routing_yaml, phase, step, signals_json, task_id, task_class = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
priors_yaml = sys.argv[8] if len(sys.argv) > 8 else ""

# Parse signals
try:
    signals = json.loads(signals_json)
except json.JSONDecodeError:
    signals = {}

# Load operator priors routing hints (non-blocking — missing file is OK)
priors_routing: dict = {}
try:
    if priors_yaml and Path(priors_yaml).is_file():
        p = load_yaml_file(priors_yaml)
        if isinstance(p, dict):
            priors_routing = p.get("routing_priors", {}) or {}
            # Merge priors into signals for downstream escalate_if evaluation
            # signal key: priors_skip_llm = true when task_class is in skip_llm_for
            # DEFENSIVE READ (Risk 5): list fields may be "insufficient_data" until
            # 10+ history entries exist. Normalize sentinel to empty list.
            def _safe_list(d, key):
                v = d.get(key, [])
                return v if isinstance(v, list) else []

            skip_llm = _safe_list(priors_routing, "skip_llm_for")
            sonnet_ok = _safe_list(priors_routing, "sonnet_sufficient_for")
            opus_ok   = _safe_list(priors_routing, "opus_justified_for")
            tc_lower = task_class.lower()
            if any(tc_lower == s.lower() for s in skip_llm):
                signals.setdefault("priors_skip_llm", True)
            if any(tc_lower == s.lower() for s in sonnet_ok):
                signals.setdefault("priors_sonnet_ok", True)
            if any(tc_lower == s.lower() for s in opus_ok):
                signals.setdefault("priors_opus_justified", True)
except Exception:
    pass   # priors are enrichment only — never block routing

# Load routing table
try:
    cfg = load_yaml_file(routing_yaml)
except Exception as e:
    print(f"ROUTING_YAML_ERROR: {e}", file=sys.stderr)
    sys.exit(2)

# Navigate to phase.step
phases = cfg.get("phases", {})
phase_cfg = phases.get(phase, {})
step_cfg = phase_cfg.get(step, {})

if not step_cfg:
    # Unknown phase/step — emit empty so bash falls through to class-based
    print("UNKNOWN_PHASE_STEP")
    sys.exit(2)

# Determine selected model: check escalate_if condition
selected_model = step_cfg.get("default", "sonnet")

# ---------------------------------------------------------------------------
# GLM-FIRST-01 policy resolver (fix-round-4, ROUTER-HAS-NO-GLM-ARM-01)
# ---------------------------------------------------------------------------
# The `glm_policy:` block in routing.yaml is the SOURCE OF TRUTH for when GLM
# (the default build writer) must yield to Sonnet (a listed exception) or to
# Opus (mission kinds where GLM is banned). Until now that block had a writer
# and NO executor: the recording layer merely LABELLED a decision it had
# already hardcoded, and guessed "unknown" for the rule id. This resolver
# READS the policy and OBEYS it — editing the yaml changes routing behaviour.
# Absent policy (other phases / other repos) => selected_model untouched.
routing_reason = "glm_default"
glm_exception_rule = "null"
_glm_resolver_rule = None  # real rule id when the resolver fires a sonnet exception

glm_policy = phase_cfg.get("glm_policy")
if not isinstance(glm_policy, dict):
    # glm_policy lives as a SIBLING of the phase blocks (under `phases:`, not
    # nested inside `build:` — its YAML indent makes it so), so fall back to
    # reading it there. Guarded: repos/phases with no glm_policy at all get None
    # here and leave selected_model untouched.
    glm_policy = phases.get("glm_policy")
if isinstance(glm_policy, dict):
    _gp_base = selected_model.split("+")[0].split("-")[0]
    if _gp_base == "glm":
        _opus_kinds = glm_policy.get("opus_only_mission_kinds", []) or []
        _exc_ids = [e.get("id") for e in (glm_policy.get("sonnet_exceptions", []) or [])
                    if isinstance(e, dict) and e.get("id")]

        def _num_ge(val, n):
            try:
                return val is not None and float(val) >= n
            except (TypeError, ValueError):
                return False

        _gp_suffix = selected_model[len(_gp_base):]  # preserve "+agent-tool" etc.

        def _swap(new_base):
            return new_base + _gp_suffix

        # STRICT precedence, first match wins. A sonnet rule fires only if its id
        # is present in the yaml — removing an id there silently disables that
        # rule. We never invent a rule id; opus_kinds/exc_ids both come from yaml.
        _gp_rules = [
            (lambda: signals.get("mission_kind") in _opus_kinds,
             None, "opus", "opus_mission_kind"),
            (lambda: bool(signals.get("protected_path") or signals.get("safety_touched")),
             "safety_gate_publish_payments", "sonnet", "sonnet_exception"),
            (lambda: _num_ge(signals.get("subsystem_count"), 4)
                    or bool(signals.get("needs_midflight_interaction")),
             "integration_critical_4subsystems", "sonnet", "sonnet_exception"),
            (lambda: bool(signals.get("ui_design_judgment")),
             "ui_design_judgment", "sonnet", "sonnet_exception"),
            (lambda: _num_ge(signals.get("glm_failure_count"), 2),
             "glm_failed_twice", "sonnet", "sonnet_exception"),
            # H5 fix (fix-round-2, ROUTER-HAS-NO-GLM-ARM-01): the yaml declares
            # glm_lock_busy_no_second_channel (leadv2-routing.yaml:86-87) but no
            # predicate ever read the glm_lock_busy signal — a declared-but-dead
            # rule. Wired: same shape as the other sonnet_exception predicates.
            (lambda: bool(signals.get("glm_lock_busy")),
             "glm_lock_busy_no_second_channel", "sonnet", "sonnet_exception"),
        ]
        for _pred, _rid, _base, _reason in _gp_rules:
            if not _pred():
                continue
            if _rid is not None and _rid not in _exc_ids:
                continue  # rule id absent from yaml -> cannot fire
            selected_model = _swap(_base)
            routing_reason = _reason
            _glm_resolver_rule = _rid
            break

tool = step_cfg.get("tool", "agent-tool")
expected_cost = step_cfg.get("expected_cost_usd", 0.0)
expected_tokens = step_cfg.get("expected_tokens", 0)
is_floor = step_cfg.get("floor", False)
# C3 fix (fix-round-2, ROUTER-HAS-NO-GLM-ARM-01): when the glm_policy resolver
# above fired a MANDATORY exception (sonnet_exception / opus_mission_kind),
# that arm is a floor for THIS decision — the cost-ceiling machinery below
# (legacy warn-band downgrade, T8b windowed recovery gate) must never demote
# it, not even to haiku, and must never erase the fired rule id. This is the
# "is_floor equivalent" the critic asked for: build steps carry no static
# floor_rules: entry (the floor is signal-derived, not step-derived), so we
# derive is_floor dynamically from the resolver's own verdict instead of
# adding a yaml row that can't express "only when the exception fired".
if routing_reason in ("sonnet_exception", "opus_mission_kind"):
    is_floor = True
escalated = False

escalate_if = step_cfg.get("escalate_if", "")
if escalate_if:
    # Evaluate simple condition: key==value or key>value
    cond = escalate_if.strip()
    try:
        if "==" in cond:
            lhs, rhs = cond.split("==", 1)
            lhs = lhs.strip().replace(".", "_")
            # Walk nested keys using dot notation
            val = signals
            for part in lhs.split("_"):
                if isinstance(val, dict):
                    val = val.get(part, None)
            if val is not None and str(val) == rhs.strip():
                escalated = True
        elif ">" in cond:
            lhs, rhs = cond.split(">", 1)
            lhs = lhs.strip()
            # Support dotted keys
            val = signals
            for part in lhs.split("."):
                if isinstance(val, dict):
                    val = val.get(part, None)
            if val is not None:
                try:
                    if float(val) > float(rhs.strip()):
                        escalated = True
                except (ValueError, TypeError):
                    pass
    except Exception:
        pass  # ignore malformed condition, don't escalate

if escalated:
    selected_model = step_cfg.get("escalate_to", selected_model)
    tool = step_cfg.get("escalate_tool", tool)
    expected_cost = step_cfg.get("escalate_cost_usd", expected_cost * 3)
    expected_tokens = int(expected_tokens * 4)

# ---------------------------------------------------------------------------
# Agent success rate check: escalate if agent has low success for change_kind
# ---------------------------------------------------------------------------
change_kind = signals.get("change_kind", "")
if change_kind and os.path.isfile(sys.argv[7] if len(sys.argv) > 7 else ""):
    # agent-stats.yaml present — check success_rate
    try:
        stats_cfg = load_yaml_file(sys.argv[7])
        agents_list = stats_cfg.get("agents", [])
        # Derive primary agent from tool/model string
        primary_agent = "developer"
        if "architect" in selected_model:
            primary_agent = "architect"
        elif "critic" in selected_model:
            primary_agent = "critic"
        for entry in agents_list:
            if entry.get("agent") == primary_agent and entry.get("change_kind") == change_kind:
                rate = float(entry.get("success_rate_30d", 1.0))
                if rate < 0.60:
                    # Auto-escalate: sonnet→opus, add critic pass
                    downgrade_chain = cfg.get("downgrade_chain", {})
                    # Escalate upward (reverse of downgrade)
                    escalate_map = {v: k for k, v in downgrade_chain.items()}
                    base_model = selected_model.split("+")[0].split("-")[0]
                    if base_model in escalate_map and not is_floor:
                        selected_model = escalate_map[base_model] + "+" + selected_model
                        escalated = True
    except Exception:
        pass

# Snapshot the pre-ceiling model (post escalate_if/success-rate, pre-downgrade)
# — the T8b fresh-trip mapping below downgrades FROM this, not from
# `selected_model` after the legacy cumulative block may have already mutated
# it once; otherwise a single windowed trip could double-hop the chain.
_pre_ceiling_model = selected_model

# ---------------------------------------------------------------------------
# Cost ceiling check
# ---------------------------------------------------------------------------
stop_rules = cfg.get("stop_rules", {})
ceiling_cfg = stop_rules.get("cost_ceiling_per_task", {})
ceiling = float(ceiling_cfg.get(task_class, 2.00))
warn_pct = float(ceiling_cfg.get("warn_threshold_pct", 60)) / 100
hard_pct = float(ceiling_cfg.get("hard_stop_threshold_pct", 95)) / 100

# C2/C3 fix (fix-round-1): whether the caller (bash) successfully held the
# shared .cost-flush.lock before invoking us. Defaults to "assume locked" so
# direct/manual invocations (tests, no-task-id calls) are unaffected; the
# bash wrapper passes an explicit 0 only when flock genuinely failed/timed out.
_lock_acquired = os.environ.get("LEADV2_LOCK_ACQUIRED", "1") == "1"

current_burn = 0.0
# burn_readable=False means "we could not safely determine cumulative spend"
# (lock not held, file present but corrupt/non-list) — NEVER the same as
# "no spend yet" (file genuinely absent, which is a known, safe current_burn=0).
burn_readable = True
if task_id:
    if not _lock_acquired:
        burn_readable = False
    else:
        costs_file = Path(f"docs/handoff/{task_id}/costs.yaml")
        # Try PROJECT_ROOT prefix
        alt = Path(os.environ.get("PROJECT_ROOT", ".")) / "docs" / "handoff" / task_id / "costs.yaml"
        for cf in [costs_file, alt]:
            if cf.is_file():
                try:
                    entries = load_yaml_file(str(cf))
                    if isinstance(entries, list):
                        current_burn = sum(float(e.get("cost_usd", 0)) for e in entries if isinstance(e, dict))
                    else:
                        burn_readable = False
                except Exception:
                    burn_readable = False
                break

ceiling_status = "ok"
downgrade_applied = False

if ceiling > 0 and current_burn > 0:
    burn_ratio = current_burn / ceiling
    if burn_ratio >= hard_pct:
        ceiling_status = "hard_stop_95pct"
    elif burn_ratio >= warn_pct:
        ceiling_status = "warn_60pct"
        # Downgrade subsequent model: opus→sonnet, but respect floor
        if not is_floor:
            downgrade_chain = cfg.get("downgrade_chain", {})
            parts = selected_model.split("+")
            new_parts = []
            for p in parts:
                base = p.split("-")[0]
                new_parts.append(downgrade_chain.get(base, p))
            new_model = "+".join(new_parts)
            if new_model != selected_model:
                selected_model = new_model
                downgrade_applied = True
                expected_cost = expected_cost * 0.3  # rough sonnet vs opus ratio

# ---------------------------------------------------------------------------
# T8b ROUTING-TIER-RECOVERY-REDESIGN — windowed recovery gate (additive).
# Legacy ceiling_status/downgrade_applied/current_burn above are UNCHANGED
# (cumulative burn — backward-compat for the 85%/95% consumers + other repo
# readers of ceiling_status, see design.md F5). This block adds a SEPARATE
# trailing-window burn gate consumed via the new keys below by
# claude-subsession.sh::_check_cost_ceiling. Router stays read-only: it never
# writes downgrade_event/recovery rows, only reads costs.yaml under a shared
# lock. Any exception anywhere -> tri-state "unknown" -> caller HOLDs.
# ---------------------------------------------------------------------------
def _env_num(name, default, lo=None, hi=None):
    try:
        v = float(os.environ.get(name) or default)
    except (TypeError, ValueError):
        v = float(default)
    if lo is not None and v < lo:
        v = lo
    if hi is not None and v > hi:
        v = hi
    return v

recovery_window_sec = _env_num("LEADV2_RECOVERY_WINDOW_SEC", 1800, 300, 86400)
recover_pct = _env_num("LEADV2_RECOVERY_RECOVER_PCT", 5) / 100.0
min_dwell_sec = _env_num("LEADV2_RECOVERY_MIN_DWELL_SEC", 300, 0, None)
recovery_flag_on = os.environ.get("LEADV2_COOLDOWN_RECOVERY", "0") == "1"

recovery_status = "unknown"     # tri-state: ok | over | unknown
downgrade_active = "unknown"    # true | false | unknown
force_model = ""
fresh_trip = "false"            # true only on the probe that FIRST crosses the
                                 # windowed trigger with no downgrade_event yet
                                 # logged — tells the caller to persist ONE event.
to_model = ""
# fix-round-5: pre-init so it's ALWAYS bound, including on paths that raise
# before ever reaching the `active = len(downgrade_rows) > 0` assignment
# below (e.g. true day-0's FileNotFoundError). The except handler reads this
# to distinguish "no downgrade ever" from "an existing downgrade_event row
# just failed to parse further" — both used to collapse into the same
# downgrade_active="unknown" and let G-3's =="true" check never fire.
active = False
# hard_stop is cumulative + always computable — never "unknown" (design §3/§4).
# C3 fix (fix-round-1): when burn is UNreadable (lock failure or corrupt
# file), hard_stop must NOT default to false — an unreadable spend history is
# exactly the condition the fail-safe contract exists for ("fail cheap, not
# fail-open"). Force hard_stop=true so both the cap-guard and do_recover's
# `not hard_stop` gate refuse premium / refuse recovery.
hard_stop = bool((not burn_readable) or (ceiling > 0 and current_burn >= hard_pct * ceiling))

if not task_id:
    # No task scope -> nothing to recover from; not an error.
    recovery_status = "ok"
    downgrade_active = "false"
else:
    try:
        from datetime import datetime, timezone

        # C2 fix (fix-round-1): never read costs.yaml unlocked. If the bash
        # wrapper couldn't hold the shared lock (timeout/failure), skip the
        # read entirely and fall straight to the except -> unknown/HOLD path.
        if not _lock_acquired:
            raise RuntimeError("cost-flush lock not held — refusing unlocked read")

        def _parse_ts(raw):
            s = str(raw).strip()
            if s.endswith("Z"):
                s = s[:-1] + "+00:00"
            return datetime.fromisoformat(s).timestamp()

        _recovery_entries = None
        for cf in [Path(f"docs/handoff/{task_id}/costs.yaml"),
                   Path(os.environ.get("PROJECT_ROOT", ".")) / "docs" / "handoff" / task_id / "costs.yaml"]:
            if cf.is_file():
                _loaded = load_yaml_file(str(cf))
                _recovery_entries = _loaded if isinstance(_loaded, list) else []
                break
        if _recovery_entries is None:
            # costs.yaml missing entirely for a task_id that's in scope — could
            # be "never spent yet" OR "file vanished mid-task" (row 1). Fail
            # safe: unknown, never silently treated as "nothing to recover".
            raise FileNotFoundError(f"costs.yaml not found for task {task_id}")

        now_epoch = datetime.now(timezone.utc).timestamp()
        downgrade_rows = [e["downgrade_event"] for e in _recovery_entries
                          if isinstance(e, dict) and isinstance(e.get("downgrade_event"), dict)]
        cost_rows = [e for e in _recovery_entries
                     if isinstance(e, dict) and "downgrade_event" not in e]

        active = len(downgrade_rows) > 0
        downgrade_ts = None
        if active:
            last_event = downgrade_rows[-1]
            to_model = str(last_event.get("to_model") or "")
            downgrade_ts = _parse_ts(last_event.get("timestamp"))
            if now_epoch < downgrade_ts:
                raise ValueError("clock-skew: downgrade_event timestamp in the future")

        windowed_burn = 0.0
        valid_ts_count = 0
        ts_fail_count = 0
        for row in cost_rows:
            ts_raw = row.get("timestamp")
            if ts_raw is None:
                ts_fail_count += 1
                continue
            ts_epoch = _parse_ts(ts_raw)
            if ts_epoch > now_epoch + 5:
                raise ValueError("clock-skew: future cost-row timestamp")
            valid_ts_count += 1
            if (now_epoch - ts_epoch) <= recovery_window_sec:
                windowed_burn += float(row.get("cost_usd", 0) or 0)

        # C1 fix (fix-round-1): "ok" is permitted ONLY when the parse is fully
        # clean AND there is >=1 valid-ts cost row AND zero rows failed
        # ts-parsing. Empty cost_rows, or ANY mix of valid+missing-ts rows,
        # both fall through to the outer except -> unknown (never a silent ok).
        if len(cost_rows) == 0 or valid_ts_count == 0 or ts_fail_count > 0:
            raise ValueError("empty cost history or incomplete timestamps — cannot compute windowed burn safely")

        if windowed_burn >= warn_pct * ceiling:
            recovery_status = "over"
        elif windowed_burn < recover_pct * ceiling:
            recovery_status = "ok"
        else:
            recovery_status = "over"   # dead-band [recover_pct, warn_pct) HOLDs

        if not active:
            if recovery_status == "over":
                # First-time windowed trip (F3): no downgrade_event row exists
                # yet, but windowed_burn just crossed warn_pct. Resolve the
                # target tier via the SAME downgrade_chain the legacy
                # cumulative block uses, floor-respecting. Router stays
                # read-only — it signals fresh_trip, caller persists the event.
                _dg_chain = cfg.get("downgrade_chain", {})
                if not is_floor:
                    _parts = _pre_ceiling_model.split("+")
                    _new_parts = [_dg_chain.get(p.split("-")[0], p) for p in _parts]
                    _fresh_to = "+".join(_new_parts).split("+")[0]
                else:
                    _fresh_to = ""
                if _fresh_to and _fresh_to != _pre_ceiling_model.split("+")[0]:
                    downgrade_active = "true"
                    fresh_trip = "true"
                    force_model = _fresh_to
                else:
                    # already at floor / no downgrade mapping available
                    downgrade_active = "false"
                    force_model = ""
            else:
                downgrade_active = "false"
                force_model = ""
        elif is_floor:
            # C3 fix (fix-round-2): an EARLIER downgrade_event (recorded by a
            # different, non-floor call for this task) must not force THIS
            # call's resolver-mandated arm down to the recorded to_model —
            # the floor is a property of the current decision, not a task-
            # wide sticky state that outranks a live safety/policy exception.
            downgrade_active = "false"
            force_model = ""
        else:
            dwell_ok = (now_epoch - downgrade_ts) >= min_dwell_sec
            forward_ok = (current_burn + float(expected_cost or 0.0)) < (hard_pct * ceiling)
            do_recover = (
                recovery_flag_on and recovery_status == "ok"
                and not hard_stop and dwell_ok and forward_ok
            )
            if do_recover:
                downgrade_active = "false"
                force_model = ""
            else:
                downgrade_active = "true"
                force_model = to_model or "__HOLD__"
    except Exception:
        recovery_status = "unknown"
        # fix-round-5 (Critical): the blanket except used to always write
        # "unknown" here, discarding whether `active` (a real downgrade_event
        # row) had already been bound above the point of failure. True day-0
        # raises FileNotFoundError before `active` is ever touched -> stays
        # False (pre-init above) -> "unknown" -> F-A's day-0 allowance still
        # applies. An EXISTING downgrade_event with a garbage/unparseable
        # timestamp sets active=True at line ~389 BEFORE the ts-parse raise
        # -> "true" -> G-3's cap now correctly fires instead of silently
        # looking identical to day-0 and leaking an uncapped premium spawn.
        downgrade_active = "true" if active else "unknown"
        force_model = to_model or "__HOLD__"

# ---------------------------------------------------------------------------
# NOTE (fix-round-3, structural): the T8b escalation cap and command_template
# construction USED TO both live here (round-2 F-A/F-B/F-C). Round-3 found
# the cap still re-desynced because (a) it keyed off `downgrade_active=="true"`
# instead of `force_model` truthiness directly (G-1: an active downgrade with
# an imperfect read resolves downgrade_active="unknown" even though
# force_model is a real, known value — the cap silently skipped), and (b) it
# ran BEFORE the bandit overlay, which could still raise the tier back up
# and desync command_template afterward (G-2). Both are architecturally the
# same bug: two writers, two different signals, applied at two different
# times. Fixed by deleting BOTH from here and moving to a single
# `resolve_effective_model` choke-point in bash, AFTER the bandit overlay,
# which is now the ONLY place that decides the final model and builds
# command_template — see below the bandit overlay block.
# Reconcile GLM-FIRST-01 attribution with the FINAL arm: cost-ceiling / downgrade
# may mutate selected_model after the resolver ran. Python is the SOLE author of
# these two fields (bash no longer guesses). Never emit "unknown"; never invent a
# rule id — a sonnet arm carries the resolver's real rule, or null if sonnet is
# the natural default / a post-resolver mutation (never a fabricated id).
_final_base = selected_model.split("+")[0].split("-")[0]
if _final_base == "glm":
    routing_reason, glm_exception_rule = "glm_default", "null"
elif _final_base == "opus":
    routing_reason, glm_exception_rule = "opus_mission_kind", "null"
elif _final_base == "sonnet":
    routing_reason = "sonnet_exception"
    glm_exception_rule = _glm_resolver_rule if _glm_resolver_rule else "null"
else:
    routing_reason, glm_exception_rule = "other", "null"

print(f"model={selected_model}")
print(f"routing_reason={routing_reason}")
print(f"glm_exception_rule={glm_exception_rule}")
print(f"tool={tool}")
print(f"expected_cost_usd={expected_cost:.4f}")
print(f"expected_tokens={expected_tokens}")
print(f"ceiling_status={ceiling_status}")
print(f"downgrade_applied={str(downgrade_applied).lower()}")
print(f"escalated={str(escalated).lower()}")
print(f"current_burn_usd={current_burn:.6f}")
print(f"ceiling_usd={ceiling:.2f}")
# H3 fix (fix-round-1): ALL T8b recovery keys gated behind task_id — no-task
# routing calls (the vast majority of phase/step routing) get byte-identical
# stdout to pre-T8b baseline.
if task_id:
    print(f"recovery_status={recovery_status}")
    print(f"force_model={force_model}")
    print(f"downgrade_active={downgrade_active}")
    print(f"fresh_trip={fresh_trip}")
    print(f"hard_stop={'true' if hard_stop else 'false'}")
    print(f"burn_readable={'true' if burn_readable else 'false'}")
PYEOF

# Run the helper — argv[7]=agent-stats, argv[8]=priors-yaml
STATS_ARG="${AGENT_STATS_YAML:-}"

# T8b: acquire flock -s on the SAME .cost-flush.lock the cost-flush writer and
# _log_downgrade_event use (both -x), so the recovery-gate read never races a
# concurrent append (design §2 TOCTOU). Only when task-scoped — routing calls
# without --task-id have no costs.yaml to protect and keep the original
# unlocked invocation byte-identical.
#
# C2/H1 fix (fix-round-1): `flock -s 9 || true` used to proceed UNLOCKED on
# any flock failure — the exact TOCTOU hole the lock exists to close. Now:
# (a) `-w LEADV2_LOCK_WAIT_SEC` (default 10s) bounds the wait so a wedged
#     lock can never hang the task forever; (b) on a non-zero flock rc we
#     NEVER run python with an unlocked read — LEADV2_LOCK_ACQUIRED=0 tells
#     the python helper to skip BOTH costs.yaml reads (legacy cumulative +
#     recovery gate) and report burn_readable=false / recovery_status=unknown
#     (fail-safe HOLD), not silently degrade to an unlocked read.
_router_py_err="/tmp/leadv2-router-err.tmp"
LEADV2_LOCK_WAIT_SEC="${LEADV2_LOCK_WAIT_SEC:-10}"
_handle_py_helper_failure() {
  local err_code="$1"
  if [[ $err_code -eq 2 ]]; then
    log_warn "routing.yaml parse error or unknown phase/step — caller uses fallback"
    cat "$_router_py_err" >&2 2>/dev/null || true
    exit 2
  fi
  log_error "router python helper failed (exit $err_code)"
  cat "$_router_py_err" >&2 2>/dev/null || true
  exit 1
}

if [[ -n "${TASK_ID:-}" ]]; then
  _cost_flush_lock="${PROJECT_ROOT}/docs/handoff/${TASK_ID}/.cost-flush.lock"
  mkdir -p "$(dirname "$_cost_flush_lock")" 2>/dev/null || true
  result=$(
    (
      if flock -w "$LEADV2_LOCK_WAIT_SEC" -s 9; then
        LEADV2_LOCK_ACQUIRED=1 python3 "$PY_HELPER" \
          "$ROUTING_YAML" "$PHASE" "$STEP" "$SIGNALS" \
          "${TASK_ID:-}" "${TASK_CLASS:-Standard}" \
          "${STATS_ARG:-}" "${PRIORS_YAML:-}"
      else
        log_warn "could not acquire cost-flush lock within ${LEADV2_LOCK_WAIT_SEC}s — reporting fail-safe HOLD, no unlocked read"
        LEADV2_LOCK_ACQUIRED=0 python3 "$PY_HELPER" \
          "$ROUTING_YAML" "$PHASE" "$STEP" "$SIGNALS" \
          "${TASK_ID:-}" "${TASK_CLASS:-Standard}" \
          "${STATS_ARG:-}" "${PRIORS_YAML:-}"
      fi
    ) 9>"$_cost_flush_lock" 2>"$_router_py_err"
  ) || _handle_py_helper_failure "$?"
else
  result=$(python3 "$PY_HELPER" \
    "$ROUTING_YAML" "$PHASE" "$STEP" "$SIGNALS" \
    "${TASK_ID:-}" "${TASK_CLASS:-Standard}" \
    "${STATS_ARG:-}" "${PRIORS_YAML:-}" 2>"$_router_py_err") || _handle_py_helper_failure "$?"
fi

if [[ "$result" == "ROUTING_YAML_ERROR"* ]] || [[ "$result" == "UNKNOWN_PHASE_STEP"* ]]; then
  log_warn "routing returned: $result — using fallback"
  exit 2
fi

# SD-31: never exit 0 with an empty/model-less routing decision. A helper
# collision (or any other silent failure upstream) that leaves $result empty
# or without a `model=` line used to fall through to `exit 0` — a swallowed
# failure indistinguishable from a real routing decision. Fail loudly instead.
if [[ -z "$result" ]] || ! printf '%s\n' "$result" | grep -q '^model='; then
  log_error "router produced no 'model=' line (empty or malformed output) — refusing to exit 0"
  cat "$_router_py_err" >&2 2>/dev/null || true
  exit 1
fi

# Extract ceiling_status to decide exit code
ceiling_status=$(printf '%s\n' "$result" | grep '^ceiling_status=' | cut -d= -f2)

# ── [BANDIT-01] Route bandit overlay ──────────────────────────────────────────
BANDIT_ARM=""
BANDIT_DEVIATION="false"
BANDIT_CONTEXT_KEY=""
# F2 fix: extract heuristic model unconditionally so route-decisions.yaml is
# correct regardless of LEADV2_ROUTE_BANDIT state.
_heuristic_model=$(printf '%s\n' "$result" | grep '^model=' | cut -d= -f2)
# ROUTER-HAS-NO-GLM-ARM-01 fix: extract routing_reason the same way, so the
# bandit overlay below can tell when the python resolver fired a mandatory
# exception (sonnet_exception / opus_mission_kind) vs the free-choice default
# (glm_default) — the resolved arm in the former case is policy-locked and
# must not be escaped by the bandit.
_heuristic_routing_reason=$(printf '%s\n' "$result" | grep '^routing_reason=' | cut -d= -f2)

if [[ "${LEADV2_ROUTE_BANDIT:-0}" == "1" ]] \
   && [[ "$ceiling_status" != "hard_stop_95pct" ]]; then
  # Derive safety bucket: true if risk==critical OR change_kind contains auth/security
  _signals_risk=$(printf '%s\n' "$SIGNALS" | python3 -c "
import sys,json
s=json.loads(sys.stdin.read())
ck=s.get('change_kind','')
r=s.get('risk','')
print('true' if r=='critical' or 'auth' in str(ck) or 'security' in str(ck) else 'false')
" 2>/dev/null || printf 'false')
  BANDIT_CONTEXT_KEY="${PHASE}:${TASK_CLASS}:${_signals_risk}"

  # C2 fix (fix-round-2, ROUTER-HAS-NO-GLM-ARM-01): allowed_arms USED TO come
  # from a second, independent inline-python re-read of step_cfg
  # default/escalate_to — blind to the glm_policy resolver above. When the
  # resolver fired a mandatory exception (routing_reason != glm_default),
  # that re-read could produce an allowed set (e.g. ["glm"]) that does NOT
  # contain the resolver's own arm (e.g. sonnet) — the bandit was then
  # invoked with --allowed '["glm"]' --heuristic sonnet, a heuristic outside
  # its own allowed set, and the recorded row lied. Fixed: build _allowed
  # from $_heuristic_model (the resolver's already-decided arm) +
  # routing_reason, never a fresh independent yaml re-read.
  # Caller may still override via LEADV2_BANDIT_ALLOWED_ARMS env (JSON array)
  # — EXCEPT on the glm_default path (see fix-round-3 branch below), where
  # the policy itself, not a bandit-tunable knob, decides the allowed set.
  _heuristic_primary=$(printf '%s' "$_heuristic_model" | cut -d+ -f1)
  if [[ "$_heuristic_routing_reason" == "glm_default" ]]; then
    # fix-round-3 (ROUTER-HAS-NO-GLM-ARM-01): glm_default is NOT free-choice.
    # routing_reason=="glm_default" is derived (python resolver, end of
    # helper) from _final_base=="glm" — i.e. it can ONLY be emitted when the
    # resolved arm is glm. GLM-FIRST-01's exception list (sonnet_exceptions /
    # opus_only_mission_kinds) is the ONLY permitted path off glm; any of
    # those firing changes routing_reason away from glm_default and is
    # handled by the mandatory-heuristic branch below instead. Round-2's C2
    # fix built _allowed from routing.yaml's own `allowed_arms:` (e.g.
    # [glm, sonnet, opus]) on exactly this path, which let Thompson sampling
    # explore freely into sonnet/opus while routing_reason kept reporting
    # glm_default — silently landing default dev spawns on Claude quota
    # (the original disease this task exists to kill) while the record lied
    # about why. Pin allowed_arms to glm alone: a single-arm allowed set can
    # only ever sample that arm, so BANDIT_DEVIATION can never fire true here
    # and chosen_arm can never leave glm. This intentionally overrides
    # LEADV2_BANDIT_ALLOWED_ARMS too — the invariant must hold unconditionally,
    # not just when no caller override is present.
    _allowed='["glm"]'
  elif [[ -n "${LEADV2_BANDIT_ALLOWED_ARMS:-}" ]]; then
    _allowed="${LEADV2_BANDIT_ALLOWED_ARMS}"
  else
    # A fired glm_policy exception makes the resolver's arm mandatory, not a
    # bandit choice — allowed_arms is exactly the heuristic arm so chosen_arm
    # can never land outside its own allowed set.
    _allowed=$(python3 -c "import json,sys; print(json.dumps([sys.argv[1]]))" "$_heuristic_primary")
  fi

  # Only invoke bandit if route-bandit.sh exists; else fall through to heuristic
  _bandit_script="${SCRIPT_DIR}/leadv2-route-bandit.sh"
  if [[ -f "$_bandit_script" ]]; then
    _bandit_out=$(bash "$_bandit_script" sample \
      --context-key "$BANDIT_CONTEXT_KEY" \
      --allowed "$_allowed" \
      --heuristic "$(printf '%s' "$_heuristic_model" | cut -d+ -f1)" 2>/dev/null) || true

    if [[ -n "$_bandit_out" ]]; then
      _chosen=$(printf '%s\n' "$_bandit_out" | grep '^chosen_arm=' | cut -d= -f2)
      _heuristic_primary=$(printf '%s' "$_heuristic_model" | cut -d+ -f1)
      # ROUTER-HAS-NO-GLM-ARM-01 fix: when the python resolver fired a
      # mandatory exception (routing_reason != glm_default — e.g.
      # sonnet_exception for safety/publish/payments, or opus_mission_kind),
      # the resolved arm is NOT a suggestion the bandit may override. Fail
      # closed: discard any bandit proposal that differs from the resolver's
      # arm and keep the resolver's arm instead — never crash the router.
      if [[ "$_heuristic_routing_reason" != "glm_default" && "$_chosen" != "$_heuristic_primary" ]]; then
        log_warn "bandit proposed '${_chosen}' but routing_reason=${_heuristic_routing_reason} locks the arm to '${_heuristic_primary}' — discarding bandit proposal"
        _chosen="$_heuristic_primary"
      fi
      if [[ -n "$_chosen" && "$_chosen" != "$_heuristic_primary" ]]; then
        BANDIT_ARM="$_chosen"
        BANDIT_DEVIATION="true"
        # fix-round-3: bandit PROPOSES here (BANDIT_ARM/BANDIT_DEVIATION), it
        # does NOT get the last word — no more patching $result's model=
        # line directly. The resolve_effective_model choke-point below reads
        # BANDIT_ARM/BANDIT_DEVIATION to build proposed_model, then applies
        # the cap, then is the ONE place that writes model=/command_template=.
      else
        BANDIT_ARM="${_chosen:-}"
      fi
    fi
  else
    # Stub path: bandit script not yet present (Group A deliverable pending)
    # Use heuristic arm unchanged — emit empty bandit_arm
    : # no-op, heuristic arm unchanged
  fi
fi
# ── end bandit overlay ─────────────────────────────────────────────────────────

# ── [T8b] resolve_effective_model — SINGLE final choke-point (fix-round-3) ──
# G-1/G-2 fix. Rounds 1-2's cap kept re-desyncing because it lived at the
# WRONG point (before the bandit overlay) and keyed off the WRONG signal
# (`downgrade_active=="true"` as a string, instead of `force_model`
# truthiness directly). G-1 repro: an active downgrade with an imperfect
# read (0 cost rows / a bad timestamp) resolves downgrade_active="unknown"
# even though force_model is a real, known value (e.g. "sonnet") — the old
# condition silently skipped the cap. G-2 repro: the bandit overlay above
# ran AFTER the old cap and could raise the tier back up, desyncing
# command_template (built even earlier, before either).
#
# This is now the ONE place, decided exactly once, that resolves the final
# model for BOTH emitted fields: (1) proposed_model = base selection,
# possibly overridden by the bandit's pick above (bandit proposes, does NOT
# get the last word); (2) the cap is the LAST word, keyed off force_model
# truthiness (mirrors claude-subsession.sh's own F-D adopt-check, so router
# self-cap == consumer check) OR burn_readable==false OR hard_stop==true;
# (3) command_template is rebuilt from the resulting effective_model and
# model= is rewritten to match — a single python transform does both in one
# pass, so they can never desync again. No other code path may write either
# field after this point.
_force_model_val=$(printf '%s\n' "$result" | grep '^force_model=' | cut -d= -f2 || true)
_downgrade_active_val=$(printf '%s\n' "$result" | grep '^downgrade_active=' | cut -d= -f2 || echo "unknown")
_burn_readable_val=$(printf '%s\n' "$result" | grep '^burn_readable=' | cut -d= -f2 || echo "true")
_hard_stop_val=$(printf '%s\n' "$result" | grep '^hard_stop=' | cut -d= -f2 || echo "false")
_tool_val=$(printf '%s\n' "$result" | grep '^tool=' | cut -d= -f2)

_proposed_model="$_heuristic_model"
if [[ -n "$BANDIT_ARM" && "$BANDIT_DEVIATION" == "true" ]]; then
  _heuristic_primary_tok=$(printf '%s' "$_heuristic_model" | cut -d+ -f1)
  _proposed_model="${_heuristic_model/$_heuristic_primary_tok/$BANDIT_ARM}"
fi

_tier_rank() {
  local base
  base="$(printf '%s' "$1" | cut -d+ -f1 | sed -e 's/-subsession$//' -e 's/-agent-tool$//')"
  case "$base" in
    haiku) echo 0 ;;
    glm) echo 0 ;;
    sonnet|fable) echo 1 ;;
    opus) echo 2 ;;
    *) echo 1 ;;
  esac
}

_effective_model="$_proposed_model"
# G-3 fix-round-4 (surgical add — no re-architect): the trigger gained one
# more OR-branch, `downgrade_active=="true" AND force_model=="__HOLD__"` — a
# malformed downgrade_event row (valid timestamp, missing to_model).
# Previously this fell through uncapped (force_model isn't "real",
# burn_readable/hard_stop are both fine) even though there IS a confirmed
# active downgrade, while the consumer (claude-subsession.sh's mirrored
# check) already forces the safe floor in this exact shape.
#
# NOTE — spec deviation, documented (see build.md): the round-4 spec text
# also lists `downgrade_active=="unknown"` in this OR-branch. Empirically
# that collides with genuine day-0/never-spent (F-A): a fresh task with NO
# costs.yaml ALSO produces downgrade_active="unknown" + force_model=
# "__HOLD__" (the FileNotFoundError except path), and F-A is a confirmed,
# must-hold invariant (explicitly reconfirmed this round) that a never-spent
# task's first premium probe must NOT be capped. As of round-5, the except
# handler above (~line 472) pre-inits `active = False` and reads it to
# distinguish the two cases: a malformed EXISTING downgrade_event row (bad
# timestamp etc.) sets `active=True` before the parse raises, so its except
# path now writes downgrade_active="true" — not "unknown" — while true
# day-0 raises FileNotFoundError before `active` is ever touched and still
# lands on "unknown". That signal is what makes restricting this branch to
# downgrade_active=="true" ONLY safe: a malformed-active-row now genuinely
# reaches "true" here (fixing G-3's literal repro — a downgrade_event row
# that exists and parses, just incompletely) while day-0 stays "unknown"
# and never trips this OR-branch, so the F-A allowance still holds.
# Every other condition below is UNCHANGED from round-3.
if { [[ -n "$_force_model_val" && "$_force_model_val" != "__HOLD__" ]]; } \
   || [[ "$_burn_readable_val" == "false" ]] \
   || [[ "$_hard_stop_val" == "true" ]] \
   || { [[ "$_downgrade_active_val" == "true" ]] && [[ "$_force_model_val" == "__HOLD__" ]]; }; then
  _cap_target="$_force_model_val"
  if [[ -z "$_cap_target" || "$_cap_target" == "__HOLD__" ]]; then
    _cap_target="haiku"   # SAFE_FLOOR — lowest tier in the downgrade_chain
  fi
  if [[ $(_tier_rank "$_proposed_model") -gt $(_tier_rank "$_cap_target") ]]; then
    _effective_model="$_cap_target"
    log_warn "resolve_effective_model: capping ${_proposed_model} -> ${_effective_model} (force_model=${_force_model_val:-<empty>}, downgrade_active=${_downgrade_active_val}, burn_readable=${_burn_readable_val}, hard_stop=${_hard_stop_val})"
  fi
fi

# Exactly ONE writer for model= and command_template= — both rebuilt fresh
# from the SAME effective_model in a single pass, so they can never desync.
result=$(printf '%s\n' "$result" | EFFECTIVE_MODEL="$_effective_model" TOOL_VAL="$_tool_val" python3 -c "
import sys, os

effective_model = os.environ['EFFECTIVE_MODEL']
tool_val = os.environ['TOOL_VAL']

# G-5 fix-round-4 (CRITICAL, surgical): round-3 merged this into ONE f-string
# per branch — an f-string treats {{ / }} as an ESCAPE for a literal single
# brace, so every {{placeholder}} silently collapsed to {placeholder},
# breaking the documented double-brace template contract for 100% of router
# calls. Restored EXACTLY as pre-round-3: each branch is built from adjacent
# string-literal segments, where each segment is EITHER a plain (non-f)
# string — {{x}} stays four literal characters, never touched — OR a
# narrow f-string segment that interpolates ONLY primary_model. The ONLY
# value this function ever interpolates is the (capped) model; every
# {{role}}/{{task_id}}/{{mission}}/{{mission_file}} placeholder must survive
# verbatim for the downstream filler to substitute.
def build_command_template(tool_str, model_str):
    primary_model = model_str.split('+')[0].replace('-subsession', '').replace('-agent-tool', '')
    if primary_model in ('bash', 'bash+python', 'bash+yaml', 'mcp-calls-only', 'skip'):
        return f'# no-LLM: {primary_model}'
    if 'subsession' in tool_str or 'subsession' in model_str:
        return (
            'bash .claude/scripts/claude-subsession.sh '
            '--role {{role}} '
            f'--model {primary_model} '
            '--task-id {{task_id}} '
            '--mission-file {{mission}} '
            '--wait'
        )
    if primary_model == 'glm':
        # H6 fix (fix-round-2, ROUTER-HAS-NO-GLM-ARM-01): this whole python
        # source lives inside an OUTER bash python3 -c '...' style DOUBLE
        # quoted string (see the wrapper below) — NOTE: no backticks or bare
        # double quotes are safe anywhere in this comment block either, bash
        # expands both inside double quotes before python ever sees the
        # text. An unescaped literal double-quote character here used to
        # close that outer bash string early; bash then quote-removed it, so
        # the quote characters never reached python, and command_template
        # lost both quotes (live-verified via od -c: zero quote-char bytes
        # in the emitted bg dispatch line) — breaking path-with-space safety
        # on the new default dispatch path. Escaped with a leading backslash
        # so bash quote-removal emits a literal quote char into the argument
        # python actually receives, reproducing the intended python source.
        return (
            'bash ~/.claude/scripts/glm-coder.sh bg '
            '\"@{{mission_file}}\" '
            '--cwd {{cwd}}'
        )
    if primary_model in ('haiku', 'sonnet', 'opus', 'fable'):
        return (
            'Agent(subagent_type={{role}}, model='
            f'{primary_model}, '
            'prompt=<mission from {{mission_file}}>)'
        )
    raise SystemExit(f'ROUTER_UNKNOWN_MODEL: {primary_model} has no dispatch branch')

new_cmpl = build_command_template(tool_val, effective_model)
_wrote_cmpl = False
for line in sys.stdin:
    if line.startswith('model='):
        sys.stdout.write('model=' + effective_model + chr(10))
    elif line.startswith('command_template='):
        sys.stdout.write('command_template=' + new_cmpl + chr(10))
        _wrote_cmpl = True
    else:
        sys.stdout.write(line)
if not _wrote_cmpl:
    sys.stdout.write('command_template=' + new_cmpl + chr(10))
")
# ── end resolve_effective_model ─────────────────────────────────────────────

hard_stop_flag=$(printf '%s\n' "$result" | grep '^hard_stop=' | cut -d= -f2 || echo "false")
if [[ "$hard_stop_flag" == "true" ]]; then
  log_error "HARD STOP: task burn >= 95% of ceiling — refusing spawn for $PHASE/$STEP"
  printf '%s\n' "$result"
  exit 1
fi

if [[ "$ceiling_status" == "warn_60pct" ]]; then
  log_warn "burn >= 60% of ceiling — model may have been downgraded for $PHASE/$STEP"
fi

# ── [BANDIT-01] Append route-decisions.yaml entry (router owns this per §9) ──────
if [[ -n "${TASK_ID:-}" ]]; then
  _handoff_dir="${PROJECT_ROOT}/docs/handoff/${TASK_ID}"
  _route_decisions="${_handoff_dir}/route-decisions.yaml"
  _decided_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  # chosen_arm is the final model= from result (bandit may have patched it)
  _final_chosen=$(printf '%s\n' "$result" | grep '^model=' | cut -d= -f2)
  # heuristic_arm: _heuristic_model is always set unconditionally before bandit block (F2 fix).
  # Fallback to _final_chosen is kept as defensive guard only.
  _heuristic_arm="${_heuristic_model:-${_final_chosen}}"
  _bandit_active="false"
  [[ "${LEADV2_ROUTE_BANDIT:-0}" == "1" ]] && _bandit_active="true"
  # GLM-FIRST-01 attribution is authored SOLELY by the python resolver (which
  # reads glm_policy from routing.yaml). Bash no longer guesses the rule id from
  # an unrelated signal — it reads the resolver's decision out of result, the
  # same way _final_chosen is extracted above. "unknown" can no longer appear.
  _routing_reason="$(printf '%s\n' "$result" | grep '^routing_reason=' | cut -d= -f2-)"
  _glm_exception_rule="$(printf '%s\n' "$result" | grep '^glm_exception_rule=' | cut -d= -f2-)"
  _routing_reason="${_routing_reason:-other}"
  _glm_exception_rule="${_glm_exception_rule:-null}"
  # C1 fix (fix-round-2, ROUTER-HAS-NO-GLM-ARM-01): safety_touched USED TO be
  # printed from a leftover bandit-bucket calc off signals.risk/change_kind —
  # NOT the keys the resolver actually reads (safety_touched/protected_path),
  # so a row could say `safety_touched: false` in the same breath as
  # `glm_exception_rule: safety_gate_publish_payments`. Derive it from the
  # resolver's own fired-rule id instead — the two fields can never disagree.
  _safety_touched_val="false"
  [[ "$_glm_exception_rule" == "safety_gate_publish_payments" ]] && _safety_touched_val="true"
  mkdir -p "$_handoff_dir"
  _route_lock="${_handoff_dir}/.route-decisions.lock"
  (
    flock -x 200 || true
    printf -- '- phase: %s\n' "${PHASE}" >> "$_route_decisions"
    printf -- '  step: %s\n' "${STEP}" >> "$_route_decisions"
    printf -- '  task_class: %s\n' "${TASK_CLASS}" >> "$_route_decisions"
    printf -- '  safety_touched: %s\n' "${_safety_touched_val}" >> "$_route_decisions"
    printf -- '  heuristic_arm: %s\n' "${_heuristic_arm}" >> "$_route_decisions"
    printf -- '  allowed_arms: %s\n' "${_allowed:-[]}" >> "$_route_decisions"
    printf -- '  chosen_arm: %s\n' "${_final_chosen}" >> "$_route_decisions"
    printf -- '  policy_id: GLM-FIRST-01\n' >> "$_route_decisions"
    printf -- '  routing_reason: %s\n' "${_routing_reason}" >> "$_route_decisions"
    printf -- '  glm_exception_rule: %s\n' "${_glm_exception_rule}" >> "$_route_decisions"
    printf -- '  bandit_active: %s\n' "${_bandit_active}" >> "$_route_decisions"
    printf -- '  bandit_deviation: %s\n' "${BANDIT_DEVIATION}" >> "$_route_decisions"
    printf -- '  context_key: %s\n' "${BANDIT_CONTEXT_KEY}" >> "$_route_decisions"
    printf -- '  decided_at: "%s"\n' "${_decided_at}" >> "$_route_decisions"
  ) 200>"$_route_lock"
fi
# ── end route-decisions append ────────────────────────────────────────────────
printf '%s\n' "$result"
# F1 fix: bandit keys emitted only when flag is on — flag-off stdout is
# byte-identical to pre-BANDIT-01 baseline.
if [[ "${LEADV2_ROUTE_BANDIT:-0}" == "1" ]]; then
  printf 'bandit_arm=%s\n' "${BANDIT_ARM}"
  printf 'bandit_deviation=%s\n' "${BANDIT_DEVIATION}"
  printf 'bandit_context_key=%s\n' "${BANDIT_CONTEXT_KEY}"
fi

# ── [WORKFLOW-01] Workflow dispatch signal ──────────────────────────────────
# Emit USE_WORKFLOW=1 for Phase 2 (plan) and Phase 5 (review) when the
# workflow flag is enabled. Callers (phases.md §Phase 2 + §Phase 5) check this
# key before choosing Workflow vs inline path. Flag-off: key absent from stdout
# so pre-WORKFLOW-01 callers are unaffected (byte-identical baseline).
if [[ "${LEADV2_WORKFLOW_ENABLED:-0}" == "1" ]]; then
  case "$PHASE" in
    plan|review)
      printf 'USE_WORKFLOW=1\n'
      ;;
  esac
fi
# ── end workflow signal ──────────────────────────────────────────────────────
exit 0
