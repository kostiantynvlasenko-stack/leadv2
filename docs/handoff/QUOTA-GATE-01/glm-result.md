# QUOTA-GATE-01 — real provider-owned quota gate for GLM lanes

**Date:** 2026-07-17 · **Author:** Claude (founder-direct mission)

Built a real, endpoint-backed quota gate on the z.ai number (superseding the
heuristic token-sum gauge `leadv2-quota-status.sh`, which was wrong by ~99.8%),
plus a live three-bucket reporter (GLM / Codex / Anthropic). Every number below
is the provider's own, read live. Tokens are never printed, logged, or cached.

## Files (canonical: `plugins/leadv2/scripts/`)
- `leadv2-quota-read.py` — credential-safe Python helper. One subcommand per
  bucket. Holds tokens in process memory only; cache files store normalized
  percentages, never tokens. Fails open to `unknown` on any error.
- `leadv2-quota-live.sh` — Bash wrapper. `report` (default) / `json` /
  `glm|codex|anthropic`. Each bucket independent.
- `leadv2-glm-quota-gate.sh` — the gate. ≥80% on 5h OR weekly ⇒ REROUTE; peak
  06:00–10:00 UTC ⇒ require `GLM_ALLOW_PEAK=1`; fail-open on its own failure.
- `glm-coder.sh` — patched: `glm_launch_gate()` called in `cmd_run` + `cmd_bg`
  (NOT `cmd_test`). Propagates the gate's exit code so the caller reroutes.

Propagated to all sync targets via `leadv2-plugin-sync.sh` (cache, leadv2-shared,
user-global, leadv2 vendored, persona-engine, m3-market, respiro-ios). The
user-global `~/.claude/scripts/glm-coder.sh` is the copy production actually
invokes (router L961, both workflow drivers, the no-opus hook all hardcode it)
but is **excluded from sync by design** (`leadv2-*` prefix only) — updated it
manually so the gate fires on the real dispatch path. See "Findings".

---

## Proof 1 — live GLM endpoint + parse (which window is which, by field)

```
$ curl -s -H "Authorization: Bearer $ZAI_AUTH_TOKEN" https://api.z.ai/api/monitor/usage/quota/limit
raw limits[]:
  type=TOKENS_LIMIT unit=3 number=5 pct=10  hours_until_reset=4.42    -> 2026-07-17T15:45Z
  type=TOKENS_LIMIT unit=6 number=1 pct=2   hours_until_reset=167.17  -> 2026-07-24T10:30Z
  type=TIME_LIMIT   unit=5 number=1 pct=1   hours_until_reset=407.17  -> 2026-08-03T10:45Z
DECISION: among type=TOKENS_LIMIT, hours_until_reset<36 => 5h window; >=36 => weekly.
```
Identification is by **`nextResetTime` distance from now** (threshold 36h), not
array index — reorder-safe. The `TIME_LIMIT` entry is the search/web-reader
credit counter (1000 total, separate budget), excluded from the token gate.
(Glance fields `unit`/`number` corroborate: `unit=3,number=5`→5h, `unit=6,number=1`→weekly.)

## Proof 2 — gate allow (<80) and refuse (≥80, threshold forced)

```
$ ./leadv2-glm-quota-gate.sh            # live 5h=10% / weekly=2%, both < 80
[glm-quota-gate] OK — GLM quota has headroom: 5h=10% (resets 2026-07-17T15:45:44Z) / weekly=2% (resets 2026-07-24T10:30:44Z). Threshold=80%. Lane may start.
>>> exit=0

$ GLM_QUOTA_THRESHOLD=5 ./leadv2-glm-quota-gate.sh   # force the refuse path
[glm-quota-gate] REROUTE — GLM quota ≥ 5% on: 5h=10% (resets 2026-07-17T15:45:44Z) AND weekly=2% (resets 2026-07-24T10:30:44Z).
  ... Fallback preference (SNAPSHOT 2026-07-17): 1. Sonnet via Anthropic Max ...
  NOTE: ... the spawn must carry the approved exception id: glm_quota_gate_80 ...
>>> exit=1
```
Refuse names current % on both windows, human-readable reset time, the fallback
ranking, and the `glm_quota_gate_80` exception id the parallel
`leadv2-glm-first-agent-gate.sh` hook will honor. The lane **reroutes, it does
not stop** — exit non-zero signals the caller to use another bucket.

## Proof 3 — peak path (simulated clock)

```
$ GLM_SIMULATE_UTC_HOUR=7 ./leadv2-glm-quota-gate.sh     # peak, no override
[glm-quota-gate] PEAK HOURS — GLM-5.2 costs 3× during 06:00–10:00 UTC (14:00–18:00 UTC+8).
  Peak ends in ~169 min (at 10:00 UTC). Quota is fine (5h=10% / weekly=2%) ...
  For a genuine P0: re-run with GLM_ALLOW_PEAK=1. Otherwise wait until 10:00 UTC.
>>> exit=2

$ GLM_SIMULATE_UTC_HOUR=7 GLM_ALLOW_PEAK=1 ./leadv2-glm-quota-gate.sh
[glm-quota-gate] PEAK OVERRIDE active (GLM_ALLOW_PEAK=1): running at 3× cost. Peak ends in ~169 min. ...
[glm-quota-gate] OK — GLM quota has headroom: ... Lane may start.
>>> exit=0
```
Peak = warn + require override (not a hard block — a P0 can still run).

## Proof 4 — fail-open (unreachable host; malformed JSON)

```
$ LEADV2_ZAI_QUOTA_URL=https://does-not-resolve-leadv2-test.invalid/... ./leadv2-glm-quota-gate.sh
[glm-quota-gate] FAIL-OPEN: GLM quota read is unknown (fetch/parse: <urlopen error [Errno 8] nodename nor servname provided, or not known>). Cannot gate on a number we do not have — lane may start.
>>> exit=0
```
Network failure, 5xx, and malformed JSON all → `exit 0` with the error on stderr.
Never `2>/dev/null` — silent failure reads identical to silent success.

## Proof 5 — glm-coder.sh wiring + all copies match

`glm-coder.sh` calls the gate via `glm_launch_gate()` (defined after the log
helpers) in `cmd_run` (L277) and `cmd_bg` (L1017); `cmd_test` is intentionally
**not** gated (health check). End-to-end from the production path:

```
$ GLM_QUOTA_THRESHOLD=1 ~/.claude/scripts/glm-coder.sh run "should-never-launch"
[glm-quota-gate] REROUTE — GLM quota ≥ 1% on: 5h=7% ...
>>> exit=1            # launch blocked, no /tmp/glm-coder-*.out created
```
sha256 of all 4 files across the 6 sync targets (canonical, cache, leadv2-shared,
leadv2-vendored, persona-engine, m3-market, respiro-ios, user-global): **all
MATCH canonical**. (glm-coder.sh in user-global was stale by design — see
Findings — and was hand-synced; now matches.)

**Bug caught and fixed during build:** the first wiring used `if ! "$gate"`,
whose `!` resets `$?` to 0 — a refused gate silently did **not** block (it leaked
one throwaway `claude` call, since cleaned up). Replaced with `"$gate"; rc=$?`
capturing the real code. Re-test confirmed a refuse now creates no out-file and
spawns no process.

## Proof 6 — three buckets live (cross-check vs founder console ~10:30Z)

```
$ ./leadv2-quota-live.sh --no-cache
GLM (z.ai, pro):       5h=10% | weekly=2%
Codex (plus):          74% used (26% remaining) | resets 2026-07-23 | credits: NONE (balance 0)
Anthropic (team):      5h=16% | weekly=8%
Anthropic (max, 20×):  5h=8%  | weekly=41%
```
Cross-check: Codex **26% remaining** (console: 27% ✓). Anthropic Max **weekly
41%** (console: 40% ✓; session 8% vs console 2% an hour earlier — usage grew, as
expected). GLM has reset low since the brief was written (brief: 5h 72–77% /
weekly 52%); structure verified independently in Proof 1. Nothing reports `0` or
`100`; `unknown` is used for any failed read.

## Proof 7 — one bucket down ≠ all buckets down

```
$ CODEX_HOME=<tmpdir with broken auth.json> ./leadv2-quota-live.sh --no-cache
GLM (z.ai, pro):       5h=10% | weekly=2%
Codex (ChatGPT):       UNKNOWN — refresh http 401 — needs `codex login`
Anthropic (team):      5h=16% | weekly=8%
Anthropic (max, 20×):  5h=8%  | weekly=41%
```
Codex's 401 blanks only Codex. GLM and Anthropic report independently.

---

## Conclusion — Codex: BUILT (fully)

Refresh-token OAuth against `https://auth.openai.com/oauth/token`
(`client_id=app_EMoamEEZ73f0CkXaXp7hrann`) → `chatgpt.com/backend-api/wham/usage`.
`rate_limit.primary_window.used_percent` reported verbatim (74% used = 26%
remaining); `limit_window_seconds=604800` (weekly), `credits.has_credits=false`.
**Refresh rotates the refresh_token on every call**, so the helper writes the new
token back to `~/.codex/auth.json` (atomic, `chmod 600`, structure preserved) —
verified; without write-back the refresh chain dies after one read. No human step
needed; only if a refresh itself 401s does it say `needs codex login`.

## Conclusion — Anthropic: BUILT (fresh-token path; DPoP refresh documented as unwired)

`https://api.anthropic.com/api/oauth/usage` works with a **fresh Bearer access
token — no DPoP proof needed for the resource server.** The founder's brief
assumed the only token (`Claude Code-credentials`, expired 2026-02-20) needed a
refresh. In fact the keychain carries several `Claude Code-credentials*` entries;
the **hex-suffixed** ones hold tokens the running CLI refreshes in-process
(8 h life). The helper scans every such entry, uses those whose `expiresAt >
now`, and reports each (here: a `team` account and the `max` 20× account). 429 →
`unknown`, never 0. Percentages come from the response (`five_hour.utilization`,
`seven_day.utilization`, `limits[]`), never from the `rateLimitTier` field (which
is stale on the team account: it reads `5x` while the entry is `team`).

**Why DPoP refresh is not wired:** a stale-token refresh requires a DPoP
(ES256/EC-P-256) proof against `https://platform.claude.com/v1/oauth/token`
(client_id is the URL `https://claude.ai/oauth/claude-code-client-metadata`,
`token_endpoint_auth_method:"none"`). The DPoP private JWK lives in the CLI's
Electron safe-storage (not plainly accessible); stdlib can't sign ES256, though
`cryptography 44.0.3` is installed and could. This is **not a gap in practice**:
the gate is always invoked from inside a live Claude session (`glm-coder.sh`),
which keeps a fresh in-process token present, so the fresh-token path covers the
real operating window. If no fresh token exists, the bucket reports `unknown`
with the reason and additionally surfaces any `rate_limit_info` previously
captured into `history.db` kv (`rate_limit_anthropic`) as a secondary signal —
the same kv the existing gauge already scaffolds. Wiring the aggregator to
*write* that kv as responses flow past is the separate risk-bearing change the
existing gauge comment scopes out; the read side is wired here.

## Findings / notes for the founder
1. **Dispatch hardcodes `~/.claude/scripts/glm-coder.sh`, but `leadv2-plugin-sync.sh`
   excludes non-`leadv2-*` files from user-global.** So that copy drifts silently.
   Hand-synced it this run; a durable fix is to either add `glm-coder.sh` to the
   user-global sync allowlist or stop hardcoding the user-global path in
   router/workflows — your call (shared-tree edit, needs your OK).
2. **The stale `Claude Code-credentials` keychain entry (sub=max, expired
   2026-02-20) is dead weight** — the live accounts are the hex-suffixed entries.
   Not deleted (credential work; flagging only).
3. The old heuristic gauge (`leadv2-quota-status.sh`) is untouched and still
   passes its regression test (`test-quota-glm-filter.sh`, 6/6). It is now
   superseded but left in place; removing it is a separate decision.
4. `GLM_QUOTA_THRESHOLD`, `GLM_SIMULATE_UTC_HOUR`, `GLM_SKIP_QUOTA_GATE`,
   `GLM_ALLOW_PEAK`, `LEADV2_ZAI_QUOTA_URL` are intentional test/ops knobs.

DELIVERABLE_COMPLETE
