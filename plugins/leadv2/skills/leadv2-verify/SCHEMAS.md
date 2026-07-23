# leadv2-verify — Corroborate config schema

Full YAML schema for the `--corroborate` config file referenced from SKILL.md
§Protocol → "Corroboration mode (default for Heavy tasks)".

## Corroborate config

```yaml
positive:
  type: log-grep          # signal-file | log-grep | http-check
  host: <user>@<host>
  path: <your-app-log-path>
  pattern: "<expected-success-signal>"
  window_min: 5
no_regression:
  - type: no-5xx-spike    # checks nginx access log for 5xx spike vs prior window
    host: <user>@<host>
    path: /var/log/nginx/access.log
    window_min: 10
    threshold_multiplier: 2.0
  - type: error-log-quiet # checks app log error count recent vs baseline
    host: <user>@<host>
    path: <your-app-log-path>
    window_min: 10
    threshold_multiplier: 2.0
    error_pattern: "(ERROR|CRITICAL|Traceback|Exception)"  # optional, shown is default
```

Invoked as:
```bash
verify-probe.sh --timeout 180 --corroborate /tmp/verify-<task-id>.yaml
```
