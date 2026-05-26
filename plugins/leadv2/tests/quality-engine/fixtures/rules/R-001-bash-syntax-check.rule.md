---
id: R-001
ported_from: bash_glob_unquoted_spaces
description: Unquoted multi-word glob in [[ ]] aborts file load silently
severity: high
scan:
  target: diff
  scope: changed_files
  file_pattern: "*.sh"
match:
  type: regex
  expr: '\[\[.*\*[a-z ]+\*.*\]\]'
aggregate:
  op: count
  field: matches
check:
  threshold: 0
  comparator: gt
action: block_deploy
created: "2026-05-20"
seen_count: 2
---

## Remediation

Run `bash -n <file>` on every changed .sh file in build phase.
Mission must require dev subagent to report PASS in summary_for_lead.
Ensure all glob patterns inside `[[ ]]` are quoted: `[[ "$x" == *"foo bar"* ]]`.
