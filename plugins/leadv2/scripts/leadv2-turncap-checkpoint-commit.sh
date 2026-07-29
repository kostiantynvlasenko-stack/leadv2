#!/usr/bin/env bash
# leadv2-turncap-checkpoint-commit.sh — LANE-TURNCAP-CHECKPOINT-01 backstop.
#
# Called by leadv2-session-runner.sh the moment it detects an attempt died
# from --max-turns exhaustion (turn_cap_turns() non-empty). This is the
# deterministic safety net: it does not depend on the model having complied
# with the in-session budget warning (leadv2-turncap-checkpoint-hook.sh) —
# it runs from OUTSIDE the killed process, after the fact.
#
# What it does:
#   1. Reads the per-task touched-files manifest the PostToolUse hook built
#      while the lane ran (one path per Write/Edit/MultiEdit call).
#   2. Keeps only paths that are (a) inside PROJECT_ROOT and (b) currently
#      dirty per `git status --porcelain -- <path>`. This is the whole
#      safety property: a shared tree has other lanes' uncommitted work
#      sitting in the same working copy, and this script must never stage
#      a file it did not see this lane touch.
#   3. If nothing survives step 2 — lane made no edits, or already
#      self-committed everything — exits 0, no-op. A clean/early finish is
#      never forced into a pointless commit.
#   4. If the manifest's files do NOT already include a fresh
#      docs/handoff/<TASK_ID>/CHECKPOINT.md (i.e. the model did not
#      self-report before the cap), generates a minimal fallback note and
#      includes it in the same commit — so a partial commit never lands
#      without a handoff artifact pointing the next attempt at it.
#   5. `git add -- <exact paths>` (never -A / .) + one commit.
#
# Usage:
#   leadv2-turncap-checkpoint-commit.sh <task_id> <project_root> <attempt> <max_attempts> <cap>
#
# Env:
#   LEADV2_TURNCAP_CHECKPOINT=0        — disable entirely (single-flip rollback)
#   LEADV2_TURNCAP_STATE_DIR           — override state dir (default: ~/.claude/state/leadv2; test hook)
#
# Exit codes: 0 on no-op or successful commit; 1 on bad usage; non-fatal
# `git commit` failure is logged and returns 1 — callers must not treat
# this as fatal to the resume loop.
set -euo pipefail

log() { printf '[turncap-checkpoint] %s\n' "$*" >&2; }

[[ "${LEADV2_TURNCAP_CHECKPOINT:-1}" == "0" ]] && { log "disabled via LEADV2_TURNCAP_CHECKPOINT=0"; exit 0; }

TASK_ID="${1:-}"
PROJECT_ROOT="${2:-}"
ATTEMPT="${3:-?}"
MAX_ATTEMPTS="${4:-?}"
CAP="${5:-?}"

if [[ -z "$TASK_ID" || -z "$PROJECT_ROOT" ]]; then
  log "usage: $0 <task_id> <project_root> [attempt] [max_attempts] [cap]"
  exit 1
fi
[[ -d "$PROJECT_ROOT/.git" ]] || { log "not a git checkout: $PROJECT_ROOT — nothing to do"; exit 0; }

SAFE_ID="$(printf -- '%s' "$TASK_ID" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SAFE_ID" ]] && { log "task id sanitizes to empty — nothing to do"; exit 0; }

STATE_DIR="${LEADV2_TURNCAP_STATE_DIR:-$HOME/.claude/state/leadv2}"
TOUCHED_FILE="${STATE_DIR}/${SAFE_ID}.touched-files"

if [[ ! -s "$TOUCHED_FILE" ]]; then
  log "no touched-files manifest for ${TASK_ID} (or empty) — nothing to checkpoint"
  exit 0
fi

TASK_DIR="${PROJECT_ROOT}/docs/handoff/${TASK_ID}"
CHECKPOINT_NOTE="${TASK_DIR}/CHECKPOINT.md"

# --- Resolve manifest -> real, in-repo, currently-dirty absolute paths ----
dirty_files=()
while IFS= read -r raw_path; do
  [[ -z "$raw_path" ]] && continue
  case "$raw_path" in
    "$PROJECT_ROOT"/*) : ;;
    *) continue ;;  # outside this repo — never touch it
  esac
  [[ -e "$raw_path" ]] || continue
  status="$(git -C "$PROJECT_ROOT" status --porcelain -- "$raw_path" 2>/dev/null || true)"
  [[ -z "$status" ]] && continue  # not dirty (already committed, or never changed)
  dirty_files+=("$raw_path")
done < <(sort -u -- "$TOUCHED_FILE")

if [[ "${#dirty_files[@]}" -eq 0 ]]; then
  log "manifest had entries but nothing is currently dirty for ${TASK_ID} — nothing to checkpoint"
  exit 0
fi

# --- Did the lane self-checkpoint (write a fresh CHECKPOINT.md) already? --
self_reported=0
for f in "${dirty_files[@]}"; do
  [[ "$f" == "$CHECKPOINT_NOTE" ]] && self_reported=1 && break
done

if [[ "$self_reported" -eq 0 ]]; then
  mkdir -p "$TASK_DIR"
  {
    printf '# Turncap auto-checkpoint — %s\n\n' "$TASK_ID"
    printf 'Attempt %s/%s hit the turn cap (%s turns) before writing its own handoff note.\n' \
      "$ATTEMPT" "$MAX_ATTEMPTS" "$CAP"
    printf 'This file is an automatic fallback, not a summary from the lane itself.\n\n'
    printf '## Files committed by this checkpoint\n'
    for f in "${dirty_files[@]}"; do
      printf -- '- %s\n' "${f#"$PROJECT_ROOT"/}"
    done
    printf '\n## What to do next\n'
    printf '1. `git show` the checkpoint commit for the files above to see what was in flight.\n'
    printf '2. Read the tail of docs/handoff/%s/session-runner.log for the last actions before the cap.\n' "$TASK_ID"
    printf '3. Treat the committed files as partial, not finished — resume from there, do not re-investigate from zero.\n'
  } > "$CHECKPOINT_NOTE"
  dirty_files+=("$CHECKPOINT_NOTE")
  log "no self-authored CHECKPOINT.md found — wrote fallback at ${CHECKPOINT_NOTE}"
fi

# --- Stage exactly these files, by name, and commit -----------------------
if ! git -C "$PROJECT_ROOT" add -- "${dirty_files[@]}"; then
  log "git add failed — leaving files uncommitted for manual inspection"
  exit 1
fi

commit_msg="chore(leadv2): turncap checkpoint ${TASK_ID} — attempt ${ATTEMPT}/${MAX_ATTEMPTS}, cap ${CAP} (auto, LANE-TURNCAP-CHECKPOINT-01)"
if git -C "$PROJECT_ROOT" commit -m "$commit_msg" -- "${dirty_files[@]}" >/dev/null; then
  sha="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)"
  log "committed ${#dirty_files[@]} file(s) for ${TASK_ID} (attempt ${ATTEMPT}/${MAX_ATTEMPTS}): ${sha}"
  exit 0
else
  log "git commit failed for ${TASK_ID} — files remain staged for manual inspection"
  exit 1
fi
