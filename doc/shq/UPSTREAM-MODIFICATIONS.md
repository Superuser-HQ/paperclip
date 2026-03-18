# Upstream Modifications

Files modified from upstream Paperclip and why. Consult this when rebasing onto upstream releases.

## Modified Files

| File | Change | Why | Ticket |
|------|--------|-----|--------|
| `Dockerfile` | Commented out `VOLUME ["/paperclip"]` | Railway bans VOLUME keyword in Dockerfiles; volumes managed via Railway platform | DEV-396 |

## Added Directories

| Directory | Purpose | Ticket |
|-----------|---------|--------|
| `deploy/server-b/` | Server B deployment automation | DEV-396 |
