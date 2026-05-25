---
name: auth-cookie-setup
description: Founder-facing guide — how to extract a Supabase session cookie from the browser and save it for Playwright auth. Step-by-step DevTools instructions.
triggers:
  - как достать cookie
  - нужен auth cookie
  - session token
  - auth cookie setup
allowed-tools: []
---

# Auth Cookie Setup

## When
Playwright tests need to run against authenticated routes. Cookie file is missing or expired.

## When NOT
Service-to-service auth using API keys (use `SUPABASE_SERVICE_ROLE_KEY`).

## Step-by-step (Chrome)

1. Open the dashboard in Chrome and log in normally.
2. Open DevTools → **Application** tab → **Cookies** → select the site (e.g. `https://timbre.fyi`).
3. Find the cookie named `sb-<project-ref>-auth-token` (e.g. `sb-icdgcpvlcfgwuhfqzrzm-auth-token`).
4. Copy the **Value** field (it starts with `base64-eyJ...` or just `eyJ...`).

## Step-by-step (Safari)

1. Enable Developer menu: Safari → Settings → Advanced → Show Develop menu.
2. Develop → Show Web Inspector → Storage → Cookies.
3. Find `sb-*-auth-token`, copy Value.

## Save the file

```bash
cat > /tmp/timbre-cookie.env <<'EOF'
SB_COOKIE_NAME=sb-icdgcpvlcfgwuhfqzrzm-auth-token
SB_COOKIE_VALUE=<paste Value here>
EOF
chmod 600 /tmp/timbre-cookie.env
```

## Security rules
- File lives at `/tmp/` — NOT in the repo, NOT committed.
- `chmod 600` so only your user can read it.
- Never print the value in CI logs.
- Cookie expires with the browser session — re-extract after logout/expiry.

## Load before Playwright
```bash
set -a; . /tmp/timbre-cookie.env; set +a
cd web && npx playwright test screenshot-audit
```

The spec reads `process.env.SB_COOKIE_NAME` / `process.env.SB_COOKIE_VALUE` and injects via `context.addCookies([{ name, value, domain, path: '/' }])`.
