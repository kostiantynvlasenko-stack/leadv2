---
name: modern-web-guidance
description: Google Chrome modern-web guidance for frontend code; run before changing HTML, CSS, client JS, UI APIs, forms, motion, or web performance.
when_to_use: Frontend files or plans only; never backend, infrastructure, SQL, CI/CD, or generic shell tasks.
---

# modern-web-guidance

Offline semantic search for modern Web APIs (Baseline-aware, framework-agnostic).
No API keys or network beyond first-run npx cache.

**Self-guard (MUST check first):**
If the current task does not touch any of `*.tsx | *.ts | *.jsx | *.css | *.html | web/ | frontend/ | apps/main/ | apps/dashboard/ | apps/admin/`, immediately return:
> "modern-web-guidance: not applicable (task does not involve frontend code)"

and skip the rest of this skill. Do not invoke `npx`.

## Step 1 — Search

Build an action-oriented query summarizing what you want to achieve.

```bash
npx -y modern-web-guidance@latest search "<query>"
```

Examples of good queries:
- `"animate dialog modal entry from top layer"`
- `"validate form input only after user interaction"`
- `"optimize LCP image loading priority"`
- `"prefetch next page on hover"`
- `"autosize textarea to content"`

Returns JSON array with `{id, description, category, featuresUsed[], tokenCount, similarity}`.
Top hits typically score >0.6 similarity. If all hits <0.5, broaden the query or use:

```bash
npx -y modern-web-guidance@latest list
```

## Step 2 — Retrieve

Retrieve the full guide (markdown with implementation steps and Baseline-aware fallbacks):

```bash
npx -y modern-web-guidance@latest retrieve "<id>"
```

Multiple IDs comma-separated also work: `retrieve "id1,id2"`.

## Step 3 — Apply

The guide contains **What** (the modern API and Baseline status), **How** (copy-pasteable implementation, framework-agnostic), and **Fallback** (what to do if your baseline doesn't support it).

Adapt the snippet to the project's framework (Next.js RSC, Tailwind v4, shadcn) but **do not** swap the native API for a JS library unless the guide explicitly says to.

For Baseline status interpretation and target baseline policy, see [REFERENCE.md](./REFERENCE.md).

## Failure modes

- **Offline / first-run cache miss** — `npx` downloads ~30MB of TensorFlow.js on first call. If offline and no cache, try: `npx --offline modern-web-guidance@latest search "..."`. If that also fails, warn ("modern-web-guidance unavailable, proceeding with training-weights patterns") and continue — do not block the phase.
- **Search returns nothing relevant** (all similarity <0.4) — the project likely needs a custom pattern not in Baseline; proceed with framework-specific best practice.
- **Triggered on non-web task** — self-guard above should catch this; if triggered anyway, return "not applicable" without invoking npx.
