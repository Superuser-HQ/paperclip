# Linear Ticket Linking

Linear ticket IDs are the canonical reference across the entire workflow:

| Surface | Format | Example |
|---------|--------|---------|
| Branch | `<type>/<ticket>-<short-description>` | `feat/DEV-42-add-webhook-handler` |
| PR title | `<ticket>: Description` | `DEV-42: Add webhook handler` |
| Commits | Conventional commits (no ticket in message) | `feat: add webhook handler` |
| Paperclip task | Ticket ID + title | `DEV-42: Add webhook handler` |
