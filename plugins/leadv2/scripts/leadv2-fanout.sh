#!/usr/bin/env bash
# leadv2-fanout.sh — dispatch N independent /leadv2 sessions, each in its own
# tmux window, terminal window (macOS osascript), or headless background
# process, each in its own git worktree (worktree isolation is handled by
# Phase 0 of the spawned /leadv2 session itself — this script only SELECTS
# tasks and LAUNCHES sessions; it never creates worktrees).
#
# Backend selection (LEAD-ANCHOR-01 tmux launch backend, 2026-07-14):
#   --tmux      force tmux backend: one shared tmux session named "leadv2",
#               one WINDOW per task (named after the task id). Reuses the
#               existing "leadv2" session if present instead of creating a
#               second one. Survives Terminal.app window close/quit — this is
#               why it exists: an accidental Terminal.app window close used to
#               kill a live /leadv2 session outright.
#   --windows   force the old Terminal.app/iTerm2 osascript backend.
#   --headless  background nohup/setsid process, no terminal at all.
#   (none)      DEFAULT on macOS: tmux if `tmux` is on PATH, else --windows
#               with a warning on stderr. Non-macOS default: --windows (errors
#               asking for --headless, unchanged prior behavior).
#
# Usage:
#   leadv2-fanout.sh [--n N] [--filter STR] [--tasks ID1,ID2,ID3]
#                     [--provider auto|claude|codex]
#                     [--dry-run] [--tmux|--windows|--headless]
#
# Task LEAD-FANOUT-01. See docs/handoff/LEAD-ANCHOR-01/mission-fanout.md.
#
# Env overrides (test hook):
#   LEADV2_PROJECT_ROOT / CLAUDE_PROJECT_DIR / PROJECT_ROOT — repo root
#   LEADV2_FANOUT_CLAUDE_BIN — override the `claude` binary (tests stub this)
#   LEADV2_FANOUT_TMUX_SESSION — override the tmux session name (default
#     "leadv2"). Tests use this to avoid ever touching a real "leadv2"
#     session; never override this for a real launch.
#
# Exit codes: 0 = ran (dry-run or real). 1 = hard failure (broken active.yaml,
# unsupported platform, bad args). Fail-CLOSED: any doubt about session
# accounting refuses to launch rather than risk two leads in one worktree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}}"

# LEAD-CONTROL-PLANE-01: source the repo-vendored copy (kept current by
# leadv2-plugin-sync.sh, patched locally for this task) rather than the
# shared-tree original — the vendored copy resolves active.yaml through
# scripts/leadv2-state-path.sh (control-plane root), the shared original
# still hardcodes docs/leadv2/active.yaml.
_REGISTRY_SH="${PROJECT_ROOT}/.claude/scripts/leadv2-active-registry.sh"
[[ -f "$_REGISTRY_SH" ]] || _REGISTRY_SH="${HOME}/.claude/leadv2-shared/scripts/leadv2-active-registry.sh"
# shellcheck source=/dev/null
source "$_REGISTRY_SH"

log() { printf -- '[fanout] %s\n' "$*" >&2; }
log_error() { log "ERROR: $*"; }

# DRIFT-GUARD PREFLIGHT (PLUGIN-CACHE-THIRD-COPY-REVERTS-FIXES-01): refuse to
# fan out onto scripts that may be silently stale in this copy. Fanout is the
# highest-blast-radius launcher of the 5 copies (it dispatches N independent
# sessions using this repo's vendored .claude/scripts/) — exactly the surface
# that silently ran on 4 reverted fixes for an hour undetected. Set
# LEADV2_SKIP_DRIFT_GUARD=1 to bypass (tests / intentional single-copy work).
#
# C1 fix (review-1.md, fix1): a hard `exit 1` here blocked ALL fanout dispatch
# the moment known, off-limits-protected SUPERVISE-V2-01 WIP drift existed in
# the LOWEST-blast-radius copy (leadv2-repo-vendored, i.e.
# ~/Projects/leadv2/.claude/scripts/ — a copy fanout itself does not read
# scripts from). We now inspect --json output: if EVERY drifted entry belongs
# to that one copy, WARN and proceed; any drift in a copy fanout actually
# reads from (cache/shared/vendored[repo]) still hard-blocks.
_DRIFT_GUARD="${SCRIPT_DIR}/leadv2-drift-guard.sh"
if [[ "${LEADV2_SKIP_DRIFT_GUARD:-0}" != "1" ]] && [[ -f "${_DRIFT_GUARD}" ]]; then
  _drift_json=""
  _drift_rc=0
  _drift_json="$(bash "${_DRIFT_GUARD}" --quiet --json)" || _drift_rc=$?
  if [[ "${_drift_rc}" -ne 0 ]]; then
    _only_vendored_drift=0
    _CLASSIFY="${SCRIPT_DIR}/leadv2-drift-only-vendored-check.py"
    if [[ -f "${_CLASSIFY}" ]] && command -v python3 >/dev/null 2>&1; then
      _only_vendored_drift="$(python3 "${_CLASSIFY}" "${_drift_json}")"
    fi
    if [[ "${_only_vendored_drift}" == "1" ]]; then
      log "WARN: drift detected but confined to the leadv2-repo-vendored copy (known SUPERVISE-V2-01 WIP, off-limits-protected, lowest blast radius — fanout does not read scripts from this copy) — proceeding with dispatch. Run 'bash ${_DRIFT_GUARD}' for details."
    else
      log_error "drift detected across the 5 leadv2 script copies — refusing to fan out on possibly-stale scripts. Run 'bash ${_DRIFT_GUARD}' for details, then 'bash ~/Projects/leadv2/plugins/leadv2/scripts/leadv2-plugin-sync.sh' from canonical to reconcile. Override: LEADV2_SKIP_DRIFT_GUARD=1."
      exit 1
    fi
  fi
fi

TASKS_YAML="${PROJECT_ROOT}/docs/tasks.yaml"
ACTIVE_YAML="$(_leadv2_yaml_file)"

# ── Arg parsing ─────────────────────────────────────────────────────────────
N=3
FILTER=""
EXPLICIT_TASKS=""
DRY_RUN=false
HEADLESS=false
FORCE=false
TMUX_FLAG=false
WINDOWS_FLAG=false
LEAD_MODEL_OVERRIDE=""
PROVIDER_REQUEST="${LEADV2_SESSION_PROVIDER:-auto}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n)          N="$2";                  shift 2 ;;
    --filter)     FILTER="$2";             shift 2 ;;
    --tasks)      EXPLICIT_TASKS="$2";     shift 2 ;;
    --dry-run)    DRY_RUN=true;            shift   ;;
    --headless)   HEADLESS=true;           shift   ;;
    --tmux)       TMUX_FLAG=true;          shift   ;;
    --windows)    WINDOWS_FLAG=true;       shift   ;;
    --force)      FORCE=true;              shift   ;;
    --lead-model) LEAD_MODEL_OVERRIDE="$2"; shift 2 ;;
    --provider)   PROVIDER_REQUEST="$2";   shift 2 ;;
    -h|--help)
      printf -- 'Usage: leadv2-fanout.sh [--n N] [--filter STR] [--tasks ID1,ID2] [--provider auto|claude|codex] [--dry-run] [--tmux|--windows|--headless] [--force] [--lead-model MODEL]\n'
      printf -- '  --tmux: one shared tmux session "leadv2", one window per task. Default\n'
      printf -- '          backend on macOS when tmux is on PATH.\n'
      printf -- '  --windows: force Terminal.app/iTerm2 osascript windows (old default).\n'
      printf -- '  --headless: background nohup process, no terminal/tmux at all.\n'
      printf -- '  --force: bypass active.yaml meta caps (hard_limit/standard_max/light_max/\n'
      printf -- '           heavy_strategic_solo). Never bypasses the same-task-already-active\n'
      printf -- '           check — that is the worktree-collision safety net, not a policy cap.\n'
      printf -- '  --lead-model MODEL: override the per-task classifier model for EVERY child\n'
      printf -- '           launched by this invocation (default: classifier picks sonnet for\n'
      printf -- '           Light/Standard, opus for Heavy/Strategic). Use `--lead-model opus`\n'
      printf -- '           when the founder explicitly wants an Opus child; never on by default.\n'
      printf -- '  --provider auto|claude|codex: provider for COMPLETE Phase 0..8 child\n'
      printf -- '           sessions. auto routes routine work by live policy/quota; high-risk\n'
      printf -- '           classes/tags remain on Claude unless an explicit policy override exists.\n'
      exit 0
      ;;
    *) log_error "unknown arg: $1"; exit 1 ;;
  esac
done

case "$PROVIDER_REQUEST" in
  auto|claude|codex) ;;
  *) log_error "--provider must be auto, claude, or codex (got: $PROVIDER_REQUEST)"; exit 1 ;;
esac

if [[ -n "$LEAD_MODEL_OVERRIDE" ]]; then
  log "--lead-model override active: every launch this run uses model=${LEAD_MODEL_OVERRIDE} (classifier's per-task pick is ignored for model; effort is unaffected)"
  if [[ "$PROVIDER_REQUEST" == "auto" ]]; then
    case "$LEAD_MODEL_OVERRIDE" in
      gpt-*|codex-*) PROVIDER_REQUEST="codex" ;;
      *)            PROVIDER_REQUEST="claude" ;;
    esac
    log "--lead-model implies provider=${PROVIDER_REQUEST}; use --provider explicitly to override"
  fi
fi

if ! [[ "$N" =~ ^[0-9]+$ ]]; then
  log_error "--n must be a non-negative integer, got '$N'"
  exit 1
fi

# ── Backend resolution ──────────────────────────────────────────────────────
# Precedence: --headless > --tmux > --windows > platform default. Platform
# default (no flag given) is tmux on macOS when tmux is on PATH, else
# windowed with a stderr warning (fail-soft, never fail-closed on backend
# choice — worktree-collision safety net above is the only fail-closed gate).
if [[ "$HEADLESS" == "true" ]]; then
  BACKEND="headless"
elif [[ "$TMUX_FLAG" == "true" ]]; then
  BACKEND="tmux"
elif [[ "$WINDOWS_FLAG" == "true" ]]; then
  BACKEND="windows"
elif [[ "$(uname -s)" == "Darwin" ]] && command -v tmux >/dev/null 2>&1; then
  BACKEND="tmux"
else
  BACKEND="windows"
fi

if [[ "$BACKEND" == "tmux" ]] && ! command -v tmux >/dev/null 2>&1; then
  log_error "tmux requested/defaulted but not found on PATH — falling back to --windows"
  BACKEND="windows"
fi

# ── Fail-CLOSED: active.yaml must exist and parse cleanly ─────────────────
if [[ ! -f "$ACTIVE_YAML" ]]; then
  log_error "active.yaml not found at $ACTIVE_YAML — refusing to fan out (fail-closed)"
  exit 1
fi
if ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$ACTIVE_YAML" >/dev/null 2>&1; then
  log_error "active.yaml at $ACTIVE_YAML is not valid YAML — refusing to fan out (fail-closed). Fix or restore it before retrying."
  exit 1
fi
if [[ ! -f "$TASKS_YAML" ]]; then
  log_error "tasks.yaml not found at $TASKS_YAML — refusing to fan out"
  exit 1
fi

# ── Selection + limit simulation (single python3 pass) ─────────────────────
# Caps are read from active.yaml meta ONLY, at runtime, every invocation —
# no overrides file, no script-side constant. Fix for LEAD-FANOUT-01 defect 1
# (2026-07-14): an earlier version also consulted
# .claude/leadv2-overrides/active-limits.yaml with overrides-wins precedence
# (mirroring leadv2-active-registry.sh::leadv2_active_check_limits). That file
# still had stale hard_limit:3/standard_max:2 committed, so it silently beat
# the founder's live meta:20/20/20 edit — a self-inflicted, unrequested
# feature (the mission never asked for overrides support). Removed outright;
# active.yaml meta is now the single source of truth for fanout's caps.
# self-spawn.sh::_task_class convention (context.class or class, default
# Standard) is mirrored for class. class is currently always Standard on the
# live tasks.yaml (no context/class column in the generated schema) —
# heavy_strategic_solo logic still runs so it activates the moment a Heavy
# task lands in tasks.yaml.
# lean: no depends_on / conflicts_with cross-check here — Phase 0 of the
# spawned session already enforces collision-check + lock; upgrade when
# fanout needs to pre-filter conflicting file footprints before launch.
# --force bypasses the CONFIGURED ceiling (hard_limit/standard_max/light_max/
# heavy_strategic_solo, all read live from active.yaml meta) — it does NOT
# bypass the same-task-already-active exclusion, which is the actual
# worktree-collision safety net this task exists to protect.
set +e
PLAN_TSV="$(python3 - "$TASKS_YAML" "$ACTIVE_YAML" "$N" "$FILTER" "$EXPLICIT_TASKS" "$FORCE" "$SCRIPT_DIR" <<'PYEOF'
import os, subprocess, sys, yaml

tasks_yaml, active_yaml, n_str, filt, explicit_csv, force_str, script_dir = sys.argv[1:8]
n = int(n_str)
filt = filt.lower()
explicit_ids = [t for t in explicit_csv.split(",") if t] if explicit_csv else []
force = force_str.lower() == "true"

with open(active_yaml, encoding="utf-8") as fh:
    active = yaml.safe_load(fh) or {}
meta = active.get("meta") or {}
sessions = [s for s in (active.get("sessions") or []) if not s.get("stale")]
active_task_ids = {str(s.get("task_id")) for s in sessions}

# active.yaml meta is the ONLY source for caps — read fresh every run, no
# overrides file, no hardcoded ceiling. Fallback defaults below only apply
# when a key is truly absent from meta (fresh/incomplete active.yaml).
# P0 concurrency fix (leadv2 0.2 audit): default hard_limit dropped 20 -> 2 —
# each child is an independent full-context session, so a high default
# multiplies token spend. Still fully overridable: any founder edit to
# active.yaml meta.hard_limit wins (this default only applies when the key is
# absent), preserving the LEAD-FANOUT-01 single-source-of-truth decision above.
hard_limit           = int(meta.get("hard_limit", 2))
# HEAVY-MAX-2-WITH-COLLISION-GUARD-01: heavy_max is now the SOLE control for
# concurrent Heavy/strategic lanes (was a blanket heavy_strategic_solo=True
# rule). Legacy heavy_strategic_solo is honored ONLY as the fallback default
# when heavy_max is absent from meta (very old active.yaml, back-compat) --
# or as an explicit kill-switch when a founder sets it True even with
# heavy_max present (forces serialize, heavy_max effectively 1).
heavy_max            = int(meta.get("heavy_max", 2))
if "heavy_max" in meta:
    heavy_strategic_solo = bool(meta.get("heavy_strategic_solo", False))
else:
    heavy_strategic_solo = bool(meta.get("heavy_strategic_solo", True))
light_max            = int(meta.get("light_max", 3))
standard_max         = int(meta.get("standard_max", 2))

total_active    = len(sessions)
light_count     = sum(1 for s in sessions if str(s.get("class", "")).lower() == "light")
standard_count  = sum(1 for s in sessions if str(s.get("class", "")).lower() in ("standard", "standard-light"))
heavy_sessions  = [s for s in sessions if str(s.get("class", "")).lower() in ("heavy", "strategic")]
heavy_count     = len(heavy_sessions)
heavy_active    = any(str(s.get("class", "")).lower() in ("heavy", "strategic") for s in sessions)

# Prod-risk tag set: a Heavy carrying any of these can never co-run with
# another Heavy carrying any of these -- both sides must be non-prod AND
# occupy disjoint subsystems (group_key) to co-run. Fail-closed (F3) on a
# missing/malformed/empty signal: unknown is treated as prod-risk, never as
# "no intersection => safe to co-run".
PROD_RISK_TAGS = {"publish", "deploy", "migration", "prod", "prod-deploy"}

def _norm_tags(raw):
    if isinstance(raw, (list, tuple, set)):
        parts = [str(x).strip().lower() for x in raw if str(x).strip()]
    elif isinstance(raw, str):
        s = raw.strip()
        if not s or s.lower() in ("-", "none", "null"):
            return None
        parts = [p.strip().lower() for p in s.split(",") if p.strip()]
    else:
        return None
    return set(parts) if parts else None

def _group_key_unknown(gk):
    if gk is None:
        return True
    s = str(gk).strip().lower()
    return s in ("", "-", "none", "null")

# FIX1/FIX2 (Codex Phase-5 review, HEAVY-MAX-2-WITH-COLLISION-GUARD-01): the
# prior _heavy_collision() folded "unknown" into the prod predicate with AND
# (`_is_prod_or_unknown(cand) and _is_prod_or_unknown(other)`), so an
# unknown-risk/unknown-group candidate could co-run with a KNOWN-non-prod
# Heavy as long as the other side wasn't also unknown/prod. That is the
# opposite of fail-closed. Collide (serialize) if ANY of these hold, each an
# INDEPENDENT clause -- never AND'd across sides:
#   - unknown_risk(cand)  OR unknown_risk(other)   -> HARD
#   - unknown_group(cand) OR unknown_group(other)  -> HARD
#   - both_prod(cand, other)                       -> HARD
#   - same_known_group(cand, other)                -> SOFT *only* when both
#     sides are known-non-prod (neither unknown, neither carrying a prod-risk
#     tag) -- any other same-known-group pairing (e.g. one side prod, one
#     not) fails closed to HARD rather than being left unclassified.
# Business rule preserved: KNOWN-non-prod + KNOWN-non-prod with DIFFERENT
# known groups -> no collision, co-run allowed.
# Returns "hard", "soft", or None (no collision).
def _heavy_collision_kind(cand_gk, cand_tags, other_gk, other_tags):
    cand_tags_set = _norm_tags(cand_tags)
    other_tags_set = _norm_tags(other_tags)
    cand_unknown_risk = cand_tags_set is None
    other_unknown_risk = other_tags_set is None
    cand_unknown_group = _group_key_unknown(cand_gk)
    other_unknown_group = _group_key_unknown(other_gk)

    cand_prod = bool(cand_tags_set & PROD_RISK_TAGS) if cand_tags_set else False
    other_prod = bool(other_tags_set & PROD_RISK_TAGS) if other_tags_set else False
    both_prod = cand_prod and other_prod

    if cand_unknown_risk or other_unknown_risk or cand_unknown_group or other_unknown_group or both_prod:
        return "hard"

    same_known_group = str(cand_gk).strip().lower() == str(other_gk).strip().lower()
    if same_known_group:
        # Neither side is unknown or prod here (both branches above already
        # returned) -- this is exactly the bypassable SOFT case.
        return "soft"
    return None

try:
    with open(tasks_yaml, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
except Exception as e:
    print(f"[fanout] ERROR: tasks.yaml failed to parse: {e}", file=sys.stderr)
    sys.exit(1)
tasks = doc.get("tasks") if isinstance(doc, dict) else doc
tasks = tasks or []

CLASSIFY_SCRIPT = os.path.join(script_dir, "leadv2-fanout-classify.sh")

# SUPERVISOR-RETRO-01 item 1: replace the old missing-class -> "Standard"
# silent fallback with the pre-launch classifier. An explicit class already
# present on the task row is passed through as --existing-class and still
# wins (classifier preserves Heavy/Strategic, or a non-Standard class with
# no risk signal); "Standard" absence is exactly the gap being closed.
_classify_cache = {}


def classify_task(t):
    tid = str(t.get("id"))
    if tid in _classify_cache:
        return _classify_cache[tid]
    intent = str(t.get("intent") or t.get("title") or "")
    tags = t.get("tags") or t.get("labels") or []
    tags_csv = ",".join(str(x) for x in tags) if isinstance(tags, list) else str(tags)
    existing = str((t.get("context") or {}).get("class") or t.get("class") or "")

    # C2 fix (SUPERVISE-V2-01 fix-1): existence guard, loud WARN, and a SAFE
    # fallback -- never a silent Heavy/opus escalation. A missing/non-
    # executable classifier used to fall into the except branch below on
    # EVERY task (its only trigger was FileNotFoundError from a script that
    # didn't exist in this repo), force-upgrading every launch to Heavy/opus
    # and burning the scarce Claude-Max bucket, with the cause buried in an
    # unread report-line `reason` string. Preserve the existing tasks.yaml
    # class (or Standard) instead, and print the WARN to stderr where a human
    # actually sees it.
    if not (os.path.isfile(CLASSIFY_SCRIPT) and os.access(CLASSIFY_SCRIPT, os.X_OK)):
        print(f"[fanout] WARN: leadv2-fanout-classify.sh missing/not executable at {CLASSIFY_SCRIPT} -- "
              f"task={tid} falls back to existing class ({existing or 'Standard'}), NOT auto-escalated to Heavy. "
              "Run leadv2-plugin-sync.sh to fix.", file=sys.stderr)
        fallback_class = existing if existing else "Standard"
        fallback_model = "opus" if fallback_class.lower() in ("heavy", "strategic") else "sonnet"
        fallback_effort = "high" if fallback_class.lower() in ("heavy", "strategic") else "medium"
        result = (fallback_class, "", "classify script unavailable -- safe fallback, no risk escalation", fallback_model, fallback_effort)
        _classify_cache[tid] = result
        return result

    try:
        proc = subprocess.run(
            [CLASSIFY_SCRIPT, "--intent", intent, "--tags", tags_csv, "--existing-class", existing],
            capture_output=True, text=True, timeout=5, check=True,
        )
        out = {}
        for line in proc.stdout.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k] = v
        result = (
            out.get("launch_class", "Standard") or "Standard",
            out.get("risk_tags", ""),
            out.get("reason", ""),
            out.get("lead_model", "sonnet") or "sonnet",
            out.get("lead_effort", "medium") or "medium",
        )
    except Exception as e:
        # Classifier crash (script exists but errored at runtime) is NOT a
        # "no signal" case -- escalate to Heavy/opus rather than silently
        # falling back to Standard (the exact bug this task fixes), but LOUD
        # this time: print the WARN so it isn't buried in an unread report
        # line. A human reviews the fanout report before anything runs.
        print(f"[fanout] WARN: leadv2-fanout-classify.sh crashed for task={tid} ({e}) -- "
              "escalating to Heavy/opus (conservative default on classifier crash).", file=sys.stderr)
        result = ("Heavy", "classifier_error", f"classifier failed: {e}", "opus", "high")
    _classify_cache[tid] = result
    return result

# Fix for LEAD-FANOUT-01 defect 2 (2026-07-14): tasks.yaml has NO literal
# `title` column (verified: 0/211 rows on the live generated schema). Every
# row DOES carry `intent` (a human-written one-liner, e.g.
# "BACKLOG-TRUTH-01: no live backlog -- ..."), which is the closest thing to
# a title this schema has. Use it, truncated for display; if a task has
# neither `title` nor `intent`, say so explicitly per-row instead of
# silently printing the bare hash.
NO_TITLE_COLUMN = not any("title" in t for t in tasks)

def task_title(t):
    raw = t.get("title") or t.get("intent")
    if not raw:
        return "(no title/intent field on this task)"
    raw = " ".join(str(raw).split())  # collapse newlines/tabs/extra spaces
    return raw if len(raw) <= 80 else raw[:77] + "..."

by_id = {str(t.get("id")): t for t in tasks}

rows = []  # (decision, task_id, label, cls, priority, reason, risk_tags, lead_model, lead_effort)

if explicit_ids:
    ordered = []
    for tid in explicit_ids:
        t = by_id.get(tid)
        if t is None:
            rows.append(("skip", tid, tid, "?", "", "not found in tasks.yaml", "", "", "", ""))
            continue
        ordered.append(t)
else:
    candidates = [
        t for t in tasks
        if str(t.get("status", "")) == "queued" and str(t.get("id")) not in active_task_ids
    ]
    if filt:
        candidates = [
            t for t in candidates
            if filt in str(t.get("id", "")).lower()
            or filt in str(t.get("group_key", "")).lower()
            or filt in str(t.get("intent", "")).lower()
        ]
    candidates.sort(
        key=lambda t: (-int(t.get("priority", 0) or 0),
                       -int(t.get("group_priority", 0) or 0),
                       str(t.get("id", "")))
    )
    ordered = candidates[:n]

# Heavy/strategic footprints claimed THIS run (F2): a 2nd Heavy selected in
# the SAME fanout pass must collision-check against the 1st, not only
# against live sessions from the active.yaml snapshot. list[(group_key, risk_tags)].
heavy_claimed_this_run = []

for t in ordered:
    tid = str(t.get("id"))
    label = task_title(t)
    cls, risk_tags, class_reason, lead_model, lead_effort = classify_task(t)
    cls_l = cls.lower()
    pri = t.get("priority", "")
    cand_group_key = t.get("group_key")

    # Unconditional, never bypassed by --force: this IS the worktree-collision
    # safety net (two leads claiming the same task_id == two leads in the
    # same worktree, the exact failure this task exists to prevent).
    if tid in active_task_ids:
        rows.append(("skip", tid, label, cls, pri, "already in active.yaml (session running)", risk_tags, lead_model, lead_effort, cand_group_key))
        continue

    if explicit_ids and str(t.get("status", "")) != "queued":
        rows.append(("skip", tid, label, cls, pri, f"not queued (status={t.get('status')})", risk_tags, lead_model, lead_effort, cand_group_key))
        continue

    # hard_violation: NEVER --force-bypassable (F5) -- hard_limit and
    # heavy_max are ceilings, not policy defaults. soft_violation: the legacy
    # solo kill-switch, per-class caps, and the collision-serialize decision
    # remain --force-overridable, unchanged from prior behavior.
    hard_violation = None
    soft_violation = None
    if total_active >= hard_limit:
        hard_violation = f"hard_limit reached ({total_active}/{hard_limit})"
    elif cls_l in ("heavy", "strategic"):
        claimed_heavy = heavy_count + len(heavy_claimed_this_run)
        if heavy_strategic_solo:
            if claimed_heavy > 0:
                soft_violation = "heavy_strategic_solo: another Heavy/strategic session already active/claimed — heavy must run alone"
        elif claimed_heavy >= heavy_max:
            hard_violation = f"heavy_max reached ({claimed_heavy}/{heavy_max})"
        else:
            kinds = [
                _heavy_collision_kind(cand_group_key, risk_tags, s.get("group_key"), s.get("risk_tags"))
                for s in heavy_sessions
            ] + [
                _heavy_collision_kind(cand_group_key, risk_tags, prev_gk, prev_tags)
                for (prev_gk, prev_tags) in heavy_claimed_this_run
            ]
            # FIX2: a HARD collision (both_prod OR any unknown risk/group) is
            # NEVER --force-bypassable -- it goes in hard_violation. Only a
            # SOFT collision (same known-non-prod group only) stays
            # --force-overridable via soft_violation.
            if "hard" in kinds:
                hard_violation = "heavy collision (prod/unknown footprint) — serialize, not force-bypassable"
            elif "soft" in kinds:
                soft_violation = "heavy collision (same known group) — serialize"
    elif heavy_active or heavy_claimed_this_run:
        soft_violation = "heavy/strategic session active — solo rule blocks others"
    elif cls_l == "light" and light_count >= light_max:
        soft_violation = f"light cap reached ({light_count}/{light_max})"
    elif cls_l in ("standard", "standard-light") and standard_count >= standard_max:
        soft_violation = f"standard cap reached ({standard_count}/{standard_max})"

    violation = hard_violation or soft_violation
    if violation and (hard_violation or not force):
        rows.append(("skip", tid, label, cls, pri, violation, risk_tags, lead_model, lead_effort, cand_group_key))
        continue

    reason = f"selected ({class_reason})" if not violation else f"FORCE OVERRIDE — would have hit: {violation}"
    rows.append(("launch", tid, label, cls, pri, reason, risk_tags, lead_model, lead_effort, cand_group_key))
    total_active += 1
    if cls_l in ("heavy", "strategic"):
        heavy_claimed_this_run.append((cand_group_key, risk_tags))
        heavy_active = True
    elif cls_l == "light":
        light_count += 1
    else:
        standard_count += 1

print(f"__NO_TITLE_COLUMN__\t{NO_TITLE_COLUMN}")
for r in rows:
    # bash `read` with IFS=$'\t' collapses RUNS of tab (tab is IFS-whitespace-
    # class, not a plain delimiter) -- an empty field (e.g. no risk_tags)
    # would silently swallow a tab and shift every later field left by one.
    # "-" is the on-the-wire empty marker; the bash consumer below undoes it.
    print("\t".join((str(x).replace("\t", " ").replace("\n", " ") or "-") for x in r))
PYEOF
)"
PY_RC=$?
if [[ $PY_RC -ne 0 ]]; then
  log_error "selection failed (rc=$PY_RC) — refusing to fan out"
  exit 1
fi

LAUNCH_COUNT=0
SKIP_COUNT=0
FORCED_ANY=false
NO_TITLE_COLUMN=false
declare -a LAUNCH_IDS=() LAUNCH_CLASSES=() LAUNCH_LABELS=()
declare -a LAUNCH_MODELS=() LAUNCH_EFFORTS=() LAUNCH_RISK_TAGS=() LAUNCH_REASONS=()
declare -a LAUNCH_PROVIDERS=() LAUNCH_ROUTE_REASONS=() LAUNCH_GROUP_KEYS=()
declare -a REPORT_LINES=()

SESSION_ROUTER="${LEADV2_SESSION_ROUTER:-$SCRIPT_DIR/leadv2-session-route.sh}"
if [[ ! -x "$SESSION_ROUTER" ]]; then
  log_error "provider router missing/not executable at $SESSION_ROUTER — refusing to launch an unclassified provider session"
  exit 1
fi

while IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 f7 f8 f9 f10; do
  [[ -z "$f1" ]] && continue
  if [[ "$f1" == "__NO_TITLE_COLUMN__" ]]; then
    [[ "$f2" == "True" ]] && NO_TITLE_COLUMN=true
    continue
  fi
  decision="$f1" tid="$f2" label="$f3" cls="$f4" pri="$f5" reason="$f6"
  risk_tags="$f7" lead_model="$f8" lead_effort="$f9" group_key="$f10"
  # undo the "-" empty-field marker (see PLAN_TSV emission comment above)
  [[ "$risk_tags" == "-" ]] && risk_tags=""
  [[ "$group_key" == "-" ]] && group_key=""
  # --lead-model CLI override wins over the classifier's per-task pick for
  # EVERY launch this run — opt-out valve for a founder-requested Opus child.
  # Effort is left as the classifier chose it (override is model-only).
  if [[ -n "$LEAD_MODEL_OVERRIDE" && "$decision" == "launch" ]]; then
    lead_model="$LEAD_MODEL_OVERRIDE"
    reason="${reason} (--lead-model override -> ${LEAD_MODEL_OVERRIDE})"
  fi
  if [[ "$decision" == "launch" ]]; then
    set +e
    route_output="$(LEADV2_PROJECT_ROOT="$PROJECT_ROOT" "$SESSION_ROUTER" \
      --class "$cls" \
      --risk-tags "$risk_tags" \
      --suggested-model "${lead_model:-sonnet}" \
      --suggested-effort "${lead_effort:-medium}" \
      --provider "$PROVIDER_REQUEST")"
    route_rc=$?
    set -e
    if [[ "$route_rc" -ne 0 ]]; then
      log_error "provider routing failed for task=${tid} (rc=${route_rc}) — refusing to launch"
      exit 1
    fi
    route_provider="" route_model="" route_effort="" route_reason=""
    while IFS='=' read -r route_key route_value; do
      case "$route_key" in
        provider) route_provider="$route_value" ;;
        model)    route_model="$route_value" ;;
        effort)   route_effort="$route_value" ;;
        reason)   route_reason="$route_value" ;;
      esac
    done <<< "$route_output"
    if [[ -z "$route_provider" || -z "$route_model" || -z "$route_effort" ]]; then
      log_error "provider router returned an incomplete decision for task=${tid} — refusing to launch"
      exit 1
    fi
    # An explicit model is the founder's final model choice. Provider inference
    # above keeps aliases on the correct runtime; the router still owns all
    # high-risk/provider-availability decisions.
    if [[ -n "$LEAD_MODEL_OVERRIDE" ]]; then
      if [[ "$route_provider" == "codex" && "$LEAD_MODEL_OVERRIDE" == gpt-* ]] \
         || [[ "$route_provider" == "claude" && "$LEAD_MODEL_OVERRIDE" != gpt-* && "$LEAD_MODEL_OVERRIDE" != codex-* ]]; then
        route_model="$LEAD_MODEL_OVERRIDE"
      else
        route_reason="${route_reason}; incompatible --lead-model ignored after provider safety fallback"
      fi
    fi
    LAUNCH_COUNT=$((LAUNCH_COUNT + 1))
    LAUNCH_IDS+=("$tid")
    LAUNCH_CLASSES+=("$cls")
    LAUNCH_LABELS+=("$label")
    LAUNCH_PROVIDERS+=("$route_provider")
    LAUNCH_MODELS+=("$route_model")
    LAUNCH_EFFORTS+=("$route_effort")
    LAUNCH_RISK_TAGS+=("$risk_tags")
    LAUNCH_REASONS+=("$reason")
    LAUNCH_ROUTE_REASONS+=("$route_reason")
    LAUNCH_GROUP_KEYS+=("$group_key")
    REPORT_LINES+=("- LAUNCH \`${label}\` (\`${tid}\`) — class=${cls}, priority=${pri}, provider=${route_provider}, model=${route_model}/${route_effort}, risk_tags=[${risk_tags}] — ${reason}; route=${route_reason}")
    [[ "$reason" == *"FORCE OVERRIDE"* ]] && FORCED_ANY=true
  else
    SKIP_COUNT=$((SKIP_COUNT + 1))
    REPORT_LINES+=("- skip \`${label}\` (\`${tid}\`, class=${cls}) — ${reason}")
  fi
done <<< "$PLAN_TSV"

log "plan: ${LAUNCH_COUNT} to launch, ${SKIP_COUNT} skipped"
for line in "${REPORT_LINES[@]:-}"; do
  [[ -n "$line" ]] && log "$line"
done

if [[ "$LAUNCH_COUNT" -eq 0 ]]; then
  log "nothing to launch — see reasons above"
fi

# ── Report artifact ─────────────────────────────────────────────────────────
TS_ISO="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="${PROJECT_ROOT}/docs/leadv2/fanout-${TS_ISO}.md"
mkdir -p "${PROJECT_ROOT}/docs/leadv2"

{
  printf -- '# fanout %s\n\n' "$TS_ISO"
  printf -- 'mode: %s%s\n\n' \
    "$([[ "$DRY_RUN" == "true" ]] && echo "DRY-RUN — nothing launched" || echo "LIVE")" \
    "$([[ "$FORCE" == "true" ]] && echo " (--force)" || echo "")"
  if [[ "$FORCED_ANY" == "true" ]]; then
    printf -- '## ⚠️ FORCE OVERRIDE ACTIVE ⚠️\n\n'
    printf -- 'At least one launch below exceeded the CONFIGURED ceiling in\n'
    printf -- 'docs/leadv2/active.yaml meta (hard_limit / standard_max / light_max /\n'
    printf -- 'heavy_strategic_solo). --force bypassed the policy cap — it never bypasses\n'
    printf -- 'the same-task-already-active exclusion. Lines tagged "FORCE OVERRIDE" below\n'
    printf -- 'name exactly which cap was exceeded and by how much.\n\n'
  fi
  if [[ "$NO_TITLE_COLUMN" == "true" ]]; then
    printf -- '## Task labels\n\n'
    printf -- 'docs/tasks.yaml has no `title` column. The label shown before each id below\n'
    printf -- 'is the `intent` field (truncated to 80 chars) — the closest thing this schema\n'
    printf -- 'has to a human title. Rows with neither `title` nor `intent` show that\n'
    printf -- 'explicitly instead of a bare hash.\n\n'
  fi
  printf -- '## Plan\n\n'
  for line in "${REPORT_LINES[@]:-}"; do
    [[ -n "$line" ]] && printf -- '%s\n' "$line"
  done
  printf -- '\n## Merge serialization (not this script'"'"'s job)\n\n'
  printf -- 'Fanning out %d session(s) means up to %d parallel /leadv2 leads may reach\n' "$LAUNCH_COUNT" "$LAUNCH_COUNT"
  printf -- '`main` around the same time. This script does NOT assume exclusive main\n'
  printf -- 'access and does NOT do any merge/rebase coordination itself — merges are\n'
  printf -- 'serialized by a separate mechanism (docs/leadv2/merge-queue.jsonl, owned by\n'
  printf -- 'another agent). If that queue is not live yet, do not fan out into `main`\n'
  printf -- 'writes without a human watching.\n'
  printf -- '\n## Quota warning\n\n'
  printf -- '%d slot(s) requested to launch this run. Flat subscription, but each parallel\n' "$LAUNCH_COUNT"
  printf -- '/leadv2 Opus lead still burns real weekly quota — do not fan out more than you\n'
  printf -- 'are prepared to actively watch. hard_limit=%s.\n' "$(python3 -c "import yaml; print((yaml.safe_load(open('${ACTIVE_YAML}')) or {}).get('meta',{}).get('hard_limit','?'))" 2>/dev/null || echo "?")"
} > "$REPORT_FILE"

log "report written: $REPORT_FILE"

if [[ "$DRY_RUN" == "true" ]]; then
  log "--dry-run: exiting without launching anything"
  exit 0
fi

if [[ "$LAUNCH_COUNT" -eq 0 ]]; then
  exit 0
fi

# _fanout_register_session — atomic write-temp+rename under flock on the
# SAME lockfile leadv2-active-registry.sh uses, so up to N fanout launches
# (and any concurrently-running gate1 self-registrations) serialize safely.
# Writes the exact field set the supervisor/session-bus need: task_id,
# worktree, branch, pid, window_title, started_at — plus the existing schema
# fields (class/phase/daemon_mode/etc.) so old readers keep working.
# Reimplemented locally (not by editing leadv2-active-registry.sh, which is
# out of this task's file scope) because its register() op has no
# window_title parameter slot.
_fanout_register_session() {
  local tid="$1" cls="$2" pid_val="$3" window_title="$4" daemon_mode="$5"
  local pid_pending="${6:-false}"
  local where="${7:-terminal}"
  local risk_tags="${8:-}"
  local lead_model="${9:-}"
  local lead_effort="${10:-}"
  local class_reason="${11:-}"
  local provider="${12:-claude}"
  local route_reason="${13:-}"
  local group_key="${14:-}"
  local branch ts_now yaml_file lockfile session_id
  branch="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf -- 'unknown')"
  ts_now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  yaml_file="$(_leadv2_yaml_file)"
  lockfile="$(_leadv2_yaml_lockfile)"
  session_id="f-$(date -u +%Y%m%dT%H%M%SZ)-${pid_val}-$$"

  local _reg_rc=0
  python3 - "$lockfile" "$yaml_file" "$session_id" "$tid" "$PROJECT_ROOT" \
    "$branch" "$ts_now" "$cls" "$pid_val" "$window_title" "$daemon_mode" \
    "docs/leadv2/tasks/${tid}/pulse.md" "$pid_pending" "$where" \
    "$risk_tags" "$lead_model" "$lead_effort" "$class_reason" \
    "$provider" "$route_reason" "$group_key" <<'PYEOF' || _reg_rc=$?
import sys, os, fcntl, tempfile, yaml

(lockfile, yaml_path, session_id, task_id, worktree, branch, started_at,
 cls, pid_str, window_title, daemon_mode_str, pulse_log, pid_pending_str,
 where, risk_tags, lead_model, lead_effort, class_reason,
 provider, route_reason, group_key) = sys.argv[1:22]

pid_val = None if pid_str in ("null", "", "None") else int(pid_str)
daemon_mode = daemon_mode_str.lower() in ("1", "true", "yes")
pid_pending = pid_pending_str.lower() in ("1", "true", "yes")

def pid_alive(p):
    try:
        os.kill(int(p), 0); return True
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        return False

# FIX3 (HEAVY-MAX-2-WITH-COLLISION-GUARD-01 Codex Phase-5 review): the F6
# under-lock re-count above only re-checks the numeric heavy_max/hard_limit
# ceiling -- it never re-ran the pairwise group_key/risk_tags collision the
# selection pass did OUTSIDE this lock. Two concurrent fanout invocations
# each selecting a distinct Heavy from the same prod-risk/unknown footprint
# can both pass the (unlocked) selection-time check and then both register
# here successfully, because neither sees the other's row until after both
# locks have already been acquired and released. Re-run ONLY the HARD half
# of the collision predicate (both_prod OR any unknown risk/group -- see
# _heavy_collision_kind in the selection pass above) under THIS lock, against
# every live heavy/strategic session already in the locked snapshot. The SOFT
# case (same known-non-prod group) is --force-bypassable by design and is not
# re-enforced under lock, consistent with the selection-pass semantics.
PROD_RISK_TAGS = {"publish", "deploy", "migration", "prod", "prod-deploy"}

def _norm_tags_reg(raw):
    if isinstance(raw, (list, tuple, set)):
        parts = [str(x).strip().lower() for x in raw if str(x).strip()]
    elif isinstance(raw, str):
        s = raw.strip()
        if not s or s.lower() in ("-", "none", "null"):
            return None
        parts = [p.strip().lower() for p in s.split(",") if p.strip()]
    else:
        return None
    return set(parts) if parts else None

def _group_key_unknown_reg(gk):
    if gk is None:
        return True
    s = str(gk).strip().lower()
    return s in ("", "-", "none", "null")

def _hard_collision(cand_gk, cand_tags, other_gk, other_tags):
    cand_tags_set = _norm_tags_reg(cand_tags)
    other_tags_set = _norm_tags_reg(other_tags)
    if cand_tags_set is None or other_tags_set is None:
        return True
    if _group_key_unknown_reg(cand_gk) or _group_key_unknown_reg(other_gk):
        return True
    return bool(cand_tags_set & PROD_RISK_TAGS) and bool(other_tags_set & PROD_RISK_TAGS)

os.makedirs(os.path.dirname(lockfile), exist_ok=True)
fd = open(lockfile, "a+")
try:
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.makedirs(os.path.dirname(yaml_path), exist_ok=True)
    if os.path.exists(yaml_path):
        with open(yaml_path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    else:
        # P0 concurrency fix (leadv2 0.2 audit): bootstrap default hard_limit
        # dropped 20 -> 2, same rationale as the read-path fallback above.
        # Overridable: a founder edit to the resulting active.yaml meta wins
        # on every subsequent run (this literal only fires once, at first
        # bootstrap of a missing active.yaml).
        data = {"meta": {"schema_version": 2, "hard_limit": 2,
                          "heavy_max": 2, "heavy_strategic_solo": False,
                          "light_max": 3, "standard_max": 2, "rendered_at": ""},
                "sessions": []}
    data.setdefault("meta", {})
    sessions = data.setdefault("sessions", [])

    existing = next((s for s in sessions if s.get("task_id") == task_id), None)
    if existing and pid_alive(existing.get("pid")):
        print(f"[fanout] {task_id} already has a live registered session — not overwriting", file=sys.stderr)
        sys.exit(0)
    if existing:
        sessions.remove(existing)

    # F6 (HEAVY-MAX-2-WITH-COLLISION-GUARD-01): register-time re-count under
    # the SAME lock -- the active.yaml snapshot the selection pass read was
    # taken OUTSIDE this lock, so a concurrent fanout invocation may have
    # registered a Heavy/strategic session (or hit hard_limit) in the
    # meantime. Re-derive live counts from THIS locked read and refuse
    # admission if it would exceed either ceiling. hard_limit/heavy_max are
    # hard invariants (F5, never --force-bypassable), so no force flag is
    # threaded through here -- only the numeric ceiling is re-verified.
    meta_live = data.get("meta") or {}
    heavy_max_live = int(meta_live.get("heavy_max", 2))
    hard_limit_live = int(meta_live.get("hard_limit", 2))
    live_sessions = [s for s in sessions if not s.get("stale")]
    live_heavy = sum(1 for s in live_sessions if str(s.get("class", "")).lower() in ("heavy", "strategic"))
    if cls.lower() in ("heavy", "strategic") and live_heavy >= heavy_max_live:
        print(f"[fanout] LOST_RACE: {task_id} would exceed heavy_max under lock ({live_heavy}/{heavy_max_live}) -- refusing to register", file=sys.stderr)
        sys.exit(3)
    if len(live_sessions) >= hard_limit_live:
        print(f"[fanout] LOST_RACE: {task_id} would exceed hard_limit under lock ({len(live_sessions)}/{hard_limit_live}) -- refusing to register", file=sys.stderr)
        sys.exit(3)

    # FIX3: pairwise HARD-collision re-check under THIS lock (see
    # _hard_collision above) -- catches the exact race the numeric re-count
    # above cannot: two concurrent fanout invocations each independently
    # selecting a distinct Heavy with a prod-risk/unknown footprint, neither
    # visible to the other's (unlocked) selection-time snapshot.
    if cls.lower() in ("heavy", "strategic"):
        for s in live_sessions:
            if str(s.get("class", "")).lower() not in ("heavy", "strategic"):
                continue
            if _hard_collision(group_key, risk_tags, s.get("group_key"), s.get("risk_tags")):
                print(f"[fanout] LOST_RACE: {task_id} HARD-collides under lock with live session task_id={s.get('task_id')} (prod/unknown footprint) -- refusing to register", file=sys.stderr)
                sys.exit(3)

    group_key_norm = None if group_key in ("", "null", "None", "-") else group_key

    sessions.append({
        "session_id": session_id, "task_id": task_id, "worktree": worktree,
        "branch": branch, "started_at": started_at, "phase": "spawning",
        "class": cls, "pulse_log": pulse_log, "pid": pid_val,
        "pid_birth": None, "parent_session_id": None,
        "daemon_mode": daemon_mode, "last_pulse_at": started_at,
        "stale": False, "window_title": window_title, "pid_pending": pid_pending,
        "where": where,
        "note": f"window_title={window_title}",
        # SUPERVISOR-RETRO-01 item 1: persisted classifier output — the
        # pre-launch decision that picked "class" above, kept for audit.
        "risk_tags": risk_tags,
        "group_key": group_key_norm,
        "lead_model": lead_model,
        "lead_effort": lead_effort,
        "class_reason": class_reason,
        "provider": provider,
        "route_reason": route_reason,
        # SUPERVISE-V2-01 fix-1 (Codex#2): same registry-honesty field set
        # leadv2_active_register()/op=register writes (leadv2-active-registry.sh)
        # -- fanout is a SECOND writer of active.yaml (window_title has no slot
        # in the shared register() op, see comment above), so these fields must
        # be set here too rather than routed through that function.
        "protocol_version": 2,
        "backend": where,
        "phase_started_at": started_at,
        "updated_at": started_at,
        "tmux_window": window_title if where == "tmux" else None,
        # lean: pane index not tracked (one pane per window in this backend)
        # -- upgrade when launch_tmux ever splits panes within a window.
        "tmux_pane": None,
        "log_path": pulse_log,
        "provider_receipts": [{
            "provider": provider,
            "task_id": task_id,
            "model": lead_model,
            "effort": lead_effort,
            "run_id": session_id,
            "status": "launched",
            "exit_code": None,
            "attempt": 0,
            "recorded_at": started_at,
        }],
    })

    d = os.path.dirname(yaml_path)
    tfd, tpath = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(tfd, "w", encoding="utf-8") as tf:
            yaml.dump(data, tf, default_flow_style=False, sort_keys=False)
        os.replace(tpath, yaml_path)
    except Exception:
        os.unlink(tpath)
        raise
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
PYEOF
  if [[ "$_reg_rc" -eq 3 ]]; then
    # FIX4: rc==3 means admission was refused under lock (F6 ceiling race OR
    # FIX3 pairwise HARD-collision race). The caller already spawned the
    # child process before this call -- returning 3 here tells it to KILL
    # that child rather than leaving it running unregistered (the ceiling was
    # cosmetic otherwise: it capped active.yaml rows, not actual processes).
    log "WARN: ${tid} lost the register-time admission race under lock (F6/FIX3) — refusing to register; caller must terminate the spawned child"
  elif [[ "$_reg_rc" -ne 0 ]]; then
    log "WARN: could not register ${tid} in active.yaml — session is running unregistered"
  fi
  return "$_reg_rc"
}

# _fanout_kill_child <pid> <used_setsid> — FIX4: terminate a just-spawned
# child whose registration was refused under lock (rc==3 from
# _fanout_register_session), so the heavy_max/hard_limit ceiling caps actual
# running sessions, not just active.yaml rows. When the child was started via
# setsid it is its own session/process-group leader (pid == pgid), so kill
# the whole group (`-pid`) to take any grandchildren (the runner's own
# subprocess tree) with it; TERM first, KILL after a short grace window if it
# didn't die. Without setsid (macOS fallback with no setsid binary) the child
# shares this script's process group, so killing the group would be
# collateral damage -- kill only the specific pid in that case.
_fanout_kill_child() {
  local pid="$1" used_setsid="${2:-false}"
  [[ -z "$pid" || "$pid" == "null" ]] && return 0
  if [[ "$used_setsid" == "true" ]]; then
    kill -TERM -- "-${pid}" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
  sleep 0.3
  if kill -0 "$pid" 2>/dev/null; then
    if [[ "$used_setsid" == "true" ]]; then
      kill -KILL -- "-${pid}" 2>/dev/null || true
    else
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
}

launch_headless() {
  local tid="$1" cls="$2" lead_model="${3:-sonnet}" lead_effort="${4:-medium}"
  local risk_tags="${5:-}" class_reason="${6:-}"
  local provider="${7:-claude}" route_reason="${8:-}"
  local group_key="${9:-}"
  local task_dir="${PROJECT_ROOT}/docs/handoff/${tid}"
  mkdir -p "$task_dir"
  local logf="${task_dir}/fanout.log"

  # exec inside the subshell so $! (of the outer &) IS the setsid pid, not an
  # extra unexeced subshell layer — matches leadv2-session-spawner.sh's own
  # setsid-nohup convention as closely as bash allows with an explicit cd.
  # LEAD-ANCHOR-01: LEADV2_ASYNC_QUESTIONS=1 tells the spawned session's founder
  # is watching the SUPERVISING lead's window, not this one — route every
  # founder-facing question through leadv2-ask.sh instead of AskUserQuestion.
  # SUPERVISOR-RETRO-01 item 2: hand off to leadv2-session-runner.sh instead of
  # calling `claude -p` directly — the runner owns --model/--effort pinning
  # plus the resume-on-exit completion loop to phase8-passed.flag.
  # FANOUT-MACOS-LAUNCHER-01: macOS has no setsid — fall back to plain nohup
  # inside the same subshell; nohup + trailing `&` still detaches from the
  # controlling terminal, and $! below keeps resolving to the runner pid on
  # both branches (see comment above).
  # The provider-neutral runner is a hard dependency. Falling back to a raw
  # one-shot CLI would violate the supervisor's Phase 0..8 + sentinel contract.
  local _runner="${SCRIPT_DIR}/leadv2-session-runner.sh"
  if [[ ! -x "$_runner" ]]; then
    log_error "leadv2-session-runner.sh missing/not executable at ${_runner} — refusing an unguarded one-shot launch"
    return 1
  fi
  # LANE-WORKTREE-ISOLATION-01: create (or reattach) this lane's own git
  # worktree+branch BEFORE launch, and run the child there instead of the
  # shared PROJECT_ROOT — SD-LANES-HAVE-NO-WORKTREE-01 found headless children
  # never actually isolated (Phase 0's EnterWorktree call is not reliable for
  # fanout children). LEADV2_PROJECT_ROOT is pinned to the ORIGINAL shared
  # root so control-plane files (active.yaml, docs/handoff, bus.jsonl) still
  # resolve to the one shared location regardless of which worktree the
  # child's code edits land in. ensure() never fails the launch — on any git
  # error it logs loud and falls back to PROJECT_ROOT (legacy shared tree).
  local _lane_dir
  _lane_dir="$("${SCRIPT_DIR}/leadv2-lane-worktree.sh" ensure "$tid" "$cls" 2>>"$logf")"
  [[ -n "$_lane_dir" ]] || _lane_dir="$PROJECT_ROOT"
  local _used_setsid=false
  if command -v setsid >/dev/null 2>&1; then
    _used_setsid=true
    ( cd "$_lane_dir" && \
      exec env LEADV2_DAEMON=1 LEADV2_ASYNC_QUESTIONS=1 LEADV2_FANOUT=1 \
        LEADV2_TASK_ID="${tid}" LEADV2_LEAD_MODEL="${lead_model}" \
        LEADV2_LEAD_EFFORT="${lead_effort}" LEADV2_SESSION_PROVIDER="${provider}" \
        LEADV2_RUNNER_FORCE_FRESH="${FORCE}" LEADV2_PROJECT_ROOT="${PROJECT_ROOT}" \
        setsid nohup "$_runner" </dev/null >>"$logf" 2>&1 ) &
  else
    ( cd "$_lane_dir" && \
      exec env LEADV2_DAEMON=1 LEADV2_ASYNC_QUESTIONS=1 LEADV2_FANOUT=1 \
        LEADV2_TASK_ID="${tid}" LEADV2_LEAD_MODEL="${lead_model}" \
        LEADV2_LEAD_EFFORT="${lead_effort}" LEADV2_SESSION_PROVIDER="${provider}" \
        LEADV2_RUNNER_FORCE_FRESH="${FORCE}" LEADV2_PROJECT_ROOT="${PROJECT_ROOT}" \
        nohup "$_runner" </dev/null >>"$logf" 2>&1 ) &
  fi
  local pid=$!
  log "headless launch: task=${tid} pid=${pid} provider=${provider} model=${lead_model}/${lead_effort} lane_dir=${_lane_dir} log=${logf}"

  local _reg_rc=0
  _fanout_register_session "$tid" "$cls" "$pid" "leadv2: ${tid}" "true" "false" "headless" \
    "$risk_tags" "$lead_model" "$lead_effort" "$class_reason" "$provider" "$route_reason" "$group_key" || _reg_rc=$?
  if [[ "$_reg_rc" -eq 3 ]]; then
    log "WARN: ${tid} admission refused under lock (F6/FIX3) — killing spawned child pid=${pid} (setsid=${_used_setsid})"
    _fanout_kill_child "$pid" "$_used_setsid"
  fi
}

# Escape a string for safe interpolation into an AppleScript double-quoted
# string literal: backslash first (so we don't double-escape the quotes we
# add next), then double-quote.
_osa_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# _fanout_resolve_spawned_pid <tid> — one poll attempt. Prints the newest
# live pid whose cmdline matches "/leadv2 <tid>" and is not already claimed by
# another row in active.yaml. Returns 1 (empty stdout) if no match yet. Shared
# by both launch_windowed (osascript hands back no pid) and launch_tmux
# (tmux new-window hands back no `claude` pid either, only the shell's) — do
# not duplicate this poll loop per backend.
_fanout_resolve_spawned_pid() {
  local tid="$1" yaml_file candidates registered p newest="" pid_file runner_pid
  pid_file="${PROJECT_ROOT}/docs/handoff/${tid}/.session-runner.pid"
  if [[ -f "$pid_file" ]]; then
    runner_pid="$(tr -d '[:space:]' < "$pid_file")"
    if [[ "$runner_pid" =~ ^[0-9]+$ ]] && kill -0 "$runner_pid" 2>/dev/null; then
      printf -- '%s' "$runner_pid"
      return 0
    fi
  fi
  candidates="$(pgrep -f "/leadv2 ${tid}" 2>/dev/null || true)"
  [[ -z "$candidates" ]] && return 1
  yaml_file="$(_leadv2_yaml_file)"
  registered="$(python3 -c "
import sys, yaml
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        data = yaml.safe_load(fh) or {}
except Exception:
    data = {}
print(' '.join(str(s.get('pid')) for s in (data.get('sessions') or []) if s.get('pid') is not None))
" "$yaml_file" 2>/dev/null || true)"
  for p in $candidates; do
    case " ${registered} " in
      *" ${p} "*) continue ;;
    esac
    newest="$p"
  done
  [[ -n "$newest" ]] || return 1
  printf -- '%s' "$newest"
}

launch_windowed() {
  local tid="$1" cls="$2" lead_model="${3:-sonnet}" lead_effort="${4:-medium}"
  local risk_tags="${5:-}" class_reason="${6:-}"
  local provider="${7:-claude}" route_reason="${8:-}"
  local group_key="${9:-}"
  if [[ "$(uname -s)" != "Darwin" ]]; then
    log_error "windowed launch requires macOS (osascript). Use --headless on this platform."
    exit 1
  fi
  if ! command -v osascript >/dev/null 2>&1; then
    log_error "osascript not found — cannot open terminal windows. Use --headless."
    exit 1
  fi

  local title="leadv2: ${tid}"
  local cmd
  local _runner="${SCRIPT_DIR}/leadv2-session-runner.sh"
  if [[ ! -x "$_runner" ]]; then
    log_error "leadv2-session-runner.sh missing/not executable at ${_runner} — refusing an unguarded one-shot launch"
    return 1
  fi
  # Windowed children use the same provider-neutral completion runner as
  # headless/tmux. The visible terminal is observability, not a weaker
  # lifecycle contract.
  # LANE-WORKTREE-ISOLATION-01: same ensure()-before-launch as launch_headless
  # — cd into the lane's own worktree, keep LEADV2_PROJECT_ROOT pinned to the
  # shared root for control-plane files.
  local _lane_dir
  _lane_dir="$("${SCRIPT_DIR}/leadv2-lane-worktree.sh" ensure "$tid" "$cls")"
  [[ -n "$_lane_dir" ]] || _lane_dir="$PROJECT_ROOT"
  printf -v cmd 'cd %q && export LEADV2_DAEMON=1 LEADV2_ASYNC_QUESTIONS=1 LEADV2_FANOUT=1 LEADV2_TASK_ID=%q LEADV2_LEAD_MODEL=%q LEADV2_LEAD_EFFORT=%q LEADV2_SESSION_PROVIDER=%q LEADV2_RUNNER_FORCE_FRESH=%q LEADV2_PROJECT_ROOT=%q; exec %q' \
    "$_lane_dir" "$tid" "$lead_model" "$lead_effort" "$provider" "$FORCE" "$PROJECT_ROOT" "$_runner"

  # AppleScript double-quoted strings treat backslash as an escape char, but
  # bash's %q emits backslash-escaped tokens (e.g. `/leadv2\ ${tid}`) — raw
  # interpolation broke every osascript call with a -2741 syntax error and no
  # window ever opened. Escape for AppleScript (backslash first, then quote)
  # on both interpolated strings before embedding.
  local cmd_osa title_osa
  cmd_osa="$(_osa_escape "$cmd")"
  title_osa="$(_osa_escape "$title")"

  if pgrep -x iTerm2 >/dev/null 2>&1; then
    osascript <<OSA
tell application "iTerm2"
  set newWindow to (create window with default profile)
  tell current session of newWindow
    set name to "${title_osa}"
    write text "${cmd_osa}"
  end tell
end tell
OSA
  else
    osascript <<OSA
tell application "Terminal"
  set newTab to do script "${cmd_osa}"
  set custom title of front window to "${title_osa}"
  activate
end tell
OSA
  fi
  log "windowed launch: task=${tid} provider=${provider} model=${lead_model}/${lead_effort} title='${title}'"

  # osascript hands the shell command to Terminal/iTerm2 asynchronously and
  # never hands back the spawned `claude` process pid directly. Registering
  # with pid=null let the row be indistinguishable from a dead session to any
  # pid-liveness sweep, and 3-of-4 windowed launches were silently dropped
  # from active.yaml as a result (LEAD-ANCHOR-01). Resolve the REAL pid by
  # polling pgrep for the newly-spawned "/leadv2 ${tid}" process (bounded,
  # ~10s @ 0.25s intervals — osascript + shell + claude startup is usually
  # <1s but give slow machines headroom). If it still can't be found, fall
  # back to pid_pending=true; the stale-sweeper grants pid_pending rows a
  # grace window instead of treating them as dead.
  local _resolved_pid="" _attempt
  for ((_attempt = 0; _attempt < 40; _attempt++)); do
    _resolved_pid="$(_fanout_resolve_spawned_pid "$tid" || true)"
    [[ -n "$_resolved_pid" ]] && break
    sleep 0.25
  done

  local _reg_rc=0
  if [[ -n "$_resolved_pid" ]]; then
    log "windowed launch: task=${tid} resolved pid=${_resolved_pid} model=${lead_model}/${lead_effort}"
    _fanout_register_session "$tid" "$cls" "$_resolved_pid" "$title" "false" "false" "terminal" \
      "$risk_tags" "$lead_model" "$lead_effort" "$class_reason" "$provider" "$route_reason" "$group_key" || _reg_rc=$?
    if [[ "$_reg_rc" -eq 3 ]]; then
      # FIX4: this script never spawned the resolved pid itself (osascript
      # handed it to Terminal/iTerm2), so there is no setsid process-group we
      # own -- kill only the specific resolved pid, never a group.
      log "WARN: ${tid} admission refused under lock (F6/FIX3) — killing spawned child pid=${_resolved_pid}"
      _fanout_kill_child "$_resolved_pid" "false"
    fi
  else
    log "WARN: could not resolve pid for task=${tid} within 10s — registering pid_pending=true"
    # No resolved pid to kill on refusal here -- pid_pending=true already
    # marks this row for the stale-sweeper's grace-window handling.
    _fanout_register_session "$tid" "$cls" "null" "$title" "false" "true" "terminal" \
      "$risk_tags" "$lead_model" "$lead_effort" "$class_reason" "$provider" "$route_reason" "$group_key" || true
  fi
}

# launch_tmux <tid> <cls> — one shared tmux session "leadv2", one WINDOW per
# task (never panes — panes get unreadable at 4+ tasks). Reuses the "leadv2"
# session if it already exists instead of spawning a second one. Output is
# piped to docs/handoff/<tid>/session.log so the supervisor can read it
# without attaching. Survives Terminal.app window close/quit (the exact
# failure LEAD-ANCHOR-01 exists to fix).
TMUX_SESSION_NAME="${LEADV2_FANOUT_TMUX_SESSION:-leadv2}"
declare -a TMUX_LAUNCHED_IDS=()

launch_tmux() {
  local tid="$1" cls="$2" lead_model="${3:-sonnet}" lead_effort="${4:-medium}"
  local risk_tags="${5:-}" class_reason="${6:-}"
  local provider="${7:-claude}" route_reason="${8:-}"
  local group_key="${9:-}"
  local window="$tid"
  local target="${TMUX_SESSION_NAME}:${window}"
  local task_dir="${PROJECT_ROOT}/docs/handoff/${tid}"
  mkdir -p "$task_dir"
  local logf="${task_dir}/session.log"
  : > "$logf"  # truncate/create so "non-empty after launch" is a real signal, not stale content

  # LANE-WORKTREE-ISOLATION-01: same ensure()-before-launch as launch_headless.
  local _lane_dir
  _lane_dir="$("${SCRIPT_DIR}/leadv2-lane-worktree.sh" ensure "$tid" "$cls" 2>>"$logf")"
  [[ -n "$_lane_dir" ]] || _lane_dir="$PROJECT_ROOT"

  # Some hosts (observed: no-tty parent shells with no pty anywhere in the
  # chain) run an intermittently unstable tmux server that can exit between
  # one window's creation and the next, independent of the new-window notty
  # fix below. Retry the whole ensure-session/window/send-keys sequence up
  # to 3 times, re-verifying with `has-session` after each attempt, before
  # falling back to pid_pending — cheap insurance, a healthy server no-ops
  # through this on attempt 1.
  local _tmux_attempt
  for ((_tmux_attempt = 1; _tmux_attempt <= 3; _tmux_attempt++)); do
    if ! tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
      tmux new-session -d -s "$TMUX_SESSION_NAME" -n "$window" -c "$_lane_dir"
      log "tmux: created session '${TMUX_SESSION_NAME}' with window '${window}' (attempt ${_tmux_attempt})"
    else
      # Never reuse a window whose task is already registered live in
      # active.yaml — but that task never reaches LAUNCH in the selection
      # pass above (active_task_ids exclusion), so any window with this name
      # here is necessarily orphaned/stale. Recreate rather than reusing it.
      if tmux list-windows -t "$TMUX_SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -qx "$window"; then
        log "tmux: window '${window}' already exists in '${TMUX_SESSION_NAME}' (stale) — recreating"
        tmux kill-window -t "${TMUX_SESSION_NAME}:${window}" 2>/dev/null || true
      fi
      # `tmux new-window` on an already-detached session crashes the tmux
      # server ("server exited unexpectedly") when the CALLING process has
      # no controlling tty (isatty()==false) — reproduced deterministically
      # when this script itself runs from a tty-less parent (e.g. a /leadv2
      # lead's own headless tool-call shell fanning out more sessions).
      # `script -q /dev/null` gives the tmux client a synthetic pty, which
      # the tmux server needs to safely allocate the new window's pane;
      # verified fix across repeated runs. `new-session -d` above has never
      # reproduced this (only the SECOND+ window trips it), unwrapped.
      if [[ "$(uname -s)" == "Darwin" ]] && command -v script >/dev/null 2>&1 && ! tty -s 2>/dev/null; then
        script -q /dev/null tmux new-window -t "$TMUX_SESSION_NAME" -n "$window" -c "$_lane_dir" >/dev/null 2>&1 || true
      else
        tmux new-window -t "$TMUX_SESSION_NAME" -n "$window" -c "$_lane_dir" 2>/dev/null || true
      fi
      log "tmux: added window '${window}' to existing session '${TMUX_SESSION_NAME}' (attempt ${_tmux_attempt})"
    fi

    if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null \
       && tmux list-windows -t "$TMUX_SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -qx "$window"; then
      break
    fi
    log "WARN: tmux server unstable creating window '${window}' (attempt ${_tmux_attempt}/3) — retrying"
    sleep 0.3
  done

  local logf_q
  logf_q="$(printf -- '%q' "$logf")"
  tmux pipe-pane -o -t "$target" "cat >> ${logf_q}" 2>/dev/null || true

  # SUPERVISOR-RETRO-01 item 2: hand off to leadv2-session-runner.sh (same as
  # launch_headless) instead of `claude -p` directly, so tmux windows also
  # get --model/--effort pinning + resume-on-exit toward phase8-passed.flag.
  # daemon=false was previously registered here even though nothing acted as
  # a daemon; the runner makes that field honest.
  local cmd
  local _runner="${SCRIPT_DIR}/leadv2-session-runner.sh"
  if [[ ! -x "$_runner" ]]; then
    log_error "leadv2-session-runner.sh missing/not executable at ${_runner} — refusing an unguarded one-shot launch"
    return 1
  fi
  printf -v cmd 'export LEADV2_DAEMON=1 LEADV2_ASYNC_QUESTIONS=1 LEADV2_FANOUT=1 LEADV2_TASK_ID=%q LEADV2_LEAD_MODEL=%q LEADV2_LEAD_EFFORT=%q LEADV2_SESSION_PROVIDER=%q LEADV2_RUNNER_FORCE_FRESH=%q LEADV2_PROJECT_ROOT=%q; exec %q' \
    "$tid" "$lead_model" "$lead_effort" "$provider" "$FORCE" "$PROJECT_ROOT" "$_runner"
  tmux send-keys -t "$target" "$cmd" C-m 2>/dev/null || true

  # tmux new-window hands back the pane's shell pid, not the exec'd `claude`
  # pid (and CLAUDE_BIN may itself be a wrapper script in tests) — resolve
  # the real pid the same way launch_windowed does, via pgrep polling.
  local _resolved_pid="" _attempt
  for ((_attempt = 0; _attempt < 40; _attempt++)); do
    _resolved_pid="$(_fanout_resolve_spawned_pid "$tid" || true)"
    [[ -n "$_resolved_pid" ]] && break
    sleep 0.25
  done

  local _reg_rc=0
  if [[ -n "$_resolved_pid" ]]; then
    log "tmux launch: task=${tid} window=${window} resolved pid=${_resolved_pid} provider=${provider} model=${lead_model}/${lead_effort}"
    _fanout_register_session "$tid" "$cls" "$_resolved_pid" "$window" "true" "false" "tmux" \
      "$risk_tags" "$lead_model" "$lead_effort" "$class_reason" "$provider" "$route_reason" "$group_key" || _reg_rc=$?
    if [[ "$_reg_rc" -eq 3 ]]; then
      # FIX4: kill the tmux window outright (cleaner than a bare pid kill for
      # this backend -- it also tears down the pane/shell, not just the
      # exec'd claude process) rather than leaving an orphaned, unregistered
      # window running against the ceiling that just refused it.
      log "WARN: ${tid} admission refused under lock (F6/FIX3) — killing tmux window ${target}"
      tmux kill-window -t "$target" 2>/dev/null || true
    fi
  else
    log "WARN: could not resolve pid for task=${tid} within 10s — registering pid_pending=true"
    # No resolved pid/confirmed window occupant to kill on refusal here --
    # pid_pending=true already marks this row for the stale-sweeper's
    # grace-window handling.
    _fanout_register_session "$tid" "$cls" "null" "$window" "true" "true" "tmux" \
      "$risk_tags" "$lead_model" "$lead_effort" "$class_reason" "$provider" "$route_reason" "$group_key" || true
  fi

  TMUX_LAUNCHED_IDS+=("$tid")
}

for i in "${!LAUNCH_IDS[@]}"; do
  tid="${LAUNCH_IDS[$i]}"
  cls="${LAUNCH_CLASSES[$i]}"
  provider="${LAUNCH_PROVIDERS[$i]:-claude}"
  lead_model="${LAUNCH_MODELS[$i]:-sonnet}"
  lead_effort="${LAUNCH_EFFORTS[$i]:-medium}"
  risk_tags="${LAUNCH_RISK_TAGS[$i]:-}"
  class_reason="${LAUNCH_REASONS[$i]:-}"
  route_reason="${LAUNCH_ROUTE_REASONS[$i]:-}"
  group_key="${LAUNCH_GROUP_KEYS[$i]:-}"
  case "$BACKEND" in
    headless) launch_headless "$tid" "$cls" "$lead_model" "$lead_effort" "$risk_tags" "$class_reason" "$provider" "$route_reason" "$group_key" ;;
    tmux)     launch_tmux "$tid" "$cls" "$lead_model" "$lead_effort" "$risk_tags" "$class_reason" "$provider" "$route_reason" "$group_key" ;;
    windows)  launch_windowed "$tid" "$cls" "$lead_model" "$lead_effort" "$risk_tags" "$class_reason" "$provider" "$route_reason" "$group_key" ;;
  esac
done

if [[ "${#TMUX_LAUNCHED_IDS[@]}" -gt 0 ]]; then
  log "tmux: attach to all sessions: tmux attach -t ${TMUX_SESSION_NAME}"
  for tid in "${TMUX_LAUNCHED_IDS[@]}"; do
    log "tmux: attach directly to ${tid}: tmux attach -t ${TMUX_SESSION_NAME} \\; select-window -t ${tid}"
  done
fi

exit 0
