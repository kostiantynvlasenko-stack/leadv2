# PO Verify Mission Template

Use this template when invoking the Playwright verify agent for Phase C of `leadv2-po-feedback-loop`.

Substitute: `{FEATURE_NAME}`, `{COMMIT_SHA}`, `{PREPROD_URL}`, `{AUDIT_FILE}`, `{FIX_TABLE}`.

---

## Mission: Browser auto-verify {FEATURE_NAME} fixes on preprod

Commit `{COMMIT_SHA}` just pushed. Wait 90s for Vercel build before starting (Vercel preview takes 60-120s).

## Setup

```bash
source ~/MythicalGames/.envrc && echo $VERCEL_AUTOMATION_BYPASS_SECRET
```

Run Playwright from `/Users/kostiantyn.vlasenko/MythicalGames/m3/` with `{ chromium } from '@playwright/test'`.

Cookie bypass: navigate to `{PREPROD_URL}/?x-vercel-protection-bypass=<SECRET>&x-vercel-set-bypass-cookie=true`

If page shows "deployment is being created" — wait 30s and retry once.

## Checks (one per P0/P1 from audit)

Read the audit file first: `{AUDIT_FILE}`

For each P0 and P1 item, write a discrete Playwright check. Pattern:

```js
// Fix #N: <one-line description>
const el = page.locator('selector-here');
const found = await el.count() > 0;
const text = found ? await el.textContent() : null;
results.push({
  n: N,
  check: '<description>',
  status: found && text?.includes('<expected>') ? 'PASS' : 'FAIL',
  note: found ? `text="${text}"` : 'selector mismatch',
});
```

Take screenshot for each visual check: `/tmp/v-{FEATURE_NAME}-N.png`

## Verification table to fill

{FIX_TABLE}

(Auto-populated from audit P0+P1 items with verification strategies)

## Output format

```
| # | Check | Status | Note |
|---|---|---|---|
| 1 | <description> | PASS/FAIL/PARTIAL/INCONCLUSIVE | <one line> |
...

SUMMARY: X/N PASS, K FAIL, M PARTIAL, P INCONCLUSIVE
```

**Status meanings:**
- `PASS` — element exists AND has correct text/behavior
- `FAIL` — element missing OR wrong (provide possible cause: selector drift, deployment lag, fix not applied)
- `PARTIAL` — element present but degraded (e.g. styling weak, behavior incomplete)
- `INCONCLUSIVE` — cannot programmatically verify (canvas-rendered text, JS animation timing, multimodal UI). Note: capture screenshot, recommend manual review.

## Failure flagging

Mark each FAIL with:
- Possible cause: `selector drift` / `deployment lag` / `fix not applied` / `selector wrong`
- Screenshot path
- DOM snippet (`page.locator('parent').innerHTML()` for context)

Lead uses this to decide: re-spawn fix-round (cause = fix not applied) vs accept (cause = test issue).

## Mobile checks

If audit has mobile-specific items, do a separate context with viewport 375×812:
```js
const mobileCtx = await browser.newContext({ viewport: {width: 375, height: 812}, isMobile: true });
```

Same PASS/FAIL pattern.

## Time budget

- Total: 5-8 min
- Skip retries beyond 2 attempts per check
- If Vercel still building after 3 minutes of 503s → mark all checks INCONCLUSIVE with note "deployment not ready"
