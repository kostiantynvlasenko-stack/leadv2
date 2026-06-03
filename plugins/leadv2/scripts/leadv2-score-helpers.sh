#!/usr/bin/env bash
# leadv2-score-helpers.sh — Sourced helper library for score extraction.
#
# Provides penalty extraction helpers used by leadv2-score-compute.sh and
# leadv2-score-trend.sh. Source this file; do not execute it directly.
#
# Functions exported:
#   extract_critical_count   <state_md> <handoff_dir>  → integer (stdout)
#   extract_review_round     <state_md> <handoff_dir>  → 0 or 1 (stdout, 1 = round >= 2)
#   extract_recovery_flag    <state_md>                → 0 or 1 (stdout, 1 = triggered)
#   extract_hack_findings    <handoff_dir>             → integer count (stdout)
#   extract_premortem_risk   <handoff_dir>             → 0 or 1 (stdout, 1 = risk_score >= 7)
#
# All functions log missing sources to stderr at INFO level; return 0 count
# instead of failing so score-compute proceeds with partial data.

# ── extract_critical_count ────────────────────────────────────────────────────
# Count critical-severity findings in:
#   1. STATE.md: lines matching severity:\s*critical
#   2. handoff_dir/critic.summary.md or critic.full.md: lines matching c[0-9]+: ... critical
# Returns combined integer count to stdout.
extract_critical_count() {
  local state_md="${1:-}"
  local handoff_dir="${2:-}"
  local count=0

  if [[ -f "$state_md" ]]; then
    local n
    n=$(grep -ciE 'severity[[:space:]]*:[[:space:]]*critical' "$state_md" 2>/dev/null || true)
    count=$(( count + n ))
  else
    printf -- '[score-helpers] extract_critical_count: source_missing=%s\n' "$state_md" >&2
  fi

  # Check critic summary/full in handoff dir
  if [[ -d "$handoff_dir" ]]; then
    local f
    for f in "$handoff_dir"/critic.summary.md "$handoff_dir"/critic.full.md; do
      if [[ -f "$f" ]]; then
        local n2
        n2=$(grep -ciE '(severity[[:space:]]*:[[:space:]]*critical|critical:)' "$f" 2>/dev/null || true)
        count=$(( count + n2 ))
      fi
    done
  else
    printf -- '[score-helpers] extract_critical_count: handoff_dir_missing=%s\n' "$handoff_dir" >&2
  fi

  printf -- '%d' "$count"
}

# ── extract_review_round ──────────────────────────────────────────────────────
# Returns 1 if the task went to review round >= 2, else 0.
# Sources:
#   1. STATE.md: key review_round: N  (>= 2 → flag)
#   2. Presence of r2-*.md files in handoff_dir → flag
extract_review_round() {
  local state_md="${1:-}"
  local handoff_dir="${2:-}"

  if [[ -f "$state_md" ]]; then
    local round_val
    round_val=$(grep -oE 'review_round[[:space:]]*:[[:space:]]*([0-9]+)' "$state_md" 2>/dev/null \
      | grep -oE '[0-9]+$' | sort -rn | head -1 || true)
    if [[ -n "$round_val" ]] && (( round_val >= 2 )); then
      printf -- '1'
      return 0
    fi
  else
    printf -- '[score-helpers] extract_review_round: source_missing=%s\n' "$state_md" >&2
  fi

  if [[ -d "$handoff_dir" ]]; then
    local r2_count
    r2_count=$(find "$handoff_dir" -maxdepth 1 -name 'r2-*.md' 2>/dev/null | wc -l | tr -d ' ')
    if (( r2_count > 0 )); then
      printf -- '1'
      return 0
    fi
  fi

  printf -- '0'
}

# ── extract_recovery_flag ─────────────────────────────────────────────────────
# Returns 1 if STATE.md contains a recovery block with triggered: true, else 0.
extract_recovery_flag() {
  local state_md="${1:-}"

  if [[ ! -f "$state_md" ]]; then
    printf -- '[score-helpers] extract_recovery_flag: source_missing=%s\n' "$state_md" >&2
    printf -- '0'
    return 0
  fi

  # Look for recovery block: "recovery:" followed within a few lines by "triggered: true"
  if grep -qE 'triggered[[:space:]]*:[[:space:]]*true' "$state_md" 2>/dev/null; then
    # Verify it's inside a recovery context
    if grep -A 5 'recovery:' "$state_md" 2>/dev/null | grep -qE 'triggered[[:space:]]*:[[:space:]]*true'; then
      printf -- '1'
      return 0
    fi
  fi

  printf -- '0'
}

# ── extract_hack_findings ─────────────────────────────────────────────────────
# Count [FINDING] markers in handoff_dir/hack-detection.full.md, or
# "Findings:" lines in any codex output in handoff_dir.
extract_hack_findings() {
  local handoff_dir="${1:-}"
  local count=0

  if [[ ! -d "$handoff_dir" ]]; then
    printf -- '[score-helpers] extract_hack_findings: handoff_dir_missing=%s\n' "$handoff_dir" >&2
    printf -- '0'
    return 0
  fi

  local hack_file="$handoff_dir/hack-detection.full.md"
  if [[ -f "$hack_file" ]]; then
    local n
    n=$(grep -cE '^\[FINDING\]' "$hack_file" 2>/dev/null || true)
    count=$(( count + n ))
    # Also count inline [FINDING] occurrences
    local n2
    n2=$(grep -cE '\[FINDING\]' "$hack_file" 2>/dev/null || true)
    # Use max of the two (avoid double-count if same line starts with [FINDING])
    if (( n2 > n )); then
      count=$(( count + n2 - n ))
    fi
  fi

  # Scan codex outputs in handoff dir for "Findings:" count lines
  local f
  for f in "$handoff_dir"/codex*.md "$handoff_dir"/codex*.txt; do
    [[ -f "$f" ]] || continue
    local n3
    n3=$(grep -cE '^[[:space:]]*[0-9]+\.' "$f" 2>/dev/null || true)
    count=$(( count + n3 ))
  done

  printf -- '%d' "$count"
}

# ── extract_premortem_risk ────────────────────────────────────────────────────
# Returns 1 if premortem summary shows risk_score >= 7, else 0.
extract_premortem_risk() {
  local handoff_dir="${1:-}"

  if [[ ! -d "$handoff_dir" ]]; then
    printf -- '[score-helpers] extract_premortem_risk: handoff_dir_missing=%s\n' "$handoff_dir" >&2
    printf -- '0'
    return 0
  fi

  local pf
  for pf in "$handoff_dir"/premortem.summary.md "$handoff_dir"/premortem-build.yaml "$handoff_dir"/premortem-deploy.yaml; do
    [[ -f "$pf" ]] || continue
    local risk_val
    risk_val=$(grep -oE 'risk_score[[:space:]]*:[[:space:]]*([0-9]+)' "$pf" 2>/dev/null \
      | grep -oE '[0-9]+$' | sort -rn | head -1 || true)
    if [[ -n "$risk_val" ]] && (( risk_val >= 7 )); then
      printf -- '1'
      return 0
    fi
  done

  printf -- '0'
}
