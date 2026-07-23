# Escalation re-ping (daemon only) — leadv2-founder-input

Referenced from Step 3a — Tier C: blocking wait / daemon mode, in `SKILL.md`.

The daemon re-pings every 60 min while paused with pending decisions older than `re_ping_at`. Each re-ping:
- Sends PushNotification with escalation text and re_ping_count
- Increments `re_ping_count`
- Sets `re_ping_at = now + min(2h * 2^count, 12h)`
