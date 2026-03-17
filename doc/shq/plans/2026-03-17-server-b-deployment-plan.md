# DEV-396: Deploy Paperclip on Server B — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create deployment automation for Paperclip on Server B (Postgres + API + UI) and a runbook for executing the deployment.

**Architecture:** Shell scripts in `deploy/server-b/` that automate Docker Compose deployment on Ubuntu. A `docker-compose.override.yml` adds restart policies without modifying the upstream compose file. A systemd unit manages boot lifecycle.

**Tech Stack:** Bash, Docker Compose, systemd, PostgreSQL 17

**Spec:** `doc/shq/plans/2026-03-17-server-b-deployment-design.md`

---

## File Structure

| File | Purpose |
|------|---------|
| `deploy/server-b/deploy.sh` | First-time deployment: installs Docker, clones repo, generates secrets, starts containers, installs systemd service |
| `deploy/server-b/bootstrap-board.sh` | Post-deploy: runs bootstrap-ceo inside container, prints invite URL |
| `deploy/server-b/update.sh` | Ongoing: pulls latest, rebuilds, restarts, health checks |
| `deploy/server-b/docker-compose.override.yml` | Adds `restart: unless-stopped` to both services |
| `deploy/server-b/paperclip.service` | Systemd unit file for boot lifecycle |
| `deploy/server-b/.env.template` | Template for `.env` with placeholders and documentation |
| `deploy/server-b/README.md` | Deployment runbook (step-by-step for human operator) |
| `doc/shq/UPSTREAM-MODIFICATIONS.md` | Fork discipline: document that no upstream files are modified (this ticket only adds new files) |

---

## Chunk 1: Environment Template and Override

### Task 1: Create `.env.template`

**Files:**
- Create: `deploy/server-b/.env.template`

- [ ] **Step 1: Create the `.env.template` file**

```bash
# ============================================================
# Paperclip Server B — Environment Configuration
# ============================================================
# Copy this file to /opt/paperclip/repo/.env and fill in values.
# See: doc/shq/plans/2026-03-17-server-b-deployment-design.md
# ============================================================

# --- Generated at deploy time (deploy.sh fills this automatically) ---
BETTER_AUTH_SECRET=__GENERATE_ME__

# --- Deployment mode (do not change) ---
# DATABASE_URL is set in docker-compose.yml, not here
PAPERCLIP_DEPLOYMENT_MODE=authenticated
PAPERCLIP_DEPLOYMENT_EXPOSURE=private

# --- Networking (fill in when networking ticket is done) ---
# Replace with Tailscale hostname or Cloudflare Tunnel URL
PAPERCLIP_PUBLIC_URL=http://localhost:3100
# Additional Tailscale hostnames (comma-separated) if needed
# PAPERCLIP_ALLOWED_HOSTNAMES=

# --- Optional: Agent adapter API keys ---
# Not required on Server B (agents run on Server C)
# ANTHROPIC_API_KEY=
# OPENAI_API_KEY=
# CURSOR_API_KEY=
# GEMINI_API_KEY=
```

- [ ] **Step 2: Commit**

```bash
git add deploy/server-b/.env.template
git commit -m "feat: add .env template for Server B deployment"
```

---

### Task 2: Create `docker-compose.override.yml`

**Files:**
- Create: `deploy/server-b/docker-compose.override.yml`

- [ ] **Step 1: Create the override file**

```yaml
# Production overrides for Server B deployment.
# Placed alongside the upstream docker-compose.yml at /opt/paperclip/repo/.
# Docker Compose automatically merges this with docker-compose.yml.
services:
  db:
    restart: unless-stopped
    ports: !reset []  # Remove host port binding — Postgres only needs to be reachable within Docker network
  server:
    restart: unless-stopped
```

- [ ] **Step 2: Commit**

```bash
git add deploy/server-b/docker-compose.override.yml
git commit -m "feat: add docker-compose override with restart policy"
```

---

### Task 3: Create `paperclip.service` systemd unit

**Files:**
- Create: `deploy/server-b/paperclip.service`

- [ ] **Step 1: Create the unit file**

```ini
[Unit]
Description=Paperclip Control Plane
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/paperclip/repo
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Commit**

```bash
git add deploy/server-b/paperclip.service
git commit -m "feat: add systemd service for Paperclip auto-start"
```

---

## Chunk 2: Deploy Script

### Task 4: Create `deploy.sh`

**Files:**
- Create: `deploy/server-b/deploy.sh`

Reference: The smoke test at `scripts/docker-onboard-smoke.sh` shows patterns for health-check waiting and bootstrap-ceo invocation.

- [ ] **Step 1: Create `deploy.sh`**

```bash
#!/usr/bin/env bash
# deploy.sh — First-time Paperclip deployment on Server B (Ubuntu)
# Idempotent: safe to re-run.
# See: doc/shq/plans/2026-03-17-server-b-deployment-design.md
set -euo pipefail

INSTALL_DIR="/opt/paperclip"
REPO_DIR="${INSTALL_DIR}/repo"
REPO_URL="${PAPERCLIP_REPO_URL:-https://github.com/Superuser-HQ/paperclip.git}"
REPO_BRANCH="${PAPERCLIP_REPO_BRANCH:-main}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Helpers ────────────────────────────────────────────────

info()  { printf '  ✓ %s\n' "$1"; }
warn()  { printf '  ⚠ %s\n' "$1" >&2; }
fatal() { printf '  ✗ %s\n' "$1" >&2; exit 1; }

check_port() {
  local port="$1"
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    fatal "Port ${port} is already in use. Free it before deploying."
  fi
}

wait_for_health() {
  local url="$1"
  local attempts="${2:-60}"
  local i
  for ((i = 1; i <= attempts; i += 1)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# ─── Prerequisites ──────────────────────────────────────────

echo "=== Paperclip Server B Deploy ==="
echo ""

echo "Checking prerequisites..."

# Skip port checks if containers are already running (idempotent re-run)
if docker compose -f "${REPO_DIR}/docker-compose.yml" ps -q server 2>/dev/null | grep -q .; then
  info "Paperclip containers already running (re-run mode)"
else
  check_port 3100
  check_port 5432
  info "Ports 3100 and 5432 are free"
fi

# ─── Docker ─────────────────────────────────────────────────

if ! command -v git >/dev/null 2>&1; then
  echo "Installing git..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq git
  info "Git installed"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
  info "Docker installed"
else
  info "Docker already installed"
fi

# ─── Directory structure ────────────────────────────────────

echo "Setting up ${INSTALL_DIR}..."
sudo mkdir -p "${INSTALL_DIR}/scripts"
sudo chown -R "$USER:$USER" "${INSTALL_DIR}"

# ─── Clone / update repo ────────────────────────────────────

if [ -d "${REPO_DIR}/.git" ]; then
  echo "Updating repo..."
  git -C "${REPO_DIR}" fetch origin
  git -C "${REPO_DIR}" reset --hard "origin/${REPO_BRANCH}"
  info "Repo updated"
else
  echo "Cloning repo..."
  git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
  info "Repo cloned"
fi

# ─── Copy override + scripts ────────────────────────────────

cp "${SCRIPT_DIR}/docker-compose.override.yml" "${REPO_DIR}/docker-compose.override.yml"
cp "${SCRIPT_DIR}/deploy.sh" "${INSTALL_DIR}/scripts/deploy.sh"
cp "${SCRIPT_DIR}/bootstrap-board.sh" "${INSTALL_DIR}/scripts/bootstrap-board.sh"
cp "${SCRIPT_DIR}/update.sh" "${INSTALL_DIR}/scripts/update.sh"
chmod +x "${INSTALL_DIR}/scripts/"*.sh
info "Scripts and override copied"

# ─── Environment file ───────────────────────────────────────

ENV_FILE="${REPO_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  info ".env already exists (preserving existing secrets)"
else
  echo "Generating .env..."
  SECRET="$(openssl rand -hex 32)"
  sed "s/__GENERATE_ME__/${SECRET}/" "${SCRIPT_DIR}/.env.template" > "${ENV_FILE}"
  info ".env created with generated BETTER_AUTH_SECRET"
fi

# ─── Build and start ────────────────────────────────────────

echo "Building and starting containers..."
cd "${REPO_DIR}"
docker compose up -d --build

echo "Waiting for health check..."
if wait_for_health "http://localhost:3100/api/health" 90; then
  info "Paperclip is healthy"
else
  fatal "Health check failed after 3 minutes. Check: docker compose logs server"
fi

# ─── Systemd ────────────────────────────────────────────────

echo "Installing systemd service..."
sudo cp "${SCRIPT_DIR}/paperclip.service" /etc/systemd/system/paperclip.service
sudo systemctl daemon-reload
sudo systemctl enable paperclip.service
info "Systemd service installed and enabled"

# ─── Done ────────────────────────────────────────────────────

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Next steps:"
echo "  1. Open an SSH tunnel:  ssh -L 3100:localhost:3100 $(hostname)"
echo "  2. Run board bootstrap: ${INSTALL_DIR}/scripts/bootstrap-board.sh"
echo "  3. Register at http://localhost:3100 using the invite URL"
echo "  4. Create the 'Superuser HQ' company via the UI"
echo ""
echo "Later (networking ticket):"
echo "  - Update PAPERCLIP_PUBLIC_URL in ${ENV_FILE}"
echo "  - Update PAPERCLIP_ALLOWED_HOSTNAMES if needed"
echo "  - Restart: cd ${REPO_DIR} && docker compose up -d"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x deploy/server-b/deploy.sh
```

- [ ] **Step 3: Commit**

```bash
git add deploy/server-b/deploy.sh
git commit -m "feat: add deploy.sh for Server B first-time setup"
```

---

## Chunk 3: Bootstrap and Update Scripts

### Task 5: Create `bootstrap-board.sh`

**Files:**
- Create: `deploy/server-b/bootstrap-board.sh`

Reference: `scripts/docker-onboard-smoke.sh:50-92` for the `generate_bootstrap_invite_url` pattern.

- [ ] **Step 1: Create `bootstrap-board.sh`**

```bash
#!/usr/bin/env bash
# bootstrap-board.sh — Generate board invite after Paperclip deployment
# Run this after deploy.sh completes.
set -euo pipefail

REPO_DIR="/opt/paperclip/repo"
CONTAINER_NAME=""

info()  { printf '  ✓ %s\n' "$1"; }
fatal() { printf '  ✗ %s\n' "$1" >&2; exit 1; }

wait_for_health() {
  local url="$1"
  local attempts="${2:-60}"
  local i
  for ((i = 1; i <= attempts; i += 1)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# ─── Find the server container ──────────────────────────────

echo "=== Paperclip Board Bootstrap ==="
echo ""

cd "${REPO_DIR}"
CONTAINER_NAME="$(docker compose ps -q server 2>/dev/null)"
if [ -z "${CONTAINER_NAME}" ]; then
  fatal "Paperclip server container not running. Run deploy.sh first."
fi
info "Server container found"

# ─── Health check ────────────────────────────────────────────

echo "Waiting for health check..."
if wait_for_health "http://localhost:3100/api/health" 90; then
  info "Paperclip is healthy"
else
  fatal "Health check failed. Check: docker compose logs server"
fi

# ─── Onboard (creates config.json required by bootstrap-ceo) ─

echo "Running onboard inside container..."
docker compose exec -T \
  -e PAPERCLIP_HOME=/paperclip \
  -e PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  -e PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
  -e PAPERCLIP_PUBLIC_URL=http://localhost:3100 \
  server \
  bash -lc 'npx --yes paperclipai@latest onboard --yes --data-dir "$PAPERCLIP_HOME"' \
  >/dev/null 2>&1 || true
info "Onboard complete"

# ─── Bootstrap CEO ──────────────────────────────────────────

echo "Running bootstrap-ceo..."
BOOTSTRAP_OUTPUT="$(
  docker compose exec -T \
    -e PAPERCLIP_HOME=/paperclip \
    -e PAPERCLIP_PUBLIC_URL=http://localhost:3100 \
    server \
    bash -lc 'npx --yes paperclipai@latest auth bootstrap-ceo --data-dir "$PAPERCLIP_HOME" --base-url "$PAPERCLIP_PUBLIC_URL"' \
  2>&1
)" || true

INVITE_URL="$(
  printf '%s\n' "${BOOTSTRAP_OUTPUT}" \
    | grep -o 'https\?://[^[:space:]]*/invite/pcp_bootstrap_[[:alnum:]]*' \
    | tail -n 1
)"

if [ -z "${INVITE_URL}" ]; then
  echo "Bootstrap output:"
  printf '%s\n' "${BOOTSTRAP_OUTPUT}"
  fatal "Could not extract invite URL from bootstrap-ceo output"
fi

info "Bootstrap invite generated"

echo ""
echo "=== Board Registration ==="
echo ""
echo "1. Open an SSH tunnel (if not already open):"
echo "   ssh -L 3100:localhost:3100 $(hostname)"
echo ""
echo "2. Open this URL in your browser:"
echo "   ${INVITE_URL}"
echo ""
echo "3. Register with your name/email/password"
echo "4. You will be promoted to instance admin"
echo "5. Create the 'Superuser HQ' company via the UI"
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x deploy/server-b/bootstrap-board.sh
git add deploy/server-b/bootstrap-board.sh
git commit -m "feat: add bootstrap-board.sh for board user setup"
```

---

### Task 6: Create `update.sh`

**Files:**
- Create: `deploy/server-b/update.sh`

- [ ] **Step 1: Create `update.sh`**

```bash
#!/usr/bin/env bash
# update.sh — Pull latest code and rebuild Paperclip on Server B
set -euo pipefail

REPO_DIR="/opt/paperclip/repo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

info()  { printf '  ✓ %s\n' "$1"; }
fatal() { printf '  ✗ %s\n' "$1" >&2; exit 1; }

wait_for_health() {
  local url="$1"
  local attempts="${2:-60}"
  local i
  for ((i = 1; i <= attempts; i += 1)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

echo "=== Paperclip Update ==="
echo ""

# ─── Pull latest ────────────────────────────────────────────

echo "Pulling latest code..."
cd "${REPO_DIR}"
git pull --ff-only
info "Code updated"

# ─── Re-copy override (in case it changed in repo) ──────────

OVERRIDE_SRC="${REPO_DIR}/deploy/server-b/docker-compose.override.yml"
if [ -f "${OVERRIDE_SRC}" ]; then
  cp "${OVERRIDE_SRC}" "${REPO_DIR}/docker-compose.override.yml"
  info "Override file refreshed"
fi

# ─── Rebuild and restart ────────────────────────────────────

echo "Rebuilding and restarting..."
docker compose up -d --build
info "Containers restarted"

echo "Waiting for health check..."
if wait_for_health "http://localhost:3100/api/health" 90; then
  info "Paperclip is healthy"
else
  fatal "Health check failed after 3 minutes. Check: docker compose logs server"
fi

echo ""
echo "=== Update complete ==="
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x deploy/server-b/update.sh
git add deploy/server-b/update.sh
git commit -m "feat: add update.sh for ongoing Server B updates"
```

---

## Chunk 4: Runbook and Fork Discipline

### Task 7: Create deployment runbook

**Files:**
- Create: `deploy/server-b/README.md`

- [ ] **Step 1: Create the runbook**

```markdown
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
| Port in use | `sudo ss -tlnp \| grep :3100` — find and stop conflicting process |
| Permission denied | Ensure user is in `docker` group: `sudo usermod -aG docker $USER` then re-login |
| Can't access UI | Verify SSH tunnel is active; check `PAPERCLIP_PUBLIC_URL` in `.env` |
```

- [ ] **Step 2: Commit**

```bash
git add deploy/server-b/README.md
git commit -m "docs: add Server B deployment runbook"
```

---

### Task 8: Document fork discipline

**Files:**
- Create: `doc/shq/UPSTREAM-MODIFICATIONS.md` (if it doesn't exist)

- [ ] **Step 1: Create or update the file**

Check if `doc/shq/UPSTREAM-MODIFICATIONS.md` exists. If not, create it:

```markdown
# Upstream Modifications

Files modified from upstream Paperclip and why. Consult this when rebasing onto upstream releases.

## Modified Files

(none yet — all SHQ changes are in separate files/directories)

## Added Directories

| Directory | Purpose | Ticket |
|-----------|---------|--------|
| `deploy/server-b/` | Server B deployment automation | DEV-396 |
```

If it already exists, add the `deploy/server-b/` entry to the table.

- [ ] **Step 2: Commit**

```bash
git add doc/shq/UPSTREAM-MODIFICATIONS.md
git commit -m "docs: track deploy/server-b in upstream modifications"
```

---

## Chunk 5: Verification

### Task 9: Local verification

No Server B access needed — verify the scripts are syntactically correct and the compose override merges cleanly.

- [ ] **Step 1: Shellcheck all scripts**

```bash
shellcheck deploy/server-b/deploy.sh
shellcheck deploy/server-b/bootstrap-board.sh
shellcheck deploy/server-b/update.sh
```

Fix any issues found.

- [ ] **Step 2: Verify compose override merges**

```bash
cd /Users/geraldyeo/Code/superuserhq/internal/isengard
cp deploy/server-b/docker-compose.override.yml .
docker compose config
```

Expected: merged config shows `restart: unless-stopped` on both `db` and `server` services. Clean up after:

```bash
rm docker-compose.override.yml
```

- [ ] **Step 3: Verify .env.template produces valid .env**

```bash
SECRET="$(openssl rand -hex 32)"
sed "s/__GENERATE_ME__/${SECRET}/" deploy/server-b/.env.template > /tmp/test-env
grep -q "BETTER_AUTH_SECRET=${SECRET}" /tmp/test-env
rm /tmp/test-env
```

Expected: grep exits 0 (secret was substituted correctly).

- [ ] **Step 4: Run typecheck (repo sanity)**

```bash
pnpm -r typecheck
```

Expected: clean pass (no source files were modified).

- [ ] **Step 5: Commit any shellcheck fixes**

If shellcheck found issues, commit the fixes:

```bash
git add deploy/server-b/
git commit -m "fix: address shellcheck findings in deploy scripts"
```
