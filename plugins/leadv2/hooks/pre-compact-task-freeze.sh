#!/usr/bin/env bash
# pre-compact-task-freeze.sh — PreCompact hook (LEAD-COMPACT-SURVIVAL-01).
#
# Problem this fixes: /compact is a generative rewrite. Nothing pins the open
# task-id list through it. Evidence:
# docs/handoff/LEAD-ANCHOR-01/long-session-analysis.md — 27 compacts across two
# sessions; at the LAST compact of each, 136/139 and 191/191 task-ids mentioned
# before the compact never resurfaced after it. That's forgetting, not closing.
#
# Fix: before compact, freeze everything that must survive into
# <leadv2_dir>/.compact-freeze.md AND print it to stdout — PreCompact stdout
# is fed into the compact summarizer's context, so the task list physically
# survives the rewrite instead of depending on a prompt-text reminder.
#
# Source of truth: FILE ONLY.
#   - docs/tasks.yaml            (file mirror of Supabase work_items; status
#                                  open/in_progress == anything not in a
#                                  closed-status set — see CLOSED_STATUSES)
#   - <leadv2_dir>/open-threads.md          (verbatim)
#   - <leadv2_dir>/scheduled-decisions.md   (DUE/OVERDUE rows only)
#   - <leadv2_dir>/tasks/*/journal.md       (tail of the most recently
#                                             touched journal, best-effort)
# NO network, NO Supabase call — after a compact nobody goes to the network,
# that is the entire premise of this hook.
#
# Cap: 120 lines. On overflow the journal tail is trimmed first (down to
# zero); the open task-id list is NEVER truncated — it is the one thing this
# hook exists to protect.
#
# Fail-open: ANY error -> exit 0, empty stdout. A broken hook must never
# block a compact.
#
# stdlib-only (bash + python3, +PyYAML if present — degrades to a regex
# line-parser without it), zero network, target <400ms.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/leadv2-temp.sh"
trap 'exit 0' ERR

# ── capture the hook's real stdin (JSON payload) before any heredoc can ─────
# consume it (heredocs piped into `python3 -` would otherwise steal stdin).
TMPFILE="$(lv2_mktemp_file "pe-compact-freeze" "json")" || exit 0
trap 'rm -f "${TMPFILE:-}"' EXIT
trap 'rm -f "${TMPFILE:-}"; exit 0' ERR
python3 -c "import sys; open('$TMPFILE','w').write(sys.stdin.read())" 2>/dev/null || exit 0

OUT="$(python3 - "$TMPFILE" <<'PYEOF' 2>/dev/null
import sys, os, re, json, subprocess, glob, datetime

CAP = 120
CLOSED_STATUSES = {
    "done", "closed", "resolved", "complete", "completed",
    "cancelled", "canceled",
}


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


def parse_tasks_yaml(path):
    """Return [(id, status, intent), ...] for tasks NOT in CLOSED_STATUSES.
    Tries PyYAML first (correctly handles folded multi-line intent scalars);
    falls back to a stdlib-only regex line-parser if PyYAML is unavailable
    or the file fails to parse.
    """
    try:
        import yaml
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        out = []
        for t in (data.get("tasks") or []):
            tid = str(t.get("id", "")).strip()
            status = str(t.get("status", "")).strip()
            intent = str(t.get("intent", "")).strip()
            priority = str(t.get("priority", "")).strip()
            if tid and status.lower() not in CLOSED_STATUSES:
                out.append((tid, status, intent, priority))
        return out
    except Exception:
        pass
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for entry in re.split(r"\n(?=- id:\s)", text):
            m_id = re.search(r"^- id:\s*(\S+)", entry)
            m_status = re.search(r"\n\s*status:\s*(\S+)", entry)
            if not m_id or not m_status:
                continue
            m_intent = re.search(r"\n\s*intent:\s*'?(.+)", entry)
            m_priority = re.search(r"\n\s*priority:\s*'?([Pp]\d)", entry)
            tid = m_id.group(1).strip()
            status = m_status.group(1).strip()
            intent = (m_intent.group(1).strip() if m_intent else "")[:120]
            priority = (m_priority.group(1).strip().upper() if m_priority else "")
            if status.lower() not in CLOSED_STATUSES:
                out.append((tid, status, intent, priority))
    except Exception:
        pass
    return out


def read_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().splitlines()
    except Exception:
        return []


def due_rows(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if re.search(r"\b(DUE|OVERDUE)\b", line):
                    rows.append(line.rstrip("\n"))
    except Exception:
        pass
    return rows


def latest_journal_tail(root, leadv2_dir, n=15):
    pattern = os.path.join(root, leadv2_dir, "tasks", "*", "journal.md")
    try:
        files = glob.glob(pattern)
        if not files:
            return None, []
        latest = max(files, key=lambda p: os.path.getmtime(p))
        task_id = os.path.basename(os.path.dirname(latest))
        with open(latest, encoding="utf-8") as f:
            lines = [l.rstrip("\n") for l in f if l.strip()]
        return task_id, lines[-n:]
    except Exception:
        return None, []


def role_and_tail(lines, tail_n=40):
    """COMPACT-DEDUP-01 FU2: open-threads.md was embedded VERBATIM (broke the
    120-line CAP -- 643 ln / 105KB observed live). Bound it instead to the two
    things with actual resume value, per the SESSION-HANDOFF-01 design panel's
    Carry table (role sacrosanct, tail truncates first):
      - ROLE block: open-threads.md's own head (WHO YOU ARE + founder
        standing rules) -- structurally the span up to the 3rd "# N."
        heading (keeps sections 1+2, drops volatile section 3+). Falls back
        to the first 28 lines if the file has fewer than 3 numbered headings.
      - FRESHEST tail: last `tail_n` lines -- open-threads.md is an
        append-only log, so the tail is always the newest entries.
    Short files (role + tail would overlap) are returned whole -- nothing to
    save by truncating. Returns (role_lines, tail_lines, dropped_count).
    """
    heading_idxs = [i for i, l in enumerate(lines) if re.match(r"^#\s*\d+\.", l)]
    role_end = heading_idxs[2] if len(heading_idxs) >= 3 else min(28, len(lines))
    tail_start = max(role_end, len(lines) - tail_n)
    if tail_start <= role_end:
        return lines, [], 0
    return lines[:role_end], lines[tail_start:], tail_start - role_end


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        try:
            payload = json.load(f)
        except Exception:
            payload = {}
    cwd = payload.get("cwd") or os.getcwd()
    root = git_toplevel(os.path.realpath(cwd))
    leadv2_dir = resolve_leadv2_dir(root)
    leadv2_abs = os.path.join(root, leadv2_dir)
    if not os.path.isdir(leadv2_abs):
        return  # other repo without a leadv2 tree — silent no-op

    tasks_yaml = os.path.join(root, "docs", "tasks.yaml")
    open_tasks = parse_tasks_yaml(tasks_yaml) if os.path.isfile(tasks_yaml) else []

    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    header = [f"# compact-freeze @ {ts}", f"open_task_count: {len(open_tasks)}"]

    # Cap the dumped task list to the top-N by priority (P0<P1<P2<P3<unranked).
    # The FULL backlog always stays in docs/tasks.yaml; this only bounds the
    # per-compact context injection (LEADV2_FREEZE_TASK_CAP overrides; default 40).
    task_dump_cap = int(os.environ.get("LEADV2_FREEZE_TASK_CAP", "10"))
    def _prank(pr):
        m = re.match(r"[Pp](\d)", pr or "")
        return int(m.group(1)) if m else 9
    ranked = sorted(enumerate(open_tasks), key=lambda x: (_prank(x[1][3]), x[0]))
    shown = [t for _, t in ranked[:task_dump_cap]]
    hidden = len(open_tasks) - len(shown)
    task_lines = [
        f"## OPEN TASK IDS (docs/tasks.yaml \u2014 top {task_dump_cap} by priority; full list in file)"
    ]
    for tid, status, intent, priority in shown:
        snippet = re.sub(r"\s+", " ", intent).strip()[:70]
        pfx = (priority + " ") if priority else ""
        task_lines.append(f"- {tid} [{status}] {pfx}{snippet}")
    if not open_tasks:
        task_lines.append("(none found / docs/tasks.yaml missing or empty)")
    elif hidden > 0:
        task_lines.append(
            f"- \u2026 +{hidden} more open tasks hidden (P0->P3->unranked sort; see docs/tasks.yaml)"
        )

    ot_lines = read_file(os.path.join(leadv2_abs, "open-threads.md"))
    ot_section = []
    if ot_lines:
        threads_tail_n = int(os.environ.get("LEADV2_FREEZE_THREADS_TAIL", "40"))
        role_lines, tail_lines, dropped = role_and_tail(ot_lines, tail_n=threads_tail_n)
        ot_section = [
            "## OPEN THREADS \u2014 role block + freshest tail (docs/leadv2/open-threads.md; capped, not verbatim)"
        ]
        ot_section += role_lines
        if dropped:
            ot_section.append(
                f"\u2026 {dropped} stale middle lines dropped (full history in docs/leadv2/open-threads.md) \u2026"
            )
        ot_section += tail_lines

    sd_rows = due_rows(os.path.join(leadv2_abs, "scheduled-decisions.md"))
    sd_section = ["## SCHEDULED DECISIONS — DUE/OVERDUE"] + sd_rows if sd_rows else []

    journal_task_id, journal_lines_full = latest_journal_tail(root, leadv2_dir)

    fixed_lines = header + task_lines + ot_section + sd_section
    # NEVER cut fixed_lines (task-id list is the one inviolable section).
    # Overflow is absorbed entirely by shrinking (or dropping) the journal tail.
    budget = CAP - len(fixed_lines) - 1  # -1 reserves the journal heading line
    journal_section = []
    if journal_lines_full and budget > 0:
        take = min(budget, len(journal_lines_full))
        journal_section = [f"## ACTIVE JOURNAL TAIL ({journal_task_id})"] + journal_lines_full[-take:]

    out_text = "\n".join(fixed_lines + journal_section) + "\n"

    try:
        with open(os.path.join(leadv2_abs, ".compact-freeze.md"), "w", encoding="utf-8") as f:
            f.write(out_text)
    except Exception:
        pass  # write is best-effort; stdout below still carries the freeze

    print(out_text, end="")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
PYEOF
)" || exit 0

[[ -n "$OUT" ]] && printf -- '%s\n' "$OUT"
exit 0
