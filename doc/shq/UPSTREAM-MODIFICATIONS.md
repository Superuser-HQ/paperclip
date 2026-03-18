# Upstream Modifications

Files modified from upstream Paperclip and why. Consult this when rebasing onto upstream releases.

## Modified Files

| File | Change | Why | Ticket |
|------|--------|-----|--------|
| `Dockerfile` | Commented out `VOLUME ["/paperclip"]`; added COPY lines for `packages/plugins/` | Railway bans VOLUME keyword; upstream added plugin packages without updating Dockerfile | DEV-396 |

## Added Directories

| Directory | Purpose | Ticket |
|-----------|---------|--------|
| `deploy/server-b/` | Server B deployment automation | DEV-396 |
