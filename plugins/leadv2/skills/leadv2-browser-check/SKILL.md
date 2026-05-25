---
name: leadv2-browser-check
description: Headless-browser inspection of a deployed page — load URL, optionally interact (click filters, fill inputs), capture network requests, console errors, UI state. Use when founder reports a UI/network issue and screenshots are not enough OR when lead needs to verify a fix on preprod without asking founder.
when_to_invoke: |
  - Founder reports filter/page issue ("loading forever", "wrong data", "doesn't work") and screenshots
    don't show network details
  - Lead needs to confirm a deploy actually works end-to-end on preprod (BE + FE wired)
  - Need to check actual /api/* request body/response or console errors on a deployed page
  - DO NOT use for: design polish, layout review, anything visual (founder screenshot is cheaper)
  - DO NOT use as a daily replacement for founder verification — token cost ~1-3K per call
---

# leadv2-browser-check

Headless Chrome inspection of a deployed (or local) URL via Playwright. Captures
network + console without needing the founder to take screenshots.

## Prereqs (one-time per machine)

```bash
# Install playwright + chromium under the plugin (not the project)
cd ~/.claude/plugins/local/leadv2/plugins/leadv2/scripts && \
  ([ -d node_modules/playwright ] || npm i playwright) && \
  npx playwright install chromium
```

If `chromium-headless-shell` already exists in `~/Library/Caches/ms-playwright/`,
`npx playwright install chromium` is a no-op.

## Usage

```bash
node ~/.claude/plugins/local/leadv2/plugins/leadv2/scripts/leadv2-browser-check.mjs <url> [interaction]
```

`interaction` is one of:

| key | what it does |
|---|---|
| `none` (default) | Just load URL, capture initial network + UI state |
| `rarity-leg` | Click "Legendary" rarity filter (checkbox or pill) |
| `health-range` | Fill Min=10, Max=90 in health/jump range slider |

Output is JSON to stdout:

```json
{
  "ok": true,
  "url": "...",
  "interaction": "rarity-leg",
  "ui": { "loading": false, "empty": false, "cardCount": 12, "chipCount": 2 },
  "requests": [
    { "method": "GET", "url": "/api/games/.../collections?...&filter=eyJ...", "at": "request" },
    { "status": 200, "url": "/api/games/...", "body": "{...truncated 500 chars...}", "at": "response" }
  ],
  "consoleErrors": [ { "type": "error", "text": "..." } ],
  "pageErrors": []
}
```

## Adding new interactions

Edit `~/.claude/plugins/local/leadv2/plugins/leadv2/scripts/leadv2-browser-check.mjs`,
add a new branch in the `if (interaction === '...')` block. Use Playwright
locators (`page.getByRole`, `page.getByLabel`, `page.getByTestId`) — never CSS
selectors.

## Cost discipline

- ~1-3K tokens per call (JSON output is ~30-100 lines).
- Founder screenshot is ~0 tokens — prefer it when feasible.
- Use this skill only when network/console inspection is essential.
- DO NOT loop or poll with this script — single call per investigation.

## Auth-gated pages

Default mode is headless + no cookies. If the page requires Privy auth, the
script will show a 401/403 in console errors. For auth-required investigation,
either:

1. Test the API directly with `curl` + an auth cookie from `~/.envrc`
2. Or extend the script to load a saved storage state (Playwright `storageState`
   parameter on `newContext`). Not done by default — add only if needed.

## When NOT to use

- Visual issues — founder screenshot is more informative
- Quick API checks — `curl` against the endpoint is faster
- Anything that requires logging in
- Mid-deploy verification — wait for deploy to finish first
