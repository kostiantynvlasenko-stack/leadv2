# Codex resume sandbox fix

- Fixed `leadv2-codex-session-runner.sh` resume argv: `--sandbox` is no longer passed to `codex exec resume`.
- Normal resume preserves `workspace-write` through `-c 'sandbox_mode="workspace-write"'`.
- Unsafe resume preserves approval and `danger-full-access` posture through accepted `-c` settings and logs that receipt.
- Phase 6/7 approval and workspace-write network configs remain on normal resumes.
- Fresh `codex exec` argv is unchanged and retains `--sandbox workspace-write`.
- Added `test-codex-resume-argv.sh` to assert the fresh and resume argv contract.
- No plugin sync was run.

DELIVERABLE_COMPLETE
