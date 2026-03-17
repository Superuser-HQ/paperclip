#!/usr/bin/env bats
# Tests for deploy/server-b/lib.sh helper functions

setup() {
  # Source the library under test
  LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  . "${LIB_DIR}/lib.sh"

  # Create a temp dir for test artifacts
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# ─── info / warn / fatal ────────────────────────────────────

@test "info prints checkmark to stdout" {
  run info "hello world"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓"* ]]
  [[ "$output" == *"hello world"* ]]
}

@test "warn prints warning to stderr" {
  run warn "something bad"
  [ "$status" -eq 0 ]
  # bats captures stderr in output when using run
  [[ "$output" == *"⚠"* ]]
  [[ "$output" == *"something bad"* ]]
}

@test "fatal prints error and exits 1" {
  run fatal "catastrophe"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗"* ]]
  [[ "$output" == *"catastrophe"* ]]
}

# ─── check_port ─────────────────────────────────────────────

@test "check_port succeeds when port is free" {
  # Mock ss to return nothing (no ports in use)
  ss() { echo ""; }
  export -f ss

  run check_port 9999
  [ "$status" -eq 0 ]
}

@test "check_port fails when port is in use" {
  # Mock ss to report port 3100 in use
  ss() { echo "LISTEN 0 128 *:3100 *:*"; }
  export -f ss

  run check_port 3100
  [ "$status" -eq 1 ]
  [[ "$output" == *"3100"* ]]
  [[ "$output" == *"already in use"* ]]
}

# ─── wait_for_health ─────────────────────────────────────────

@test "wait_for_health succeeds when endpoint responds" {
  # Mock curl to succeed immediately
  curl() { return 0; }
  export -f curl

  run wait_for_health "http://localhost:3100/api/health" 3
  [ "$status" -eq 0 ]
}

@test "wait_for_health fails after max attempts" {
  # Mock curl to always fail
  curl() { return 1; }
  export -f curl

  # Override sleep to avoid actual waiting
  sleep() { :; }
  export -f sleep

  run wait_for_health "http://localhost:3100/api/health" 2
  [ "$status" -eq 1 ]
}

@test "wait_for_health retries until success" {
  # Track attempts via a file (subshell-safe)
  local counter_file="${TEST_TMPDIR}/curl_count"
  echo "0" > "$counter_file"

  export DEPLOY_TEST_COUNTER="${counter_file}"

  curl() {
    local count
    count="$(cat "$DEPLOY_TEST_COUNTER")"
    count=$((count + 1))
    echo "$count" > "$DEPLOY_TEST_COUNTER"
    if [ "$count" -ge 3 ]; then
      return 0
    fi
    return 1
  }
  export -f curl

  sleep() { :; }
  export -f sleep

  run wait_for_health "http://localhost:3100/api/health" 10
  [ "$status" -eq 0 ]
}

# ─── generate_env_file ───────────────────────────────────────

@test "generate_env_file creates .env from template" {
  local template="${TEST_TMPDIR}/template"
  local env_out="${TEST_TMPDIR}/.env"

  cat > "$template" <<'TMPL'
BETTER_AUTH_SECRET=__GENERATE_ME__
PAPERCLIP_DEPLOYMENT_MODE=authenticated
TMPL

  run generate_env_file "$template" "$env_out"
  [ "$status" -eq 0 ]
  [ -f "$env_out" ]

  # Secret should be substituted (no longer __GENERATE_ME__)
  run grep -c "__GENERATE_ME__" "$env_out"
  [ "$status" -ne 0 ]

  # Should contain a 64-char hex string
  run grep -E "^BETTER_AUTH_SECRET=[0-9a-f]{64}$" "$env_out"
  [ "$status" -eq 0 ]

  # Other values preserved
  run grep "PAPERCLIP_DEPLOYMENT_MODE=authenticated" "$env_out"
  [ "$status" -eq 0 ]
}

@test "generate_env_file preserves existing .env" {
  local template="${TEST_TMPDIR}/template"
  local env_out="${TEST_TMPDIR}/.env"

  echo "BETTER_AUTH_SECRET=existing_secret" > "$env_out"
  echo "BETTER_AUTH_SECRET=__GENERATE_ME__" > "$template"

  run generate_env_file "$template" "$env_out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]

  # Original secret preserved
  run grep "existing_secret" "$env_out"
  [ "$status" -eq 0 ]
}

# ─── containers_running ─────────────────────────────────────

@test "containers_running returns true when container is up" {
  # Mock docker to return a container ID
  docker() { echo "abc123"; }
  export -f docker

  run containers_running "/fake/docker-compose.yml"
  [ "$status" -eq 0 ]
}

@test "containers_running returns false when no containers" {
  # Mock docker to return nothing
  docker() { echo ""; }
  export -f docker

  run containers_running "/fake/docker-compose.yml"
  [ "$status" -ne 0 ]
}

@test "containers_running returns false when docker fails" {
  # Mock docker to fail (e.g., compose file not found)
  docker() { return 1; }
  export -f docker

  run containers_running "/fake/docker-compose.yml"
  [ "$status" -ne 0 ]
}
