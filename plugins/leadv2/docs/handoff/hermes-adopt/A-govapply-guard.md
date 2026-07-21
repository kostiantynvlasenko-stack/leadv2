# A — GOVAPPLY-GUARD-01

SHA256 drift-guard + auto-backup shipped for governance-proposal applies. Both appliers now
refuse/backup before writing.

- NEW `scripts/leadv2-govapply-guard.sh`: `--target <path> [--expected-sha256 <hex64>]`.
  Exit 0 = OK + `.bak.<UTC-ts>` written; 2 = target missing; 3 = drift (live sha256 != expected,
  refuses, no backup). `--expected-sha256` omitted = backup-only (no baseline to compare, used
  by migration-apply). `LEADV2_GOVAPPLY_NOGUARD=1` bypasses everything, warns to stderr.
- `scripts/leadv2-shadow-apply.sh` `--promote`: calls the guard with the proposal's
  `target_sha256` (via `_prop target_sha256`) right before the existing snapshot+patch block;
  on refusal sets `status=blocked_by_eval` and exits 1. Legacy proposals with no `target_sha256`
  fall back to backup-only (never hard-refused).
- `scripts/leadv2-migration-apply.sh`: guards+backs up each changed migration file before
  delegating to `.claude/leadv2-overrides/migrate.sh` (no proposal baseline exists for
  migrations — backup-only mode).
- `workflows/leadv2-learn.js` (proposal-writing part only): after `lv2-shadow-emit.py` emits a
  proposal, a chained best-effort python3 one-liner patches `target_sha256` (sha256 of the
  target file at generation time) into the just-written yaml, idempotently (skips if already
  set). Recomputes the proposal id deterministically (matches emitter's `sha1(task_id+kind+target)`)
  so the existing single-stdout id-regex parsing in the batched `agent()` call is untouched.
- NEW `tests/test-govapply-guard.sh`: 6/6 pass — matching-hash applies+backs-up, drifted-hash
  refuses+no-backup, no-baseline backup-only, NOGUARD bypass, missing-target (exit 2),
  missing-arg (exit 1). `shellcheck -x` clean on all 3 touched/new `.sh` files.
- Verified end-to-end in isolation (stub emitter): emit → sha256-patch → proposal yaml
  `target_sha256` matches `shasum -a 256` of the live target; idempotent on re-run.

**Known gap (out of scope, flagged not fixed):** `lv2-shadow-emit.py` is a vendored script (not
tracked in this source repo — lives only in consuming repos' `.claude/scripts/`), so it was not
edited; the sha256 patch happens as a second step chained after it instead. The shared
`leadv2-shadow-proposal.schema.json` contract (`.claude/leadv2-shared/contracts/`) has
`additionalProperties: false` and does not yet list `target_sha256` — needs a shared-tree edit
(founder approval required per shared-tree edit policy) to stay schema-valid.

DELIVERABLE_COMPLETE
