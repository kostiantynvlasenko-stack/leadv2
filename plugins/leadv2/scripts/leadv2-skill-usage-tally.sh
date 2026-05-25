#!/usr/bin/env bash
# leadv2-skill-usage-tally.sh — Wiring + invocation snapshot for /leadv2 plugin skills.
#
# Prints a table classifying each skill in `skills/` by wiring status:
#   DISPATCH    — explicit Skill(skill="X") site found
#   WIRED       — name referenced in commands/leadv2.md or other skill SKILL.md
#   DORMANT     — no references anywhere outside its own dir
#
# Also reports last-modified date as a proxy for recency. Invoked weekly by
# lead-reflect §7.5; can also run standalone:  bash leadv2-skill-usage-tally.sh
#
# Source of truth for plugin path: $CLAUDE_PLUGIN_ROOT; falls back to script dir.

set -uo pipefail
# Note: -e disabled — grep returns 1 on "no match" which is normal here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUG_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKILLS_DIR="$PLUG_ROOT/skills"
COMMAND_FILE="$PLUG_ROOT/commands/leadv2.md"

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "ERR: skills dir not found at $SKILLS_DIR" >&2
  exit 1
fi

printf '%-40s %-10s %-12s %s\n' "SKILL" "STATUS" "MTIME" "REFS"
printf '%-40s %-10s %-12s %s\n' "----------------------------------------" "----------" "------------" "----"

dormant_count=0
wired_count=0
dispatch_count=0

while IFS= read -r -d '' skill_dir; do
  skill_name=$(basename "$skill_dir")
  skill_file="$skill_dir/SKILL.md"
  [[ -f "$skill_file" ]] || continue

  # Search files: commands + other skills' SKILL.md (exclude this skill's own dir)
  search_paths=()
  [[ -f "$COMMAND_FILE" ]] && search_paths+=("$COMMAND_FILE")
  while IFS= read -r -d '' other_skill_md; do
    [[ "$other_skill_md" != "$skill_file" ]] && search_paths+=("$other_skill_md")
  done < <(find "$SKILLS_DIR" -name 'SKILL.md' -print0)

  if [[ ${#search_paths[@]} -eq 0 ]]; then
    refs=0
    dispatch_hits=0
  else
    refs=$( { grep -lE "\b${skill_name}\b" "${search_paths[@]}" 2>/dev/null || true; } | wc -l | tr -d ' ')
    dispatch_hits=$( { grep -hE "Skill\(skill=\"${skill_name}\"" "${search_paths[@]}" 2>/dev/null || true; } | wc -l | tr -d ' ')
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

  if [[ "$dispatch_hits" -gt 0 ]]; then
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

total=$((dormant_count + wired_count + dispatch_count))
echo ""
echo "summary: total=$total dispatch=$dispatch_count wired=$wired_count dormant=$dormant_count"
[[ "$dormant_count" -gt 0 ]] && \
  echo "action: review DORMANT entries; inline / dispatch / delete per /leadv2 retro 2026-05-19"
