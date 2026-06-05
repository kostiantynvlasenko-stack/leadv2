#!/usr/bin/env bash
# leadv2-validate-skills.sh — Validate SKILL.md front-matter for all skills.
#
# Checks per skill:
#   1. Front-matter starts at line 1 (first line is ---)
#   2. Front-matter closes with ---
#   3. YAML parses (python3 yaml.safe_load)
#   4. Front-matter is a mapping
#   5. name exists and is a non-empty string
#   6. description exists and is a non-empty string
#   7. name values are unique across all files
#
# Usage: bash leadv2-validate-skills.sh [ROOT_DIR]
# Exit 0 = all pass; exit 1 = failures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUG_ROOT="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKILLS_DIR="$PLUG_ROOT/skills"

if [[ ! -d "$SKILLS_DIR" ]]; then
  printf 'ERROR: skills dir not found: %s\n' "$SKILLS_DIR" >&2
  exit 1
fi

python3 - "$SKILLS_DIR" <<'PYEOF'
import sys, os, glob, yaml

skills_dir = sys.argv[1]
skill_files = sorted(glob.glob(os.path.join(skills_dir, '*/SKILL.md')))
if not skill_files:
    print(f"ERROR: no SKILL.md files found under {skills_dir}")
    sys.exit(1)

errors, names, ok_count = [], {}, 0
for skill_file in skill_files:
    skill_name = os.path.basename(os.path.dirname(skill_file))
    try:
        content = open(skill_file, encoding='utf-8').read()
    except OSError as exc:
        errors.append((skill_name, f"cannot read: {exc}")); continue
    lines = content.split('\n')
    if not lines or lines[0].strip() != '---':
        errors.append((skill_name, "front-matter missing or not at line 1")); continue
    try:
        end_idx = lines.index('---', 1)
    except ValueError:
        errors.append((skill_name, "no closing '---' in front-matter")); continue
    fm_text = '\n'.join(lines[1:end_idx])
    try:
        data = yaml.safe_load(fm_text)
    except yaml.YAMLError as exc:
        errors.append((skill_name, f"YAML error: {str(exc).split(chr(10))[0]}")); continue
    if not isinstance(data, dict):
        errors.append((skill_name, f"not a mapping (got {type(data).__name__})")); continue
    name = data.get('name'); desc = data.get('description'); before = len(errors)
    if not name or not isinstance(name, str) or not name.strip():
        errors.append((skill_name, f"name missing/empty (got {name!r})")); name = None
    if not desc or not isinstance(desc, str) or not desc.strip():
        errors.append((skill_name, f"description missing/empty (got {desc!r})"))
    if name:
        if name in names:
            errors.append((skill_name, f"duplicate name '{name}' — first at {names[name]}"))
        else:
            names[name] = skill_file
    if len(errors) == before:
        ok_count += 1

total = len(skill_files)
if errors:
    print(f"FAIL: {len(errors)} error(s) in {total} skill(s)\n")
    for s, m in errors: print(f"  [{s}] {m}")
    sys.exit(1)
else:
    print(f"PASS: all {total} skill(s) valid — {ok_count} unique names, 0 errors")
PYEOF
