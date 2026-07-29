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
    leadv2-router-v2.py filter   --arms-json FILE --glm-policy-json FILE
                                  [--mission-kind K] [--protected-path]
                                  [--glm-quota-gate-tripped]
                                  [--glm-failure-count N] [--channel-down a,b]

`resolve` prints pipe-friendly key=value lines (matching the rest of the
dispatch tooling's journal style) and exits 0 with a winner, 3 with no
eligible arm. `dry-run` prints the full decision vector as indented JSON,
always exits 0 -- for humans / --dry-run smoke tests, never gates a real
dispatch.

`filter` (T4, SMART-ROUTING-V2 L1 hard filters) is a DIFFERENT, EARLIER
layer than `resolve`'s quota-headroom ordering above: it decides which arms
are eligible AT ALL, from policy + registry facts alone -- never from
usable_now/headroom. See filter_arms() below for the invariant this exists
to guarantee (an excluded arm is never resurrected by a headroom number).
Prints the same eligible=/filtered= key=value lines `resolve` uses so
callers can pipe filter's `eligible` list straight into resolve's `--chain`.
Always exits 0 (a filter producing zero eligible arms is a valid, reportable
outcome for the caller to act on -- not this layer's failure).
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


def headroom_weight(usable_now, weights):
    """Return the configured monotone weight for usable_now.

    ``usable_now is None`` is *unknown*, not zero and not abundant.  Unknown
    headroom does not trip the reserve rule (there is no evidence it is below
    reserve), remains fail-open/rankable, and receives only the explicit
    ``min_usable_now: null`` weight.  Thus it cannot masquerade as healthy.
    """
    if usable_now is None:
        for row in weights:
            if row.get("min_usable_now") is None:
                return float(row["weight"])
        return 0.2
    known = sorted((r for r in weights if r.get("min_usable_now") is not None),
                   key=lambda r: float(r["min_usable_now"]), reverse=True)
    for row in known:
        if float(usable_now) >= float(row["min_usable_now"]):
            return float(row["weight"])
    return float(known[-1]["weight"]) if known else 1.0


def select_arms(arms, l1_result, quota, estimate, samples, headroom_weights):
    """L3 selector: L1 survivors -> reserve -> samples*headroom -> argmax.

    This deliberately accepts L1's *already filtered* set, rather than all
    arms plus filter inputs.  Consequently an L1-rejected arm has no code path
    to scoring or selection, irrespective of quota, sample, or score.
    """
    arm_by_id = {arm["id"]: arm for arm in arms}
    survivors = [arm_by_id[aid] for aid in l1_result["eligible"] if aid in arm_by_id]
    # Preserve L1 reasons first; they are never overwritten downstream.
    filtered = list(l1_result.get("filtered", []))
    vector = []
    for arm in survivors:
        aid = arm["id"]
        bucket = arm.get("bucket", aid).split(":", 1)[0]
        usable = bucket_usable_now(quota.get(bucket) or {})
        threshold = float(arm.get("reserve_threshold", 0))
        allowed = (estimate.get("duration_class") == "short" and
                   estimate.get("work_kind") in set(arm.get("reserve_allow") or ["review"]))
        # Unknown is not comparable to the threshold: fail open, but its
        # configured unknown weight below makes it rank last absent competence.
        if usable is not None and usable < threshold and not allowed:
            filtered.append({"arm": aid, "reason": "reserve"})
            continue
        sample = float(samples.get(aid, 0.75))
        weight = headroom_weight(usable, headroom_weights)
        vector.append({"arm": aid, "bucket": bucket, "usable_now": usable,
                       "reserve_threshold": threshold, "sample": sample,
                       "headroom_weight": weight, "score": sample * weight})
    winner_row = max(vector, key=lambda row: (row["score"], -l1_result["eligible"].index(row["arm"])),
                     default=None)
    return {
        "eligible": [row["arm"] for row in vector], "filtered": filtered,
        "vector": vector, "headroom": {row["arm"]: row["usable_now"] for row in vector},
        "samples": {row["arm"]: row["sample"] for row in vector},
        "winner": winner_row["arm"] if winner_row else None,
        "winner_reason": "max_sample_x_headroom" if winner_row else "all_arms_filtered",
        "task_class": "%s:%s" % (estimate.get("work_kind", "unknown"),
                                     "short" if estimate.get("duration_class") == "short" and estimate.get("complexity") in ("trivial", "simple") else "long"),
        "estimate_id": estimate.get("estimate_id", "unknown"),
    }

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


# ---------------------------------------------------------------------------
# T4 -- L1 hard filters (SMART-ROUTING-V2 docs/specs/smart-routing-v2.md sec3).
#
# Deliberately narrower inputs than resolve()'s: filter_arms() never receives
# usable_now/headroom, so a filtered arm CANNOT be traded back in by a good
# score -- the invariant is structural (the function has no parameter to leak
# it through), not just a behavioural promise a test happens to check.
#
# Reason-code priority mirrors the spec table order; a filtered arm gets the
# FIRST rule that excludes it (setdefault), matching "reason codes matter as
# much as the verdict" -- one code per arm, the one that actually decided it.
# ---------------------------------------------------------------------------

# GLM-FIRST-01's own build arm plus the codex-fitting arm are the only two
# ROUTER-QUOTA-DRIVEN-01/T3-registry buckets a mission_kind policy ban can
# reach; sonnet/opus/haiku all sit on the anthropic bucket and are the
# opus_only_mission_kinds' intended DESTINATION, never its target.
POLICY_BAN_BUCKETS = ("glm", "codex")


def filter_arms(arms, glm_policy, signals):
    """Pure function: registry + policy + per-dispatch signals -> {eligible, filtered}.

    arms: list of {id, channel, model, bucket, reserve_threshold, reserve_allow}
          (T3 router_v2.arms shape; extra keys ignored).
    glm_policy: the routing.yaml phases.glm_policy dict (opus_only_mission_kinds
          etc.), or None/{} if absent -- an absent policy bans nothing (the
          block staying the SOLE source of policy bans means "missing" is
          "no ban configured", not "ban everything").
    signals: {
        mission_kind: str | None,
        protected_path: bool,
        glm_quota_gate_tripped: bool,   # caller already ran leadv2-glm-quota-gate.sh
        glm_failure_count: int,          # F1-spoof-fix note below
        channel_down: [arm_id, ...],
    }

    No LLM, no I/O, no clock -- same determinism contract as resolve().
    """
    glm_policy = glm_policy or {}
    reasons = {}  # arm_id -> reason (first match wins, spec table order)

    opus_only = set(glm_policy.get("opus_only_mission_kinds", []) or [])
    mission_kind = signals.get("mission_kind")
    if mission_kind is not None and mission_kind in opus_only:
        for arm in arms:
            if arm.get("bucket") in POLICY_BAN_BUCKETS:
                reasons.setdefault(arm["id"], "policy_ban")

    if signals.get("protected_path"):
        # Spec sec3 L1: protected path -> "only sonnet/opus arms" eligible.
        for arm in arms:
            if arm.get("model") not in ("sonnet", "opus"):
                reasons.setdefault(arm["id"], "protected_path")

    if signals.get("glm_quota_gate_tripped"):
        for arm in arms:
            if arm.get("bucket") == "glm":
                reasons.setdefault(arm["id"], "quota_gate")

    # F1-spoof-fix (leadv2-dispatch-code.sh "FIX PASS 2"): glm_failure_count
    # has no real ledger backing it yet, so a caller-supplied value that would
    # TRIP the rule is not trustworthy input -- same posture as dispatch-
    # code.sh's own capped/ignored-and-journalled handling. The caller decides
    # whether to surface the ignore; this function just refuses to act on an
    # unverified >=2 by treating it as 0 until a real ledger source exists.
    glm_failure_count = signals.get("glm_failure_count") or 0
    if signals.get("glm_failure_count_ledger_verified") and glm_failure_count >= 2:
        for arm in arms:
            if arm.get("bucket") == "glm":
                reasons.setdefault(arm["id"], "failed_twice")

    channel_down = set(signals.get("channel_down") or [])
    for arm in arms:
        if arm["id"] in channel_down:
            reasons.setdefault(arm["id"], "channel_down")

    eligible = [arm["id"] for arm in arms if arm["id"] not in reasons]
    filtered = [{"arm": aid, "reason": reasons[aid]}
                for aid in [a["id"] for a in arms] if aid in reasons]
    return {"eligible": eligible, "filtered": filtered}


def load_quota(quota_json_path, quota_live_path):
    if quota_json_path:
        with open(quota_json_path) as fh:
            return json.load(fh)
    live = quota_live_path or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                           "leadv2-quota-live.sh")
    out = subprocess.check_output(["bash", live, "json"], text=True)
    return json.loads(out)


def _run_filter(args):
    with open(args.arms_json) as fh:
        arms = json.load(fh)
    glm_policy = {}
    if args.glm_policy_json:
        with open(args.glm_policy_json) as fh:
            glm_policy = json.load(fh) or {}
    channel_down = [a.strip() for a in (args.channel_down or "").split(",") if a.strip()]
    signals = {
        "mission_kind": args.mission_kind,
        "protected_path": bool(args.protected_path),
        "glm_quota_gate_tripped": bool(args.glm_quota_gate_tripped),
        "glm_failure_count": args.glm_failure_count or 0,
        "glm_failure_count_ledger_verified": bool(args.glm_failure_count_ledger_verified),
        "channel_down": channel_down,
    }
    result = filter_arms(arms, glm_policy, signals)
    print("eligible=%s" % ",".join(result["eligible"]))
    print("filtered=%s" % json.dumps(result["filtered"], sort_keys=True))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["resolve", "dry-run", "filter"])
    parser.add_argument("--chain",
                        help="resolve/dry-run: comma-separated ordered arm ids, e.g. glm,codex,sonnet")
    parser.add_argument("--quota-json", help="fixture file (tests); default reads live quota")
    parser.add_argument("--quota-live", help="override path to leadv2-quota-live.sh")
    parser.add_argument("--arms-json", help="filter/resolve: path to router_v2.arms as JSON array")
    parser.add_argument("--glm-policy-json", help="filter: path to phases.glm_policy as JSON object")
    parser.add_argument("--l1-json", help="resolve: JSON L1 filter result (eligible/filtered)")
    parser.add_argument("--estimate-json", help="resolve: arm-blind TaskEstimate JSON")
    parser.add_argument("--samples-json", help="resolve: arm-id -> pre-sampled competence JSON")
    parser.add_argument("--headroom-weights-json", help="resolve: router_v2.headroom_weights JSON")
    parser.add_argument("--mission-kind", help="filter: mission_kind signal")
    parser.add_argument("--protected-path", action="store_true",
                        help="filter: safety-gate/publish/payments touched")
    parser.add_argument("--glm-quota-gate-tripped", action="store_true",
                        help="filter: caller already ran leadv2-glm-quota-gate.sh and it exited non-zero")
    parser.add_argument("--glm-failure-count", type=int, default=0,
                        help="filter: only acted on with --glm-failure-count-ledger-verified (F1-spoof-fix)")
    parser.add_argument("--glm-failure-count-ledger-verified", action="store_true",
                        help="filter: caller confirms --glm-failure-count is ledger-backed, not caller-guessed")
    parser.add_argument("--channel-down", help="filter: comma-separated arm ids that are hard-unavailable")
    args = parser.parse_args(argv)

    if args.mode == "filter":
        if not args.arms_json:
            sys.stderr.write("leadv2-router-v2.py filter: --arms-json is required\n")
            return 2
        return _run_filter(args)

    # The complete T6/T7 L3 path.  Its inputs are materialized JSON so it is
    # pure and replayable from the journal; the shell wrapper obtains them from
    # T4/T5/L4 in production.  Supplying --l1-json structurally prevents any
    # L1-filtered arm from being revived by later layers.
    if args.mode == "resolve" and args.l1_json:
        required = (args.arms_json, args.estimate_json, args.samples_json,
                    args.headroom_weights_json)
        if not all(required):
            sys.stderr.write("leadv2-router-v2.py resolve: L3 requires --arms-json --estimate-json --samples-json --headroom-weights-json\n")
            return 2
        with open(args.arms_json) as fh:
            arms = json.load(fh)
        with open(args.l1_json) as fh:
            l1 = json.load(fh)
        with open(args.estimate_json) as fh:
            estimate = json.load(fh)
        with open(args.samples_json) as fh:
            samples = json.load(fh)
        with open(args.headroom_weights_json) as fh:
            weights = json.load(fh)
        quota = load_quota(args.quota_json, args.quota_live)
        result = select_arms(arms, l1, quota, estimate, samples, weights)
        print("winner=%s" % (result["winner"] or ""))
        print("reason=%s" % result["winner_reason"])
        print("eligible=%s" % ",".join(result["eligible"]))
        print("filtered=%s" % json.dumps(result["filtered"], sort_keys=True))
        print("headroom=%s" % json.dumps(result["headroom"], sort_keys=True))
        print("samples=%s" % json.dumps(result["samples"], sort_keys=True))
        print("task_class=%s" % result["task_class"])
        print("estimate_id=%s" % result["estimate_id"])
        return 0 if result["winner"] else 3

    if not args.chain:
        sys.stderr.write("leadv2-router-v2.py: --chain is required for resolve/dry-run\n")
        return 2
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
