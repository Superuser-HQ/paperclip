#!/usr/bin/env bash
# update.sh — Pull latest code and rebuild Paperclip on Server B
set -euo pipefail

REPO_DIR="/opt/paperclip/repo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

echo "=== Paperclip Update ==="
echo ""

# ─── Pull latest ────────────────────────────────────────────

echo "Pulling latest code..."
cd "${REPO_DIR}"
git pull --ff-only
info "Code updated"

# ─── Re-copy override + scripts (in case they changed in repo) ─

DEPLOY_SRC="${REPO_DIR}/deploy/server-b"
if [ -d "${DEPLOY_SRC}" ]; then
  cp "${DEPLOY_SRC}/docker-compose.override.yml" "${REPO_DIR}/docker-compose.override.yml"
  cp "${DEPLOY_SRC}/"*.sh /opt/paperclip/scripts/
  chmod +x /opt/paperclip/scripts/*.sh
  info "Override and deployment scripts refreshed"
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
