# leadv2-verify — Generic probe templates (no project override)

Referenced from SKILL.md §Protocol → "5b. Verify-probe types — generic (used when no override)".
Use these templates to choose a probe type/pattern by change category when
`.claude/leadv2-overrides/verify.sh` does not exist.

**Publish cycle log grep:**
```
log-grep on host:
  path: <your-app-log-path>     # example — fill from .claude/leadv2-overrides/stack.yaml
  pattern: "cycle_complete|action_published"
  timeout: 3600
```

**Web / dashboard change**:
```
http-check:
  url: <stack.yaml web.domain>/<page>
  expected: 200
  timeout: 300
```

**Schema / migration**:
```
supabase-check:
  description: "manual: verify <column> exists in <table>, RLS policy updated"
```

**Cron / scheduler change**:
```
log-grep with longer timeout:
  pattern: "<new cron job name> executed"
  timeout: <cron_interval_seconds + 300>
```
