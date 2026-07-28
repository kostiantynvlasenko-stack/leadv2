#!/usr/bin/env python3
"""Acceptance tests for smart-routing-v2 T6 (ROUTER-QUOTA-DRIVEN-01).

Covers the mission's acceptance table verbatim:
  - Codex@0 credits + GLM@83% weekly + Anthropic healthy -> winner=sonnet (Anthropic)
  - an exhausted arm returns to rotation once its reset time passes, with NO
    file edited (quota input is faked, not the exclusion list)
  - the `unknown` quota-read case matches the fail-open policy
  - a dry-run prints the chosen arm + reason for >=4 contrasting quota states
"""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
ROUTER_PY_PATH = SCRIPTS / "leadv2-router-v2.py"
ROUTER_SH_PATH = SCRIPTS / "leadv2-router-v2.sh"

spec = importlib.util.spec_from_file_location("router_v2", ROUTER_PY_PATH)
router_v2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(router_v2)

CHAIN = ["glm", "codex", "sonnet"]


def glm_bucket(five_hour_pct=10.0, weekly_pct=10.0, status="ok"):
    if status != "ok":
        return {"provider": "glm", "status": "unknown", "usable_now": None, "binding_window": None}
    five_hour = {"pct": five_hour_pct, "usable_now": max(0.0, 100 - five_hour_pct) / 5.0}
    weekly = {"pct": weekly_pct, "usable_now": max(0.0, 100 - weekly_pct) / 168.0}
    binding = "five_hour" if five_hour["usable_now"] <= weekly["usable_now"] else "weekly"
    return {"provider": "glm", "status": "ok", "five_hour": five_hour, "weekly": weekly,
            "binding_window": binding}


def codex_bucket(used_percent=10.0, status="ok"):
    if status != "ok":
        return {"provider": "codex", "status": "unknown", "usable_now": None, "binding_window": None}
    remaining = max(0.0, 100 - used_percent)
    window = {"kind": "primary", "used_percent": used_percent, "usable_now": remaining / 10.0}
    return {"provider": "codex", "status": "ok", "windows": [window], "binding_window": "primary"}


def anthropic_bucket(five_hour_pct=6.0, weekly_pct=28.0, status="ok", active=True):
    if status != "ok":
        return {"provider": "anthropic", "status": "unknown", "usable_now": None, "binding_window": None}
    five_hour = {"pct": five_hour_pct, "usable_now": max(0.0, 100 - five_hour_pct) / 5.0}
    seven_day = {"pct": weekly_pct, "usable_now": max(0.0, 100 - weekly_pct) / 168.0}
    binding = "five_hour" if five_hour["usable_now"] <= seven_day["usable_now"] else "seven_day"
    account = {"account_label": "max_20x", "active": active, "status": "ok",
               "five_hour": five_hour, "seven_day": seven_day, "binding_window": binding}
    return {"provider": "anthropic", "status": "ok", "accounts": [account]}


class AcceptanceTableTests(unittest.TestCase):
    def test_codex_zero_glm_83pct_weekly_anthropic_healthy_picks_anthropic(self):
        quota = {"glm": glm_bucket(weekly_pct=83.0),
                 "codex": codex_bucket(used_percent=100.0),
                 "anthropic": anthropic_bucket()}
        result = router_v2.resolve(CHAIN, quota)
        self.assertEqual(result["winner"], "sonnet")
        filtered = {f["arm"]: f["reason"] for f in result["filtered"]}
        self.assertEqual(filtered["glm"], "quota_gate")
        self.assertEqual(filtered["codex"], "quota_exhausted")

    def test_all_healthy_keeps_existing_chain_order_glm_first(self):
        quota = {"glm": glm_bucket(), "codex": codex_bucket(), "anthropic": anthropic_bucket()}
        result = router_v2.resolve(CHAIN, quota)
        self.assertEqual(result["winner"], "glm")

    def test_glm_healthy_codex_exhausted_sonnet_healthy_picks_glm(self):
        quota = {"glm": glm_bucket(), "codex": codex_bucket(used_percent=100.0),
                 "anthropic": anthropic_bucket()}
        result = router_v2.resolve(CHAIN, quota)
        self.assertEqual(result["winner"], "glm")

    def test_all_arms_exhausted_or_gated_returns_no_winner(self):
        quota = {"glm": glm_bucket(weekly_pct=95.0),
                 "codex": codex_bucket(used_percent=100.0),
                 "anthropic": anthropic_bucket(five_hour_pct=100.0, weekly_pct=100.0)}
        result = router_v2.resolve(CHAIN, quota)
        self.assertIsNone(result["winner"])
        self.assertEqual(result["winner_reason"], "all_arms_exhausted")


class AutoRecoveryTests(unittest.TestCase):
    """An exhausted arm returns to rotation once its window resets -- proven by
    feeding two DIFFERENT quota snapshots (before/after reset) through the SAME
    pure resolve() call. No exclusion file exists anywhere in this test; the
    only thing that changes between the two calls is the live quota reading,
    exactly as it will once Codex's window actually rolls over on 2026-08-04.
    """

    def test_codex_exhausted_then_recovered_after_reset_no_file_touched(self):
        before = {"glm": glm_bucket(), "codex": codex_bucket(used_percent=100.0),
                  "anthropic": anthropic_bucket()}
        result_before = router_v2.resolve(CHAIN, before)
        self.assertEqual(result_before["winner"], "glm")
        self.assertIn({"arm": "codex", "reason": "quota_exhausted"}, result_before["filtered"])

        # Simulate the reset firing: codex's usage window reports fresh headroom.
        after = {"glm": glm_bucket(weekly_pct=95.0),  # force glm out so codex is the winner
                 "codex": codex_bucket(used_percent=5.0),
                 "anthropic": anthropic_bucket()}
        result_after = router_v2.resolve(CHAIN, after)
        self.assertEqual(result_after["winner"], "codex")
        self.assertEqual(result_after["filtered"], [{"arm": "glm", "reason": "quota_gate"}])


class UnknownPolicyTests(unittest.TestCase):
    def test_unknown_bucket_is_eligible_not_excluded_and_ranked_after_known_healthy(self):
        quota = {"glm": glm_bucket(status="unknown"),
                 "codex": codex_bucket(used_percent=50.0),
                 "anthropic": anthropic_bucket()}
        result = router_v2.resolve(CHAIN, quota)
        glm_row = next(v for v in result["vector"] if v["arm"] == "glm")
        self.assertTrue(glm_row["eligible"])
        self.assertEqual(glm_row["reason"], "unknown_headroom_failopen")
        self.assertIsNone(glm_row["usable_now"])
        # A known-healthy arm earlier in the chain still wins over the unknown one --
        # unknown is never treated as "plenty" (that's the 2026-07-28 misreading).
        self.assertNotEqual(result["winner"], "glm")

    def test_all_unknown_still_returns_first_in_chain_order(self):
        quota = {"glm": glm_bucket(status="unknown"), "codex": codex_bucket(status="unknown"),
                  "anthropic": anthropic_bucket(status="unknown")}
        result = router_v2.resolve(CHAIN, quota)
        self.assertEqual(result["winner"], "glm")
        self.assertEqual(result["winner_reason"], "unknown_headroom_failopen")


class BashWrapperDryRunTests(unittest.TestCase):
    """Exercises leadv2-router-v2.sh (not just the python core) for >=4
    contrasting quota states, matching the mission's explicit dry-run bullet.
    """

    def _run(self, mode, quota, chain=CHAIN, extra_env=None, task_id=None):
        with tempfile.TemporaryDirectory() as tmp:
            qf = Path(tmp) / "quota.json"
            qf.write_text(json.dumps(quota))
            cmd = ["bash", str(ROUTER_SH_PATH), mode, "--chain", ",".join(chain),
                   "--quota-json", str(qf)]
            if task_id:
                cmd += ["--task-id", task_id]
            env = {**os.environ}
            if extra_env:
                env.update(extra_env)
            proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
            return proc

    def test_four_contrasting_states_dry_run(self):
        states = {
            "all_healthy": {"glm": glm_bucket(), "codex": codex_bucket(),
                             "anthropic": anthropic_bucket()},
            "codex_zero_credits": {"glm": glm_bucket(weekly_pct=83.0),
                                    "codex": codex_bucket(used_percent=100.0),
                                    "anthropic": anthropic_bucket()},
            "glm_and_codex_exhausted": {"glm": glm_bucket(weekly_pct=90.0),
                                         "codex": codex_bucket(used_percent=100.0),
                                         "anthropic": anthropic_bucket()},
            "all_unknown": {"glm": glm_bucket(status="unknown"),
                             "codex": codex_bucket(status="unknown"),
                             "anthropic": anthropic_bucket(status="unknown")},
        }
        expected_winner = {
            "all_healthy": "glm",
            "codex_zero_credits": "sonnet",
            "glm_and_codex_exhausted": "sonnet",
            "all_unknown": "glm",
        }
        self.assertGreaterEqual(len(states), 4)
        for name, quota in states.items():
            proc = self._run("dry-run", quota)
            self.assertEqual(proc.returncode, 0, msg=f"{name}: {proc.stderr}")
            decision = json.loads(proc.stdout)
            self.assertEqual(decision["winner"], expected_winner[name], msg=name)
            self.assertIn("winner_reason", decision)

    def test_resolve_mode_prints_pipe_friendly_lines_and_exit_code(self):
        quota = {"glm": glm_bucket(weekly_pct=90.0), "codex": codex_bucket(used_percent=100.0),
                 "anthropic": anthropic_bucket(five_hour_pct=100.0, weekly_pct=100.0)}
        proc = self._run("resolve", quota)
        self.assertEqual(proc.returncode, 3)
        self.assertIn("winner=\n", proc.stdout)
        self.assertIn("reason=all_arms_exhausted", proc.stdout)

    def test_resolve_mode_winner_found_exits_zero(self):
        quota = {"glm": glm_bucket(), "codex": codex_bucket(), "anthropic": anthropic_bucket()}
        proc = self._run("resolve", quota)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("winner=glm", proc.stdout)

    def test_resolve_journals_route_v2_resolved_when_task_id_given(self):
        with tempfile.TemporaryDirectory() as tmp:
            journal_stub = Path(tmp) / "journal.sh"
            log_file = Path(tmp) / "journal.log"
            journal_stub.write_text(
                "#!/usr/bin/env bash\n"
                'printf -- "%s\\n" "$*" >> "' + str(log_file) + '"\n'
            )
            journal_stub.chmod(0o755)
            quota = {"glm": glm_bucket(), "codex": codex_bucket(), "anthropic": anthropic_bucket()}
            proc = self._run("resolve", quota, extra_env={"LEADV2_JOURNAL_BIN": str(journal_stub)},
                             task_id="abc12345")
            self.assertEqual(proc.returncode, 0)
            self.assertTrue(log_file.exists())
            logged = log_file.read_text()
            self.assertIn("route_v2_resolved", logged)
            self.assertIn("winner=glm", logged)
            self.assertIn("abc12345", logged)


if __name__ == "__main__":
    unittest.main(verbosity=2)
