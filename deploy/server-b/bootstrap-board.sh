#!/usr/bin/env bash
# bootstrap-board.sh — Generate board invite after Paperclip deployment
# Run this after deploy.sh completes.
set -euo pipefail

REPO_DIR="/opt/paperclip/repo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

# ─── Find the server container ──────────────────────────────

echo "=== Paperclip Board Bootstrap ==="
echo ""

cd "${REPO_DIR}"
if ! docker compose ps -q server 2>/dev/null | grep -q .; then
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
# onboard is idempotent — safe to re-run, may warn if already done
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
BOOTSTRAP_EXIT=0
if BOOTSTRAP_OUTPUT="$(
  docker compose exec -T \
    -e PAPERCLIP_HOME=/paperclip \
    -e PAPERCLIP_PUBLIC_URL=http://localhost:3100 \
    server \
    bash -lc 'npx --yes paperclipai@latest auth bootstrap-ceo --data-dir "$PAPERCLIP_HOME" --base-url "$PAPERCLIP_PUBLIC_URL"' \
  2>&1
)"; then
  BOOTSTRAP_EXIT=0
else
  BOOTSTRAP_EXIT=$?
fi

if [ "$BOOTSTRAP_EXIT" -ne 0 ] && [ "$BOOTSTRAP_EXIT" -ne 124 ]; then
  echo "Bootstrap output:"
  printf '%s\n' "${BOOTSTRAP_OUTPUT}"
  fatal "bootstrap-ceo failed with exit code ${BOOTSTRAP_EXIT}"
fi

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
