---
title: 'DEV-396: Deploy Paperclip on Server B'
status: draft
date: 2026-03-17
linear: DEV-396
---

# DEV-396: Deploy Paperclip on Server B (Postgres, API, UI)

## Overview

Deploy the Paperclip fork as the control plane in the SHQ architecture, in `authenticated/private` mode. **Primary deployment target is Railway** (managed platform). Docker Compose on a VPS is the self-hosted fallback.

## Acceptance Criteria (from ticket)

- Paperclip running
- UI accessible via public URL
- Database initialised with schema
- Can create a company via UI

### Validation Plan

| Criterion | Verification |
|-----------|-------------|
| Paperclip running | `/api/health` returns `{"status":"ok"}` |
| UI accessible | HTTP 200 on `/` via Railway public URL |
| Database initialised | Migrations auto-apply on boot; verify via health check |
| Can create a company | Board user registers via invite URL, creates company via UI |

## Approach: Railway (Primary)

**Railway with managed Postgres** — deploy the existing Dockerfile to Railway with a Railway-provisioned PostgreSQL instance. Railway auto-detects the Dockerfile, provisions a public URL with SSL, and auto-deploys on push to `main`.

### Why Railway

- **No VPS to manage** — managed platform handles infrastructure, SSL, restarts
- **Public URL out of the box** — eliminates the need for Cloudflare Tunnel for webhook ingress (Linear can hit Railway directly)
- **Managed Postgres** — provisioned in one click, auto-exposes `DATABASE_URL`, built-in backups
- **Auto-deploy on push** — connect the private GitHub repo, every push to `main` deploys automatically
- **Existing Dockerfile works as-is** — Railway auto-detects and builds from it
- **Cost-effective** — Hobby plan at $5/month includes $5 usage credit, likely sufficient for the control plane workload

### Architecture on Railway

```
Railway Project: "paperclip"
├── Service: "server" (from Dockerfile)
│   ├── Source: GitHub (Superuser-HQ/paperclip, main branch)
│   ├── Builder: Dockerfile (auto-detected)
│   ├── Port: 3100
│   ├── Public domain: *.up.railway.app (auto-SSL) or custom domain
│   └── Env: DATABASE_URL=${{Postgres.DATABASE_URL}}, BETTER_AUTH_SECRET, etc.
└── Service: "Postgres" (Railway-managed)
    ├── Image: Railway's SSL-enabled Postgres
    ├── Volume: persistent (Railway-managed)
    └── Connection: internal via railway.internal DNS
```

### What this changes vs the original 3-server design

| Original Design | Railway |
|-----------------|---------|
| Server B = dedicated VPS | Railway-managed service |
| Docker Compose + systemd | Railway auto-deploy from GitHub |
| Cloudflare Tunnel for webhook ingress | Railway public URL (native SSL) |
| Manual Postgres on the same host | Railway-managed Postgres |
| SSH tunnel for bootstrap access | Public URL available immediately |
| `deploy.sh` / `update.sh` scripts | Git push = deploy |

### What stays the same

- Server A (Kani + Rem orchestration) and Server C (worker agents) remain on VPS if applicable
- Agent adapters and heartbeat model unchanged
- Paperclip runs in `authenticated/private` mode
- Board user bootstrap flow (bootstrap-ceo → invite → register)

### Storage model

| Data | Managed by | Persistence |
|------|-----------|-------------|
| PostgreSQL data | Railway Postgres volume | Persistent, Railway-managed, built-in backups |
| Paperclip home (uploads, config, secrets key) | Railway volume on server service | Persistent across deploys |

## Environment Configuration

### Railway variables

| Variable | Value | Notes |
|----------|-------|-------|
| `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` | Railway variable reference, auto-linked |
| `BETTER_AUTH_SECRET` | 64-char random hex | Sealed variable (write-only after set) |
| `PAPERCLIP_DEPLOYMENT_MODE` | `authenticated` | Login required |
| `PAPERCLIP_DEPLOYMENT_EXPOSURE` | `private` | Private mode |
| `PORT` | `3100` | Railway reads this to route traffic |
| `SERVE_UI` | `true` | Serve UI from same process |
| `PAPERCLIP_PUBLIC_URL` | `https://<app>.up.railway.app` | Set after domain is generated |

### Optional (agent adapters)

API keys for adapters. Not required on the control plane (agents run separately), but available for flexibility.

| Variable | Adapter |
|----------|---------|
| `ANTHROPIC_API_KEY` | claude-local |
| `OPENAI_API_KEY` | codex-local |
| `CURSOR_API_KEY` | cursor-local |
| `GEMINI_API_KEY` | gemini-local |

All local adapters fall back to subscription auth when API keys are not set.

## Deployment Steps (Railway)

### First-time setup

1. Create a Railway project (via dashboard or `railway init`)
2. Add a PostgreSQL service (`railway add -d postgres`)
3. Connect `Superuser-HQ/paperclip` private repo as a service (Railway GitHub App integration)
4. Configure environment variables (see table above)
   - `DATABASE_URL` = `${{Postgres.DATABASE_URL}}`
   - `BETTER_AUTH_SECRET` = generate with `openssl rand -hex 32`, mark as sealed
   - Set remaining variables
5. Generate a public domain (`railway domain` or via dashboard)
6. Set `PAPERCLIP_PUBLIC_URL` to the generated domain
7. Deploy (triggers automatically on repo connection, or `railway up`)
8. Verify: `curl https://<app>.up.railway.app/api/health`

### Board user bootstrap

1. After first deploy, access the public URL directly (no SSH tunnel needed)
2. Run bootstrap-ceo via Railway's shell or CLI:
   ```sh
   railway shell  # opens a shell in the running container
   npx paperclipai@latest auth bootstrap-ceo --data-dir /paperclip --base-url "$PAPERCLIP_PUBLIC_URL"
   ```
3. Copy the invite URL from the output
4. Open the invite URL in your browser, register with name/email/password
5. Board member is promoted to instance admin
6. Create the "Superuser HQ" company via the UI

### Ongoing updates

Push to `main` — Railway auto-deploys. No manual intervention needed.

For manual deploys: `railway up` from the repo directory.

### Useful commands

```sh
# View logs
railway logs

# Open shell in running container
railway shell

# Check service status
railway status

# View environment variables
railway variables

# Open Railway dashboard
railway open
```

## Approach: Docker Compose (Fallback)

Self-hosted deployment on a VPS using Docker Compose. Use this if Railway is unavailable or if the deployment needs to run on-premise.

The existing automation in `deploy/server-b/` provides:

| File | Purpose |
|------|---------|
| `deploy/server-b/deploy.sh` | First-time setup: Docker, repo clone, secrets, containers, systemd |
| `deploy/server-b/bootstrap-board.sh` | Post-deploy: bootstrap-ceo, invite URL |
| `deploy/server-b/update.sh` | Ongoing: git pull, rebuild, restart |
| `deploy/server-b/docker-compose.override.yml` | Adds `restart: unless-stopped`, removes DB host port |
| `deploy/server-b/paperclip.service` | Systemd unit for boot lifecycle |
| `deploy/server-b/.env.template` | Environment config template |
| `deploy/server-b/lib.sh` | Shared helpers (sourced by scripts) |
| `deploy/server-b/README.md` | Deployment runbook |

### Server layout (Docker Compose)

```
/opt/paperclip/
├── repo/                       # full repo clone (docker build context)
│   ├── docker-compose.yml
│   ├── docker-compose.override.yml
│   ├── Dockerfile
│   ├── .env
│   └── ...
└── scripts/
    ├── deploy.sh
    ├── bootstrap-board.sh
    └── update.sh
```

### Docker Compose environment

| Variable | Value | Notes |
|----------|-------|-------|
| `DATABASE_URL` | `postgres://paperclip:paperclip@db:5432/paperclip` | Internal Docker network |
| `BETTER_AUTH_SECRET` | 64-char random hex | Generated by `deploy.sh` |
| `PAPERCLIP_DEPLOYMENT_MODE` | `authenticated` | Login required |
| `PAPERCLIP_DEPLOYMENT_EXPOSURE` | `private` | Tailscale/private network |
| `PAPERCLIP_PUBLIC_URL` | `http://localhost:3100` (placeholder) | Replace with Tailscale/Cloudflare URL |

### Docker Compose bootstrap

1. Copy `deploy/server-b/` to the server
2. Run `deploy.sh` (installs Docker, clones repo, starts containers)
3. Open SSH tunnel: `ssh -L 3100:localhost:3100 server-b`
4. Run `bootstrap-board.sh` (generates invite URL)
5. Register via `http://localhost:3100`, create company

See `deploy/server-b/README.md` for the full runbook.

## Linear Webhook Ingress

With Railway, Linear webhooks point directly at the Railway public URL:

```
Linear → https://<app>.up.railway.app/api/webhooks/linear
```

No Cloudflare Tunnel needed. The Cloudflare Tunnel requirement from the original design is eliminated by Railway's native public URL with auto-SSL.

For the Docker Compose fallback, Cloudflare Tunnel or Tailscale Funnel would still be needed for webhook ingress (separate ticket).

## Out of Scope

- Agent deployment on Server C (separate ticket)
- Agent persona/skill configuration (separate ticket)
- Tailscale setup for inter-server communication (separate ticket, may be simplified or eliminated by Railway)

## Dependencies

- Railway account with GitHub App connected to `Superuser-HQ/paperclip`
- For Docker Compose fallback: VPS accessible via SSH with Ubuntu + internet access
