#!/usr/bin/env python3
"""
leadv2-route-bandit-py.py — Python helper for leadv2-route-bandit.sh.

Called via: python3 leadv2-route-bandit-py.py <subcmd> <args...>

Subcmds:
  parse_yaml  <path>                    -> JSON state
  to_yaml     <json_str>                -> YAML text
  sample      <ctx_key> <allowed_json> <heuristic> <state_json>  -> chosen_arm=<arm>
  get_cooldown <state_json> <ctx_key>   -> int (remaining closes)
  decrement_cooldown <ctx_key> <state_json> -> updated state JSON
  parse_rd    <rd_yaml_path>            -> JSON array of route-decision entries
  update      <task_id> <rd_json> <sc_json> <state_json> -> updated state JSON
  stamp_meta  <state_json> <now_iso>    -> state JSON with meta stamped
  rebuild     <scorecard_content> <handoff_base_dir> -> state JSON
"""

from __future__ import annotations

import json
import os
import random
import re
import sys
from datetime import datetime, timezone
from typing import Any


# ── YAML parser (hand-rolled for our controlled format) ───────────────────────

def parse_yaml_text(text: str) -> dict[str, Any]:
    """Parse the route-bandit-state.yaml format into a dict."""
    state: dict[str, Any] = {"version": 1, "arms": {}, "cooldowns": {}, "meta": {}}
    current_section: str | None = None
    current_ctx: str | None = None
    in_applied_list: bool = False

    for raw_line in text.splitlines():
        stripped = raw_line.rstrip()
        if not stripped or stripped.lstrip().startswith("#"):
            continue

        indent = len(raw_line) - len(raw_line.lstrip())
        line = stripped.lstrip()

        if indent == 0:
            in_applied_list = False
            if line.startswith("version:"):
                try:
                    state["version"] = int(line.split(":", 1)[1].strip())
                except (ValueError, IndexError):
                    pass
            elif line.startswith("arms:"):
                current_section = "arms"
                current_ctx = None
            elif line.startswith("cooldowns:"):
                current_section = "cooldowns"
                current_ctx = None
            elif line.startswith("meta:"):
                current_section = "meta"
        elif indent == 2 and current_section in ("arms", "cooldowns"):
            in_applied_list = False
            # Context key line: may be quoted or bare
            key = line.rstrip(":").strip().strip('"')
            current_ctx = key
            if current_section == "arms" and current_ctx not in state["arms"]:
                state["arms"][current_ctx] = {}
            elif current_section == "cooldowns" and current_ctx not in state["cooldowns"]:
                state["cooldowns"][current_ctx] = {}
        elif indent == 4 and current_section == "arms" and current_ctx is not None:
            # arm line: sonnet:   {alpha: 8, beta: 2}
            m = re.match(r'([\w+\-]+):\s*\{alpha:\s*(\d+),\s*beta:\s*(\d+)\}', line)
            if m:
                arm_name, a, b = m.group(1), int(m.group(2)), int(m.group(3))
                state["arms"][current_ctx][arm_name] = {"alpha": a, "beta": b}
        elif indent == 4 and current_section == "cooldowns" and current_ctx is not None:
            if ":" in line:
                k, _, v = line.partition(":")
                k = k.strip()
                v = v.strip().strip('"')
                if k == "heuristic_only_until_n":
                    try:
                        state["cooldowns"][current_ctx][k] = int(v)
                    except ValueError:
                        pass
                elif k in ("written_at", "reason"):
                    state["cooldowns"][current_ctx][k] = v
        elif indent == 2 and current_section == "meta":
            if line.startswith("applied_task_ids:"):
                state["meta"].setdefault("applied_task_ids", [])
                in_applied_list = True
            elif ":" in line and not line.startswith("- "):
                in_applied_list = False
                k, _, v = line.partition(":")
                k = k.strip()
                v = v.strip().strip('"')
                if k == "total_updates":
                    try:
                        state["meta"][k] = int(v)
                    except ValueError:
                        pass
                else:
                    state["meta"][k] = v
        elif indent == 4 and current_section == "meta" and in_applied_list and line.startswith("- "):
            tid = line[2:].strip().strip('"')
            if tid:
                state["meta"].setdefault("applied_task_ids", []).append(tid)

    return state


def state_to_yaml(state: dict[str, Any]) -> str:
    """Serialize state dict to YAML text."""
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines: list[str] = []

    lines.append(f"version: {state.get('version', 1)}")
    lines.append("arms:")
    for ctx_key in sorted(state.get("arms", {})):
        ctx_arms = state["arms"][ctx_key]
        lines.append(f"  {json.dumps(ctx_key)}:")
        for arm_name in sorted(ctx_arms):
            ab = ctx_arms[arm_name]
            a = int(ab.get("alpha", 1))
            b = int(ab.get("beta", 1))
            lines.append(f"    {arm_name}:   {{alpha: {a}, beta: {b}}}")

    lines.append("cooldowns:")
    cds = state.get("cooldowns", {})
    for ctx_key in sorted(cds):
        cd = cds[ctx_key]
        lines.append(f"  {json.dumps(ctx_key)}:")
        lines.append(f"    heuristic_only_until_n: {cd.get('heuristic_only_until_n', 0)}")
        lines.append(f"    written_at: \"{cd.get('written_at', now_iso)}\"")
        lines.append(f"    reason: \"{cd.get('reason', '')}\"")

    meta = state.get("meta", {})
    lines.append("meta:")
    lines.append(f"  last_updated: \"{meta.get('last_updated', now_iso)}\"")
    lines.append(f"  total_updates: {meta.get('total_updates', 0)}")
    applied = meta.get("applied_task_ids", [])
    if applied:
        lines.append("  applied_task_ids:")
        for tid in applied:
            lines.append(f"    - {json.dumps(tid)}")

    return "\n".join(lines)


# ── seeded priors ─────────────────────────────────────────────────────────────

def _init_arm(arm: str, heuristic: str) -> dict[str, int]:
    """Seeded prior: heuristic gets alpha=8/beta=2, others 1/1."""
    if arm == heuristic:
        return {"alpha": 8, "beta": 2}
    return {"alpha": 1, "beta": 1}


def _ensure_arm(state: dict, ctx_key: str, arm: str, heuristic: str) -> None:
    state.setdefault("arms", {}).setdefault(ctx_key, {})
    if arm not in state["arms"][ctx_key]:
        state["arms"][ctx_key][arm] = _init_arm(arm, heuristic)


# ── Thompson sampling ─────────────────────────────────────────────────────────

def thompson_sample(ctx_key: str, allowed: list[str], heuristic: str,
                    state: dict[str, Any]) -> str:
    """Return the arm with the highest Beta-distributed sample."""
    if not allowed:
        return heuristic

    ctx_arms = state.get("arms", {}).get(ctx_key, {})
    best_arm = heuristic
    best_val = -1.0

    for arm in allowed:
        if arm in ctx_arms:
            a = int(ctx_arms[arm].get("alpha", 1))
            b = int(ctx_arms[arm].get("beta", 1))
        else:
            # lazy seeded priors
            a, b = (8, 2) if arm == heuristic else (1, 1)
        val = random.betavariate(a, b)
        if val > best_val:
            best_val = val
            best_arm = arm

    return best_arm


# ── reward formula ────────────────────────────────────────────────────────────

def compute_reward(sc: dict[str, Any]) -> float:
    verify_pass = int(sc.get("verify_pass", 0) or 0)
    post_reg    = int(sc.get("post_deploy_regression", 0) or 0)
    cost_actual   = sc.get("cost_actual_usd")
    cost_estimate = sc.get("cost_estimate_usd")

    if cost_actual is not None and cost_estimate is not None:
        try:
            ca, ce = float(cost_actual), float(cost_estimate)
            cost_eff = max(0.0, 1.0 - (ca / ce - 1.0)) if ce > 0 else 1.0
            return 0.6 * verify_pass + 0.25 * (1 - post_reg) + 0.15 * cost_eff
        except (TypeError, ValueError):
            pass

    return 0.7 * verify_pass + 0.3 * (1 - post_reg)


# ── route-decisions.yaml parser ───────────────────────────────────────────────

def parse_rd_yaml(text: str) -> list[dict[str, Any]]:
    """Parse route-decisions.yaml list of entries."""
    entries: list[dict[str, Any]] = []
    blocks = re.split(r"\n- ", "\n" + text.strip())
    for block in blocks:
        if not block.strip():
            continue
        entry: dict[str, Any] = {}
        for line in block.splitlines():
            line = line.strip().lstrip("- ")
            if not line or line.startswith("#"):
                continue
            if ":" in line:
                k, _, v = line.partition(":")
                k = k.strip()
                v = v.strip().strip('"')
                if k in ("bandit_active", "bandit_deviation", "safety_touched"):
                    entry[k] = v.lower() in ("true", "1", "yes")
                elif k == "allowed_arms":
                    pass  # multi-line list; skip for simple parser
                else:
                    entry[k] = v
        if "context_key" in entry and "chosen_arm" in entry:
            entries.append(entry)
    return entries


# ── subcmd implementations ────────────────────────────────────────────────────

def cmd_parse_yaml(args: list[str]) -> None:
    path = args[0]
    try:
        text = open(path).read()
        state = parse_yaml_text(text)
    except Exception:
        state = {}
    print(json.dumps(state))


def cmd_to_yaml(args: list[str]) -> None:
    json_str = args[0]
    try:
        state = json.loads(json_str)
        print(state_to_yaml(state))
    except Exception:
        print("version: 1\narms: {}\ncooldowns: {}\nmeta: {}")


def cmd_sample(args: list[str]) -> None:
    ctx_key, allowed_j, heuristic, state_raw = args[0], args[1], args[2], args[3]
    try:
        allowed = json.loads(allowed_j)
        if not isinstance(allowed, list):
            allowed = [heuristic]
        state = json.loads(state_raw) if state_raw.strip().startswith("{") else {}
    except Exception:
        allowed = [heuristic]
        state = {}

    try:
        chosen = thompson_sample(ctx_key, allowed, heuristic, state)
    except Exception:
        chosen = heuristic

    print(f"chosen_arm={chosen}")


def cmd_get_cooldown(args: list[str]) -> None:
    state_raw, ctx_key = args[0], args[1]
    try:
        state = json.loads(state_raw)
        n = state.get("cooldowns", {}).get(ctx_key, {}).get("heuristic_only_until_n", 0)
        print(int(n))
    except Exception:
        print(0)


def cmd_decrement_cooldown(args: list[str]) -> None:
    ctx_key, state_raw = args[0], args[1]
    try:
        state = json.loads(state_raw)
        cds = state.get("cooldowns", {})
        if ctx_key in cds:
            n = int(cds[ctx_key].get("heuristic_only_until_n", 0))
            if n > 1:
                cds[ctx_key]["heuristic_only_until_n"] = n - 1
            else:
                del cds[ctx_key]
            state["cooldowns"] = cds
        print(json.dumps(state))
    except Exception:
        print(state_raw)


def cmd_parse_rd(args: list[str]) -> None:
    path = args[0]
    try:
        text = open(path).read()
        entries = parse_rd_yaml(text)
    except Exception:
        entries = []
    print(json.dumps(entries))


def cmd_update(args: list[str]) -> None:
    task_id, rd_raw, sc_raw, state_raw = args[0], args[1], args[2], args[3]
    try:
        rd_list = json.loads(rd_raw) if rd_raw.strip() else []
    except Exception:
        rd_list = []
    try:
        sc = json.loads(sc_raw) if sc_raw.strip() else {}
    except Exception:
        sc = {}
    try:
        state = json.loads(state_raw) if state_raw.strip().startswith("{") else {}
    except Exception:
        state = {}

    state.setdefault("arms", {})
    state.setdefault("cooldowns", {})
    state.setdefault("version", 1)
    state.setdefault("meta", {})

    # Idempotency guard: if this task_id was already applied, skip
    applied_tasks: list[str] = state["meta"].get("applied_task_ids", [])
    if task_id in applied_tasks:
        # Already applied — return state unchanged (idempotent)
        print(json.dumps(state))
        return

    composite = compute_reward(sc)
    reward_success = composite >= 0.5

    circuit_triggers: list[str] = []
    # PLUGIN-REVIEW-FIX-01 fix7: entries with source=="stub" are synthetic
    # placeholders written by phase8-close D-5a when route-decisions.yaml is
    # missing — they carry no real bandit_deviation/reward signal and must
    # never move alpha/beta counts.
    considered = 0
    stub_skipped = 0

    for entry in rd_list:
        ctx_key = entry.get("context_key", "")
        arm     = entry.get("chosen_arm", "")
        deviation = bool(entry.get("bandit_deviation", False))
        heuristic = entry.get("heuristic_arm", arm)
        if not ctx_key or not arm:
            continue
        considered += 1

        if entry.get("source") == "stub":
            stub_skipped += 1
            continue

        _ensure_arm(state, ctx_key, arm, heuristic)
        ab = state["arms"][ctx_key][arm]

        if reward_success:
            ab["alpha"] = int(ab.get("alpha", 1)) + 1
        else:
            ab["beta"] = int(ab.get("beta", 1)) + 1
        state["arms"][ctx_key][arm] = ab

        if deviation and not reward_success:
            circuit_triggers.append(ctx_key)

    if stub_skipped:
        print(f"WARN[bandit]: {stub_skipped} stub entries ignored", file=sys.stderr)
    if considered > 0 and stub_skipped == considered:
        print("update_result=skipped_stub", file=sys.stderr)

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for ctx_key in circuit_triggers:
        state["cooldowns"][ctx_key] = {
            "heuristic_only_until_n": 10,
            "written_at": now_iso,
            "reason": "deviation+failure",
        }

    # Decrement existing cooldowns (skip newly written)
    for ctx_key in list(state["cooldowns"]):
        if ctx_key in circuit_triggers:
            continue
        cd = state["cooldowns"][ctx_key]
        n = int(cd.get("heuristic_only_until_n", 0))
        if n <= 1:
            del state["cooldowns"][ctx_key]
        else:
            state["cooldowns"][ctx_key]["heuristic_only_until_n"] = n - 1

    # Record task_id as applied (idempotency guard); cap list at 500 to prevent unbounded growth.
    # F4 fix: when cap fires, write meta.last_purge_at + meta.last_purge_closed_at so callers
    # know the idempotency window shrank.  Replay risk: task_ids older than the purge boundary
    # could be double-applied; callers should not re-invoke update for closed_at < last_purge_closed_at
    # unless the task_id appears in the retained tail.
    applied_tasks.append(task_id)
    if len(applied_tasks) > 500:
        # Capture the oldest retained closed_at as watermark before slicing
        # so downstream can detect whether a replay candidate is within the safe window.
        purge_watermark = now_iso  # conservative: mark purge time
        applied_tasks = applied_tasks[-500:]
        state["meta"]["last_purge_at"] = purge_watermark
        state["meta"]["last_purge_size"] = 500
        # Emit warning to stderr so operators see it in logs
        import sys as _sys
        print(
            f"[leadv2-bandit] WARN: applied_task_ids capped at 500 — "
            f"idempotency window shrank; last_purge_at={purge_watermark}",
            file=_sys.stderr,
        )
    state["meta"]["applied_task_ids"] = applied_tasks

    print(json.dumps(state))


def cmd_stamp_meta(args: list[str]) -> None:
    state_raw, now_iso = args[0], args[1]
    try:
        state = json.loads(state_raw)
        state.setdefault("meta", {})
        state["meta"]["last_updated"] = now_iso
        state["meta"]["total_updates"] = int(state["meta"].get("total_updates", 0)) + 1
        state.setdefault("version", 1)
        print(json.dumps(state))
    except Exception:
        print(state_raw)


def cmd_rebuild(args: list[str]) -> None:
    sc_content, handoff_base = args[0], args[1]
    state: dict[str, Any] = {
        "version": 1, "arms": {}, "cooldowns": {},
        "meta": {"total_updates": 0},
    }

    rows: list[dict[str, Any]] = []
    for line in sc_content.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            pass

    # Deterministic: sort by closed_at
    rows.sort(key=lambda r: str(r.get("closed_at", "")))

    for row in rows:
        task_id = row.get("task_id", "")
        if not task_id:
            continue
        rd_path = os.path.join(handoff_base, task_id, "route-decisions.yaml")
        if not os.path.exists(rd_path):
            continue
        try:
            rd_list = parse_rd_yaml(open(rd_path).read())
        except Exception:
            continue

        composite = compute_reward(row)
        reward_success = composite >= 0.5

        for entry in rd_list:
            ctx_key  = entry.get("context_key", "")
            arm      = entry.get("chosen_arm", "")
            heuristic = entry.get("heuristic_arm", arm)
            if not ctx_key or not arm:
                continue
            _ensure_arm(state, ctx_key, arm, heuristic)
            ab = state["arms"][ctx_key][arm]
            if reward_success:
                ab["alpha"] = int(ab.get("alpha", 1)) + 1
            else:
                ab["beta"] = int(ab.get("beta", 1)) + 1
            state["arms"][ctx_key][arm] = ab
            state["meta"]["total_updates"] = state["meta"].get("total_updates", 0) + 1

    print(json.dumps(state))


# ── dispatch ──────────────────────────────────────────────────────────────────

CMDS = {
    "parse_yaml":          cmd_parse_yaml,
    "to_yaml":             cmd_to_yaml,
    "sample":              cmd_sample,
    "get_cooldown":        cmd_get_cooldown,
    "decrement_cooldown":  cmd_decrement_cooldown,
    "parse_rd":            cmd_parse_rd,
    "update":              cmd_update,
    "stamp_meta":          cmd_stamp_meta,
    "rebuild":             cmd_rebuild,
}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: leadv2-route-bandit-py.py <subcmd> [args...]", file=sys.stderr)
        sys.exit(1)

    subcmd = sys.argv[1]
    remaining = sys.argv[2:]

    if subcmd not in CMDS:
        print(f"unknown subcmd: {subcmd}", file=sys.stderr)
        sys.exit(1)

    try:
        CMDS[subcmd](remaining)
    except Exception as e:
        print(f"error in {subcmd}: {e}", file=sys.stderr)
        sys.exit(1)
