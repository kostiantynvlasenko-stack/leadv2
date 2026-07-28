# Session runner turn-cap fix

FIX-SESSION-RUNNER-TURNCAP-01 raises Claude's default per-attempt cap from 30
to 60 turns. This gives a nine-phase Heavy pipeline enough tool-turn headroom;
`LEADV2_CLAUDE_MAX_TURNS` remains the lane-specific override.

The runner parses each attempt's stream-JSON terminal records. A record whose
`num_turns` meets the configured cap is logged as turn-cap exhaustion, not a
crash, and the next attempt resumes the same session with a fresh budget.

Before attempt zero and every subsequent launch, the runner reuses
`_leadv2_derive_real_state` and checks both Phase-8 proof and the E2E gate
completion flag. Either durable signal prevents a needless relaunch.

Regression test: `plugins/leadv2/scripts/tests/test-session-runner-turncap.sh`.
