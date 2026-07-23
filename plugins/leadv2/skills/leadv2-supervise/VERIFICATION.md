# Verification & Testing

Pre-deployment test coverage for leadv2-supervise functionality.

## Test Suites

### B1: Fail-closed root/registry/state-write unit tests

**Script:** `plugins/leadv2/scripts/tests/test-supervise-failclosed.sh`

Tests core reliability: root-permission gating, registry initialization, and atomic state writes. Validates that permission failures and broken state do not cause silent cascades.

### D-d + SUPERVISE-V2: Full reconciliation & loop behavior

**Script:** `plugins/leadv2/tests/test-supervise-v2.sh` (SUPERVISE-V2-01 item 6)

Validates the complete supervise machinery:
- Loop cadence and lane ceiling limits
- Pick-script ranking schema correctness
- Tmux triple-proof adoption matrix (window name + PID descent + corroboration)
- Tombstone-before-prune ordering (dead lane safety)
- Observe-only visibility: `would_adopt` / `would_prune` never drop an eligible candidate, even when the action itself is suppressed
- Truth-probe timeout → unavailable transition

### Session routing: Provider & model assignment

**Script:** `plugins/leadv2/scripts/tests/test-session-route.sh`

Validates deterministic provider/model decisions:
- Light/Standard candidates route to Codex when available; Heavy/Strategic stay on Claude/Opus
- Quota fallback chain (Codex unavailable → Claude; Opus quota dry → Sonnet)
- High-risk fail-closed cases (never Codex for security-sensitive work)

### Codex runner: Fresh + resume semantics

**Script:** `plugins/leadv2/scripts/tests/test-codex-session-runner.sh`

Validates the provider-neutral runner (used by both Claude and Codex lanes):
- Fresh launch creates a new Codex session and passes `/leadv2 <task-id>`
- Resume finds and re-enters an existing session by task-id
- Completion sentinel: the runner requires the common Phase-8 `phase8-passed.flag` to declare victory
- Provider receipts persist to `active.yaml` (auditable trail)

## Run Before Deployment

Run both test suites before relying on the watch loop in a real session:

```bash
# Unit tests (fast, <2min)
plugins/leadv2/scripts/tests/test-supervise-failclosed.sh
plugins/leadv2/scripts/tests/test-session-route.sh
plugins/leadv2/scripts/tests/test-codex-session-runner.sh

# Integration tests (slower, ~5-10min; requires live active.yaml + tmux)
plugins/leadv2/tests/test-supervise-v2.sh
```

All tests must pass (exit 0) before a supervise session is safe for production use.
