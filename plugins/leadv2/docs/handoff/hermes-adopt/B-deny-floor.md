# B-deny-floor — PreToolUse:Bash deny-floor hook

Shipped a pre-execution hard floor blocking unambiguously-destructive Bash
commands even under Codex danger-full-access. Complements post-hoc
off_limits/hack-detection review, which never ran before execution.

## Files
- NEW `config/leadv2-deny-patterns.yaml` — 10 conservative rules (rm -rf /,
  rm -rf ~/$HOME, git reset --hard, git clean -fdx, git stash, git push
  --force to main/master, mkfs, dd of=/dev/, chmod -R 777 /, curl|bash /
  wget|sh). Each rule: name/regex/enabled/message, independently toggleable.
- NEW `hooks/leadv2-deny-floor.sh` — matches
  `hooks/leadv2-block-bash-heredoc.sh` contract exactly: stdin JSON →
  python3 inline extracts `tool_input.command` → `exit 0` allow / `exit 2`
  + stderr message block. `set -euo pipefail` + ERR trap fail-open (`exit
  0`). Parses the yaml with a simple line-based python3 parser (no PyYAML
  dependency) per contract's "simple regex/line parse ok".
- `hooks/hooks.json` — registered as the first hook in the existing
  `PreToolUse` → `matcher: "Bash"` array, ahead of
  `leadv2-block-bash-heredoc.sh`, same JSON shape as siblings.
- NEW `tests/test-deny-floor.sh` — 15 assertions (8 blocked-destructive, 5
  allowed-legit, 1 kill-switch, 1 inline-override). All pass.

## Kill-switches (both proven by test)
- `LEADV2_DENY_FLOOR=0` env var → hook exits 0 immediately, before reading
  stdin.
- Inline `# deny-floor: allow` comment appended to the command → bypasses
  after matching, same pattern as the heredoc-guard's `# bash-guard: allow`.

## Verification
- `python3 -m json.tool` on `hooks.json` — valid JSON.
- `bash -n hooks/leadv2-deny-floor.sh` — syntax OK.
- `bash tests/test-deny-floor.sh` — 15 passed, 0 failed.
- `shellcheck hooks/leadv2-deny-floor.sh tests/test-deny-floor.sh` — clean,
  exit 0.

## Notes
- Ran no git commands (per hard constraint) — lead commits centrally.
- Did not touch off_limits/hack-detection review code, only added the new
  pre-execution hook + its config + its registration.
- Bias kept toward few, tight regexes (word-boundaries, path anchors) to
  avoid false positives on legit work (e.g. `git push origin
  feature-branch`, `rm -rf /tmp/scratch`, `git reset HEAD~1` all verified
  ALLOWED in tests).

DELIVERABLE_COMPLETE
