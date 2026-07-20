#!/usr/bin/env bash
# leadv2-skill-lint.sh — deterministic ZERO-LLM linter for skill/agent-config
# files (skills/**/SKILL.md, agents/*.md). Catches frontmatter drift and
# prompt regressions before commit. Distinct from leadv2-prompt-lint.sh
# (spawn-prompt word cap) and leadv2-mission-lint.sh (mission-file dup/size
# checks) — this one validates the SKILL.md/agent.md config files themselves.
#
# Checks (pure grep/awk/python3-yaml, no LLM call):
#   1. Frontmatter present + parseable; description present and not vague/empty
#   2. Loop/repeated-spawning language with no termination/iteration limit
#   3. Tool/skill name referenced in prose but absent from declared
#      allowed-tools/tools/skills (schema-intent mismatch, best-effort)
#   4. Broken/duplicate frontmatter keys
#
# Usage: leadv2-skill-lint.sh [file...]
#   No args -> lints default targets: skills/**/SKILL.md, agents/*.md
#   (relative to the plugin root, two dirs up from this script).
#
# Output: "FILE:LINE  [check:SEVERITY]  message" per finding.
# Exit 0  = clean (or MEDIUM-only findings).
# Exit 2  = at least one HIGH-severity finding.
# Exit 1  = usage/internal error (e.g. missing python3/yaml).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "[skill-lint] ERROR: python3 + PyYAML required" >&2
  exit 1
fi

# --- resolve target file list -----------------------------------------------
declare -a FILES=()
if [[ $# -ge 1 ]]; then
  FILES=("$@")
else
  while IFS= read -r f; do FILES+=("$f"); done < <(
    find "${PLUGIN_ROOT}/skills" -type f -name 'SKILL.md' 2>/dev/null
    find "${PLUGIN_ROOT}/agents" -maxdepth 1 -type f -name '*.md' ! -iname 'README.md' 2>/dev/null
  )
fi

if [[ "${#FILES[@]}" -eq 0 ]]; then
  echo "[skill-lint] no target files found" >&2
  exit 0
fi

# --- python3 checker (per-file) --------------------------------------------
# Written to a scratch file (not a stdin heredoc) so argv carries the target
# path cleanly — avoids the heredoc+stdin-conflict pitfall.
CHECKER="$(mktemp)"
trap 'rm -f "$CHECKER"' EXIT

cat >"$CHECKER" <<'PYEOF'
import re
import sys

import yaml

TOOL_VOCAB = {
    "Read", "Write", "Edit", "Bash", "Glob", "Grep", "WebFetch", "WebSearch",
    "Task", "TodoWrite", "NotebookEdit", "Monitor", "AskUserQuestion", "Agent",
}
VAGUE_DESC = {
    "todo", "tbd", "fixme", "xxx", "description", "placeholder", "skill",
    "agent", "wip", "tba", "n/a", "na", "none", "-",
}
LOOP_RE = re.compile(
    r"\b(loop(?:ing)?|iterat\w*|repeat(?:edly)?|for each\b.*\bspawn|"
    r"while\b.*\bspawn|keep spawning|spawn until|spawn (?:agents|subagents) "
    r"(?:for each|repeatedly))\b",
    re.IGNORECASE,
)
SPAWN_NEARBY_RE = re.compile(r"\bspawn(?:s|ing|ed)?\b|\bsubagents?\b|\bAgent\(", re.IGNORECASE)
TERMINATION_RE = re.compile(
    r"\b(max(?:imum)?|limit|cap|budget|hard cap|no more than|at most|"
    r"\d+\s*(?:times|iterations?)|iterations?|terminat\w*|stop after|ceiling)\b",
    re.IGNORECASE,
)
BACKTICK_TOOL_RE = re.compile(r"`([A-Za-z][A-Za-z0-9_]*)`")
BACKTICK_SKILL_RE = re.compile(r"`([a-z0-9][a-z0-9-]*)`\s+skill\b")

findings = []  # (line, check, severity, message)


def add(line, check, severity, message):
    findings.append((line, check, severity, message))


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v).strip() for v in value]
    if isinstance(value, str):
        return [v.strip() for v in value.split(",") if v.strip()]
    return []


def main(path):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    lines = text.splitlines()

    if not lines or lines[0].strip() != "---":
        add(1, "frontmatter-missing", "HIGH", "file does not start with a '---' frontmatter block")
        _run_body_only_checks(lines, {}, 1)
        return

    close_idx = None
    for i in range(1, min(len(lines), 200)):
        if lines[i].strip() == "---":
            close_idx = i
            break
    if close_idx is None:
        add(1, "frontmatter-missing", "HIGH", "no closing '---' found for frontmatter block")
        _run_body_only_checks(lines, {}, 1)
        return

    fm_lines = lines[1:close_idx]
    fm_text = "\n".join(fm_lines)

    # duplicate top-level keys (PyYAML silently keeps last -> must scan raw text)
    key_re = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):")
    seen = {}
    for offset, l in enumerate(fm_lines, start=2):
        m = key_re.match(l)
        if m:
            key = m.group(1)
            seen.setdefault(key, []).append(offset)
    for key, occurrences in seen.items():
        if len(occurrences) > 1:
            add(occurrences[-1], "frontmatter-duplicate-key", "HIGH",
                f"key '{key}' declared {len(occurrences)}x (lines {occurrences})")

    try:
        data = yaml.safe_load(fm_text) or {}
        if not isinstance(data, dict):
            raise ValueError("frontmatter did not parse to a mapping")
    except Exception as exc:  # noqa: BLE001 - report any parse failure
        add(1, "frontmatter-unparsable", "HIGH", f"YAML parse error: {exc}")
        _run_body_only_checks(lines, {}, close_idx + 1)
        return

    desc = data.get("description")
    if not isinstance(desc, str) or not desc.strip():
        add(3 if "description" not in fm_text else 1, "description-missing", "HIGH",
            "no non-empty 'description' key in frontmatter")
    else:
        words = desc.strip().split()
        if desc.strip().lower() in VAGUE_DESC or len(words) == 1:
            add(1, "description-vague", "HIGH",
                f"description is a placeholder/one-word value: {desc.strip()!r}")
        elif len(words) < 4:
            add(1, "description-vague", "MEDIUM",
                f"description is very short ({len(words)} words): {desc.strip()!r}")

    declared_tools = set(as_list(data.get("tools"))) | set(as_list(data.get("allowed-tools")))
    declared_skills = set(as_list(data.get("skills")))

    _run_body_only_checks(lines, {"tools": declared_tools, "skills": declared_skills}, close_idx + 1)


def _run_body_only_checks(lines, declared, body_start_idx):
    declared_tools = declared.get("tools", set())
    declared_skills = declared.get("skills", set())

    # check 2: loop/repeated-spawn language with no termination limit anywhere
    full_text = "\n".join(lines)
    has_termination = bool(TERMINATION_RE.search(full_text))
    if not has_termination:
        for idx in range(body_start_idx, len(lines)):
            window = "\n".join(lines[idx:idx + 3])
            if LOOP_RE.search(lines[idx]) and SPAWN_NEARBY_RE.search(window):
                add(idx + 1, "loop-no-termination", "HIGH",
                    "loop/repeat language near a spawn reference with no max/limit/cap/iteration bound found in file")
                break  # one finding per file is enough signal

    # check 3a: backtick tool name mentioned but not declared
    if declared:  # only meaningful once we know the file has real frontmatter
        seen_tools = set()
        for idx in range(body_start_idx, len(lines)):
            for m in BACKTICK_TOOL_RE.finditer(lines[idx]):
                tok = m.group(1)
                if tok in TOOL_VOCAB and tok not in declared_tools and tok not in seen_tools:
                    seen_tools.add(tok)
                    add(idx + 1, "tool-mismatch", "MEDIUM",
                        f"tool `{tok}` referenced in prose but not in declared tools/allowed-tools")

        seen_skills = set()
        for idx in range(body_start_idx, len(lines)):
            for m in BACKTICK_SKILL_RE.finditer(lines[idx]):
                tok = m.group(1)
                if declared_skills and tok not in declared_skills and tok not in seen_skills:
                    seen_skills.add(tok)
                    add(idx + 1, "skill-mismatch", "MEDIUM",
                        f"skill `{tok}` referenced in prose but not in declared 'skills:' list")


if __name__ == "__main__":
    target = sys.argv[1]
    main(target)
    high = 0
    for line, check, severity, message in findings:
        print(f"{target}:{line}  [{check}:{severity}]  {message}")
        if severity == "HIGH":
            high += 1
    sys.exit(2 if high else 0)
PYEOF

# --- run checker across all target files ------------------------------------
overall_rc=0
for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "[skill-lint] missing file: $f" >&2
    overall_rc=1
    continue
  fi
  rc=0
  python3 "$CHECKER" "$f" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    overall_rc=2
  elif [[ "$rc" -ne 0 ]]; then
    [[ "$overall_rc" -eq 0 ]] && overall_rc=1
  fi
done

exit "$overall_rc"
