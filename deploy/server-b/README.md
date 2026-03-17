# Server B Deployment Runbook

Deploys Paperclip (control plane) on Server B with containerised PostgreSQL.

**Design spec:** `doc/shq/plans/2026-03-17-server-b-deployment-design.md`
**Linear:** DEV-396

## Prerequisites

- Ubuntu server accessible via SSH
- Internet access (Docker install + image pulls)
- Git access to `github.com/Superuser-HQ/paperclip`

## First-Time Deployment

### 1. Copy deploy scripts to Server B

```sh
scp -r deploy/server-b/ server-b:/tmp/paperclip-deploy/
```

### 2. SSH into Server B and run deploy

```sh
ssh server-b
bash /tmp/paperclip-deploy/deploy.sh
```

Note: Do NOT use `sudo bash deploy.sh` — the script uses `sudo` internally where needed. Running the whole script as root breaks file ownership.

This will:
- Install Docker if needed
- Clone the repo to `/opt/paperclip/repo/`
- Generate secrets and `.env`
- Build and start containers
- Install systemd service for auto-start on boot

### 3. Bootstrap board user

Open an SSH tunnel from your local machine:

```sh
ssh -L 3100:localhost:3100 server-b
```

On Server B, run:

```sh
/opt/paperclip/scripts/bootstrap-board.sh
```

Follow the printed instructions to register via `http://localhost:3100`.

### 4. Create company

After registering, create the "Superuser HQ" company via the UI.

## Ongoing Updates

```sh
ssh server-b
/opt/paperclip/scripts/update.sh
```

## Useful Commands

```sh
# Check status
cd /opt/paperclip/repo && docker compose ps

# View logs
cd /opt/paperclip/repo && docker compose logs -f server

# View DB tables
cd /opt/paperclip/repo && docker compose exec db psql -U paperclip -c '\dt'

# Restart
cd /opt/paperclip/repo && docker compose restart

# Stop (temporary — will restart on next boot)
cd /opt/paperclip/repo && docker compose down

# Stop and disable (permanent — won't restart on boot)
sudo systemctl stop paperclip
sudo systemctl disable paperclip

# Backup DB
cd /opt/paperclip/repo && docker compose exec db pg_dump -U paperclip paperclip > backup.sql
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Health check fails | `docker compose logs server` — check for migration errors |
| Port in use | `sudo ss -tlnp` and find conflicting process |
| Permission denied | Ensure user is in `docker` group: `sudo usermod -aG docker $USER` then re-login |
| Can't access UI | Verify SSH tunnel is active; check `PAPERCLIP_PUBLIC_URL` in `.env` |
