# Deployment Conventions

## Directory Structure

Deployment automation lives in `deploy/<server-name>/` (e.g., `deploy/server-b/`). Each server gets its own directory with:

- Shell scripts (`deploy.sh`, `update.sh`, etc.)
- `docker-compose.override.yml` — overrides for the upstream compose file
- `.env.template` — environment config template
- `README.md` — deployment runbook
- `lib.sh` — shared helpers (sourced by scripts, testable in isolation)
- `tests/` — BATS unit tests for `lib.sh`

## Docker Compose

- **Never modify the upstream `docker-compose.yml`.** Use `docker-compose.override.yml` for production overrides (restart policies, port changes, extra env vars).
- Docker Compose automatically merges override files when they sit alongside the main compose file.
- Use named volumes (not bind mounts) for production data.

## Scripts

- All scripts source `lib.sh` for shared helpers — don't duplicate `info()`, `fatal()`, `wait_for_health()`, etc.
- Scripts use `sudo` internally where needed — don't run the whole script as root.
- After Docker install, exit and require re-login for group changes to take effect.
- `update.sh` must refresh deployment scripts from the repo after `git pull`.

## Testing

- Use BATS for shell script unit tests.
- Extract testable logic into `lib.sh` so functions can be sourced and tested in isolation.
- Mock external commands (`docker`, `curl`, `ss`) via `export -f` in BATS tests.

## Fork Discipline

Track all SHQ-added directories in `doc/shq/UPSTREAM-MODIFICATIONS.md`.
