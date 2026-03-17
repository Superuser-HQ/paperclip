# Heartbeat-Aware Skills

All SHQ agent skills must be written for **autonomous heartbeat execution** — not interactive conversation. This means:

- No prompting the user for input mid-execution
- No conversational back-and-forth patterns
- Use task comments and human communication channels (Slack/Telegram) for async coordination when blocked
- Skills wake up, check work, act, and exit

This applies to both new skills and rewrites of operating-system repo skills (`content-pipeline`, `sales-pipeline`, etc.).
