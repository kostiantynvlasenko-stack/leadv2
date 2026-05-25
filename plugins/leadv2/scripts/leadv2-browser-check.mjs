#!/usr/bin/env node
// Quick browser check for preprod — load page, capture network + console, report
// Usage: node preprod-browser-check.mjs <url> [interaction-id]
//
// Interactions:
//   none           — just load page and capture initial network
//   rarity-leg     — click Rarity > Legendary checkbox/pill
//   health-range   — set health range slider 10-90
//
// Output: JSON to stdout with { console: [...], requests: [...], errors: [...] }
// Only logs API requests (to /api/) and errors. Strips noise.

import { chromium } from 'playwright';

const url = process.argv[2] || 'https://peng-190-collection-grid.m3.mythical.work/game/pudgy-party?view=collections';
const interaction = process.argv[3] || 'none';

const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ viewport: { width: 1400, height: 900 } });
// Vercel SSO bypass via Protection-Bypass-For-Automation secret.
// Append the query params to the initial URL — Vercel sets a cookie so subsequent
// navigations stay authenticated.
let initUrl = url;
if (process.env.VERCEL_AUTOMATION_BYPASS_SECRET) {
  const sep = initUrl.includes('?') ? '&' : '?';
  initUrl = `${initUrl}${sep}x-vercel-set-bypass-cookie=samesitenone&x-vercel-protection-bypass=${process.env.VERCEL_AUTOMATION_BYPASS_SECRET}`;
}
const page = await ctx.newPage();

const requests = [];
const consoleMessages = [];
const errors = [];

page.on('request', (req) => {
  const u = req.url();
  if (u.includes('/api/') && !u.includes('analytics') && !u.includes('vercel')) {
    requests.push({ method: req.method(), url: u.replace(/^https?:\/\/[^/]+/, ''), at: 'request' });
  }
});

page.on('response', async (resp) => {
  const u = resp.url();
  if (u.includes('/api/') && !u.includes('analytics') && !u.includes('vercel')) {
    const status = resp.status();
    let body = null;
    try {
      if (status >= 400 || resp.request().method() === 'GET') {
        const txt = await resp.text();
        body = txt.length > 500 ? txt.slice(0, 500) + '...' : txt;
      }
    } catch (e) { /* ignore */ }
    requests.push({ status, url: u.replace(/^https?:\/\/[^/]+/, ''), body, at: 'response' });
  }
});

page.on('console', (msg) => {
  const type = msg.type();
  if (type === 'error' || type === 'warning') {
    consoleMessages.push({ type, text: msg.text().slice(0, 300) });
  }
});

page.on('pageerror', (err) => {
  errors.push({ message: err.message.slice(0, 300) });
});

try {
  await page.goto(initUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  // Wait for at least one collections list response, then settle 2s more
  await page.waitForResponse((r) => r.url().includes('/api/services/market/games/') && r.url().includes('/collections') && r.status() === 200, { timeout: 20000 }).catch(() => {});
  await page.waitForTimeout(2500);

  if (interaction === 'rarity-leg') {
    // Try checkbox first, then pill button
    const cb = page.getByLabel('Legendary', { exact: false });
    if (await cb.count() > 0) {
      await cb.first().click({ timeout: 5000 });
    } else {
      await page.getByRole('button', { name: 'Legendary' }).click({ timeout: 5000 });
    }
    await page.waitForTimeout(3000); // wait for filter to apply
  } else if (interaction === 'health-range') {
    // set health range via min/max inputs
    const minInput = page.getByLabel('Min').first();
    const maxInput = page.getByLabel('Max').first();
    await minInput.fill('10');
    await maxInput.fill('90');
    await page.waitForTimeout(3000);
  }

  // Capture key UI signals
  const grid = await page.locator('text=Loading collections').count();
  const empty = await page.locator('text=No collections').count();
  const cards = await page.locator('[data-testid="collection-card"], a[href*="/collection/contract/"]').count();
  const chips = await page.locator('text=/×/').count();

  console.log(JSON.stringify({
    ok: true,
    url,
    interaction,
    ui: { loading: grid > 0, empty: empty > 0, cardCount: cards, chipCount: chips },
    requests,
    consoleErrors: consoleMessages,
    pageErrors: errors,
  }, null, 2));
} catch (e) {
  console.log(JSON.stringify({ ok: false, error: e.message, requests, consoleErrors: consoleMessages, pageErrors: errors }));
} finally {
  await browser.close();
}
