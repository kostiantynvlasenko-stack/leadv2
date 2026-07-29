#!/usr/bin/env bash
# leadv2-lane-shape.sh — LANE-SHAPE-01. Makes solo-vs-line review a mechanism, not
# lead discipline. Implements docs/specs/lane-shape.md (persona-engine repo; design
# is stack-agnostic, this is the shared-plugin implementation).
#
# PROBLEM THIS SOLVES
#   A dispatched lane could self-report "done" with no independent review and no
#   evidence. The only thing standing between that and a false "done" was the lead
#   remembering to check — which failed twice in one session (2026-07-28): a lane
#   reported done having deployed nothing, and a status pass called seven commits
#   "deployed" because the files they touch happened to exist on the server.
#
# THE TWO SHAPES (spec §2)
#   solo — build only. Terminal "done" = acceptance command output pasted + close gate.
#   line — frame-check (diagnosis only) -> build -> review -> verify -> harness-register.
#          Terminal "done" = verify-probe-result.yaml: outcome=probe_ok (existing
#          leadv2-verify contract).
#
# SUBCOMMANDS
#   classify        dispatch-time: computes C1-C5, writes shape+evidence to
#                   context.yaml (immutable once written). Refuses a diagnostic
#                   mission with no Evidence block. (spec §3, §4, task 2)
#   frame-check     LINE diagnosis-only: one-shot out-of-process MATCH/MISMATCH
#                   check; verdict invalid unless it quotes an observed line.
#                   (spec §4, task 3)
#   assert-artifacts  close-time: per-shape artifact set present, checked by
#                   CONTENT not existence. Called from leadv2-phase8-assert.sh A9.
#                   (spec §6, task 6)
#   retro-check     close-time: re-derives minimum shape from the ACTUAL diff;
#                   a solo-labeled task whose diff touches a C3-excluded surface
#                   is refused. (spec §3 C3, §6, task 6)
#   verify-probe    derives verification.probe from evidence.repro_cmd, re-runs it,
#                   diffs the observed output against evidence.predicted_delta.
#                   (spec §5, task 5)
#   harness-check   requires a task-id-tagged harness entry OR harness_na. (spec §5.4, task 7)
#   journal         appends one telemetry line per close. (spec task 8)
#
# GATE FLAG (spec §9, migration, one-flag rollback at every stage)
#   LEADV2_LANE_SHAPE=off (default) | warn | enforce
#     off      classify/assert-artifacts/retro-check are no-ops (exit 0, nothing
#               written) — Stage 0, zero behavior change.
#     warn     shape is computed and written to context.yaml; violations print
#               WARN and exit 0 — Stage 1.
#     enforce  violations refuse (dispatch) or fail the close gate — Stage 2.
#   Per-repo override: .claude/leadv2-overrides/ may set a different default via
#   LEADV2_LANE_SHAPE_DEFAULT (read only when the env var itself is unset).
#
# NOT SHAPE-ELIGIBLE (spec §2, last line)
#   A mission whose declared writes touch contracts/, supabase/migrations/, or
#   >=2 of {platform/, agent/, web/} is not shape-eligible at all — classify exits 3
#   ("route to classified pipeline"), never 2 (evidence refusal) or 0 (accepted).
#
# EXIT CODES (classify)
#   0  accepted, shape written (solo or line)
#   2  refused — diagnostic mission with no Evidence block (enforce only)
#   3  not shape-eligible — must enter the classified pipeline
#   4  shape already recorded for this task_id (immutable-after violation)
#   5  bad usage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-"$0"}")" 2>/dev/null && pwd)"
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
export LEADV2_PROJECT_ROOT="${PROJECT_ROOT}"

# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh"
_lv2_load_paths

log()  { printf -- '[lane-shape] %s\n' "$*" >&2; }

lane_shape_mode() {
  local mode="${LEADV2_LANE_SHAPE:-${LEADV2_LANE_SHAPE_DEFAULT:-off}}"
  case "$mode" in off|warn|enforce) printf '%s' "$mode" ;; *) printf 'off' ;; esac
}

_context_path() { printf '%s/%s/context.yaml' "${LEADV2_HANDOFF_DIR}" "$1"; }

# ── C1-C5 + shape computation (pure; no I/O beyond reading the negative-memory
#    file if present) ─────────────────────────────────────────────────────────
# args: mission_text writes_csv acceptance_cmd rollback_onestep nm_file
# Mission text is passed as argv, NOT piped via stdin: a `python3 - <<HEREDOC`
# invocation's heredoc IS its stdin, so a piped mission would silently read as
# empty (found live during testing — c1 was always true because DEFECT_RE/
# FIX_VERB_RE matched against '').
_classify_py() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PYEOF'
import re, sys

mission, writes_csv, acceptance_cmd, rollback_onestep, nm_file = sys.argv[1:6]
writes = [w.strip() for w in writes_csv.split(",") if w.strip()]

# C1: constructive (no causal claim about live/runtime behavior). A mission that
# names a defect ("repeats/broken/fails/not working/stuck/hangs") OR uses a
# diagnostic-fix verb targeting behavior fails C1 -> diagnostic.
DEFECT_RE = re.compile(
    r"\b(repeat(s|ing)?|broken|fail(s|ing)?|not working|isn'?t working|"
    r"stopped working|stuck|hang(s|ing)?|regressi(on|ng)|bug\b)\b", re.I)
FIX_VERB_RE = re.compile(r"\b(fix|stop|restore|repair|diagnose|root[- ]cause)\b", re.I)
c1 = not (DEFECT_RE.search(mission) or FIX_VERB_RE.search(mission))
diagnostic = not c1

# Evidence block (## Evidence ... fields). Only meaningful for diagnostic missions.
ev_match = re.search(r"^##\s*Evidence\s*$", mission, re.I | re.M)
has_evidence_heading = bool(ev_match)
repro_cmd = observed = predicted_delta = ""
if has_evidence_heading:
    tail = mission[ev_match.end():]
    m = re.search(r"repro_cmd\s*:\s*(.+)", tail)
    repro_cmd = m.group(1).strip().strip('"') if m else ""
    m = re.search(r"observed\s*:\s*(.+)", tail)
    observed = m.group(1).strip().strip('"') if m else ""
    m = re.search(r"predicted_delta\s*:\s*(.+)", tail)
    predicted_delta = m.group(1).strip().strip('"') if m else ""
evidence_complete = has_evidence_heading and bool(repro_cmd) and bool(observed) and bool(predicted_delta)

# Not-shape-eligible surfaces (spec §2 last line): contracts/, supabase/migrations/,
# or >=2 of {platform/, agent/, web/}.
NOT_ELIGIBLE_RE = re.compile(r"(^|/)(contracts|supabase/migrations)(/|$)")
subsystems = {w.split("/", 1)[0] for w in writes if "/" in w or w}
core_subsystems = {s for s in subsystems if s in ("platform", "agent", "web")}
not_eligible = any(NOT_ELIGIBLE_RE.search(w) for w in writes) or len(core_subsystems) >= 2

# C2: machine-checkable acceptance command declared.
c2 = bool(acceptance_cmd.strip())

# C3: blast radius <=1 subsystem, none of the hard-excluded surfaces.
EXCLUDED_RE = re.compile(
    r"(^|/)(supabase/migrations|contracts)(/|$)|safety.?gate|publish|payments?|billing|prompt.?assembl", re.I)
c3 = len(core_subsystems) <= 1 and not any(EXCLUDED_RE.search(w) for w in writes)

# C4: one-step rollback, lead-asserted.
c4 = rollback_onestep.strip().lower() in ("1", "true", "yes")

# C5: no negative-memory match (keyword overlap against active entries' approach text).
c5 = True
nm_hit = ""
if nm_file:
    try:
        import yaml
        data = yaml.safe_load(open(nm_file, encoding="utf-8")) or {}
        entries = [e for e in (data.get("entries") or []) if e.get("status") == "active"]
        mission_words = set(re.findall(r"[a-z0-9_]{4,}", mission.lower()))
        for e in entries:
            approach_words = set(re.findall(r"[a-z0-9_]{4,}", str(e.get("approach", "")).lower()))
            overlap = mission_words & approach_words
            if len(overlap) >= 4:
                c5 = False
                nm_hit = e.get("id", "unknown")
                break
    except FileNotFoundError:
        pass

solo_eligible = c1 and c2 and c3 and c4 and c5
shape = "solo" if (not diagnostic and solo_eligible) else "line"

print(f"not_eligible={'1' if not_eligible else '0'}")
print(f"diagnostic={'1' if diagnostic else '0'}")
print(f"has_evidence={'1' if evidence_complete else '0'}")
print(f"c1={'1' if c1 else '0'}")
print(f"c2={'1' if c2 else '0'}")
print(f"c3={'1' if c3 else '0'}")
print(f"c4={'1' if c4 else '0'}")
print(f"c5={'1' if c5 else '0'}")
print(f"nm_hit={nm_hit}")
print(f"shape={shape}")
print(f"repro_cmd={repro_cmd}")
print(f"observed={observed}")
print(f"predicted_delta={predicted_delta}")
PYEOF
}

# Writes shape+rationale+evidence into context.yaml. Refuses (rc=4) if `shape`
# is already present — the field is immutable-after-write (spec §8).
_write_context_yaml() {
  local ctx="$1" shape="$2" c1="$3" c2="$4" c3="$5" c4="$6" c5="$7" \
        repro_cmd="$8" observed="$9" predicted_delta="${10}" acceptance_cmd="${11}"
  python3 - "$ctx" "$shape" "$c1" "$c2" "$c3" "$c4" "$c5" "$repro_cmd" "$observed" "$predicted_delta" "$acceptance_cmd" <<'PYEOF'
import os, sys, tempfile
import yaml

(ctx, shape, c1, c2, c3, c4, c5, repro_cmd, observed, predicted_delta,
 acceptance_cmd) = sys.argv[1:12]

data = {}
if os.path.exists(ctx):
    with open(ctx, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}

if data.get("shape"):
    sys.exit(4)  # immutable-after: already recorded

data["shape"] = shape
data["shape_rationale"] = {
    "c1_constructive": c1 == "1",
    "c2_machine_checkable_acceptance": c2 == "1",
    "c3_blast_radius_le_1": c3 == "1",
    "c4_one_step_rollback": c4 == "1",
    "c5_no_negative_prior": c5 == "1",
}
if repro_cmd:
    data["evidence"] = {
        "type": "command",
        "repro_cmd": repro_cmd,
        "observed": observed,
        "predicted_delta": predicted_delta,
    }
    data["verification"] = {
        "probe": {"repro_cmd": repro_cmd, "expected_delta": predicted_delta},
    }
if acceptance_cmd:
    data["acceptance_cmd"] = acceptance_cmd

os.makedirs(os.path.dirname(ctx), exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".context.", suffix=".yaml.tmp", dir=os.path.dirname(ctx))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        yaml.safe_dump(data, fh, sort_keys=False)
    os.replace(tmp, ctx)
except BaseException:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PYEOF
}

cmd_classify() {
  local task_id="" mission="" writes="" acceptance_cmd="" rollback="" evidence_file="" mission_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id)         task_id="$2"; shift 2 ;;
      --mission)         mission="$2"; shift 2 ;;
      --mission-file)    mission_file="$2"; shift 2 ;;
      --writes)          writes="$2"; shift 2 ;;
      --acceptance-cmd)  acceptance_cmd="$2"; shift 2 ;;
      --rollback-onestep) rollback="1"; shift ;;
      *) log "unknown arg: $1"; exit 5 ;;
    esac
  done
  [[ -n "$task_id" ]] || { log "classify: --task-id required"; exit 5; }
  if [[ -n "$mission_file" ]]; then
    [[ -r "$mission_file" ]] || { log "classify: cannot read mission file: $mission_file"; exit 5; }
    mission="$(cat "$mission_file")"
  fi
  [[ -n "${mission//[[:space:]]/}" ]] || { log "classify: mission is empty"; exit 5; }

  local mode; mode="$(lane_shape_mode)"
  if [[ "$mode" == "off" ]]; then
    log "LEADV2_LANE_SHAPE=off — classify is a no-op (Stage 0)"
    exit 0
  fi

  local nm_file="${LEADV2_PROJECT_ROOT}/docs/leadv2-negative-memory.yaml"
  [[ -f "$nm_file" ]] || nm_file=""

  local out; out="$(_classify_py "$mission" "$writes" "$acceptance_cmd" "$rollback" "$nm_file")"
  local not_eligible diagnostic has_evidence c1 c2 c3 c4 c5 nm_hit shape repro_cmd observed predicted_delta
  not_eligible="$(sed -n 's/^not_eligible=//p' <<<"$out")"
  diagnostic="$(sed -n 's/^diagnostic=//p' <<<"$out")"
  has_evidence="$(sed -n 's/^has_evidence=//p' <<<"$out")"
  c1="$(sed -n 's/^c1=//p' <<<"$out")"; c2="$(sed -n 's/^c2=//p' <<<"$out")"
  c3="$(sed -n 's/^c3=//p' <<<"$out")"; c4="$(sed -n 's/^c4=//p' <<<"$out")"
  c5="$(sed -n 's/^c5=//p' <<<"$out")"; nm_hit="$(sed -n 's/^nm_hit=//p' <<<"$out")"
  shape="$(sed -n 's/^shape=//p' <<<"$out")"
  repro_cmd="$(sed -n 's/^repro_cmd=//p' <<<"$out")"
  observed="$(sed -n 's/^observed=//p' <<<"$out")"
  predicted_delta="$(sed -n 's/^predicted_delta=//p' <<<"$out")"

  if [[ "$not_eligible" == "1" ]]; then
    log "not shape-eligible: writes touch contracts/, supabase/migrations/, or >=2 core subsystems — route ${task_id} to the classified pipeline (plan triad), do not dispatch as a lane"
    exit 3
  fi

  if [[ "$diagnostic" == "1" && "$has_evidence" != "1" ]]; then
    if [[ "$mode" == "enforce" ]]; then
      log "REFUSED ${task_id}: diagnostic mission (names a defect / uses a fix verb) has no ## Evidence block (repro_cmd/observed/predicted_delta). Add one before dispatch (spec §4)."
      exit 2
    else
      log "WARN ${task_id}: diagnostic mission missing ## Evidence block — would be refused under LEADV2_LANE_SHAPE=enforce"
    fi
  fi

  log "${task_id}: shape=${shape} c1=${c1} c2=${c2} c3=${c3} c4=${c4} c5=${c5}${nm_hit:+ nm_hit=${nm_hit}}"

  local ctx; ctx="$(_context_path "$task_id")"
  local rc=0
  _write_context_yaml "$ctx" "$shape" "$c1" "$c2" "$c3" "$c4" "$c5" \
    "$repro_cmd" "$observed" "$predicted_delta" "$acceptance_cmd" || rc=$?
  if [[ $rc -eq 4 ]]; then
    log "REFUSED ${task_id}: shape already recorded in ${ctx} — shape is immutable after dispatch"
    exit 4
  elif [[ $rc -ne 0 ]]; then
    log "failed to write ${ctx} (rc=${rc})"
    exit 1
  fi
  printf 'shape=%s task=%s\n' "$shape" "$task_id"
  exit 0
}

# ── frame-check: LINE diagnosis-only one-shot MATCH/MISMATCH (spec §4, task 3) ─
cmd_frame_check() {
  local task_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) task_id="$2"; shift 2 ;;
      *) log "unknown arg: $1"; exit 5 ;;
    esac
  done
  [[ -n "$task_id" ]] || { log "frame-check: --task-id required"; exit 5; }
  local ctx; ctx="$(_context_path "$task_id")"
  [[ -f "$ctx" ]] || { log "frame-check: no context.yaml for ${task_id}"; exit 5; }

  local observed predicted_delta
  observed="$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1]))or{}; print((d.get('evidence')or{}).get('observed',''))" "$ctx")"
  predicted_delta="$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1]))or{}; print((d.get('evidence')or{}).get('predicted_delta',''))" "$ctx")"
  [[ -n "$observed" ]] || { log "frame-check: no evidence.observed in ${ctx} — nothing to check"; exit 5; }

  local claude_bin="${LEADV2_LANE_SHAPE_CLAUDE_BIN:-claude}"
  local prompt
  prompt="$(printf 'Does the OBSERVED output actually show the named defect, and would the proposed fix plausibly turn OBSERVED into PREDICTED_DELTA?\nOBSERVED:\n%s\nPREDICTED_DELTA:\n%s\nRespond with strict JSON: {"verdict":"MATCH"|"MISMATCH","quoted_line":"<one line copied verbatim from OBSERVED>","reason":"<one sentence>"}' "$observed" "$predicted_delta")"

  local raw
  raw="$("$claude_bin" -p "$prompt" --max-turns 1 --permission-mode bypassPermissions --output-format json 2>/dev/null)" || {
    log "frame-check: ${claude_bin} invocation failed"; exit 1;
  }

  local verdict quoted
  verdict="$(printf '%s' "$raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null || true)"
  quoted="$(printf '%s' "$raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('quoted_line',''))" 2>/dev/null || true)"

  local verdict_file="${LEADV2_HANDOFF_DIR}/${task_id}/frame.verdict.md"
  mkdir -p "$(dirname "$verdict_file")"

  if [[ -z "$quoted" || "$observed" != *"$quoted"* ]]; then
    printf -- '# Frame-check verdict: INVALID\n\nverdict returned no line quoted from `observed` — mechanically rejected (spec §6 risk table).\nraw: %s\n' "$raw" > "$verdict_file"
    log "frame-check: INVALID — no quoted observed line"
    exit 2
  fi

  printf -- '# Frame-check verdict: %s\n\nquoted_line: %s\n\nraw: %s\n' "$verdict" "$quoted" "$raw" > "$verdict_file"
  if [[ "$verdict" == "MATCH" ]]; then
    log "frame-check: MATCH"
    exit 0
  else
    log "frame-check: MISMATCH — bounced to lead pre-build"
    exit 1
  fi
}

# ── assert-artifacts: close-time per-shape artifact set, checked by CONTENT
#    (spec §6, task 6) ─────────────────────────────────────────────────────────
cmd_assert_artifacts() {
  local task_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) task_id="$2"; shift 2 ;;
      *) log "unknown arg: $1"; exit 5 ;;
    esac
  done
  [[ -n "$task_id" ]] || { log "assert-artifacts: --task-id required"; exit 5; }
  local ctx dir; ctx="$(_context_path "$task_id")"; dir="${LEADV2_HANDOFF_DIR}/${task_id}"

  if [[ ! -f "$ctx" ]]; then
    log "assert-artifacts: no context.yaml for ${task_id} — not opted into lane-shape, N/A"
    exit 0
  fi
  local shape; shape="$(python3 -c "import yaml,sys; print((yaml.safe_load(open(sys.argv[1]))or{}).get('shape',''))" "$ctx")"
  [[ -n "$shape" ]] || { log "assert-artifacts: context.yaml has no shape — N/A"; exit 0; }

  local -a failures=()

  if [[ "$shape" == "solo" ]]; then
    # Content check, not presence: an ## Acceptance heading with >=1 non-blank
    # line of pasted output beneath it, in ANY *.full.md under the task dir.
    local found=0
    shopt -s nullglob
    for f in "${dir}"/*.full.md; do
      if python3 -c "
import re, sys
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'^##\s*Acceptance\s*$', t, re.I | re.M)
sys.exit(0 if m and re.search(r'\S', t[m.end():m.end()+2000].split('##', 1)[0]) else 1)
" "$f"; then
        found=1; break
      fi
    done
    shopt -u nullglob
    if [[ $found -eq 0 ]]; then
      failures+=("SOLO: no *.full.md under ${dir} has a non-empty ## Acceptance section with pasted command output")
    fi
  elif [[ "$shape" == "line" ]]; then
    shopt -s nullglob
    local review_found=0
    for f in "${dir}"/*.review.md "${dir}"/review-verdict.yaml; do
      [[ -s "$f" ]] && review_found=1
    done
    shopt -u nullglob
    [[ $review_found -eq 1 ]] || failures+=("LINE: no review verdict artifact (*.review.md or review-verdict.yaml) under ${dir}")

    local probe_file="${dir}/verify-probe-result.yaml"
    if [[ -f "$probe_file" ]]; then
      local outcome; outcome="$(python3 -c "import yaml,sys; print((yaml.safe_load(open(sys.argv[1]))or{}).get('outcome',''))" "$probe_file" 2>/dev/null || true)"
      [[ "$outcome" == "probe_ok" ]] || failures+=("LINE: ${probe_file} outcome is '${outcome:-<missing>}', not probe_ok")
    else
      failures+=("LINE: ${probe_file} missing — run: leadv2-lane-shape.sh verify-probe --task-id ${task_id}")
    fi

    local harness_ok=0
    if [[ -f "$probe_file" ]] && python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1]))or{}; sys.exit(0 if d.get('harness_na') else 1)" "$probe_file" 2>/dev/null; then
      harness_ok=1
    fi
    if [[ $harness_ok -eq 0 ]]; then
      "${SCRIPT_DIR}/leadv2-lane-shape.sh" harness-check --task-id "$task_id" >/dev/null 2>&1 && harness_ok=1
    fi
    [[ $harness_ok -eq 1 ]] || failures+=("LINE: no harness registry entry for ${task_id} and no harness_na reason in ${probe_file}")
  else
    failures+=("unknown shape '${shape}' in ${ctx}")
  fi

  local mode; mode="$(lane_shape_mode)"
  if (( ${#failures[@]} > 0 )); then
    for f in "${failures[@]}"; do log "FAIL: $f"; done
    if [[ "$mode" == "enforce" ]]; then
      exit 1
    else
      log "mode=${mode} — not blocking close (would block under enforce)"
      exit 0
    fi
  fi
  log "assert-artifacts: ${task_id} (shape=${shape}) — artifact set complete"
  exit 0
}

# ── retro-check: re-derive minimum shape from the ACTUAL diff (spec §3 C3, task 6) ─
cmd_retro_check() {
  local task_id="" base="main" diff_files=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id)    task_id="$2"; shift 2 ;;
      --base)       base="$2"; shift 2 ;;
      --diff-files) diff_files="$2"; shift 2 ;;   # test seam: comma-separated, skips git
      *) log "unknown arg: $1"; exit 5 ;;
    esac
  done
  [[ -n "$task_id" ]] || { log "retro-check: --task-id required"; exit 5; }
  local ctx; ctx="$(_context_path "$task_id")"
  [[ -f "$ctx" ]] || { log "retro-check: no context.yaml for ${task_id} — N/A"; exit 0; }
  local shape; shape="$(python3 -c "import yaml,sys; print((yaml.safe_load(open(sys.argv[1]))or{}).get('shape',''))" "$ctx")"
  [[ -n "$shape" ]] || { log "retro-check: no shape recorded — N/A"; exit 0; }

  local files
  if [[ -n "$diff_files" ]]; then
    files="$(tr ',' '\n' <<<"$diff_files")"
  else
    files="$(git -C "$LEADV2_PROJECT_ROOT" diff --name-only "${base}...HEAD" 2>/dev/null || true)"
  fi

  local min_shape="solo"
  if [[ -n "$files" ]]; then
    min_shape="$(python3 -c "
import re, sys
files = [l for l in sys.stdin.read().splitlines() if l.strip()]
EXCLUDED = re.compile(r'(^|/)(supabase/migrations|contracts)(/|\$)|safety.?gate|publish|payments?|billing|prompt.?assembl', re.I)
subsystems = {f.split('/', 1)[0] for f in files if '/' in f}
core = {s for s in subsystems if s in ('platform', 'agent', 'web')}
excluded = any(EXCLUDED.search(f) for f in files)
print('line' if (excluded or len(core) >= 2) else 'solo')
" <<<"$files")"
  fi

  local mode; mode="$(lane_shape_mode)"
  if [[ "$shape" == "solo" && "$min_shape" == "line" ]]; then
    log "FAIL retro shape check: ${task_id} declared solo but its actual diff touches a LINE-only surface (excluded path or >=2 subsystems)"
    [[ "$mode" == "enforce" ]] && exit 1
    log "mode=${mode} — not blocking close (would block under enforce)"
  else
    log "retro-check: ${task_id} declared shape (${shape}) still holds against the actual diff"
  fi
  exit 0
}

# ── verify-probe: re-run repro_cmd, diff vs predicted_delta (spec §5, task 5) ──
cmd_verify_probe() {
  local task_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) task_id="$2"; shift 2 ;;
      *) log "unknown arg: $1"; exit 5 ;;
    esac
  done
  [[ -n "$task_id" ]] || { log "verify-probe: --task-id required"; exit 5; }
  local ctx dir; ctx="$(_context_path "$task_id")"; dir="${LEADV2_HANDOFF_DIR}/${task_id}"
  [[ -f "$ctx" ]] || { log "verify-probe: no context.yaml for ${task_id}"; exit 5; }

  local repro_cmd expected
  repro_cmd="$(python3 -c "import yaml,sys; print((((yaml.safe_load(open(sys.argv[1]))or{}).get('verification')or{}).get('probe')or{}).get('repro_cmd',''))" "$ctx")"
  expected="$(python3 -c "import yaml,sys; print((((yaml.safe_load(open(sys.argv[1]))or{}).get('verification')or{}).get('probe')or{}).get('expected_delta',''))" "$ctx")"
  [[ -n "$repro_cmd" ]] || { log "verify-probe: no verification.probe.repro_cmd in ${ctx} (solo shape, or evidence not derived) — nothing to probe"; exit 5; }

  local actual rc
  actual="$(cd "$LEADV2_PROJECT_ROOT" && eval "$repro_cmd" 2>&1)"; rc=$?

  local outcome="probe_neg"
  [[ "$actual" == *"$expected"* ]] && outcome="probe_ok"

  local out_file="${dir}/verify-probe-result.yaml"
  mkdir -p "$dir"
  python3 - "$out_file" "$outcome" "$repro_cmd" "$rc" <<'PYEOF' >/dev/null
import sys, yaml, datetime
path, outcome, repro_cmd, rc = sys.argv[1:5]
yaml.safe_dump({
    "outcome": outcome,
    "repro_cmd": repro_cmd,
    "exit_code": int(rc),
    "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}, open(path, "w", encoding="utf-8"), sort_keys=False)
PYEOF
  log "verify-probe: ${task_id} outcome=${outcome}"
  [[ "$outcome" == "probe_ok" ]] && exit 0 || exit 1
}

# ── harness-check: task-id-tagged entry required (spec §5.4, task 7) ──────────
cmd_harness_check() {
  local task_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) task_id="$2"; shift 2 ;;
      *) log "unknown arg: $1"; exit 5 ;;
    esac
  done
  [[ -n "$task_id" ]] || { log "harness-check: --task-id required"; exit 5; }
  local registry="${LEADV2_PROJECT_ROOT}/tests/e2e/full-cycle-harness.sh"
  [[ -f "$registry" ]] || registry="${LEADV2_PROJECT_ROOT}/docs/testing/e2e-full-cycle-harness.md"
  if [[ -f "$registry" ]] && grep -qF -- "$task_id" "$registry"; then
    log "harness-check: ${task_id} found in ${registry}"
    exit 0
  fi
  log "harness-check: ${task_id} not found in harness registry"
  exit 1
}

# ── journal: one telemetry line per close (spec task 8) ────────────────────────
cmd_journal() {
  local task_id="" rounds="0" gates_fired=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id)     task_id="$2"; shift 2 ;;
      --rounds)      rounds="$2"; shift 2 ;;
      --gates-fired) gates_fired="$2"; shift 2 ;;
      *) log "unknown arg: $1"; exit 5 ;;
    esac
  done
  [[ -n "$task_id" ]] || { log "journal: --task-id required"; exit 5; }
  local ctx; ctx="$(_context_path "$task_id")"
  local shape="unknown"
  [[ -f "$ctx" ]] && shape="$(python3 -c "import yaml,sys; print((yaml.safe_load(open(sys.argv[1]))or{}).get('shape','unknown'))" "$ctx")"
  local jfile="${LEADV2_PROJECT_ROOT}/docs/leadv2/lane-shape-telemetry.jsonl"
  mkdir -p "$(dirname "$jfile")"
  python3 -c "
import json, sys, datetime
print(json.dumps({
    'ts': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'task_id': sys.argv[1], 'shape': sys.argv[2], 'rounds': int(sys.argv[3]),
    'gates_fired': sys.argv[4],
}))
" "$task_id" "$shape" "$rounds" "$gates_fired" >> "$jfile"
  log "journal: appended shape=${shape} rounds=${rounds} gates_fired=${gates_fired}"
  exit 0
}

usage() {
  cat >&2 <<'EOF'
Usage: leadv2-lane-shape.sh <subcommand> [args]
  classify --task-id ID (--mission TEXT|--mission-file F) [--writes CSV] [--acceptance-cmd CMD] [--rollback-onestep]
  frame-check --task-id ID
  assert-artifacts --task-id ID
  retro-check --task-id ID [--base main] [--diff-files CSV]
  verify-probe --task-id ID
  harness-check --task-id ID
  journal --task-id ID [--rounds N] [--gates-fired LIST]
EOF
  exit 5
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    classify)          cmd_classify "$@" ;;
    frame-check)       cmd_frame_check "$@" ;;
    assert-artifacts)  cmd_assert_artifacts "$@" ;;
    retro-check)        cmd_retro_check "$@" ;;
    verify-probe)       cmd_verify_probe "$@" ;;
    harness-check)       cmd_harness_check "$@" ;;
    journal)             cmd_journal "$@" ;;
    *) usage ;;
  esac
}

main "$@"
