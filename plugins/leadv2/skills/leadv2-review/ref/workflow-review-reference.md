# Workflow review fan-out — reference JS shape (leadv2-review §2)

Referenced from `leadv2-review/SKILL.md` §2. This is the REFERENCE SHAPE only — the canonical,
maintained script is `~/.claude/workflows/leadv2-review.js`. Do NOT hand-inline a fresh script
from this file; it exists purely so the shape of the fan-out is legible without opening the .js.

```js
// Workflow script — review fan-out
const DIFF_PATH = `/tmp/leadv2-review-<id>.diff`;

const round1 = await parallel([
  agent("critic", {
    model: safetyTouched ? "claude-opus-4-8" : "claude-sonnet-5",
    prompt: `Adversarial code review. Diff: ${DIFF_PATH}. Brief: /tmp/review-mission-<id>.md.
             Output CHALLENGE blocks per critic role format with severity tags.`,
    outputSchema: {
      type: "object",
      properties: {
        findings: {
          type: "array",
          items: {
            type: "object",
            properties: {
              severity: { type: "string", enum: ["critical", "high", "medium", "low", "nit"] },
              dimension: { type: "string" },
              description: { type: "string" },
              suggested_fix: { type: "string" }
            },
            required: ["severity", "dimension", "description"]
          }
        },
        max_severity: { type: "string" }
      },
      required: ["findings", "max_severity"]
    }
  }),
  // security-auditor fires only when safety-touched (same gate as manual Cases B/C)
  ...(safetyTouched ? [agent("security-auditor", {
    model: "claude-sonnet-5",
    prompt: `Security review. Diff: ${DIFF_PATH}. Full-file read allowed for security-sensitive paths.`,
    outputSchema: {
      type: "object",
      properties: {
        findings: { type: "array", items: { type: "object" } },
        has_critical: { type: "boolean" }
      },
      required: ["findings", "has_critical"]
    }
  })] : []),
  agent("developer", {
    model: "claude-sonnet-5",
    prompt: `Run hack-detection per .claude/skills/leadv2-hack-detection/SKILL.md on diff ${DIFF_PATH}.
             Output findings YAML with block_count/warn_count/has_block summary.`,
    outputSchema: {
      type: "object",
      properties: {
        findings: { type: "array" },
        summary: {
          type: "object",
          properties: {
            block_count: { type: "number" },
            warn_count: { type: "number" },
            has_block: { type: "boolean" }
          },
          required: ["block_count", "warn_count", "has_block"]
        }
      },
      required: ["findings", "summary"]
    }
  })
]);

// Adversarial-verify stage — per-finding 3-vote majority kill
// Each finding is put to 3 independent review dimensions; ≥2 refutations kill it.
const verified = await pipeline(round1, {
  agent: "critic",
  model: "claude-sonnet-5",
  prompt: `For each Critical/High finding from round1, apply 3-vote majority-kill:
           vote on (correctness, risk, actionability). If ≥2 votes refute → kill finding.
           Output: verified_findings[], killed_findings[] with kill_reasons.`,
  outputSchema: {
    type: "object",
    properties: {
      verified_findings: { type: "array" },
      killed_findings: { type: "array" },
      kill_reasons: { type: "object" }
    },
    required: ["verified_findings", "killed_findings"]
  }
});
```

The Workflow returns structured JSON findings directly — no Monitor polling, no manual deliverable-file
reads. Write the JSON results to `docs/handoff/<id>/reviews/round1-findings.json` and proceed to §3 using
the structured output (no `cx-tail.sh` needed). Codex review (`codex-task.sh adversarial-review`) stays
orthogonal: fire it as an optional background Bash call outside the Workflow if available.
