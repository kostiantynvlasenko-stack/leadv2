# B3 deny-floor fix2 — 4 Codex findings

All 4 fixed. `bash tests/test-deny-floor.sh`: 32 passed, 0 failed. `shellcheck -x` on both scripts: clean, 0 warnings.

1. **git_clean_fdx regex** — replaced fixed-order substring match with two lookaheads requiring BOTH a force token (`-f`/`--force`) and a dirs token (`-d`) anywhere in the command, any order/grouping/separation, plus a negative lookahead excluding `-n`/`--dry-run`. Verified: `-fdx`, `-xdf`, `-f -d`, `-x -f -d` block; `-n` allows.
2. **dev_redirect_overwrite (new rule)** — `>>?\s*/dev/(sd|nvme|disk|hd|vd|xvd)`, catastrophic tier. `/dev/null|stdout|stderr|tty` unaffected (prefix list excludes them by construction).
3. **remote_curl_pipe_shell** — rule deleted from yaml; test updated from BLOCK to ALLOW with rationale note.
4. **Tiered inline-override** — added `allow_inline_override: true|false` per rule in yaml (missing = false, fail-safe). Hook now matches the rule first, then only honors `# deny-floor: allow` if that rule's field is `true`. CATASTROPHIC (rm_rf_root/home, mkfs, dd_to_dev, dev_redirect_overwrite, chmod_r_777_root, **and git_push_force_main** — judgment call: shared-remote effect, not a local throwaway-tree op) = false. SOFT (git_reset_hard, git_clean_fdx, git_stash) = true.

No git commands run. Touched only the 3 owned files (yaml/hook/test). Pre-existing git-stash fix untouched and still passes (list/show/pop/apply allowed, bare/push/save/clear/drop blocked).

DELIVERABLE_COMPLETE
