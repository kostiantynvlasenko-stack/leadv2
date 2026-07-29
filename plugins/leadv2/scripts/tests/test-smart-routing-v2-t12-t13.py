#!/usr/bin/env python3
"""Acceptance tests for router-v2 T12 arm lifecycle and T13 judge audit."""
from __future__ import annotations
import importlib.util, json, os, pathlib, subprocess, tempfile, unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
BANDIT = SCRIPTS / "leadv2-route-bandit.sh"
HELPER = SCRIPTS / "leadv2-route-bandit-py.py"
spec = importlib.util.spec_from_file_location("route_bandit_py", HELPER)
route_bandit_py = importlib.util.module_from_spec(spec); spec.loader.exec_module(route_bandit_py)

class LifecycleAndAuditTests(unittest.TestCase):
    def command(self, root, *args):
        return subprocess.run(["bash", str(BANDIT), *args], text=True, capture_output=True, check=True,
            env=os.environ | {"LEADV2_ROUTER_V2":"1", "LEADV2_PROJECT_ROOT":str(root)})
    def parsed(self, state):
        return json.loads(subprocess.check_output(["python3", str(HELPER), "parse_yaml", str(state)], text=True))

    def test_reset_decay_journal_and_eligible_exploration(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp); state=root/"state.yaml"
            state.write_text('version: 1\narms:\n  "build:long":\n    fresh:   {alpha: 3, beta: 1}\n    incumbent:   {alpha: 95, beta: 5}\ncooldowns:\nmeta:\n  total_updates: 0\n')
            before=self.parsed(state)["arms"]["build:long"]["incumbent"]
            self.assertIn("reset_result=ok", self.command(root,"reset-arm","--arm","incumbent","--mode","decay","--state-file",str(state),"--by","test").stdout)
            after=self.parsed(state)["arms"]["build:long"]["incumbent"]
            self.assertAlmostEqual(before["alpha"]/(before["alpha"]+before["beta"]), after["alpha"]/(after["alpha"]+after["beta"]), delta=.01)
            self.assertAlmostEqual(after["alpha"]+after["beta"], (before["alpha"]+before["beta"])/2, delta=.01)
            self.command(root,"reset-arm","--arm","fresh","--mode","reset","--state-file",str(state))
            self.assertEqual({"alpha":3.0,"beta":1.0}, self.parsed(state)["arms"]["build:long"]["fresh"])
            self.assertIn('"event": "arm_reset"', (root/"docs/leadv2/route-bandit-journal.jsonl").read_text())
            sampled_state=self.parsed(state)
            draws=[route_bandit_py.thompson_sample_v2("build:long", ["fresh","incumbent"], sampled_state)[0] for _ in range(1000)]
            self.assertGreaterEqual(draws.count("fresh"),50, "eligible under-sampled arm gets >=5% exploration")

    def test_judge_audit_lists_simple_miscalibration_and_empty_is_ok(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp); estimates=root/"estimates.jsonl"; outcomes=root/"outcomes.jsonl"
            estimates.write_text('{"estimate_id":"e1","complexity":"simple","estimate_source":"judge"}\n{"estimate_id":"e2","complexity":"simple","estimate_source":"fallback"}\n')
            outcomes.write_text('{"task_id":"one","estimate_id":"e1","estimate_source":"judge","fix_rounds":3}\n{"task_id":"two","estimate_id":"e2","estimate_source":"fallback","fix_rounds":4}\n')
            out=self.command(root,"judge-audit","--estimates-file",str(estimates),"--outcomes-file",str(outcomes)).stdout
            self.assertIn("complexity=simple count=2 fix_rounds>=3=2 rate=100.0%",out)
            self.assertIn("task_id=one",out); self.assertIn("task_id=two",out); self.assertIn("fallback_share=1/2=50.0%",out)
            empty=root/"empty.jsonl"; empty.write_text("")
            self.assertIn("no data",self.command(root,"judge-audit","--estimates-file",str(estimates),"--outcomes-file",str(empty)).stdout)

if __name__ == "__main__": unittest.main(verbosity=2)
