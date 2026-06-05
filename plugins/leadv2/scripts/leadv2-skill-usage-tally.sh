#!/usr/bin/env bash
# leadv2-skill-usage-tally.sh — Wiring + invocation snapshot for /leadv2 plugin skills.
#
# Prints a table classifying each skill in `skills/` by wiring status:
#   DISPATCH    — explicit Skill(skill="X") site found
#   WIRED       — name referenced in commands/*.md, docs/*.md, hooks/hooks.json,
#                 hooks/*.sh, scripts/*.sh, scripts/*.py, or other skill SKILL.md
#   DEFERRED    — SKILL.md front-matter has status: deferred* (takes priority over DORMANT)
#   DORMANT     — no references anywhere outside its own dir (and not deferred)
#
# Also reports last-modified date as a proxy for recency. Invoked weekly by
# lead-reflect §7.5; can also run standalone:  bash leadv2-skill-usage-tally.sh
#
# Options:
#   --consumer-root <path>   Also grep <path> tree for `leadv2:<name>` or `<name>`
#                            refs (repeatable). A skill appearing here = WIRED.
#
# Source of truth for plugin path: $CLAUDE_PLUGIN_ROOT; falls back to script dir.

set -uo pipefail
# Note: -e disabled — grep returns 1 on "no match" which is normal here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUG_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKILLS_DIR="$PLUG_ROOT/skills"

# ── Parse optional --consumer-root args ──────────────────────────────────────
consumer_roots=()
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  if [[ "${args[$i]}" == "--consumer-root" ]]; then
    i=$(( i + 1 ))
    if [[ $i -lt ${#args[@]} ]]; then
      consumer_roots+=("${args[$i]}")
    fi
  fi
  i=$(( i + 1 ))
done

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "ERR: skills dir not found at $SKILLS_DIR" >&2
  exit 1
fi

printf '%-40s %-10s %-12s %s\n' "SKILL" "STATUS" "MTIME" "REFS"
printf '%-40s %-10s %-12s %s\n' "----------------------------------------" "----------" "------------" "----"

dormant_count=0
wired_count=0
dispatch_count=0
deferred_count=0

while IFS= read -r -d '' skill_dir; do
  skill_name=$(basename "$skill_dir")
  skill_file="$skill_dir/SKILL.md"
  [[ -f "$skill_file" ]] || continue

  # ── Check for deferred status in front-matter ─────────────────────────────
  is_deferred=0
  if head -10 "$skill_file" 2>/dev/null | grep -qE '^status:\s*deferred'; then
    is_deferred=1
  fi

  # ── Build search_paths: commands/*.md, docs/*.md, hooks/hooks.json,
  #    hooks/*.sh, scripts/*.sh, scripts/*.py, other skills' SKILL.md ─────────
  search_paths=()

  # commands/*.md
  while IFS= read -r -d '' f; do
    search_paths+=("$f")
  done < <(find "$PLUG_ROOT/commands" -name '*.md' -print0 2>/dev/null)

  # docs/*.md
  while IFS= read -r -d '' f; do
    search_paths+=("$f")
  done < <(find "$PLUG_ROOT/docs" -name '*.md' -print0 2>/dev/null)

  # hooks/hooks.json
  [[ -f "$PLUG_ROOT/hooks/hooks.json" ]] && search_paths+=("$PLUG_ROOT/hooks/hooks.json")

  # hooks/*.sh
  while IFS= read -r -d '' f; do
    search_paths+=("$f")
  done < <(find "$PLUG_ROOT/hooks" -name '*.sh' -print0 2>/dev/null)

  # scripts/*.sh and scripts/*.py (exclude this script to avoid self-match noise)
  while IFS= read -r -d '' f; do
    [[ "$f" == "${BASH_SOURCE[0]}" ]] && continue
    search_paths+=("$f")
  done < <(find "$PLUG_ROOT/scripts" \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null)

  # other skills' SKILL.md
  while IFS= read -r -d '' other_skill_md; do
    [[ "$other_skill_md" != "$skill_file" ]] && search_paths+=("$other_skill_md")
  done < <(find "$SKILLS_DIR" -name 'SKILL.md' -print0)

  # ── Consumer roots: collect files from supplied path trees ────────────────
  consumer_paths=()
  for cr in "${consumer_roots[@]}"; do
    if [[ -d "$cr" ]]; then
      while IFS= read -r -d '' f; do
        consumer_paths+=("$f")
      done < <(find "$cr" -type f \( -name '*.md' -o -name '*.json' -o -name '*.sh' -o -name '*.py' -o -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null)
    fi
  done

  # ── Count refs ────────────────────────────────────────────────────────────
  refs=0
  dispatch_hits=0
  if [[ ${#search_paths[@]} -gt 0 || ${#consumer_paths[@]} -gt 0 ]]; then
    all_paths=()
    [[ ${#search_paths[@]} -gt 0 ]]  && all_paths+=("${search_paths[@]}")
    [[ ${#consumer_paths[@]} -gt 0 ]] && all_paths+=("${consumer_paths[@]}")
    refs=$( { grep -lE "\b${skill_name}\b|leadv2:${skill_name}" "${all_paths[@]}" 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [[ ${#search_paths[@]} -gt 0 ]]; then
      dispatch_hits=$( { grep -hE "Skill\(skill=\"${skill_name}\"" "${search_paths[@]}" 2>/dev/null || true; } | wc -l | tr -d ' ')
    fi
  fi

  # Detect AUTO-invoke status: skills whose description starts with "Phase N",
  # or matching a known phase-backbone / always-on list. These fire via Claude's
  # description-matching and don't need explicit grep evidence.
  AUTO_LIST="leadv2-plan leadv2-build leadv2-review leadv2-deploy leadv2-close leadv2-recovery leadv2-verify leadv2-token-discipline leadv2-subagent-protocol"
  is_auto=0
  if [[ " $AUTO_LIST " == *" $skill_name "* ]]; then
    is_auto=1
  elif head -10 "$skill_file" 2>/dev/null | grep -qE '^description:\s*"?Phase [0-9]'; then
    is_auto=1
  fi

  # DEFERRED takes priority — parked skills must not appear as DORMANT
  if [[ "$is_deferred" -eq 1 ]]; then
    status="DEFERRED"
    deferred_count=$((deferred_count+1))
  elif [[ "$dispatch_hits" -gt 0 ]]; then
    status="DISPATCH"
    dispatch_count=$((dispatch_count+1))
  elif [[ "$refs" -gt 0 ]]; then
    status="WIRED"
    wired_count=$((wired_count+1))
  elif [[ "$is_auto" -eq 1 ]]; then
    status="AUTO"
    wired_count=$((wired_count+1))
  else
    status="DORMANT"
    dormant_count=$((dormant_count+1))
  fi

  mtime=$(date -r "$skill_file" +%Y-%m-%d 2>/dev/null || echo "?")
  printf '%-40s %-10s %-12s refs=%d dispatch=%d\n' "$skill_name" "$status" "$mtime" "$refs" "$dispatch_hits"
done < <(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
# Note: sort -z is GNU-only; macOS lacks it. Output order is filesystem-dependent.

total=$((dormant_count + wired_count + dispatch_count + deferred_count))
echo ""
echo "summary: total=$total dispatch=$dispatch_count wired=$wired_count dormant=$dormant_count deferred=$deferred_count"
[[ "$dormant_count" -gt 0 ]] && \
  echo "action: review DORMANT entries; inline / dispatch / delete per /leadv2 retro 2026-05-19"
[[ "$deferred_count" -gt 0 ]] && \
  echo "action: DEFERRED skills are parked pending v0.2+ — revisit when their gating milestone ships"
