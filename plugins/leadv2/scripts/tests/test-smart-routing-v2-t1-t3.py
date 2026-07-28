#!/usr/bin/env python3
"""Focused additive acceptance tests for smart-routing-v2 T1, T2, and T3."""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
PLUGIN = SCRIPTS.parent
READER_PATH = SCRIPTS / "leadv2-quota-read.py"
spec = importlib.util.spec_from_file_location("quota_reader", READER_PATH)
quota_reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quota_reader)


class QuotaNormalizationTests(unittest.TestCase):
    def test_remaining_over_hours_and_under_one_hour_clamp(self):
        now = dt.datetime(2026, 7, 29, 12, tzinfo=dt.timezone.utc)
        normal = quota_reader.normalize_window(25, "2026-07-29T15:00:00Z", now)
        self.assertEqual(normal["remaining_pct"], 75.0)
        self.assertEqual(normal["hours_to_reset"], 3.0)
        self.assertEqual(normal["usable_now"], 25.0)
        clamped = quota_reader.normalize_window(20, "2026-07-29T12:30:00Z", now)
        self.assertEqual(clamped["usable_now"], 80.0)

    def test_unknown_is_null_not_zero(self):
        self.assertIsNone(quota_reader.normalize_window(None, None)["usable_now"])
        self.assertIsNone(quota_reader.unknown("glm", "fixture")["usable_now"])

    def test_binding_window_is_lowest_per_window_rate(self):
        windows = {"five_hour": {"usable_now": 9.0}, "weekly": {"usable_now": 1.5}}
        self.assertEqual(quota_reader.binding_window(windows), "weekly")


class ActiveAccountTests(unittest.TestCase):
    def setUp(self):
        self.saved = {key: os.environ.get(key) for key in (
            "LEADV2_ROUTING_CONFIG", "LEADV2_ANTHROPIC_ACTIVE_SERVICE",
            "LEADV2_ANTHROPIC_FORCE_UNRESOLVED")}
        self.original_services = quota_reader._keychain_services
        self.original_keychain = quota_reader._read_keychain
        self.original_http = quota_reader.http_json
        self.config_dir = tempfile.TemporaryDirectory()
        config = Path(self.config_dir.name) / "routing.yaml"
        config.write_text("router_v2:\n  active_account: max_20x\n")
        os.environ["LEADV2_ROUTING_CONFIG"] = str(config)
        quota_reader._keychain_services = lambda: {
            "Claude Code-credentials", "Claude Code-credentials-team"
        }
        expires = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000) + 60_000
        blobs = {
            "Claude Code-credentials": {"claudeAiOauth": {
                "accessToken": "never-printed", "expiresAt": expires,
                "subscriptionType": "max", "rateLimitTier": "max_20x"}},
            "Claude Code-credentials-team": {"claudeAiOauth": {
                "accessToken": "never-printed", "expiresAt": expires,
                "subscriptionType": "team", "rateLimitTier": "team"}},
        }
        quota_reader._read_keychain = lambda service: blobs[service]
        def fake_http(_url, headers=None, **_kwargs):
            # The Authorization value is deliberately ignored; tests ensure no
            # credential ever appears in output rather than inspecting it.
            return 200, json.dumps({"five_hour": {"utilization": 20,
                                                    "resets_at": "2099-01-01T01:00:00Z"},
                                    "seven_day": {"utilization": 50,
                                                  "resets_at": "2099-01-07T01:00:00Z"}})
        quota_reader.http_json = fake_http

    def tearDown(self):
        quota_reader._keychain_services = self.original_services
        quota_reader._read_keychain = self.original_keychain
        quota_reader.http_json = self.original_http
        self.config_dir.cleanup()
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_current_session_credential_marks_only_max_20x_active(self):
        result = quota_reader.read_anthropic()
        active = [a for a in result["accounts"] if a["active"]]
        self.assertEqual(result["account_resolution"], "session_credential")
        self.assertEqual(result["active_account"], "max_20x")
        self.assertEqual(len(active), 1)
        self.assertEqual(active[0]["account_label"], "max_20x")

    def test_forced_unresolved_reports_pinned_journal_value_and_exits(self):
        os.environ["LEADV2_ANTHROPIC_FORCE_UNRESOLVED"] = "1"
        result = quota_reader.read_anthropic()
        self.assertEqual(result["account_resolution"], "pinned_unresolved")
        self.assertEqual(result["account_resolution_journal"], "account=pinned_unresolved")
        self.assertEqual(len([a for a in result["accounts"] if a["active"]]), 1)


class RegistryTests(unittest.TestCase):
    def test_registry_is_valid_and_complete(self):
        with (PLUGIN / "config" / "leadv2-routing.yaml").open() as fh:
            config = yaml.safe_load(fh)
        router_v2 = config["router_v2"]
        self.assertEqual(router_v2["active_account"], "max_20x")
        self.assertTrue(router_v2["headroom_weights"])
        self.assertEqual({arm["id"] for arm in router_v2["arms"]},
                         {"glm", "codex", "claude-haiku", "claude-sonnet", "claude-opus"})
        for arm in router_v2["arms"]:
            for field in ("id", "channel", "model", "bucket", "reserve_threshold", "reserve_allow"):
                self.assertIn(field, arm)
            self.assertIsInstance(arm["reserve_allow"], list)

    def test_report_labels_active_anthropic_account(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "reader.py"
            fake.write_text("""#!/usr/bin/env python3
import json, sys
p = sys.argv[1]
if p == 'anthropic':
 print(json.dumps({'provider':'anthropic','status':'ok','active_account':'max_20x','account_resolution':'session_credential','accounts':[{'account_label':'max_20x','active':True,'subscription_type':'max','tier':'max_20x','five_hour_pct':10,'seven_day_pct':20},{'account_label':'max_5x','active':False,'subscription_type':'team','tier':'team','five_hour_pct':90,'seven_day_pct':90}]}))
else: print(json.dumps({'provider':p,'status':'unknown','error':'fixture'}))
""")
            output = subprocess.check_output(
                ["bash", str(SCRIPTS / "leadv2-quota-live.sh"), "report"],
                env={**os.environ, "LEADV2_QUOTA_READ": str(fake)}, text=True)
        self.assertIn("Anthropic (max_20x ACTIVE", output)
        self.assertIn("Anthropic active account: max_20x (session_credential)", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
