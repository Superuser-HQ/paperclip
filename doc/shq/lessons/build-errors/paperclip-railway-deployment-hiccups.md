---
title: "Deploying Paperclip to Railway — build and runtime fixes"
category: build-errors
date: 2026-03-18
tags: [railway, docker, dockerfile, pnpm, lockfile, plugin-sdk, database-url, deployment]
severity: high
---

# Deploying Paperclip to Railway — build and runtime fixes

## Problem

Deploying Paperclip's Dockerfile to Railway failed at multiple stages: banned `VOLUME` keyword, stale lockfile, missing workspace package in COPY, missing build step, and finally a runtime crash due to missing `DATABASE_URL`.

## Issues and Fixes (in order encountered)

### 1. Railway bans `VOLUME` keyword

**Error:** `The 'VOLUME' keyword is banned in Dockerfiles. Use Railway volumes instead.`

**Fix:** Comment out `VOLUME ["/paperclip"]` in the Dockerfile. Railway manages volumes via its platform, not Dockerfile directives.

### 2. Stale pnpm lockfile (`cross-env` missing)

**Error:** `ERR_PNPM_OUTDATED_LOCKFILE — Cannot install with "frozen-lockfile" because pnpm-lock.yaml is not up to date with package.json`

**Root cause:** `cross-env` was added to `package.json` but the lockfile wasn't regenerated. The "Refresh Lockfile" CI workflow existed but hadn't run.

**Fix:** Synced fork with upstream (which had the updated lockfile), then rebased the feature branch. Note: GitHub's "Sync fork" button only works on the default branch — for other branches, use `git rebase origin/upstream` locally.

### 3. Missing `packages/plugins/` COPY in Dockerfile

**Error:** `error TS2307: Cannot find module '@paperclipai/plugin-sdk'`

**Root cause:** Upstream added `packages/plugins/sdk/` (and other plugin packages) as workspace deps but didn't update the Dockerfile's COPY step. `pnpm install --frozen-lockfile` needs all workspace package.json files present.

**Fix:** Add COPY lines for all plugin packages:
```dockerfile
COPY packages/plugins/sdk/package.json packages/plugins/sdk/
COPY packages/plugins/create-paperclip-plugin/package.json packages/plugins/create-paperclip-plugin/
COPY packages/plugins/examples/plugin-authoring-smoke-example/package.json packages/plugins/examples/plugin-authoring-smoke-example/
COPY packages/plugins/examples/plugin-file-browser-example/package.json packages/plugins/examples/plugin-file-browser-example/
COPY packages/plugins/examples/plugin-hello-world-example/package.json packages/plugins/examples/plugin-hello-world-example/
COPY packages/plugins/examples/plugin-kitchen-sink-example/package.json packages/plugins/examples/plugin-kitchen-sink-example/
```

### 4. plugin-sdk not built before server

**Error:** Same TS2307 — `pnpm install` succeeded but `tsc` couldn't find the module's type declarations.

**Root cause:** The server imports from `@paperclipai/plugin-sdk`, which needs to be compiled first so `dist/` exists with type declarations.

**Fix:** Add a build step before the server build:
```dockerfile
RUN pnpm --filter @paperclipai/plugin-sdk build
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/server build
```

### 5. Runtime crash — no DATABASE_URL

**Error:** `Embedded PostgreSQL failed; Postgres init script exited with code 1`

**Root cause:** Without `DATABASE_URL`, Paperclip falls back to embedded PGlite, which can't initialize under the `node` user in the container. The env var wasn't set yet on the Railway service.

**Fix:** Set `DATABASE_URL` on the paperclip service pointing to Railway's managed Postgres using the internal connection string (`postgres.railway.internal:5432`). Also set `PAPERCLIP_PUBLIC_URL` to the Railway domain so the hostname is allowed.

## Prevention

- When syncing with upstream, check the Dockerfile's COPY list against `pnpm-workspace.yaml` — any new workspace package needs a corresponding COPY line.
- Always set `DATABASE_URL` before the first deploy on Railway. Use `railway variables --service <name> --set "KEY=value"` or the dashboard.
- Railway's `${{Service.VAR}}` reference syntax doesn't work via CLI (shell interprets `${{`). Use the dashboard for cross-service references, or hardcode the internal connection string.
- Track all Dockerfile modifications in `doc/shq/UPSTREAM-MODIFICATIONS.md` per fork discipline.
