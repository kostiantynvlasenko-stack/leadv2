#!/usr/bin/env python3
"""
leadv2-skill-budget-audit.py — Token-cost and quality audit for /leadv2 skills.

Per skill (READ-ONLY — never deletes anything):
  - Estimated prompt tokens (chars/4 heuristic)
  - Description quality flags: too long (>80 words) or trivially short (<4 words)
  - Duplicate name detection across roots
  - Usage status: shells out to leadv2-skill-usage-tally.sh, folds result in

Output: prioritised report — highest token cost + dormant first.
Recommendations printed as text; nothing is modified.

Usage:
  python3 leadv2-skill-budget-audit.py [ROOT_DIR]
"""
import sys, os, glob, subprocess
from pathlib import Path

SCRIPT_DIR  = Path(__file__).parent.resolve()
PLUG_ROOT   = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else SCRIPT_DIR.parent
SKILLS_DIR  = PLUG_ROOT / "skills"
TALLY       = SCRIPT_DIR / "leadv2-skill-usage-tally.sh"

if not SKILLS_DIR.is_dir():
    print(f"ERROR: skills dir not found: {SKILLS_DIR}")
    sys.exit(1)


def parse_frontmatter(path: Path):
    """Return (fm_dict_or_None, full_text)."""
    try:
        import yaml
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines()
        if not lines or lines[0].strip() != "---":
            return None, text
        try:
            end = lines.index("---", 1)
        except ValueError:
            return None, text
        fm_text = "\n".join(lines[1:end])
        try:
            data = yaml.safe_load(fm_text)
        except Exception:
            data = None
        return data, text
    except Exception:
        return None, ""


# ── 1. Parse skills ───────────────────────────────────────────────────────────
skills: list[dict] = []
names_seen: dict[str, Path] = {}

for skill_file in sorted(SKILLS_DIR.glob("*/SKILL.md")):
    skill_name = skill_file.parent.name
    fm, full_text = parse_frontmatter(skill_file)

    name = (fm or {}).get("name", skill_name) if isinstance(fm, dict) else skill_name
    desc = (fm or {}).get("description", "")   if isinstance(fm, dict) else ""
    desc = desc if isinstance(desc, str) else ""

    est_tokens = max(1, len(full_text) // 4)
    desc_words = len(desc.split()) if desc else 0

    dup_of = None
    if name in names_seen:
        dup_of = names_seen[name]
    else:
        names_seen[name] = skill_file

    skills.append({
        "skill_name": skill_name,
        "name":       name,
        "desc":       desc,
        "desc_words": desc_words,
        "est_tokens": est_tokens,
        "fm_valid":   isinstance(fm, dict),
        "dup_of":     dup_of,
        "path":       skill_file,
        "status":     "UNKNOWN",
    })

# ── 2. Tally usage via existing script ───────────────────────────────────────
tally_by_name: dict[str, str] = {}

if TALLY.exists():
    try:
        result = subprocess.run(
            ["bash", str(TALLY)],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "CLAUDE_PLUGIN_ROOT": str(PLUG_ROOT)},
        )
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] in ("DISPATCH", "WIRED", "DORMANT", "AUTO", "DEFERRED"):
                tally_by_name[parts[0]] = parts[1]
    except Exception as exc:
        print(f"WARN: could not run tally script: {exc}", file=sys.stderr)
else:
    print(f"WARN: tally script not found: {TALLY}", file=sys.stderr)

for s in skills:
    s["status"] = tally_by_name.get(s["skill_name"], "UNKNOWN")

# ── 3. Sort: DORMANT first, DEFERRED next, then by token cost desc ───────────
STATUS_ORDER = {"DORMANT": 0, "DEFERRED": 1, "UNKNOWN": 2, "WIRED": 3, "AUTO": 4, "DISPATCH": 5}

skills.sort(key=lambda s: (STATUS_ORDER.get(s["status"], 9), -s["est_tokens"]))

# ── 4. Report ─────────────────────────────────────────────────────────────────
total_tokens = sum(s["est_tokens"] for s in skills)
dormant   = [s for s in skills if s["status"] == "DORMANT"]
deferred  = [s for s in skills if s["status"] == "DEFERRED"]
desc_long = [s for s in skills if s["desc_words"] > 80]
desc_short= [s for s in skills if 0 < s["desc_words"] < 4]
dups      = [s for s in skills if s["dup_of"] is not None]
bad_fm    = [s for s in skills if not s["fm_valid"]]

print("=" * 72)
print("leadv2 Skill Budget Audit")
print("=" * 72)
print(f"Total skills : {len(skills)}   Est. total tokens : {total_tokens:,}")
print(f"DORMANT      : {len(dormant)}   DEFERRED             : {len(deferred)}")
print(f"Desc long(>80w): {len(desc_long)}   Desc short(<4w): {len(desc_short)}   Dup names : {len(dups)}   YAML errors : {len(bad_fm)}")
print()
print(f"{'SKILL':<42} {'STATUS':<10} {'~TOKENS':>8}  {'DESC_W':>6}  FLAGS")
print("-" * 72)
for s in skills:
    flags = []
    if not s["fm_valid"]:          flags.append("YAML-ERR")
    if s["dup_of"]:                flags.append(f"DUP:{s['name']}")
    if s["desc_words"] > 80:       flags.append("DESC-LONG")
    if 0 < s["desc_words"] < 4:   flags.append("DESC-SHORT")
    if s["status"] == "DORMANT":   flags.append("RECOMMEND-REVIEW")
    if s["status"] == "DEFERRED":  flags.append("DEFERRED-V0.2+")
    print(f"{s['skill_name']:<42} {s['status']:<10} {s['est_tokens']:>8,}  {s['desc_words']:>6}  {'  '.join(flags)}")

print()
print(f"TOTAL estimated tokens loaded per session: {total_tokens:,}")

# ── 5. Recommendations ────────────────────────────────────────────────────────
if bad_fm or dups or desc_long or desc_short or dormant or deferred:
    print()
    print("RECOMMENDATIONS (read-only — nothing deleted):")
    for s in bad_fm:
        print(f"  FIX-YAML   [{s['skill_name']}]: description needs quoting (unquoted colon or bracket)")
    for s in dups:
        print(f"  RENAME     [{s['skill_name']}]: name '{s['name']}' duplicates {s['dup_of']}")
    for s in desc_long:
        print(f"  TRIM-DESC  [{s['skill_name']}]: {s['desc_words']} words — trim to <=80")
    for s in desc_short:
        print(f"  EXPAND-DESC[{s['skill_name']}]: {s['desc_words']} word(s) — expand to >=4 words")
    for s in dormant:
        print(f"  DORMANT    [{s['skill_name']}]: ~{s['est_tokens']:,} tokens, unused — inline or dispatch")
    for s in deferred:
        print(f"  DEFERRED   [{s['skill_name']}]: ~{s['est_tokens']:,} tokens, parked pending v0.2+ milestone")
