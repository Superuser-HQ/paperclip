#!/usr/bin/env bash
# lib.sh — Shared helpers for Server B deployment scripts
# Source this file: . "$(dirname "$0")/lib.sh"

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

generate_env_file() {
  local template_path="$1"
  local output_path="$2"

  if [ -f "${output_path}" ]; then
    info ".env already exists (preserving existing secrets)"
    return 0
  fi

  local secret
  secret="$(openssl rand -hex 32)"
  sed "s/__GENERATE_ME__/${secret}/" "${template_path}" > "${output_path}"
  info ".env created with generated BETTER_AUTH_SECRET"
}

containers_running() {
  local compose_file="$1"
  docker compose -f "${compose_file}" ps -q server 2>/dev/null | grep -q .
}
