---
id: R-002
ported_from: d11a4c55c3f8
description: Deploy script uses hardcoded path that diverges from active VPS path
severity: high
scan:
  target: diff
  scope: changed_files
  file_pattern: "deploy*.sh"
match:
  type: regex
  expr: '/home/persona[^-/]'
aggregate:
  op: count
  field: matches
check:
  threshold: 0
  comparator: gt
action: block_deploy
created: "2026-05-20"
seen_count: 3
---

## Remediation

Deploy paths must use the `$VPS_ROOT` variable from environment, not hardcoded
`/home/persona` strings. Verify `state-paths.yaml` has the correct root for each VPS.
