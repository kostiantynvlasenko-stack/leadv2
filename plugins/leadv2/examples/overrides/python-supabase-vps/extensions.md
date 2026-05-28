# Project-specific lead rules — Python + Supabase + VPS

## Required workflow

- All database changes go through the `migrate` skill (creates a migration file + applies + verifies). Never raw `psql` against prod.
- Supabase RLS policies must be reviewed by `security-auditor` on every PR that touches `migrations/`.
- Touching `api/auth/` automatically requires `security-auditor` review regardless of size.

## Deploy quirks

- `deploy.sh` assumes the systemd unit can be restarted without dropping in-flight requests. If you have long-running connections, switch to blue-green deploy.
- `verify.sh` watches the app log for a success pattern. Make sure your app actually emits a `cycle_complete` (or your equivalent) line on success — the lead can't verify what your app doesn't log.

## Required env (in your shell or `.env`)

```sh
export DEPLOY_VPS_HOST="user@1.2.3.4"
export DEPLOY_REMOTE_REPO="/home/app/myproject"
export DEPLOY_SERVICE_NAME="myapp.service"
export VERIFY_LOG_PATH="/var/log/myapp/cycle.log"
export VERIFY_SUCCESS_PATTERN="cycle_complete|task_done"
export VERIFY_TIMEOUT_SEC=300
```

## Known limitations

- Single VPS. For dual-VPS or multi-region, fork `deploy.sh` to push to all hosts in parallel and verify both.
