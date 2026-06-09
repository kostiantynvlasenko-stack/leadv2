# FORCE-REFLECT-FIX — dev deliverable

## What changed

`plugins/leadv2/hooks/leadv2-force-reflect.sh` — full rewrite of detection logic.

**Dropped:** mtime/30-min check + cross-dir artifact glob (`verify*.md`, `deploy*.yaml`).

**Added:** `active.yaml` phase-based detection via `python3` + `pyyaml`.

## Core diff (changed lines only)

```diff
-now=$(date +%s)
-mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
-
-for base in "$CWD/docs/handoff" "$CWD/docs/leadv2/tasks"; do
-  [[ -d "$base" ]] || continue
-  for taskdir in "$base"/*/; do
-    comp=""
-    for art in "$taskdir"verify*.md "$taskdir"deploy*.md "$taskdir"deploy*.yaml; do
-      [[ -f "$art" ]] && { comp="$art"; break; }
-    done
-    [[ -z "$comp" ]] && continue
-    [[ $(( now - $(mtime "$comp") )) -ge 1800 ]] && continue
-    { [[ -f "${taskdir}phase8-passed.flag" ]] || ... } && continue
-  done
-done

+ACTIVE_YAML="$CWD/docs/leadv2/active.yaml"
+[[ -f "$ACTIVE_YAML" ]] || exit 0
+python3 - "$CWD" "$ACTIVE_YAML" <<'PYEOF'
+  TRIGGER_PHASES = {"deploy", "verify", "live_verify", "close"}
+  # iterate sessions[], fire only for matching phase+task_id
+  # resolve taskdir (handoff > tasks > create), check close flags, one-shot marker
+PYEOF
```

## Phase strings used (sourced from skills)

| Phase written | By skill |
|---|---|
| `deploy` | leadv2-review/SKILL.md |
| `verify` | leadv2-deploy/SKILL.md |
| `close` | leadv2-verify/SKILL.md |
| `live_verify` | older tasks (kept in trigger set) |

Non-trigger (no fire): `intake`, `classify`, `plan`, `build`, `review`.

## Tests

3 self-contained bash tests, all passed:
- `phase=build` -> no block
- `phase=verify` first call -> block + `.reflect-forced` written
- `phase=verify` second call -> no-op (one-shot guard)

## Syntax check

`bash -n plugins/leadv2/hooks/leadv2-force-reflect.sh` -> OK

DELIVERABLE_COMPLETE
