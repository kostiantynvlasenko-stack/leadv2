# leadv2-recovery — Reference (scripts, validation, edge-case protocol)

Companion to [SKILL.md](./SKILL.md). Pointers in the main flow link here for the full
verbatim scripts/blocks needed by the specific step named in each heading.

## 0b. Validate probe result contract

Before classifying failure, validate the probe result file against the contract
(`docs/specs/leadv2-verify-contract.md`):

```bash
source "$(bash .claude/scripts/lv2 --path leadv2-helpers.sh)"
PROBE_RESULT="docs/handoff/${TASK_ID}/verify-probe-result.yaml"
if [[ -f "$PROBE_RESULT" ]]; then
  _validate_probe_result "$PROBE_RESULT" || {
    printf '[recovery] WARN: probe result file invalid — treating outcome as probe_timeout\n' >&2
  }
  outcome=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open(sys.argv[1])) or {}
print(d.get('outcome', 'probe_timeout'))
" "$PROBE_RESULT" 2>/dev/null || echo "probe_timeout")
else
  # Fallback: derive outcome from verify-probe exit code passed in context
  outcome="${PROBE_OUTCOME:-probe_timeout}"
fi
```

Use `outcome` (not the raw exit code) for all downstream classification logic.

## 1c. Compress previous-phase outputs

Before reading any prior-phase handoff files (architect.md, developer.md, diff.md), compress them if large to reduce recovery-brief token cost:

```bash
source "$(bash .claude/scripts/lv2 --path leadv2-helpers.sh)"
for f in \
  "docs/handoff/${TASK_ID}/architect.md" \
  "docs/handoff/${TASK_ID}/developer.md" \
  "docs/handoff/${TASK_ID}/diff.md"; do
  [[ -f "$f" ]] && leadv2_compress_handoff "$f"
done
# Read via helper — compressed twin is preferred when it exists
architect_out=$(leadv2_read_handoff "docs/handoff/${TASK_ID}/architect.md")
```

This prevents the full incident log (potentially hundreds of KB) from being ingested raw into the recovery architect brief.

## 2b. Diff-only recovery-context

When recovery attempt 2 spawns (after attempt 1 fails), **do NOT replay full incident log**.

**Protocol:**
1. Call `bash .claude/scripts/lv2 leadv2-recovery-context.sh --task-id <id> --attempt 2`
2. The script emits the compact RECOVERY-CONTEXT format and archives the full log:
   ```
   RECOVERY-CONTEXT (compact)
   Original task: <id>
   Classification: Heavy
   Regression: <one-paragraph>
   Attempt 1 approach: <two-sentences>
   Attempt 1 failure: <one-sentence>
   Diff between original-broken and attempt-1: <git diff>
   Next approach requested: <one-sentence>
   ```
3. Inject compact context into attempt-2 architect brief in place of full incident log
4. Full incident log archived at `docs/handoff/<id>/recovery-full.md` — available for audit but NOT loaded into architect context

**Fallback:** if diff unavailable, script falls back to `[diff unavailable — check git log manually]`. Proceed with compact context regardless.

## 6. Circuit break

After 2 recoveries failed OR architect answers D ABANDON on attempt 2:

```
PushNotification: "leadv2 circuit break on <task-id>: 2 recoveries failed. rolled back. needs founder."

AskUserQuestion:
  question: "Task <id> failed verify 2x after recovery attempts. Production is at <rolled-back-state | last-hotfix>. What next?"
  options:
    - label: "Abandon task, open tracker item"
      description: "Roll back if not yet, file in docs/ops/RECOVERY_TRACKER.md with full history"
    - label: "Manual takeover"
      description: "Lead freezes state, founder debugs live. Provide log paths + commit range."
    - label: "Retry with new scope"
      description: "Kill this task-id, re-open Gate 1 with founder's revised mission"
```

Write LEAD_V2_STATE:
```
status: paused
phase: recovery
step: circuit_break
note: "2 recoveries failed, founder decision pending. last probe: <result>"
```
