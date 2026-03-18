# DEV-396: Deploy Paperclip on Server B — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Paperclip (control plane) with PostgreSQL, API, and UI accessible via public URL. Primary target is Railway; Docker Compose on VPS is the fallback.

**Architecture:** Railway project with two services (Paperclip server from Dockerfile + managed Postgres). Existing Docker Compose scripts in `deploy/server-b/` serve as the self-hosted fallback.

**Tech Stack:** Railway, Docker, PostgreSQL 17, Bash (fallback scripts)

**Spec:** `doc/shq/plans/2026-03-17-server-b-deployment-design.md`

---

## Chunk 1: Railway Project Setup

### Task 1: Create Railway project and add Postgres

- [ ] **Step 1: Create the Railway project**

  Via Railway CLI or dashboard. Connect to `Superuser-HQ/paperclip` private repo.

  ```sh
  railway init  # or use Railway MCP / dashboard
  ```

- [ ] **Step 2: Add PostgreSQL service**

  ```sh
  railway add -d postgres
  ```

- [ ] **Step 3: Verify Postgres is running**

  ```sh
  railway variables  # should show DATABASE_URL from Postgres service
  ```

---

### Task 2: Configure environment variables

- [ ] **Step 1: Generate BETTER_AUTH_SECRET locally**

  ```sh
  openssl rand -hex 32
  ```

- [ ] **Step 2: Set all required variables on the server service**

  ```sh
  railway variables set \
    DATABASE_URL='${{Postgres.DATABASE_URL}}' \
    BETTER_AUTH_SECRET=<generated-secret> \
    PAPERCLIP_DEPLOYMENT_MODE=authenticated \
    PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
    PORT=3100 \
    SERVE_UI=true
  ```

  Mark `BETTER_AUTH_SECRET` as sealed in the Railway dashboard after setting.

- [ ] **Step 3: Generate public domain**

  ```sh
  railway domain
  ```

- [ ] **Step 4: Set PAPERCLIP_PUBLIC_URL to the generated domain**

  ```sh
  railway variables set PAPERCLIP_PUBLIC_URL=https://<generated>.up.railway.app
  ```

---

## Chunk 2: Deploy and Verify

### Task 3: Deploy Paperclip

- [ ] **Step 1: Trigger deployment**

  If GitHub is connected, push to `main` triggers auto-deploy. Otherwise:

  ```sh
  railway up
  ```

- [ ] **Step 2: Monitor deployment logs**

  ```sh
  railway logs
  ```

  Watch for:
  - Dockerfile build completing
  - Database migrations running
  - Server starting on port 3100

- [ ] **Step 3: Verify health check**

  ```sh
  curl https://<app>.up.railway.app/api/health
  # Expected: {"status":"ok"}
  ```

- [ ] **Step 4: Verify UI is accessible**

  Open `https://<app>.up.railway.app` in a browser. Should see the Paperclip login page.

---

### Task 4: Bootstrap board user

- [ ] **Step 1: Open a shell in the running container**

  ```sh
  railway shell
  ```

- [ ] **Step 2: Run bootstrap-ceo inside the container**

  ```sh
  npx paperclipai@latest auth bootstrap-ceo \
    --data-dir /paperclip \
    --base-url "$PAPERCLIP_PUBLIC_URL"
  ```

- [ ] **Step 3: Copy the invite URL from the output**

  Look for a URL like: `https://<app>.up.railway.app/invite/pcp_bootstrap_...`

- [ ] **Step 4: Register board user**

  Open the invite URL in your browser. Register with name/email/password.

- [ ] **Step 5: Create the "Superuser HQ" company via the UI**

---

## Chunk 3: Acceptance Verification

### Task 5: Run acceptance checks

- [ ] **Step 1: Health check**

  ```sh
  curl -s https://<app>.up.railway.app/api/health | grep -q '"status":"ok"'
  ```

- [ ] **Step 2: UI accessible**

  ```sh
  curl -s -o /dev/null -w '%{http_code}' https://<app>.up.railway.app/
  # Expected: 200
  ```

- [ ] **Step 3: Database initialised**

  Migrations auto-applied on boot. Verify by checking that the health endpoint works (it queries the DB).

- [ ] **Step 4: Company created**

  Log in to the UI and verify "Superuser HQ" company exists.

---

## Chunk 4: Docker Compose Fallback (Already Complete)

The self-hosted fallback scripts already exist in `deploy/server-b/`:

| File | Status |
|------|--------|
| `deploy/server-b/deploy.sh` | Done |
| `deploy/server-b/bootstrap-board.sh` | Done |
| `deploy/server-b/update.sh` | Done |
| `deploy/server-b/docker-compose.override.yml` | Done |
| `deploy/server-b/paperclip.service` | Done |
| `deploy/server-b/.env.template` | Done |
| `deploy/server-b/lib.sh` | Done |
| `deploy/server-b/tests/lib.bats` | Done |
| `deploy/server-b/README.md` | Done |

No changes needed — these serve as the fallback if Railway doesn't work out.

---

## Chunk 5: Documentation Updates

### Task 6: Update fork discipline tracking

- [ ] **Step 1: Update `doc/shq/UPSTREAM-MODIFICATIONS.md`**

  Ensure the Railway deployment approach is documented. No upstream files are modified.

- [ ] **Step 2: Update design spec status**

  Change frontmatter `status: draft` to `status: active` in `doc/shq/plans/2026-03-17-server-b-deployment-design.md` after successful deployment.

---

## Chunk 6: Post-Deploy Configuration

### Task 7: Linear webhook setup (after deployment)

- [ ] **Step 1: Configure Linear webhook**

  In Linear workspace settings, add webhook pointing to:

  ```
  https://<app>.up.railway.app/api/webhooks/linear
  ```

  Note: This replaces the Cloudflare Tunnel approach from the original design. Railway's public URL provides direct webhook ingress with auto-SSL.

- [ ] **Step 2: Verify webhook delivery**

  Create a test Linear issue and check Railway logs for the incoming webhook.
