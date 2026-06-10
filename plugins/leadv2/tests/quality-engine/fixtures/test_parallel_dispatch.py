"""
test_parallel_dispatch.py — C1.6 pytest fixtures for G1-parallel-dispatch.

Covers:
  (a) dep-blocked task skipped in fill loop (deps_done returns False for non-terminal dep)
  (b) hard-limit N=2 free slots respected when 3 candidates exist
  (c) footprint overlap between two tasks -> collision exit 2, not silent pick
  (d) dep_id not found -> task not claimed (dep_missing guard, D10)

Decisions exercised: D2, D3, D4, D10, D11, D14, D19.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def _tasks_yaml(items: list[dict[str, Any]]) -> str:
    return yaml.dump(items, default_flow_style=False, allow_unicode=True, sort_keys=False)


def _make_task(
    tid: str,
    status: str = "pending",
    lane: str = "action",
    priority: str = "medium",
    files_hint: list[str] | None = None,
    depends_on: list[str] | None = None,
    conflicts_with: list[str] | None = None,
    claim_by: str | None = None,
) -> dict[str, Any]:
    return {
        "id": tid,
        "lane": lane,
        "priority": priority,
        "status": status,
        "title": f"Task {tid}",
        "created_at": "2026-06-10T00:00:00Z",
        "closed_at": None,
        "origin": None,
        "claim": {"by": claim_by, "lease_expires": None},
        "attempts": 0,
        "max_attempts": 3,
        "last_error": None,
        "reject_reason": None,
        "summary_one_line": None,
        "context": {
            "files": [],
            "files_hint": files_hint or [],
            "depends_on": depends_on or [],
            "conflicts_with": conflicts_with or [],
            "note": None,
        },
        "notes": None,
    }


# Literal strings for heredoc boundary extraction (avoids in-source f-string tricks)
_TASKS_DISPATCH_MARKER_START = "python3 - \"$_TASKS_FILE\" \"$_TASKS_LOCK\" \"$@\" <<'DISPATCHER'\n"
_TASKS_DISPATCH_MARKER_END = "\nDISPATCHER\n"


def _dispatch_op(
    tasks_file: Path, lock_path: Path, op: str, *args: str
) -> "subprocess.CompletedProcess[str]":
    """Extract and run the _tasks_dispatch Python block from leadv2-tasks-lib.sh."""
    lib_src = Path(__file__).parents[3] / "scripts" / "leadv2-tasks-lib.sh"
    assert lib_src.exists(), f"tasks-lib not found at {lib_src}"

    raw = lib_src.read_text()
    start = raw.index(_TASKS_DISPATCH_MARKER_START) + len(_TASKS_DISPATCH_MARKER_START)
    end = raw.index(_TASKS_DISPATCH_MARKER_END, start)
    py_src = raw[start:end]

    cmd = [sys.executable, "-c", py_src, str(tasks_file), str(lock_path), op, *args]
    return subprocess.run(cmd, capture_output=True, text=True)


# ---------------------------------------------------------------------------
# (a) Dep-blocked task skipped
# ---------------------------------------------------------------------------

class TestDepBlocked:
    """C1.6(a): tasks with non-terminal depends_on are excluded from top_n."""

    def test_dep_pending_blocks_claim(self, tmp_path: Path) -> None:
        blocker = _make_task("DEP-001", status="pending")
        blocked = _make_task("TASK-002", status="pending", depends_on=["DEP-001"])
        tf = tmp_path / "tasks.yaml"
        tf.write_text(_tasks_yaml([blocker, blocked]))
        r = _dispatch_op(tf, tmp_path / "tasks.lock", "top_n", "5")
        assert r.returncode == 0
        ids = [ln.split("\t")[2] for ln in r.stdout.splitlines() if "\t" in ln]
        assert "DEP-001" in ids
        assert "TASK-002" not in ids

    def test_dep_in_progress_blocks_claim(self, tmp_path: Path) -> None:
        blocker = _make_task("DEP-010", status="in_progress", claim_by="s-session")
        blocked = _make_task("TASK-011", status="pending", depends_on=["DEP-010"])
        tf = tmp_path / "tasks.yaml"
        tf.write_text(_tasks_yaml([blocker, blocked]))
        r = _dispatch_op(tf, tmp_path / "tasks.lock", "top_n", "5")
        assert r.returncode == 0
        ids = [ln.split("\t")[2] for ln in r.stdout.splitlines() if "\t" in ln]
        assert "TASK-011" not in ids

    def test_dep_done_unblocks_task(self, tmp_path: Path) -> None:
        done_dep = _make_task("DEP-020", status="done")
        unblocked = _make_task("TASK-021", status="pending", depends_on=["DEP-020"])
        tf = tmp_path / "tasks.yaml"
        tf.write_text(_tasks_yaml([done_dep, unblocked]))
        r = _dispatch_op(tf, tmp_path / "tasks.lock", "top_n", "5")
        assert r.returncode == 0
        ids = [ln.split("\t")[2] for ln in r.stdout.splitlines() if "\t" in ln]
        assert "TASK-021" in ids


# ---------------------------------------------------------------------------
# (b) Hard-limit N=2 respected when 3 candidates
# ---------------------------------------------------------------------------

class TestHardLimit:
    """C1.6(b): top_n=2 returns exactly 2 results when 3 candidates exist (D3)."""

    def test_hard_limit_two_of_three(self, tmp_path: Path) -> None:
        tasks = [
            _make_task("T-001", priority="high"),
            _make_task("T-002", priority="medium"),
            _make_task("T-003", priority="low"),
        ]
        tf = tmp_path / "tasks.yaml"
        tf.write_text(_tasks_yaml(tasks))
        r = _dispatch_op(tf, tmp_path / "tasks.lock", "top_n", "2")
        assert r.returncode == 0
        lines = [ln for ln in r.stdout.splitlines() if "\t" in ln]
        assert len(lines) == 2, f"N=2 must yield exactly 2; got {len(lines)}"
        assert lines[0].split("\t")[2] == "T-001", "highest priority must be first"

    def test_three_of_three_returned(self, tmp_path: Path) -> None:
        tasks = [_make_task(f"T-{i:03d}") for i in range(3)]
        tf = tmp_path / "tasks.yaml"
        tf.write_text(_tasks_yaml(tasks))
        r = _dispatch_op(tf, tmp_path / "tasks.lock", "top_n", "3")
        assert r.returncode == 0
        lines = [ln for ln in r.stdout.splitlines() if "\t" in ln]
        assert len(lines) == 3


# ---------------------------------------------------------------------------
# (c) Footprint collision detected
# ---------------------------------------------------------------------------

class TestFootprintCollision:
    """C1.6(c): collision-check --compare-tasks exits 2 on files_hint overlap (D4/D14)."""

    _SCRIPT: Path = Path(__file__).parents[3] / "scripts" / "leadv2-collision-check.sh"

    def _compare(
        self, tmp_path: Path, hints_a: list[str], hints_b: list[str]
    ) -> "subprocess.CompletedProcess[str]":
        docs = tmp_path / "docs"
        docs.mkdir(exist_ok=True)
        (docs / "tasks.yaml").write_text(
            _tasks_yaml([_make_task("CA-001", files_hint=hints_a), _make_task("CA-002", files_hint=hints_b)])
        )
        env = {"LEADV2_PROJECT_ROOT": str(tmp_path), "PATH": "/usr/bin:/bin:/usr/local/bin"}
        return subprocess.run(
            ["bash", str(self._SCRIPT), "--compare-tasks", "CA-001", "CA-002"],
            capture_output=True, text=True, env=env, cwd=str(tmp_path),
        )

    def test_overlapping_hints_exit_2(self, tmp_path: Path) -> None:
        r = self._compare(
            tmp_path,
            hints_a=["plugins/leadv2/scripts/*.sh"],
            hints_b=["plugins/leadv2/scripts/leadv2-tasks-lib.sh"],
        )
        assert r.returncode == 2, f"expected exit 2; got {r.returncode} stdout={r.stdout!r}"
        assert "COLLISION" in r.stdout

    def test_non_overlapping_exit_0(self, tmp_path: Path) -> None:
        r = self._compare(
            tmp_path,
            hints_a=["plugins/leadv2/scripts/*.sh"],
            hints_b=["docs/specs/*.md"],
        )
        assert r.returncode == 0, f"expected exit 0; got {r.returncode}"

    def test_absent_files_hint_exit_0_with_warn(self, tmp_path: Path) -> None:
        r = self._compare(tmp_path, hints_a=[], hints_b=["docs/**/*.md"])
        assert r.returncode == 0, "absent files_hint must pass-through (exit 0)"
        assert "WARN" in r.stderr and "files_hint absent" in r.stderr, (
            f"expected WARN: files_hint absent; stderr={r.stderr!r}"
        )

    def test_both_absent_exit_0_with_warn(self, tmp_path: Path) -> None:
        r = self._compare(tmp_path, hints_a=[], hints_b=[])
        assert r.returncode == 0
        assert "WARN" in r.stderr


# ---------------------------------------------------------------------------
# (d) dep_missing guard: dep_id not found -> task blocked (D10)
# ---------------------------------------------------------------------------

class TestDepMissingGuard:
    """C1.6(d): dep not in tasks.yaml => dep_missing; claim blocked (D10)."""

    def test_phantom_dep_blocks_task(self, tmp_path: Path) -> None:
        task = _make_task("TASK-100", status="pending", depends_on=["PHANTOM-999"])
        tf = tmp_path / "tasks.yaml"
        tf.write_text(_tasks_yaml([task]))
        r = _dispatch_op(tf, tmp_path / "tasks.lock", "top_n", "5")
        assert r.returncode == 0
        ids = [ln.split("\t")[2] for ln in r.stdout.splitlines() if "\t" in ln]
        assert "TASK-100" not in ids, "task with phantom dep must be blocked (D10)"

    def test_dep_missing_surfaced_in_output(self, tmp_path: Path) -> None:
        task = _make_task("TASK-101", status="pending", depends_on=["PHANTOM-998"])
        tf = tmp_path / "tasks.yaml"
        tf.write_text(_tasks_yaml([task]))
        r = _dispatch_op(tf, tmp_path / "tasks.lock", "top_n", "5")
        assert r.returncode == 0
        combined = r.stderr + r.stdout
        assert "dep_missing" in combined, f"dep_missing must be logged; got: {combined!r}"
        assert "PHANTOM-998" in combined

    def test_phantom_dep_does_not_block_independent_task(self, tmp_path: Path) -> None:
        blocked = _make_task("TASK-110", status="pending", depends_on=["PHANTOM-997"])
        free = _make_task("TASK-111", status="pending")
        tf = tmp_path / "tasks.yaml"
        tf.write_text(_tasks_yaml([blocked, free]))
        r = _dispatch_op(tf, tmp_path / "tasks.lock", "top_n", "5")
        assert r.returncode == 0
        ids = [ln.split("\t")[2] for ln in r.stdout.splitlines() if "\t" in ln]
        assert "TASK-111" in ids
        assert "TASK-110" not in ids

    def test_unclaim_resets_to_pending(self, tmp_path: Path) -> None:
        """C1.4: unclaim sets status=pending and clears claim.by atomically."""
        task = _make_task("TASK-200", status="in_progress", claim_by="s-test-session")
        tf = tmp_path / "tasks.yaml"
        tf.write_text(_tasks_yaml([task]))
        r = _dispatch_op(tf, tmp_path / "tasks.lock", "unclaim", "TASK-200")
        assert r.returncode == 0, f"unclaim failed: {r.stderr}"
        items = yaml.safe_load(tf.read_text()) or []
        t = {str(it.get("id", "")): it for it in items}["TASK-200"]
        assert t["status"] == "pending"
        assert (t.get("claim") or {}).get("by") is None
