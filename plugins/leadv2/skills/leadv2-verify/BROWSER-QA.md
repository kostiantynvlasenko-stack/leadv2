# leadv2-verify — Browser-qa step detail (frontend changes only)

Referenced from SKILL.md §"Browser-qa step (frontend changes only)". Read this file
only after the SKILL.md trigger condition (`RUN ONLY IF`) has fired — for all other
tasks this step is a no-op and this file is not needed.

## Loading frontend roots

```bash
frontend_roots_file=".claude/leadv2-overrides/frontend-paths.txt"
if [[ -f "$frontend_roots_file" ]]; then
  mapfile -t frontend_roots < <(grep -vE '^\s*(#|$)' "$frontend_roots_file")
else
  frontend_roots=("web/")
fi
```

## When triggered

**1. Find preview URL**

```bash
# Option A: from recent vercel output recorded in context.yaml or LEAD_V2_STATE.md
preview_url=$(python3 -c "
import yaml, sys
ctx = yaml.safe_load(open('docs/leadv2/tasks/${TASK_ID}/context.yaml')) or {}
print(ctx.get('deploy_gate', {}).get('vercel_preview_url', '') or '')
" 2>/dev/null)

# Option B: from vercel meta output if present
if [[ -z "$preview_url" && -f "web/.vercel/output/meta.json" ]]; then
  preview_url=$(python3 -c "
import json, sys
d = json.load(open('web/.vercel/output/meta.json'))
print(d.get('url','') or d.get('previewUrl','') or '')
" 2>/dev/null || true)
fi
```

**2. HTTP smoke check (if preview URL found)**

```bash
if [[ -n "$preview_url" ]]; then
  http_status=$(curl -sIL --max-time 15 -w '%{http_code}' -o /dev/null "$preview_url" 2>/dev/null || echo "000")
  if [[ "$http_status" -ge 400 ]] || [[ "$http_status" == "000" ]]; then
    echo "[verify-browser] WARN: preview URL returned HTTP $http_status — $preview_url" >&2
    browser_qa_verdict="http_warn:${http_status}"
  else
    echo "[verify-browser] HTTP check OK: $http_status — $preview_url" >&2
    browser_qa_verdict="http_ok:${http_status}"
  fi
else
  echo "[verify-browser] NOTE: no preview URL found — skipping HTTP check" >&2
  browser_qa_verdict="no_url"
fi
```

**3. Playwright smoke check (optional, if available)**

```bash
# Check whether browser-qa skill or Playwright MCP is available for this project.
BROWSER_QA_OVERRIDE="${CLAUDE_PROJECT_ROOT:-$PWD}/.claude/leadv2-overrides/browser-qa.sh"
if [[ -x "$BROWSER_QA_OVERRIDE" && -n "$preview_url" ]]; then
  # Delegate one quick smoke check (load route, screenshot, no console errors).
  LEAD_V2_TASK_ID="$TASK_ID" \
  LEAD_V2_PREVIEW_URL="$preview_url" \
    bash "$BROWSER_QA_OVERRIDE" \
    && browser_qa_verdict="playwright_ok" \
    || browser_qa_verdict="playwright_warn"
else
  echo "[verify-browser] NOTE: no browser-qa.sh override — Playwright check skipped" >&2
fi
```

**4. Write result to handoff**

```bash
mkdir -p "docs/handoff/${TASK_ID}"
cat > "docs/handoff/${TASK_ID}/verify-browser.md" <<EOF
# Browser QA — ${TASK_ID}

- preview_url: ${preview_url:-none}
- http_status: ${http_status:-n/a}
- verdict: ${browser_qa_verdict:-skipped}
- timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
```
