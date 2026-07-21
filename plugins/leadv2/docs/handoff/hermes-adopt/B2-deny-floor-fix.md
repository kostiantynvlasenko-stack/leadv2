# B2 — deny-floor fix-round

Both defects fixed in `config/leadv2-deny-patterns.yaml`; `hooks/leadv2-deny-floor.sh` needed no change (matching logic already generic).

## git_stash (false-positive fix)
Before: `git\s+stash(\s|$)` — blocked ANY `git stash <subcmd>`.
After: `git\s+stash(?!\s+(list|show|pop|apply|branch)\b)(\s|$)` — negative-lookahead allowlist of read-only subcommands; blocks bare/push/save/clear/drop only.

## rm_rf_root (leak fix)
Before: `...\s+/(\s|$)|...` (both rf/fr flag-order alternatives) — only matched root followed by whitespace or end-of-string, missed glob/dot variants.
After: `...\s+/(?:\s|$|\*|\.(?=\s|$))|...` — terminator set now covers `/`, `/ `, `/*`, `/.`; `/tmp/...`, `./...`, `/some/path` still pass through untouched.

## Tests
Added 6 new assertions (block: `git stash clear`, `rm -rf /*`, `rm -rf / `; allow: `git stash list`, `git stash show`, `git stash pop`). Total: 15 → 21, all PASS. `shellcheck -x hooks/leadv2-deny-floor.sh` clean.

Files touched: `config/leadv2-deny-patterns.yaml`, `tests/test-deny-floor.sh`. No hook logic change needed.

DELIVERABLE_COMPLETE
