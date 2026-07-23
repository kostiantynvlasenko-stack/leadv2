# leadv2-plan — Reference

On-demand detail for `SKILL.md`. Consulted only when the pointing step actually fires — not
needed on every Plan run.

## Agent Priors Read Snippet

Referenced from step **1a-2. Agent priors**.

Quick read — extract only the relevant slice for the agents you intend to spawn:

```python
# Quick read — extract relevant slice only
import yaml
from pathlib import Path
priors = yaml.safe_load(Path("docs/leadv2-priors.yaml").read_text()) if Path("docs/leadv2-priors.yaml").is_file() else {}
for agent in planned_agents:
    ap = priors.get("agent_priors", {}).get(agent, {})
    model = ap.get("model_recommendation", {}).get(change_kind) or ap.get("model_recommendation", {}).get("default", "sonnet")
    # log: f"{agent}: model={model} best_on={ap.get('best_on',[])} avoid_on={ap.get('avoid_on',[])}"
```

When `docs/leadv2-priors.yaml` is present, use `best_on`/`avoid_on` to confirm agent assignment and
`model_recommendation[change_kind]` to set the `--model` flag in the mission. When it's absent,
fall back to class-based model selection (silent, no error).

## Persona Config Audit Scan

Referenced from step **1a-3. Persona-config audit**. Runs inline before writing the mission file,
only when the multi-persona trigger conditions in SKILL.md are met.

```bash
PERSONAS=$(ls -1 personas/ 2>/dev/null | grep -v '^_')
# 1. Hardcoded persona-id references
> /tmp/persona-hardcodes.$$.txt
for p in $PERSONAS; do
  grep -rnE "\b${p}\b" agent/ personas/_shared/ \
    --include='*.sh' --include='*.py' --include='*.md' 2>/dev/null \
    | grep -v "${p}/" \
    | grep -vE '^[^:]+:(\s*#|\s*//|\s*\*)' \
    | head -5 >> /tmp/persona-hardcodes.$$.txt
done
# 2. Magic-number safety thresholds
grep -rnE '(voice_floor|pillar_min|sim_cap|image_ratio|safety_threshold)\s*=\s*0?\.[0-9]+' \
  agent/ personas/_shared/ --include='*.sh' --include='*.py' 2>/dev/null \
  | head -20 >> /tmp/persona-hardcodes.$$.txt
```

If hits accumulate in `/tmp/persona-hardcodes.$$.txt`, follow SKILL.md's write + decision-injection
steps. If empty, proceed silently — no file, never blocks Plan progression.

## F4 Tool Hints

Referenced from step **2.5 F4 tool hints**. Full read + merge logic and the phase-default table:

```python
import yaml
from pathlib import Path

# Load override file if present (project worktree-relative path)
override_path = Path(".claude/leadv2-overrides/toolsets.yaml")
overrides = yaml.safe_load(override_path.read_text()) if override_path.is_file() else {}
phase_overrides = overrides.get("phase_overrides") or {}

# Phase defaults (F4 advisory hints)
DEFAULT_TOOLS = {
    "intake":   ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "codebase-memory-mcp-*"],
    "classify": ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "codebase-memory-mcp-*"],
    "plan":     ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "codebase-memory-mcp-*"],
    "build":    ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "codebase-memory-mcp-*",
                 "Edit", "Write", "Bash"],
    "review":   ["Read", "Grep", "Bash", "codebase-memory-mcp-*"],
    "deploy":   ["Bash", "Read"],
    "close":    ["Read", "Write"],
}

allowed_tools = {phase: phase_overrides.get(phase, defaults)
                 for phase, defaults in DEFAULT_TOOLS.items()}
# Emit as context.yaml field: allowed_tools: {intake: [...], build: [...], ...}
```

These hints are advisory only — subagents see them in context.yaml and use them as preferences,
not hard constraints. See subagent-preamble.md §1.1.
