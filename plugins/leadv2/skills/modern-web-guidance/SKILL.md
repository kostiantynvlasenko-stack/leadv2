---
name: modern-web-guidance
description: Google Chrome modern-web guidance for frontend code; run before changing HTML, CSS, client JS, UI APIs, forms, motion, or web performance.
when_to_use: Frontend files or plans only; never backend, infrastructure, SQL, CI/CD, or generic shell tasks.
---

# modern-web-guidance

Wrapper around Google Chrome's `modern-web-guidance` CLI. Searches and retrieves best-practice
guides for modern Web APIs (Baseline-aware, framework-agnostic). Runs offline via TensorFlow.js
semantic search; no API keys, no network beyond first-run npx cache.

**Self-guard (MUST check first):**
If the current task does not touch any of `*.tsx | *.ts | *.jsx | *.css | *.html | web/ | frontend/ | apps/main/ | apps/dashboard/ | apps/admin/`, immediately return:
> "modern-web-guidance: not applicable (task does not involve frontend code)"
and skip the rest of this skill. Do not invoke `npx`.

## Why this skill

Training weights for Claude/GPT contain web patterns that are 1-3 years stale. Native APIs that
shipped in 2024-2025 (Popover API, `field-sizing`, scroll-driven animations, View Transitions,
`:user-invalid`, anchor positioning, fetch priority) are often missed in favor of heavier JS/CSS
solutions. Google measured **+37 percentage points** of best-practice compliance when agents use
this skill before writing UI code.

## Step 1 — Search

Build an action-oriented query summarizing what you want to achieve.

```bash
npx -y modern-web-guidance@latest search "<query>"
```

**Examples of good queries:**
- `"animate dialog modal entry from top layer"`
- `"validate form input only after user interaction"`
- `"optimize LCP image loading priority"`
- `"prefetch next page on hover"`
- `"autosize textarea to content"`

Returns JSON array with `{id, description, category, featuresUsed[], tokenCount, similarity}`.
Top hits typically score >0.6 similarity. If all hits <0.5, broaden the query or fall back to:

```bash
npx -y modern-web-guidance@latest list
```

## Step 2 — Retrieve

Once you have a relevant `id`, retrieve the full guide (markdown with implementation steps and
Baseline-aware fallbacks):

```bash
npx -y modern-web-guidance@latest retrieve "<id>"
```

Multiple IDs comma-separated also work: `retrieve "id1,id2"`.

## Step 3 — Apply

The guide contains:
- **What** — the modern API and its Baseline status (Widely available / Newly available / Limited)
- **How** — copy-pasteable implementation (HTML/CSS/JS, framework-agnostic)
- **Fallback** — what to do if your project's target baseline doesn't support the feature

Adapt the snippet to the project's framework (Next.js RSC, Tailwind v4, shadcn) but **do not**
swap the native API for a JS library unless the guide explicitly says to.

## Failure modes

- **Offline / first-run cache miss** — `npx` downloads ~30MB of TensorFlow.js on first call. If
  offline and no cache, fall back to: `npx --offline modern-web-guidance@latest search "..."`. If
  that also fails, warn in the log ("modern-web-guidance unavailable, proceeding with training-weights
  patterns") and continue — do not block the phase.
- **Search returns nothing relevant (all similarity <0.4)** — the project likely needs a custom
  pattern not in Baseline; proceed with framework-specific best practice.
- **Triggered on non-web task** — self-guard above should catch this; if you got here anyway, return
  "not applicable" without invoking npx.

## Interpreting Baseline status

- **Widely available** (30+ months) — use without fallback
- **Newly available** (<30 months) — use with progressive enhancement; provide a no-feature fallback
- **Limited availability** — use only if the project's baseline policy explicitly allows it

If the project's `AGENTS.md`, `CLAUDE.md`, or `.claude/leadv2-overrides/stack.yaml` defines a baseline
target (e.g. "Baseline 2024"), honor it.

## Reference

- Upstream skill: https://github.com/GoogleChrome/modern-web-guidance
- Documentation: https://developer.chrome.com/docs/modern-web-guidance
- Baseline definition: https://web.dev/baseline
