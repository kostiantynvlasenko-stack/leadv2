#!/usr/bin/env bash
# leadv2-render-close.sh — Render a closed YAML into BOARD.md, LEAD_V2_STATE.md,
# DIALOGUE.md, and QUEUE.md. Idempotent via <!-- rendered: <task_id> --> markers.
#
# Usage:
#   leadv2-render-close.sh <task_id>
#   leadv2-render-close.sh --all        # re-render all closed YAMLs (idempotent)
#
# Exit codes:
#   0  success (rendered or no-op)
#   1  YAML missing, schema invalid, or python3 absent
#   2  target file missing or unwritable (partial render)
#   3  fingerprint conflict (YAML exists with different content — not used here;
#      the fingerprint check lives in phase8-close.sh YAML write step)
#
# YAML schema required fields:
#   task_id, closed_at, title, summary_one_line, class, outcome,
#   files_touched, commit, vps_deployed, also_closes, followups,
#   board_prose, dialogue_prose

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT}}"
cd "$PROJECT_ROOT"

# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh"
_lv2_load_paths

log()         { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_info()    { log "INFO: $*"; }
log_error()   { log "ERROR: $*"; }
log_warning() { log "WARN: $*"; }

# ── dependency check ──────────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  log_error "python3 is required but not found"
  exit 1
fi

# ── argument parsing ──────────────────────────────────────────────────────────
ALL_MODE=0
TASK_ID=""

if [[ "${1:-}" == "--all" ]]; then
  ALL_MODE=1
elif [[ -n "${1:-}" ]]; then
  TASK_ID="$1"
else
  log_error "Usage: leadv2-render-close.sh <task_id> | --all"
  exit 1
fi

CLOSED_DIR="${LEADV2_LEADV2_DIR}/closed"
BOARD_FILE="${LEADV2_BOARD_PATH}"
STATE_FILE="${LEADV2_LEAD_STATE_PATH}"
DIALOGUE_FILE="${LEADV2_DIALOGUE_PATH}"
QUEUE_FILE="${LEADV2_QUEUE_PATH}"

# ── atomic file write helper ───────────────────────────────────────────────────
# Write content to a temp file then mv atomically.
atomic_write() {
  local target="$1"
  local tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  cat > "$tmp"
  mv "$tmp" "$target"
}

# ── render one task ───────────────────────────────────────────────────────────
render_task() {
  local task_id="$1"
  local yaml_path="${CLOSED_DIR}/${task_id}.yaml"

  if [[ ! -f "$yaml_path" ]]; then
    log_error "YAML not found: $yaml_path"
    return 1
  fi

  # Parse YAML — exits non-zero on schema failure
  local vars
  if ! vars=$(python3 - "$yaml_path" <<'PYEOF'
import sys, yaml, json, tempfile

yaml_path = sys.argv[1]

with open(yaml_path) as f:
    data = yaml.safe_load(f)

required = [
    "task_id", "closed_at", "title", "summary_one_line",
    "class", "outcome", "files_touched", "commit",
    "vps_deployed", "also_closes", "followups",
    "board_prose", "dialogue_prose",
]
missing = [k for k in required if k not in data]
if missing:
    print(f"MISSING: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)

def esc(s):
    return str(s).replace("'", "'\\''")

print(f"YAML_TASK_ID='{esc(data['task_id'])}'")
print(f"YAML_DATE='{str(data['closed_at'])[:10]}'")
print(f"YAML_TITLE='{esc(data['title'])}'")
print(f"YAML_SUMMARY='{esc(data['summary_one_line'])}'")
print(f"YAML_COMMIT='{esc(data['commit'])}'")
print(f"YAML_CLASS='{esc(data['class'])}'")
print(f"YAML_OUTCOME='{esc(data['outcome'])}'")

board_tmp = tempfile.mktemp(suffix=".board_prose")
dial_tmp  = tempfile.mktemp(suffix=".dial_prose")
with open(board_tmp, "w") as f:
    f.write(data["board_prose"])
with open(dial_tmp, "w") as f:
    f.write(data["dialogue_prose"])
print(f"BOARD_PROSE_FILE='{board_tmp}'")
print(f"DIAL_PROSE_FILE='{dial_tmp}'")
PYEOF
    ); then
    log_error "YAML schema invalid for ${task_id} — missing required fields"
    return 1
  fi

  # Source the shell vars
  eval "$vars"

  local marker="<!-- rendered: ${YAML_TASK_ID} -->"
  local rendered_any=0

  # Pre-flight: only LEAD_V2_STATE.md is a hard requirement.
  # BOARD.md, DIALOGUE.md, QUEUE.md are best-effort — missing is a warning, not a failure.
  if [[ ! -f "$STATE_FILE" ]]; then
    log_error "Target missing: $STATE_FILE — aborting render for ${task_id}"
    return 1
  fi

  # cleanup prose temp files on exit
  trap 'rm -f "${BOARD_PROSE_FILE:-}" "${DIAL_PROSE_FILE:-}"' RETURN

  # ── 1. BOARD.md — targeted-prepend (best-effort) ───────────────────────────
  if [[ ! -f "$BOARD_FILE" ]]; then
    log_warning "BOARD.md missing: ${BOARD_FILE} — skipping (non-blocking)"
  elif grep -qF "$marker" "$BOARD_FILE"; then
    log_info "BOARD.md already rendered for ${YAML_TASK_ID} — skipping"
  else
    local board_prose
    board_prose="$(cat "$BOARD_PROSE_FILE")"
    # Build new HEAD block
    local new_block
    new_block="## HEAD — ${YAML_DATE} Kyiv (${YAML_TASK_ID} — ${YAML_TITLE})"$'\n\n'
    new_block+="${board_prose}"$'\n\n'
    new_block+="${marker}"$'\n'

    # Insert immediately after the first line (the <!-- BOARD HEAD --> comment)
    {
      head -1 "$BOARD_FILE"
      printf -- '%s\n' "$new_block"
      tail -n +2 "$BOARD_FILE"
    } | atomic_write "$BOARD_FILE" || log_warning "BOARD.md write failed for ${YAML_TASK_ID} — non-blocking"
    log_info "BOARD.md: prepended HEAD block for ${YAML_TASK_ID}"
    rendered_any=1
  fi

  # ── 2. LEAD_V2_STATE.md — targeted-insert after history: ───────────────────
  if [[ ! -f "$STATE_FILE" ]]; then
    log_error "Target missing: $STATE_FILE — aborting"
    return 1
  elif grep -qF "$marker" "$STATE_FILE"; then
    log_info "LEAD_V2_STATE.md already rendered for ${YAML_TASK_ID} — skipping"
  else
    local history_line="  - ${YAML_TASK_ID} ✅ ${YAML_DATE} — ${YAML_SUMMARY} ${marker}"
    # Insert new line immediately after the line containing 'history:'
    python3 - "$STATE_FILE" "$history_line" <<'PYEOF'
import sys

path = sys.argv[1]
new_line = sys.argv[2]

with open(path) as f:
    lines = f.readlines()

out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and line.strip().startswith("history:"):
        out.append(new_line + "\n")
        inserted = True

if not inserted:
    # fallback: append at end
    out.append(new_line + "\n")

import tempfile, os
tmp = path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    f.writelines(out)
os.replace(tmp, path)
PYEOF
    log_info "LEAD_V2_STATE.md: inserted history line for ${YAML_TASK_ID}"
    rendered_any=1
  fi

  # ── 3. DIALOGUE.md — targeted-prepend after line 1 (best-effort) ───────────
  if [[ ! -f "$DIALOGUE_FILE" ]]; then
    log_warning "DIALOGUE.md missing: ${DIALOGUE_FILE} — skipping (non-blocking)"
  elif grep -qF "$marker" "$DIALOGUE_FILE"; then
    log_info "DIALOGUE.md already rendered for ${YAML_TASK_ID} — skipping"
  else
    local dial_prose
    dial_prose="$(cat "$DIAL_PROSE_FILE")"
    local new_dial_block
    new_dial_block="## ${YAML_DATE} — ${YAML_TASK_ID} (${YAML_TITLE})"$'\n'
    new_dial_block+="${dial_prose}"$'\n'
    new_dial_block+="${marker}"$'\n'

    # Update <!-- last_outcome: ... --> on line 1, then insert block after line 1
    {
      printf -- '<!-- last_outcome: %s %s %s -->\n' \
        "${YAML_TASK_ID}" "${YAML_DATE}" "${YAML_OUTCOME}"
      printf -- '%s\n' "$new_dial_block"
      tail -n +2 "$DIALOGUE_FILE"
    } | atomic_write "$DIALOGUE_FILE" || log_warning "DIALOGUE.md write failed for ${YAML_TASK_ID} — non-blocking"
    log_info "DIALOGUE.md: prepended entry for ${YAML_TASK_ID}"
    rendered_any=1
  fi

  # ── 4. QUEUE.md [x] mark (best-effort; skip when frozen redirect banner) ────
  if [[ -f "$QUEUE_FILE" ]]; then
    # Check if QUEUE.md is a frozen redirect banner — first non-blank line contains
    # "frozen" or "redirected" → skip write entirely.
    _qmd_banner=0
    if python3 -c "
import sys
with open('${QUEUE_FILE}') as f:
    for line in f:
        stripped = line.strip()
        if stripped:
            if 'frozen' in stripped.lower() or 'redirected' in stripped.lower():
                sys.exit(0)
            break
sys.exit(1)
" 2>/dev/null; then
      _qmd_banner=1
    fi
    if [[ "$_qmd_banner" -eq 1 ]]; then
      log_info "QUEUE.md: frozen redirect banner detected — skipping [x] write for ${YAML_TASK_ID}"
    elif grep -qF "$marker" "$QUEUE_FILE"; then
      log_info "QUEUE.md already rendered for ${YAML_TASK_ID} — skipping"
    else
      printf -- '\n- [x] %s — %s %s\n' \
        "${YAML_TASK_ID}" "${YAML_DATE}" "${marker}" \
        >> "$QUEUE_FILE" || log_warning "QUEUE.md [x] write failed for ${YAML_TASK_ID} — non-blocking"
      log_info "QUEUE.md: marked [x] for ${YAML_TASK_ID}"
    fi
  else
    log_warning "QUEUE.md missing: ${QUEUE_FILE} — skipping [x] write (non-blocking)"
  fi

  # ── 5. tasks.yaml summary_one_line update (best-effort via lib) ─────────────
  local _lib_sh="${PROJECT_ROOT}/.claude/scripts/leadv2-tasks-lib.sh"
  if [[ -f "$_lib_sh" ]]; then
    # shellcheck source=/dev/null
    source "$_lib_sh" 2>/dev/null || true
    if declare -f leadv2_tasks_update >/dev/null 2>&1; then
      leadv2_tasks_update "${YAML_TASK_ID}" --key summary_one_line --value "${YAML_SUMMARY}" \
        2>/dev/null || log_warning "leadv2_tasks_update summary_one_line failed for ${YAML_TASK_ID} — non-blocking"
      log_info "tasks.yaml: summary_one_line updated for ${YAML_TASK_ID}"
    fi
  fi

  if (( rendered_any )); then
    log_info "Render complete for ${YAML_TASK_ID}"
  else
    log_info "No-op for ${YAML_TASK_ID} — all targets already rendered"
  fi
  return 0
}

# ── post-close handoff cleanup: archive transient files ──────────────────────
# Removes .full.md (kept .summary.md as canonical) and mission-*.md (only useful
# during active task). Source-of-truth lives in closed/<id>.yaml.
_cleanup_handoff_artifacts() {
  local tid="$1"
  local hd="${PROJECT_ROOT}/docs/handoff/${tid}"
  [[ ! -d "$hd" ]] && return 0
  local n
  n=$(find "$hd" -maxdepth 1 -type f \( -name '*.full.md' -o -name 'mission-*.md' -o -name '*-mission.md' -o -name 'phase8-passed.flag.prompted' \) -delete -print 2>/dev/null | wc -l | tr -d ' ')
  [[ "${n:-0}" -gt 0 ]] && log_info "cleanup: removed $n transient file(s) from handoff/${tid}/"
  return 0
}

# ── yaml-queue sync: mark task done in tasks.yaml via lib ────────────────────
# Called after render_task so the sentinel is already on disk.
_queue_release_task() {
  local tid="$1"
  local tasks_lib="${PROJECT_ROOT}/.claude/scripts/leadv2-tasks-lib.sh"
  [[ ! -f "$tasks_lib" ]] && return 0
  # shellcheck source=leadv2-tasks-lib.sh
  source "$tasks_lib"
  local outcome="${LEADV2_RELEASE_OUTCOME:-success}"
  # Check current status — skip if already terminal (idempotency guard)
  local current_status
  current_status=$(leadv2_tasks_by_id "$tid" 2>/dev/null \
    | python3 -c "import sys,yaml; d=(yaml.safe_load(sys.stdin) or [{}])[0]; print(d.get('status',''))" 2>/dev/null || true)
  case "${current_status}" in
    done|poisoned|rejected|failed|archived|closed|completed|admin-closed)
      log_info "queue-release: $tid already terminal ($current_status) — skipping"
      return 0
      ;;
    "")
      log_info "queue-release: $tid not found in tasks.yaml — skipping"
      return 0
      ;;
  esac
  leadv2_tasks_release "$tid" --outcome "$outcome" || {
    log_warning "tasks.yaml release failed for $tid"
    return 0   # best-effort, do not gate-fail render-close
  }
  log_info "queue-release: $tid → done (outcome=$outcome)"
}

# ── main ──────────────────────────────────────────────────────────────────────
if (( ALL_MODE )); then
  exit_code=0
  shopt -s nullglob
  yaml_files=( "${CLOSED_DIR}"/*.yaml )
  shopt -u nullglob
  if (( ${#yaml_files[@]} == 0 )); then
    log_info "No closed YAMLs found in ${CLOSED_DIR}"
    exit 0
  fi
  for yaml_file in "${yaml_files[@]}"; do
    tid="$(basename "$yaml_file" .yaml)"
    render_task "$tid" || { rc=$?; (( exit_code = exit_code > rc ? exit_code : rc )); }
    _queue_release_task "$tid"
    _cleanup_handoff_artifacts "$tid"
  done
  exit "$exit_code"
else
  render_task "$TASK_ID"
  _queue_release_task "$TASK_ID"
  _cleanup_handoff_artifacts "$TASK_ID"
  exit $?
fi
