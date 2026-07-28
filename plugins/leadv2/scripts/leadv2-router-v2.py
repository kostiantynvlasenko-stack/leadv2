#!/usr/bin/env python3
"""
leadv2-router-v2.py -- deterministic, quota-driven arm selection (T6).

ROUTER-QUOTA-DRIVEN-01: replaces the hand-maintained ~/.claude/leadv2-excluded-arms
stopgap. An arm whose live quota truth (leadv2-quota-read.py T1 usable_now, see
that file's normalize_window/binding_window) shows zero usable headroom is
skipped AUTOMATICALLY; it returns to rotation on its own the moment usable_now
recovers past 0, because usable_now is recomputed live from reset_iso vs now on
every call -- nothing to edit, nothing to remember, nothing to expire.

Policy (mission-specified, not the full smart-routing-v2.md L3 scorer -- no
task judge, no learned competence table; those are separate tasks):
    usable_now <= 0     -> EXCLUDED  reason=quota_exhausted
    usable_now is None  -> ELIGIBLE  reason=unknown_headroom_failopen  (an
                            unknown read is never treated as exhausted NOR as
                            healthy -- it is rankable, just not preferred over
                            a known-healthy arm; see resolve()'s ordering)
    usable_now > 0       -> ELIGIBLE  reason=headroom_available

Winner selection is deterministic: known-healthy arms (usable_now > 0) are
tried first in the caller's chain order, THEN unknown-headroom arms in chain
order, so an unknown read never displaces a provably-healthy arm but also
never gets treated as exhausted (fail-open, matching leadv2-glm-quota-gate.sh
sec3 and quota-read.py's "unknown is never 0%" invariant). Every arm's full
vector (usable_now, eligible, reason) is always returned so the caller can
journal a fully audit-able decision.

Usage:
    leadv2-router-v2.py resolve  --chain glm,codex,sonnet [--quota-json FILE]
    leadv2-router-v2.py dry-run  --chain glm,codex,sonnet [--quota-json FILE]

`resolve` prints pipe-friendly key=value lines (matching the rest of the
dispatch tooling's journal style) and exits 0 with a winner, 3 with no
eligible arm. `dry-run` prints the full decision vector as indented JSON,
always exits 0 -- for humans / --dry-run smoke tests, never gates a real
dispatch.
"""
import argparse
import json
import os
import subprocess
import sys

# Arm id -> quota bucket key in leadv2-quota-live.sh json output. The Anthropic
# arms (sonnet/opus/haiku, however the caller spells them) share ONE quota
# bucket -- the account leadv2-quota-read.py resolved as active (T2) -- because
# that is what the account actually meters, not the model chosen within it.
BUCKET_FOR_ARM = {
    "glm": "glm",
    "codex": "codex",
    "sonnet": "anthropic",
    "opus": "anthropic",
    "haiku": "anthropic",
    "claude-sonnet": "anthropic",
    "claude-opus": "anthropic",
    "claude-haiku": "anthropic",
}

EXHAUSTED_AT_OR_BELOW = 0.0

# Mirrors leadv2-glm-quota-gate.sh sec1 exactly (same env var, same >=threshold-
# on-EITHER-window semantics) so GLM's existing 80% reroute policy is reused,
# not reimplemented as a second, possibly-drifting gate ("never open a second
# channel to bypass a gate" -- this IS the sanctioned gate, applied a step
# earlier, before a spawn attempt is even made).
GLM_GATE_ENV = "GLM_QUOTA_THRESHOLD"
GLM_GATE_DEFAULT = 80.0


def _glm_gate_exceeded(bucket_payload):
    if not isinstance(bucket_payload, dict) or bucket_payload.get("status") != "ok":
        return False
    try:
        threshold = float(os.environ.get(GLM_GATE_ENV, GLM_GATE_DEFAULT))
    except (TypeError, ValueError):
        threshold = GLM_GATE_DEFAULT
    for window_name in ("five_hour", "weekly"):
        pct = (bucket_payload.get(window_name) or {}).get("pct")
        try:
            if pct is not None and float(pct) >= threshold:
                return True
        except (TypeError, ValueError):
            continue
    return False


def _window_usable_now(window):
    if not isinstance(window, dict):
        return None
    return window.get("usable_now")


def bucket_usable_now(bucket_payload):
    """Return usable_now for one provider payload's binding window, or None.

    None covers both "provider unreachable" (status != ok) and "provider
    answered but no binding window could be resolved" -- both are unknown,
    never fabricated as 0.
    """
    if not isinstance(bucket_payload, dict):
        return None
    if bucket_payload.get("status") != "ok":
        return None
    provider = bucket_payload.get("provider")
    binding = bucket_payload.get("binding_window")
    if provider == "glm":
        return _window_usable_now(bucket_payload.get(binding) if binding else None)
    if provider == "codex":
        windows = bucket_payload.get("windows") or []
        window = next((w for w in windows if w.get("kind") == binding), None)
        return _window_usable_now(window)
    if provider == "anthropic":
        accounts = bucket_payload.get("accounts") or []
        active = next((a for a in accounts if a.get("active")), None)
        if not active or active.get("status") != "ok":
            return None
        acct_binding = active.get("binding_window")
        return _window_usable_now(active.get(acct_binding) if acct_binding else None)
    return None


def classify_arm(arm, quota):
    bucket = BUCKET_FOR_ARM.get(arm)
    if bucket is None:
        return {"arm": arm, "bucket": None, "usable_now": None,
                "eligible": False, "reason": "unmapped_arm"}
    payload = quota.get(bucket) or {}
    if arm == "glm" and _glm_gate_exceeded(payload):
        return {"arm": arm, "bucket": bucket, "usable_now": bucket_usable_now(payload),
                "eligible": False, "reason": "quota_gate"}
    usable_now = bucket_usable_now(payload)
    if usable_now is None:
        return {"arm": arm, "bucket": bucket, "usable_now": None,
                "eligible": True, "reason": "unknown_headroom_failopen"}
    if usable_now <= EXHAUSTED_AT_OR_BELOW:
        return {"arm": arm, "bucket": bucket, "usable_now": usable_now,
                "eligible": False, "reason": "quota_exhausted"}
    return {"arm": arm, "bucket": bucket, "usable_now": usable_now,
            "eligible": True, "reason": "headroom_available"}


def resolve(chain, quota):
    """Pure function: chain (ordered arm ids) + quota json -> decision dict.

    No I/O, no clock read -- fully deterministic given its two inputs, which
    is what makes "byte-deterministic on a seeded/fixture run" true without
    needing to seed anything.
    """
    vector = [classify_arm(arm, quota) for arm in chain]
    eligible = [v for v in vector if v["eligible"]]
    filtered = [v for v in vector if not v["eligible"]]
    # Known-healthy first (chain order preserved), unknown-headroom after --
    # never let an unread bucket outrank a provably-healthy one, but never
    # exclude it either (fail-open).
    known = [v for v in eligible if v["usable_now"] is not None]
    unknown = [v for v in eligible if v["usable_now"] is None]
    ordered_eligible = known + unknown
    winner = ordered_eligible[0] if ordered_eligible else None
    return {
        "chain": chain,
        "vector": vector,
        "eligible": [v["arm"] for v in ordered_eligible],
        "filtered": [{"arm": v["arm"], "reason": v["reason"]} for v in filtered],
        "winner": winner["arm"] if winner else None,
        "winner_reason": winner["reason"] if winner else "all_arms_exhausted",
        "headroom": {v["arm"]: v["usable_now"] for v in vector},
    }


def load_quota(quota_json_path, quota_live_path):
    if quota_json_path:
        with open(quota_json_path) as fh:
            return json.load(fh)
    live = quota_live_path or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                           "leadv2-quota-live.sh")
    out = subprocess.check_output(["bash", live, "json"], text=True)
    return json.loads(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["resolve", "dry-run"])
    parser.add_argument("--chain", required=True,
                        help="comma-separated ordered arm ids, e.g. glm,codex,sonnet")
    parser.add_argument("--quota-json", help="fixture file (tests); default reads live quota")
    parser.add_argument("--quota-live", help="override path to leadv2-quota-live.sh")
    args = parser.parse_args(argv)

    chain = [a.strip() for a in args.chain.split(",") if a.strip()]
    if not chain:
        sys.stderr.write("leadv2-router-v2.py: --chain must name at least one arm\n")
        return 2
    quota = load_quota(args.quota_json, args.quota_live)
    result = resolve(chain, quota)

    if args.mode == "dry-run":
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    print("winner=%s" % (result["winner"] or ""))
    print("reason=%s" % result["winner_reason"])
    print("eligible=%s" % ",".join(result["eligible"]))
    print("filtered=%s" % json.dumps(result["filtered"], sort_keys=True))
    print("headroom=%s" % json.dumps(result["headroom"], sort_keys=True))
    return 0 if result["winner"] else 3


if __name__ == "__main__":
    sys.exit(main())
