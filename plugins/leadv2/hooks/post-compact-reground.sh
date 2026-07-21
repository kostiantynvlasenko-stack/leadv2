#!/usr/bin/env bash
# post-compact-reground.sh — SessionStart hook, matcher "compact" (LEAD-COMPACT-SURVIVAL-01).
#
# Pairs with pre-compact-task-freeze.sh: that hook writes <leadv2_dir>/.compact-freeze.md
# just before /compact runs. This hook re-prints that SAME frozen content as the very
# first tool_result of the post-compact session, plus a hard re-grounding directive.
# Source: FILE ONLY (.compact-freeze.md written pre-compact) — no network, no
# re-derivation, no Supabase.
#
# Fail-open: ANY error -> exit 0, empty stdout. Never blocks a session start.
# stdlib-only (bash + python3), zero network, target <400ms.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/leadv2-temp.sh"
trap 'exit 0' ERR

# ── capture the hook's real stdin (JSON payload) before any heredoc can ─────
# consume it (heredocs piped into `python3 -` would otherwise steal stdin).
TMPFILE="$(lv2_mktemp_file "pe-post-compact-reground" "json")" || exit 0
trap 'rm -f "${TMPFILE:-}"' EXIT
trap 'rm -f "${TMPFILE:-}"; exit 0' ERR
python3 -c "import sys; open('$TMPFILE','w').write(sys.stdin.read())" 2>/dev/null || exit 0

OUT="$(python3 - "$TMPFILE" <<'PYEOF' 2>/dev/null
import sys, os, re, json, subprocess

CAP = 120

DIRECTIVE = (
    "POST-COMPACT RE-GROUND -- mandatory, before any other action.\n"
    "Tasks above were open BEFORE the compact. The compact did not close them.\n"
    "1. In your very first reply, explicitly list which of these are still live and their state.\n"
    "2. Do not start new work until you have checked against this list.\n"
    "3. If a task is no longer relevant, close it explicitly in tasks.yaml -- never by silence."
)


def git_toplevel(path):
    try:
        r = subprocess.run(
            ["git", "-C", path, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=2,
        )
        top = r.stdout.strip()
        return os.path.realpath(top) if r.returncode == 0 and top else path
    except Exception:
        return path


def resolve_leadv2_dir(root):
    sp = os.path.join(root, ".claude", "leadv2-overrides", "state-paths.yaml")
    try:
        with open(sp, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"^\s*leadv2_dir\s*:\s*(.+?)\s*$", line)
                if m:
                    val = m.group(1).strip().strip("'\"")
                    if val and val not in ("null", "~"):
                        return val
    except Exception:
        pass
    return "docs/leadv2"


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        try:
            payload = json.load(f)
        except Exception:
            payload = {}
    cwd = payload.get("cwd") or os.getcwd()
    root = git_toplevel(os.path.realpath(cwd))
    leadv2_dir = resolve_leadv2_dir(root)
    freeze_path = os.path.join(root, leadv2_dir, ".compact-freeze.md")
    if not os.path.isfile(freeze_path):
        return  # nothing frozen — silent no-op

    with open(freeze_path, encoding="utf-8") as f:
        frozen_lines = [l.rstrip("\n") for l in f]

    directive_lines = DIRECTIVE.splitlines()
    # reserve directive + wrapper tags + blank separator
    budget = CAP - len(directive_lines) - 3
    if budget < 0:
        budget = 0
    body = frozen_lines[:budget]

    out = (
        ["<post-compact-reground>"]
        + body
        + [""]
        + directive_lines
        + ["</post-compact-reground>"]
    )
    print("\n".join(out))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
PYEOF
)" || exit 0

[[ -n "$OUT" ]] && printf -- '%s\n' "$OUT"
exit 0
