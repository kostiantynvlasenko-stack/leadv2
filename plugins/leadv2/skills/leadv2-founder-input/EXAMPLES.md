# Poll-loop implementation (leadv2-founder-input)

Referenced from Step 3a — Tier C: blocking wait / interactive mode, in `SKILL.md`.

```bash
# Poll loop (bash inside skill)
DEADLINE=$(( $(date +%s) + 1800 ))
REMINDED=0
while [[ $(date +%s) -lt $DEADLINE ]]; do
  STATUS=$(python3 -c "import yaml; d=yaml.safe_load(open('$DEC_FILE')); print(d.get('status',''))")
  if [[ "$STATUS" == "answered" ]]; then break; fi
  if [[ $(date +%s) -gt $((DEADLINE - 900)) && "$REMINDED" -eq 0 ]]; then
    push_notify "[/leadv2] Reminder: decision still pending for $TASK_ID"
    REMINDED=1
  fi
  sleep 10
done
```
