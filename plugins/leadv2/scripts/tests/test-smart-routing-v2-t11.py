#!/usr/bin/env python3
"""Acceptance tests for T11: v2 outcome-fed route-bandit updates."""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile
import unittest


SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
BANDIT = SCRIPTS / "leadv2-route-bandit.sh"


class OutcomeFedBanditTests(unittest.TestCase):
    def run_bandit(self, root: pathlib.Path, state: pathlib.Path, outcomes: pathlib.Path, task: str):
        env = os.environ | {
            "LEADV2_ROUTER_V2": "1",
            "LEADV2_PROJECT_ROOT": str(root),
        }
        return subprocess.run(
            ["bash", str(BANDIT), "update", "--task-id", task,
             "--state-file", str(state), "--outcomes-file", str(outcomes)],
            env=env, text=True, capture_output=True, check=True,
        )

    def test_outcomes_produce_exact_deltas_and_rerun_is_noop(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            state = root / "route-bandit-state.yaml"
            outcomes = root / "route-outcomes.jsonl"
            rows = [
                {"task_id": "t-success", "arm": "glm", "task_class": "build:long",
                 "committed": True, "review_verdict": "passed", "fix_rounds": 2},
                {"task_id": "t-blocked", "arm": "glm", "task_class": "build:long",
                 "committed": True, "review_verdict": "blocked", "fix_rounds": 0},
                {"task_id": "t-fixes", "arm": "codex", "task_class": "review:short",
                 "committed": True, "review_verdict": "passed", "fix_rounds": 3},
            ]
            outcomes.write_text("".join(json.dumps(row) + "\n" for row in rows))
            for row in rows:
                self.assertIn("update_result=ok", self.run_bandit(root, state, outcomes, row["task_id"]).stdout)
            before = state.read_text()
            self.assertIn("update_result=ok", self.run_bandit(root, state, outcomes, "t-success").stdout)
            self.assertEqual(before, state.read_text(), "applied_task_ids makes re-run a no-op")
            parsed = subprocess.check_output(["python3", str(SCRIPTS / "leadv2-route-bandit-py.py"), "parse_yaml", str(state)], text=True)
            arms = json.loads(parsed)["arms"]
            self.assertEqual({"alpha": 4, "beta": 2}, arms["build:long"]["glm"])
            self.assertEqual({"alpha": 3, "beta": 2}, arms["review:short"]["codex"])

    def test_unseen_v2_key_uses_optimistic_prior(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            state = root / "route-bandit-state.yaml"
            outcomes = root / "route-outcomes.jsonl"
            outcomes.write_text(json.dumps({"task_id": "unseen", "arm": "claude-haiku", "task_class": "docs:short", "committed": True, "review_verdict": "unknown", "fix_rounds": 0}) + "\n")
            self.run_bandit(root, state, outcomes, "unseen")
            parsed = subprocess.check_output(["python3", str(SCRIPTS / "leadv2-route-bandit-py.py"), "parse_yaml", str(state)], text=True)
            self.assertEqual({"alpha": 4, "beta": 1}, json.loads(parsed)["arms"]["docs:short"]["claude-haiku"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
