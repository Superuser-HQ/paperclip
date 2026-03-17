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

# ─── Git ────────────────────────────────────────────────────

if ! command -v git >/dev/null 2>&1; then
  echo "Installing git..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq git
  info "Git installed"
fi

# ─── Docker ─────────────────────────────────────────────────

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
  warn "User '$USER' has been added to the 'docker' group."
  fatal "Please log out and log back in, then re-run this script for the group change to take effect."
else
  info "Docker already installed"
  if ! docker info >/dev/null 2>&1; then
    fatal "Docker is installed but current user cannot connect to the daemon. Check: sudo usermod -aG docker $USER, then re-login."
  fi
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
