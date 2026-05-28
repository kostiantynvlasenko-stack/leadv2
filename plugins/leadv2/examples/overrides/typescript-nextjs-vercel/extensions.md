# Project-specific lead rules — Next.js + Vercel

## Required workflow

- Frontend changes in `web/` must be visually-tested before claiming done. The lead will spawn `frontend-developer` (Sonnet) for UI work — that agent is required to run the dev server and check the change in a browser.
- Server Actions and API routes go through `critic` (Opus) for type-safety + auth review.
- Migrations on Supabase via the `migrate` skill, never raw SQL.

## Deploy quirks

- Vercel build can fail silently on missing env vars in production. The lead's `env-audit` hook reads `.env.example` and warns if you're touching code that needs a new var but didn't add it to Vercel project settings.
- `deploy.sh` requires `vercel link` to have been run once (creates `.vercel/project.json`). First-time setup is manual.

## Required env

```sh
# Optional overrides:
export WEB_DIR="web"                    # default
export VERIFY_HEALTH_PATH="/api/health" # default
export VERIFY_TIMEOUT_SEC=120
```

## Known limitations

- The verify script health-checks the latest production URL. For preview deploys, branch deploys, or staging, fork the script.
