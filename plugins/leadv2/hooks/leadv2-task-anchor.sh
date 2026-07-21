#!/usr/bin/env bash
# leadv2-task-anchor.sh — UserPromptSubmit hook (LEAD-ANCHOR-01).
#
# Problem this fixes: nothing re-anchored the lead on the ACTIVE /leadv2 task
# when a new founder message arrived — the newest message silently won, the
# task was abandoned mid-flight, and the lead narrated instead of continuing
# the plan. Spec: docs/handoff/LEAD-ANCHOR-01/mission.md (persona-engine repo).
#
# Detection:
#   1. docs/leadv2/active.yaml has a live (non-stale) session whose worktree
#      matches this invocation's cwd, OR
#   2. a STATE.md (docs/leadv2/tasks/<id>/STATE.md — canonical per
#      leadv2-phase8-assert.sh; docs/handoff/<id>/STATE.md checked too for
#      forward-compat) modified in the last 12h with no sibling
#      docs/handoff/<id>/phase8-passed.flag (the real close sentinel path,
#      per leadv2-phase8-assert.sh).
#   No active task -> THREAD anchor fallback (round 2, LEAD-ANCHOR-01 r2):
#   if docs/leadv2/open-threads.md and/or scheduled-decisions.md exist, print
#   a reworded <task-anchor> block instead of staying silent. Only truly
#   empty state (neither file present) emits nothing.
#
# Output: a <task-anchor> block, hard-capped at 40 lines, ending with the
# fixed DIRECTIVE text verbatim (task mode) or the reworded THREAD DIRECTIVE
# (thread-fallback mode).
#
# Round 2 also adds auto-capture: any incoming prompt that looks like a new
# ask (>=20 chars, not a bare answer) is appended, deduped, to
# docs/leadv2/open-threads.md under "## Captured asks (auto)" (cap 40
# entries). Capture is best-effort and NEVER affects hook exit/stdout.
#
# Fail-open: ANY error -> exit 0 with empty stdout. Never blocks a prompt.
# stdlib-only (bash + python3, +PyYAML if present — degrades gracefully
# without it), zero network. Target <300ms.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/leadv2-temp.sh"
trap 'exit 0' ERR

# ── capture the hook's real stdin (JSON payload) before any heredoc can ─────
# consume it (heredocs piped into `python3 -` would otherwise steal stdin).
TMPFILE="$(lv2_mktemp_file "leadv2-task-anchor" "json")" || exit 0
trap 'rm -f "${TMPFILE:-}"' EXIT
trap 'rm -f "${TMPFILE:-}"; exit 0' ERR
python3 -c "import sys; open('$TMPFILE','w').write(sys.stdin.read())" 2>/dev/null || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -x "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-state-path.sh" ]]; then
    STATE_RESOLVER="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-state-path.sh"
else
    STATE_RESOLVER="${HOOK_DIR}/../scripts/leadv2-state-path.sh"
fi

OUT="$(python3 - "$TMPFILE" "$STATE_RESOLVER" <<'PYEOF' 2>/dev/null
import sys, os, json, subprocess, glob, time, re

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

def resolve_dir(root, key, default):
    sp = os.path.join(root, ".claude", "leadv2-overrides", "state-paths.yaml")
    try:
        with open(sp, encoding="utf-8") as f:
            for line in f:
                m = re.match(rf"^\s*{re.escape(key)}\s*:\s*(.+?)\s*$", line)
                if m:
                    val = m.group(1).strip().strip("'\"")
                    if val and val not in ("null", "~"):
                        return val
    except Exception:
        pass
    return default

def load_yaml(path):
    try:
        import yaml
    except ImportError:
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}

def first_heading(path):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.lstrip().startswith("#"):
                    return line.lstrip("# ").strip()
    except Exception:
        pass
    return ""

def grep_phase(path):
    try:
        with open(path, encoding="utf-8") as f:
            txt = f.read()
        m = re.search(r"(?im)^\s*phase\s*[:=]\s*(\S+)", txt)
        if m:
            return m.group(1).strip()
    except Exception:
        pass
    return ""


def process_ancestors():
    """Return this hook's live OS process ancestry, nearest parent first."""
    out = []
    seen = set()
    pid = os.getppid()
    while pid > 1 and pid not in seen:
        seen.add(pid)
        out.append(pid)
        try:
            raw = subprocess.run(
                ["ps", "-o", "ppid=", "-p", str(pid)],
                capture_output=True, text=True, timeout=1,
            ).stdout.strip()
            nxt = int(raw) if raw else 0
        except Exception:
            break
        if nxt <= 1 or nxt == pid:
            break
        pid = nxt
    return out


def control_plane_path(root, resolver, name):
    if os.environ.get("LEADV2_STATE_ROOT"):
        return os.path.join(os.environ["LEADV2_STATE_ROOT"], name)
    if not resolver or not os.path.isfile(resolver):
        return ""
    try:
        result = subprocess.run(
            [resolver, "--no-link", name],
            cwd=root,
            env={**os.environ, "PROJECT_ROOT": root},
            capture_output=True, text=True, timeout=2,
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except Exception:
        return ""


def live_supervisor_owned_by_this_process(root, resolver, ancestors):
    path = control_plane_path(root, resolver, ".supervise-active")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh) or {}
        pid = int(data.get("pid"))
        os.kill(pid, 0)
        return pid in ancestors
    except Exception:
        return False


# ── LEAD-ANCHOR-01 round 2: Hole 1 — THREAD anchor fallback ────────────────

def read_last_nonblank_lines(path, n):
    try:
        with open(path, encoding="utf-8") as f:
            lines = [l.rstrip("\n") for l in f if l.strip()]
        return lines[-n:]
    except Exception:
        return []


def count_due_rows(path):
    try:
        with open(path, encoding="utf-8") as f:
            txt = f.read()
        return len(re.findall(r"\b(?:DUE|OVERDUE)\b", txt, re.IGNORECASE))
    except Exception:
        return 0


def build_thread_anchor(root, leadv2_dir):
    ot_path = os.path.join(root, leadv2_dir, "open-threads.md")
    sd_path = os.path.join(root, leadv2_dir, "scheduled-decisions.md")
    has_ot = os.path.exists(ot_path)
    has_sd = os.path.exists(sd_path)
    if not has_ot and not has_sd:
        return None  # truly empty state — no thread anchor

    THREAD_DIRECTIVE = (
        "DIRECTIVE — you are mid-thread, not mid-task.\n"
        "1. This message does not erase the threads above. If it is a question, answer it in\n"
        "   <=3 lines and return to the open thread. If it opens new work, it goes to\n"
        "   docs/leadv2/open-threads.md first.\n"
        "2. Only an explicit stop/scope-change order pauses a thread. \"Also do X\" = queue X in\n"
        "   docs/leadv2/open-threads.md, do NOT switch to it.\n"
        "3. PULSE MODE: no narration. Chat output is allowed ONLY at: Gate-1, an async question,\n"
        "   Phase-8 close. Everything else is silent tool work.\n"
        "4. Anything promised for later goes to docs/leadv2/scheduled-decisions.md the same turn."
    )

    header = ["<task-anchor>", "NO ACTIVE TASK — thread anchor (docs/leadv2/open-threads.md)"]
    content = []
    if has_ot:
        tail = read_last_nonblank_lines(ot_path, 8)
        if tail:
            content.append("open threads (last 8 lines):")
            content.extend(tail)
    if has_sd:
        content.append(f"scheduled-decisions: {count_due_rows(sd_path)} DUE/OVERDUE row(s)")
    footer = [""] + THREAD_DIRECTIVE.splitlines() + ["</task-anchor>"]

    budget = 40 - len(header) - len(footer)
    if budget < 0:
        content = []
    elif len(content) > budget:
        content = content[:budget]

    return "\n".join(header + content + footer)


# ── LEAD-ANCHOR-01 round 2: Hole 2 — auto-capture new founder asks ─────────

_ANSWER_WORDS = {"да", "нет", "ок", "окей", "yes", "no", "approve", "approved", "ok"}
_ENTRY_RE = re.compile(r"^- \[ \] (\S+) — (.*)$")

# LEAD-ANCHOR-01 round 3: harness/system events must never be captured as
# founder asks — these are machine-emitted, not prose typed by a human.
_REJECT_SUBSTRINGS = (
    "<task-notification>",
    "<system-reminder>",
    "<command-",
    "<local-command",
    "<task-anchor>",
    "[system notification",
    "caveat:",
    "[request interrupted",
    "<tool-use-id>",
    "<output-file>",
)
_COMPACT_PREAMBLE = "this session is being continued"
_MAX_PROMPT_LEN = 2000
_TAG_RE = re.compile(r"<[a-zA-Z]")


def looks_like_new_ask(prompt):
    p = (prompt or "").strip()
    if len(p) < 20:
        return False
    if len(p) > _MAX_PROMPT_LEN:
        return False  # a paste/dump, not a founder ask
    # Allowlist mindset: real founder asks are prose. Anything opening with a
    # tag/bracket character is a harness/system event, not typed by a human.
    if p[:1] in ("<", "["):
        return False
    lower_full = p.lower()
    if lower_full.startswith(_COMPACT_PREAMBLE):
        return False
    for needle in _REJECT_SUBSTRINGS:
        if needle in lower_full:
            return False
    lower = re.sub(r"[\s.!?]+$", "", lower_full)
    if lower in _ANSWER_WORDS:
        return False
    if re.fullmatch(r"(вариант|variant|option)\s*\d+", lower):
        return False
    if re.fullmatch(r"\d+", lower):
        return False
    return True


def capture_ask(root, leadv2_dir, prompt):
    if not looks_like_new_ask(prompt):
        return
    leadv2_path = os.path.join(root, leadv2_dir)
    if not os.path.isdir(leadv2_path):
        return  # no docs/leadv2/ in this repo — skip capture entirely

    ot_path = os.path.join(leadv2_path, "open-threads.md")
    single_line = " ".join(prompt.split())[:140]
    if _TAG_RE.search(single_line):
        return  # belt-and-braces: never persist an angle-bracket tag fragment
    dedupe_key = single_line[:60]

    lockf = None
    try:
        import fcntl
        lockf = open(ot_path + ".capture.lock", "a+")
        fcntl.flock(lockf, fcntl.LOCK_EX)
    except Exception:
        lockf = None

    try:
        existing = ""
        if os.path.exists(ot_path):
            with open(ot_path, encoding="utf-8") as f:
                existing = f.read()

        for line in existing.splitlines():
            m = _ENTRY_RE.match(line)
            if m and m.group(2)[:60] == dedupe_key:
                return  # already captured — dedupe

        heading = "## Captured asks (auto)"
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        new_entry = f"- [ ] {ts} — {single_line}"

        lines = existing.splitlines()
        if heading in lines:
            h_idx = lines.index(heading)
            j = h_idx + 1
            entries = []
            while j < len(lines) and _ENTRY_RE.match(lines[j]):
                entries.append(lines[j])
                j += 1
            entries.append(new_entry)
            entries = entries[-40:]  # cap at 40 entries, drop oldest
            new_lines = lines[: h_idx + 1] + entries + lines[j:]
            new_content = "\n".join(new_lines) + "\n"
        else:
            sep = "\n" if existing and not existing.endswith("\n") else ""
            new_content = existing + sep + ("\n" if existing else "") + heading + "\n" + new_entry + "\n"

        tmp_path = f"{ot_path}.tmp.{os.getpid()}"
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write(new_content)
        os.replace(tmp_path, ot_path)  # atomic-ish rename, never a partial write
    finally:
        if lockf is not None:
            try:
                import fcntl
                fcntl.flock(lockf, fcntl.LOCK_UN)
            except Exception:
                pass
            try:
                lockf.close()
            except Exception:
                pass


def safe_capture(root, leadv2_dir, payload):
    # Capture must NEVER affect hook exit status or stdout — swallow everything.
    try:
        capture_ask(root, leadv2_dir, payload.get("prompt") or payload.get("message") or "")
    except Exception:
        pass


def main():
    tmpfile = sys.argv[1]
    state_resolver = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        with open(tmpfile, encoding="utf-8") as f:
            payload = json.load(f)
    except Exception:
        payload = {}

    cwd = payload.get("cwd") or os.getcwd()
    try:
        cwd = os.path.realpath(cwd)
    except Exception:
        pass

    root = git_toplevel(cwd)

    leadv2_dir = resolve_dir(root, "leadv2_dir", "docs/leadv2")
    handoff_dir = resolve_dir(root, "handoff_dir", "docs/handoff")
    ancestors = process_ancestors()

    # SUPERVISOR/LEAD MODE ISOLATION: the supervising session shares the
    # registry and main checkout with its children, but it owns no task and
    # must never inherit a child's anchor. Scope by the live sentinel's owner
    # PID, not by repo/worktree. A child/ordinary lead has a different process
    # tree and therefore continues into normal task resolution below.
    if live_supervisor_owned_by_this_process(root, state_resolver, ancestors):
        session_id = re.sub(r"[^A-Za-z0-9._-]", "", str(payload.get("session_id") or ""))
        if session_id:
            try:
                marker = f"/tmp/.leadv2-supervisor-mode-{session_id}"
                with open(marker, "a", encoding="utf-8"):
                    pass
            except Exception:
                pass
        print("\n".join([
            "<supervisor-anchor>",
            "ACTIVE MODE: SUPERVISOR — no task/worktree/phase is owned by this session.",
            "Observe shared receipts/questions and dispatch only independent full Phase 0..8 lead sessions; never adopt a child task as your own.",
            "</supervisor-anchor>",
        ]))
        return

    task_id = None
    phase = "?"
    cls = "?"

    # ── 1) active.yaml: live session matching this worktree ─────────────────
    active_yaml = os.path.join(root, leadv2_dir, "active.yaml")
    data = load_yaml(active_yaml)
    sessions = [
        s for s in (data.get("sessions") or [])
        if isinstance(s, dict) and not s.get("stale")
    ]
    candidates = []
    owned_candidates = []
    for s in sessions:
        try:
            session_pid = int(s.get("pid"))
        except (TypeError, ValueError):
            session_pid = None
        if session_pid is not None and session_pid in ancestors:
            owned_candidates.append(s)
        elif session_pid is not None:
            # A valid PID belonging to a different live process tree is a
            # different lead session even when both rows temporarily point at
            # the main checkout. Never select it by worktree fallback.
            try:
                os.kill(session_pid, 0)
                continue
            except (ProcessLookupError, PermissionError):
                continue
        wt = s.get("worktree") or ""
        try:
            wt_real = os.path.realpath(wt) if wt else ""
        except Exception:
            wt_real = wt
        if wt_real and (wt_real == cwd or wt_real == root):
            candidates.append(s)
    selected = owned_candidates or candidates
    if selected:
        selected.sort(key=lambda s: str(s.get("started_at") or ""), reverse=True)
        best = selected[0]
        task_id = best.get("task_id")
        phase = str(best.get("phase") or "?")
        cls = str(best.get("class") or "?")

    # ── 2) fallback: recent STATE.md with no phase8-passed.flag sibling ─────
    if not task_id:
        now = time.time()
        found = []
        for pattern in (
            os.path.join(root, leadv2_dir, "tasks", "*", "STATE.md"),
            os.path.join(root, handoff_dir, "*", "STATE.md"),
        ):
            for path in glob.glob(pattern):
                try:
                    mtime = os.path.getmtime(path)
                except Exception:
                    continue
                if now - mtime > 12 * 3600:
                    continue
                tid = os.path.basename(os.path.dirname(path))
                flag = os.path.join(root, handoff_dir, tid, "phase8-passed.flag")
                if os.path.exists(flag):
                    continue
                found.append((mtime, tid, path))
        if found:
            found.sort(reverse=True)
            _, task_id, _ = found[0]

    if not task_id:
        safe_capture(root, leadv2_dir, payload)
        thread_out = build_thread_anchor(root, leadv2_dir)
        if thread_out:
            print(thread_out)
        return  # no active leadv2 task — THREAD anchor (if any) already printed

    # TOKEN-EFFICIENCY: the full anchor (goal, plan, journal, other sessions,
    # 10-line directive) used to be re-injected on every founder message and
    # then remain in the conversation forever. Emit it once per session+task;
    # subsequent prompts get only the live task/phase and the scope rule.
    # /compact starts a new prompt context but keeps the same session id, so
    # post-compact regrounding remains owned by the dedicated compact hooks.
    session_id = re.sub(r"[^A-Za-z0-9._-]", "", str(payload.get("session_id") or ""))
    anchor_marker = ""
    if session_id and os.environ.get("LEADV2_TASK_ANCHOR_COMPACT_REPEAT", "1") != "0":
        safe_task = re.sub(r"[^A-Za-z0-9._-]", "", str(task_id))
        anchor_marker = f"/tmp/.leadv2-task-anchor-full-{session_id}-{safe_task}"
        if os.path.isfile(anchor_marker):
            safe_capture(root, leadv2_dir, payload)
            print("\n".join([
                "<task-anchor>",
                f"ACTIVE TASK: {task_id} | phase: {phase} | class: {cls}",
                "This message does not replace it: answer a question in <=3 lines, then continue. Only explicit stop/scope-change pauses it.",
                "</task-anchor>",
            ]))
            return

    # ── gather details ───────────────────────────────────────────────────────
    context_path = os.path.join(root, handoff_dir, task_id, "context.yaml")
    ctx = load_yaml(context_path)

    goal = str(ctx.get("goal") or ctx.get("mission") or "").strip()
    if goal:
        goal = goal.splitlines()[0].strip()

    state_candidates = (
        os.path.join(root, leadv2_dir, "tasks", task_id, "STATE.md"),
        os.path.join(root, handoff_dir, task_id, "STATE.md"),
    )

    if not goal:
        for sp in state_candidates:
            goal = first_heading(sp)
            if goal:
                break

    if phase == "?":
        for sp in state_candidates:
            p = grep_phase(sp)
            if p:
                phase = p
                break

    if cls == "?":
        cls = str(ctx.get("class") or ctx.get("task_class") or "?")

    plan_lines = []
    steps = ((ctx.get("plan") or {}).get("steps") or [])
    if isinstance(steps, list):
        for st in steps[:6]:
            if not isinstance(st, dict):
                continue
            sid = st.get("id", "?")
            text = str(st.get("mission") or st.get("step") or "").strip()
            text = text.splitlines()[0] if text else ""
            if len(text) > 80:
                text = text[:77] + "..."
            status = str(st.get("status") or "").lower()
            mark = "✓" if status in ("done", "complete", "completed") else "·"
            plan_lines.append(f"{mark} {sid}. {text}")

    # ── LEAD-BUS-01: other live sessions from docs/leadv2/bus.jsonl ─────────
    # Cap 8 lines. Best-effort: any error here must never affect the anchor.
    other_sessions_lines = []
    try:
        bus_path = os.path.join(root, leadv2_dir, "bus.jsonl")
        if os.path.isfile(bus_path):
            with open(bus_path, encoding="utf-8") as bf:
                bus_lines = [l for l in bf.read().splitlines() if l.strip()]
            latest = {}  # other task_id -> (phase, files, last_type)
            for l in bus_lines:
                try:
                    ev = json.loads(l)
                except Exception:
                    continue
                tid = ev.get("task_id")
                if not tid or tid == task_id:
                    continue
                info = latest.setdefault(tid, {"phase": "?", "files": [], "type": ""})
                info["type"] = ev.get("type") or info["type"]
                if ev.get("type") == "phase":
                    info["phase"] = str((ev.get("payload") or {}).get("phase") or info["phase"])
                if ev.get("type") == "files":
                    fp = (ev.get("payload") or {}).get("files")
                    if isinstance(fp, list):
                        info["files"] = [str(x) for x in fp]
            my_files = set(latest.get(task_id, {}).get("files", []))
            for l in bus_lines:
                try:
                    ev = json.loads(l)
                except Exception:
                    continue
                if ev.get("task_id") == task_id and ev.get("type") == "files":
                    fp = (ev.get("payload") or {}).get("files")
                    if isinstance(fp, list):
                        my_files = set(str(x) for x in fp)
            live = {t: v for t, v in latest.items() if v["type"] not in ("closed", "merged")}
            if live:
                other_sessions_lines.append(f"OTHER LIVE SESSIONS ({len(live)}):")
                for tid, info in list(live.items())[:7]:
                    files_str = ", ".join(info["files"][:4]) if info["files"] else "?"
                    shared = my_files & set(info["files"])
                    if shared:
                        other_sessions_lines.append(
                            f"  {tid} | phase {info['phase']} | ⚠ CONFLICT with your files: {', '.join(sorted(shared))}"
                        )
                    else:
                        other_sessions_lines.append(f"  {tid} | phase {info['phase']} | files: {files_str}")
    except Exception:
        other_sessions_lines = []
    other_sessions_lines = other_sessions_lines[:8]

    # ── journal tail: discover leadv2-journal.sh, don't hardcode a path ──────
    journal_lines = []
    for cand in (
        os.path.join(root, ".claude", "scripts", "leadv2-journal.sh"),
        os.path.expanduser("~/.claude/leadv2-shared/scripts/leadv2-journal.sh"),
        os.path.expanduser("~/.claude/scripts/leadv2-journal.sh"),
    ):
        if os.path.isfile(cand):
            try:
                r = subprocess.run(
                    ["bash", cand, "tail", task_id, "4"],
                    capture_output=True, text=True, timeout=2, cwd=root,
                )
                if r.returncode == 0 and r.stdout.strip():
                    journal_lines = [l for l in r.stdout.splitlines() if l.strip()][-4:]
            except Exception:
                journal_lines = []
            break

    DIRECTIVE = (
        "DIRECTIVE — this founder message does NOT replace the active task.\n"
        "1. Route it: Skill(leadv2-founder-question-router). Answer inline in <=3 lines if it is a\n"
        "   question/nuance; then CONTINUE the task from the phase above.\n"
        "2. Only an explicit stop/scope-change order pauses the task. \"Also do X\" = queue X in\n"
        "   docs/leadv2/open-threads.md, do NOT switch to it.\n"
        "3. PULSE MODE: no narration. Chat output is allowed ONLY at: Gate-1, an async question,\n"
        "   Phase-8 close. Everything else is silent tool work.\n"
        "4. Anything promised for later goes to docs/leadv2/scheduled-decisions.md the same turn."
    )

    header = [
        "<task-anchor>",
        f"ACTIVE TASK: {task_id} | phase: {phase} | class: {cls}",
    ]
    content = []
    if goal:
        content.append(f"goal: {goal}")
    if plan_lines:
        content.append("plan:")
        content.extend(plan_lines)
    if journal_lines:
        content.append("journal (last 4):")
        content.extend(journal_lines)
    if other_sessions_lines:
        content.extend(other_sessions_lines)
    footer = [""] + DIRECTIVE.splitlines() + ["</task-anchor>"]

    budget = 40 - len(header) - len(footer)
    if budget < 0:
        content = []
    elif len(content) > budget:
        content = content[:budget]

    print("\n".join(header + content + footer))
    if anchor_marker:
        try:
            with open(anchor_marker, "x", encoding="utf-8") as fh:
                fh.write(f"{task_id}\n")
        except FileExistsError:
            pass
        except Exception:
            pass
    safe_capture(root, leadv2_dir, payload)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
PYEOF
)" || exit 0

[[ -n "$OUT" ]] && printf -- '%s\n' "$OUT"
exit 0
