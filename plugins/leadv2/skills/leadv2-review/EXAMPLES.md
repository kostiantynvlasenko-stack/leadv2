# Anti-patterns

- Running Codex Round 2 after 0 Critical — burns tokens for nothing (CX-01).
- Spawning critic(opus) on every task regardless of safety touch — Opus is for risk-heavy only.
- Merging "just style nits" after Round 1 clean — don't over-engineer; skip to deploy.
- Calling architect(opus) for alt approach on Round 1 failures — that's Round 2's job first.
- Passing full file paths to reviewers without the diff — diff-first saves >50% reviewer tokens.
- Skipping hack-detection — it runs in parallel and is always cheap.
- Skipping the low-risk pre-check — Light+low-risk tasks should never hit review overhead.
