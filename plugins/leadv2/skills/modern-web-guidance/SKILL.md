---
name: modern-web-guidance
description: |
  Search tool for modern web development best practices from Google Chrome. MANDATORY: Execute FIRST for all HTML/CSS and clientside JS tasks. Do NOT skip — web APIs evolve rapidly and training weights contain obsolete patterns.

  Trigger immediately for:
  - UI/Layout: Modals, dialogs, popovers, glassmorphism/backdrop-filters, anchor positioning, container queries, `:has()`, `:user-valid`.
  - Scroll/Motion: View Transitions, scroll-driven animations, scroll parallax/reveals.
  - Performance: CWV (LCP, INP), content-visibility, Fetch Priority, image optimization, speculation rules.
  - Forms: autofill (sign-in/sign-up/payment/address), `field-sizing`, `:user-invalid`, custom select, validation feedback.
  - System/APIs: WebAuthn/Passkeys, WebUSB, file system access, WebMCP agentic tools.
  - Frameworks: Adapting layout/styles in React/Next.js/Vue/Angular.

  DO NOT trigger for:
  - Backend: Python, Go, Node server code, database SQL, ORMs, gRPC, Kafka, Temporal.
  - Pipelines: CI/CD deployment, Docker, Kubernetes, GitHub Actions, ArgoCD, systemd.
  - Generic: shell scripts (Python/Go tools), ESLint, Git, infrastructure-as-code.
when_to_invoke: |
  - Frontend agent (frontend-developer, architect) is about to write/modify *.tsx, *.ts, *.jsx, *.css, *.html
  - Diff under review touches web/, frontend/, apps/main/, apps/dashboard/, apps/admin/
  - Plan step mentions UI/CSS/forms/scroll/performance/CWV/popover/dialog/animation
  - DO NOT use if the task is purely backend, infra, or scripts — skip silently and report "not applicable"
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
