# Architect escape-hatch mission template (leadv2-review §6)

Referenced from `leadv2-review/SKILL.md` §6. Used when max 2 review rounds are exhausted and
Critical findings are still present.

```bash
# Compose full history mission file:
cat > /tmp/alt-approach-<id>.md <<EOF
Task: <id>
Mission: <original>
Round 1 findings: <summary>
Round 1 fix: <what was done>
Round 2 findings: <summary>
Remaining Critical: <list>

Propose alternative approach that bypasses this class of issue.
If no alt exists, explain why and recommend escalate-to-founder with what decision is needed.
Max 300 words.
EOF

~/.claude/scripts/claude-subsession.sh --role architect --model opus \
  --task-id <id> --mission-file /tmp/alt-approach-<id>.md --effort max
```
