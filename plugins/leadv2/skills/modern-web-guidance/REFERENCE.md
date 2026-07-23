# Background & Baseline Status Reference

## Why this skill

Training weights for Claude/GPT contain web patterns that are 1–3 years stale. Native APIs that
shipped in 2024–2025 (Popover API, `field-sizing`, scroll-driven animations, View Transitions,
`:user-invalid`, anchor positioning, fetch priority) are often missed in favor of heavier JS/CSS
solutions. Google measured **+37 percentage points** of best-practice compliance when agents use
this skill before writing UI code.

## Interpreting Baseline status

- **Widely available** (30+ months) — use without fallback
- **Newly available** (<30 months) — use with progressive enhancement; provide a no-feature fallback
- **Limited availability** — use only if the project's baseline policy explicitly allows it

If the project's `AGENTS.md`, `CLAUDE.md`, or `.claude/leadv2-overrides/stack.yaml` defines a baseline
target (e.g. "Baseline 2024"), honor it.

## Links

- Upstream skill: https://github.com/GoogleChrome/modern-web-guidance
- Documentation: https://developer.chrome.com/docs/modern-web-guidance
- Baseline definition: https://web.dev/baseline
