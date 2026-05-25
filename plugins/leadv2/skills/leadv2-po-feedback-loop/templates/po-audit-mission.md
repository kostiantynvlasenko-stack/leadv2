# PO Audit Mission Template

Use this template when invoking architect-opus for Phase A of `leadv2-po-feedback-loop`.

Substitute placeholders: `{FEATURE_NAME}`, `{PREPROD_URL}`, `{TASK_DIR}`, `{KEY_FLOWS}`, `{DOMAIN_BENCHMARKS}`, `{LOCAL_BASELINE_SKILL}`.

---

## Mission: PO UX Audit — {FEATURE_NAME}

You are a senior Product Owner doing a holistic UX review of the {FEATURE_NAME} on preprod. Your goal: identify what's working, broken, missing, and produce a **prioritized list of improvements** to make this best-in-class.

**MANDATORY: Write the deliverable file before exiting.** Use the Write tool. Do not exit with the file unwritten.

## Setup

```bash
source ~/MythicalGames/.envrc && echo $VERCEL_AUTOMATION_BYPASS_SECRET
```

Run Playwright from `/Users/kostiantyn.vlasenko/MythicalGames/m3/` (or persona-engine root) with:
```js
import { chromium } from '@playwright/test';
```

Cookie bypass first: navigate to `{PREPROD_URL}/?x-vercel-protection-bypass=<SECRET>&x-vercel-set-bypass-cookie=true`

If page shows Vercel deployment-pending, wait 30s and retry once.

## What to audit (capture screenshots + DOM)

For EACH key flow `{KEY_FLOWS}`:

### Capture all states
- **Loaded** — feature rendered with real data (`/tmp/po-{FEATURE_NAME}-loaded.png`)
- **Empty** — find data path with 0 results / fresh user (`/tmp/po-{FEATURE_NAME}-empty.png`)
- **Loading** — throttle network in Playwright to capture skeleton (`/tmp/po-{FEATURE_NAME}-loading.png`)
- **Error** — induce error if possible (broken filter / bad URL param) (`/tmp/po-{FEATURE_NAME}-error.png`)
- **Mobile 375×812** — viewport switch (`/tmp/po-{FEATURE_NAME}-mobile.png`)

### Inspect DOM
- Heading hierarchy (h1/h2/h3 order)
- Touch targets (button/anchor sizes ≥44px on mobile)
- ARIA labels, role, aria-sort, aria-describedby
- Loading skeleton vs spinner
- Empty-state copy + CTA
- Error-state with retry path

### Walk user flows
- Entry → primary CTA → expected outcome
- Edge cases: disabled state, partial data, slow network
- Mobile: drawer/sheet open + content visibility

## Analysis framework

Compare against THREE benchmarks:

**1. Domain benchmarks ({DOMAIN_BENCHMARKS})**
- For NFT marketplace: OpenSea, Blur, Magic Eden patterns
- For SaaS dashboard: Linear, Stripe, Vercel
- For consumer app: top 3 in App Store category
- Cite specific patterns: "OpenSea shows 24h volume delta as colored badge"

**2. Local design baseline ({LOCAL_BASELINE_SKILL})**
- Detect via Glob — if `m3-nft-design/QUICKREF.md` exists use that, else `emil-design-engineering/SKILL.md`, else `frontend-design/QUICKREF.md`
- Color system, typography scale, spacing tokens
- Tonal surfaces, accent usage rules (e.g. m3: single Electric Blue, no purple)

**3. Modern Web Guidance**
- Invoke skill `leadv2:modern-web-guidance` for current best practices
- Contrast ratios (WCAG AA 4.5:1 for body text)
- Touch targets ≥44×44px on mobile
- `dvh` not `vh` for full-height (iOS chrome)
- Container queries vs media queries
- Scroll-driven animations, View Transitions where applicable
- ARIA semantics + keyboard navigation

## Deliverable

Write `{TASK_DIR}/po-audit-{FEATURE_NAME}.md` using THIS structure (keep under 70 lines total):

```markdown
# PO Audit — {FEATURE_NAME}
## Date: YYYY-MM-DD

URL audited: {PREPROD_URL}/...

## What's working well ✅
- (3-5 specific things that should NOT be regressed)

## Critical gaps 🔴 (P0 — max 5, blocks "best-in-class")
1. **<specific UI element + problem>** — <one-sentence fix> **<S/M/L effort>**
2. ...

## High-value improvements 🟡 (P1 — max 6, significant UX win)
1. ...

## Nice-to-haves 🟢 (P2 — max 4, polish)
1. ...

## Screenshots
- `/tmp/po-{FEATURE_NAME}-loaded.png`
- ...
```

Be specific. Instead of "improve cards", say "Collection cards missing 24h volume delta — add `+5.2%` badge in green next to floor price (OpenSea pattern, data already in API as `price_change_7d_pct`)".

## Quality bar

- Each finding cites: specific UI element + concrete fix code/pseudocode + effort estimate
- P0 = ship-blocking. P1 = noticeably better. P2 = nice polish.
- Max 5 P0. If you find more, the bar is wrong — re-evaluate.
- No vague language: "more readable" → "increase contrast from white/40 to white/60"
