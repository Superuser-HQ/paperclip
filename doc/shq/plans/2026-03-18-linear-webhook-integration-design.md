---
title: 'DEV-392/393: Linear → Paperclip Webhook Integration'
status: draft
date: 2026-03-18
linear: DEV-392, DEV-393
---

# Linear → Paperclip Webhook Integration Design

## Overview

Integrate Linear with Paperclip so that creating a labeled ticket in Linear automatically creates a routed task in Paperclip. Linear tickets act as epics — the board creates them, agents break them into sub-tasks within Paperclip.

**Scope:** Inbound only (Linear → Paperclip). Outbound sync (Paperclip → Linear) is deferred to DEV-394.

## User Flow

1. Board member creates a Linear ticket and adds a department label (`engineering`, `marketing`, or `sales`)
2. Linear fires a webhook to Paperclip
3. Paperclip verifies the signature, resolves the label, and creates a task
4. Task is assigned to the department's chief of staff (Rem for engineering, Kani for marketing/sales)
5. Chief of staff agent wakes up via heartbeat and breaks the task into sub-tasks for specialist agents

## Architecture

```
Linear Workspace                          Paperclip (Railway)
────────────────                          ───────────────────
                                          ┌─ OAuth App Token ──→ Linear GraphQL API
                                          │  (boot: fetch labels, fallback queries)
                                          │
Issue created/updated ──→ Webhook POST ──→ POST /api/webhooks/linear
  with labelIds                           │
                                          ├─ Verify HMAC signature + timestamp
                                          ├─ Resolve labelIds via cached map
IssueLabel changed ───→ Webhook POST ──→  ├─ Update label cache
                                          │
                                          ├─ If exactly one dept label:
                                          │    Create/update Paperclip task
                                          │    Assign to chief of staff
                                          │    Wake agent via heartbeat
                                          ├─ If zero dept labels: ignore
                                          └─ If multiple dept labels:
                                               Post comment on Linear issue
                                               ("conflicting labels"), skip
```

**Deployment assumption:** Single Paperclip instance on Railway. In-memory caches (label map, dedup LRU) are acceptable because there is no horizontal scaling. The DB unique constraint on `shq_linear_issue_map` provides durable dedup for task creation across restarts.

## Authentication

### OAuth App (Linear API access)

Uses `client_credentials` grant with `actor=app` — a server-to-server flow with no user interaction.

**One-time setup:**

1. Create OAuth app at `linear.app/settings/api/applications/new`
2. Name: "Paperclip", enable `client_credentials` grant
3. Scopes: `read`, `write`
4. Copy `client_id` and `client_secret` → store in `shq_linear_config` table (secrets stored via Paperclip's `company_secrets` system)

**Token lifecycle:**

```
Paperclip                                     Linear API
─────────                                     ──────────
POST https://api.linear.app/oauth/token
  grant_type=client_credentials
  client_id=<stored>
  client_secret=<stored>
                                          ──→ { access_token, expires_in: 2592000 }

Store token + expiry in shq_linear_config
```

- On boot: check `tokenExpiresAt`, refresh if expired or within 24 hours of expiry
- On 401 from any Linear API call: refresh token and retry once
- No cron job — lazy refresh is sufficient for infrequent label resolution calls

### Webhook Verification

**One-time setup:**

1. In Linear settings → API → Webhooks → New webhook
2. URL: `https://paperclip-production-e0fa.up.railway.app/api/webhooks/linear`
3. Resource types: `Issue`, `IssueLabel`
4. Copy webhook signing secret → store in `shq_linear_config`

**Per-request verification:**

1. Compute HMAC-SHA256 of raw request body using the webhook secret
2. Compare against `linear-signature` header using `crypto.timingSafeEqual` (Express lowercases all headers)
3. Verify `webhookTimestamp` is within 5 minutes (300 seconds) of current time (replay protection, per Linear's recommendation)
4. Reject with 401 if verification fails

## Webhook Endpoint

**Route:** `POST /api/webhooks/linear`

**File:** `server/src/routes/linear-webhook.ts` (new file, isolated per fork discipline)

**Registration:** Mounted in `server/src/app.ts` alongside other route registrations: `app.use("/api/webhooks/linear", linearWebhookRoutes(db))`

### Request Flow

1. Read raw body (before JSON parsing) for HMAC verification
2. Verify signature + timestamp
3. Parse JSON payload
4. Resolve company: match `organizationId` from parsed payload against `shq_linear_config.workspaceId`. If no match, return 200 and ignore. For SHQ's single-company setup, there is one row in `shq_linear_config`.
5. Check `linear-delivery` header against dedup LRU cache — skip if already processed
6. Dispatch by `type` field:
   - `Issue` with `action: "create"` → create Paperclip task
   - `Issue` with `action: "update"` → create or update Paperclip task
   - `Issue` with `action: "remove"` → cancel Paperclip task
   - `IssueLabel` → update label cache
7. Add `linear-delivery` to dedup cache
8. Return `200` immediately

**Timeout budget:** Linear expects a response within 5 seconds. The synchronous path must only include: HMAC verification, JSON parse, DB lookup/write, and heartbeat wakeup. Deferred work (Linear API calls for conflict comments, fallback label queries) runs after returning 200 via `setImmediate` or the Express `res.on('finish')` pattern. This ensures the 5-second deadline is met even when Linear's API is slow.

### Issue Event Handling

**On create:**

1. Extract `labelIds` from `data`
2. Filter `labelIds` against known routable IDs in `shq_linear_label_routes` first (fast, no API call)
3. For any remaining unknown `labelIds`, check the label cache. If still unknown, defer a fallback query to Linear API (non-blocking — these are non-department labels and don't affect routing)
4. If zero department labels → ignore, return 200
5. If multiple department labels → defer a comment post on Linear issue via API: "Conflicting department labels: [list]. Please use exactly one of: engineering, marketing, sales." Return 200.
6. If exactly one department label:
   - Look up `agentId` from `shq_linear_label_routes`
   - Create Paperclip task with:
     - `title`: `"DEV-123: Original title"` (Linear identifier prefix)
     - `description`: Linear issue description
     - `priority`: mapped from Linear (see Priority Mapping table)
     - `status`: `todo` (not the default `backlog`, because Linear tickets represent board-approved work that should be immediately actionable by agents)
     - `assigneeAgentId`: chief of staff from routing table
   - Insert row into `shq_linear_issue_map` linking Linear issue UUID → Paperclip task ID
   - Wake assignee agent via `heartbeat.wakeup()`
   - Log activity

**On update:**

1. Extract `labelIds` from `data`
2. Find existing Paperclip task via `shq_linear_issue_map` by `linearIssueId`
3. **If not found** (late-labeling scenario — issue was created without a department label, then labeled later):
   - Evaluate department labels using the same logic as "On create"
   - If exactly one department label → create the task (same as create flow)
   - If zero or conflicting → ignore or post comment (same rules as create)
4. **If found** (existing mapped task):
   - If `updatedFrom` contains `labelIds` change:
     - Re-evaluate department labels
     - If conflicting → defer comment post, **pause the existing task** (set status to `backlog` to prevent agent work on a mis-routed task). When the user fixes labels, the next update webhook resumes routing.
     - If changed to a different single department → reassign to new chief of staff
     - If all department labels removed → cancel the task
   - Update title, description, priority if changed

**On remove:**

1. Find existing Paperclip task via `shq_linear_issue_map` by `linearIssueId`
2. If found → set status to `cancelled`

### Idempotency

- `linear-delivery` header (UUID) stored in an LRU cache with 1-hour TTL and max 10,000 entries (e.g. `lru-cache` package). This is ephemeral — lost on restart. Acceptable for single-instance deployment.
- Task creation uses unique constraint on `(companyId, linearIssueId)` in `shq_linear_issue_map` as the durable safety net. A DB constraint violation on insert means the task already exists — treat as a no-op, not an error.

## Label Cache

**Purpose:** Translate Linear label UUIDs to names for display and cache freshness. Routing decisions use `shq_linear_label_routes` directly (by label UUID), so the cache is not in the critical path for routing.

**Implementation:** In-memory `Map<string, string>` (label UUID → label name).

**Lifecycle:**

1. **Boot:** Fetch all labels from Linear GraphQL API (`issueLabels { nodes { id name } }`), populate map
2. **IssueLabel webhook:** On `create`/`update`/`remove` events, update the map entry
3. **Fallback:** If a webhook arrives with an unknown label ID not in `shq_linear_label_routes`, defer a query to Linear API for that label and update the cache (non-blocking)
4. **Restart:** Cache rebuilt from Linear API on next boot (not persisted)

## Conflict Handling

When an issue has multiple department labels (e.g. both `engineering` and `marketing`):

**On create (no existing task):**

1. Do NOT create a Paperclip task
2. Defer a comment post on the Linear issue via the OAuth app token:
   > "Conflicting department labels: engineering, marketing. Paperclip requires exactly one department label for routing. Please remove one."
3. The comment appears as posted by "Paperclip" (the OAuth app actor)
4. When the user fixes the labels and saves, Linear fires an update webhook, and the "late-labeling" path in "On update" creates the task

**On update (existing task already mapped):**

1. **Pause the existing task** — set status to `backlog` to prevent the assigned agent from continuing work on a mis-routed task
2. Defer a comment post on the Linear issue (same message as above)
3. When the user fixes the labels, the next update webhook re-evaluates: if a single valid label remains, reassign the task to the correct chief and set status back to `todo`

## Data Model

### New Tables (SHQ-specific, prefixed)

**`shq_linear_config`** — per-company Linear integration settings

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `companyId` | uuid | FK → companies, unique |
| `workspaceId` | text | Linear workspace ID |
| `webhookSecretId` | uuid | FK → `company_secrets` (HMAC signing secret) |
| `oauthClientId` | text | OAuth app client ID |
| `oauthClientSecretId` | uuid | FK → `company_secrets` (OAuth client secret) |
| `accessToken` | text | Current token (short-lived, 30-day rotation — stored directly, not in secrets system, since it's auto-refreshed) |
| `tokenExpiresAt` | timestamp | 30-day rolling expiry |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | |

Sensitive credentials (`webhookSecret`, `oauthClientSecret`) are stored via Paperclip's existing `company_secrets` / `company_secret_versions` system with the `local_encrypted` provider. This provides versioning, rotation, audit trails, and redaction — consistent with how other secrets are managed in the platform. The `accessToken` is stored directly in `shq_linear_config` because it's auto-refreshed every 30 days and doesn't need versioning.

**`shq_linear_label_routes`** — department label → agent routing

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `companyId` | uuid | FK → companies |
| `linearLabelId` | text | Linear label UUID |
| `linearLabelName` | text | Human-readable (e.g. "engineering") |
| `agentId` | uuid | FK → agents (chief of staff) |
| `createdAt` | timestamp | |

Unique constraint on `(companyId, linearLabelId)`.

**`shq_linear_issue_map`** — maps Linear issues to Paperclip tasks

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `companyId` | uuid | FK → companies |
| `linearIssueId` | text | Linear issue UUID |
| `linearIdentifier` | text | Linear identifier (e.g. "DEV-123") |
| `issueId` | uuid | FK → issues (Paperclip task) |
| `createdAt` | timestamp | |

Unique constraint on `(companyId, linearIssueId)`. Index on `issueId` for reverse lookups.

### Why not `plugin_entities`?

The upstream `plugin_entities` table is designed for structured external-entity mappings, but using it requires:
- Registering a plugin via the plugin manifest/lifecycle system
- Plugin must be in "ready" state for entity operations
- Entity CRUD routes are scoped under `/api/plugins/:pluginId/...`
- Plugin webhook deliveries table (`plugin_webhook_deliveries`) tracks deliveries per-plugin

This coupling means the Linear integration would depend on the plugin system being initialized and the plugin being in "ready" state — adding a fragile dependency to a critical integration path. The SHQ junction table (`shq_linear_issue_map`) is self-contained, has no external lifecycle dependencies, and is trivially queryable for routing lookups. The trade-off is a small amount of schema duplication in exchange for full isolation from upstream plugin system changes.

## Priority Mapping

Paperclip supports `critical`, `high`, `medium`, `low` (no `none` or `urgent`).

| Linear priority | Linear name | Paperclip priority |
|---|---|---|
| 0 | No priority | `medium` |
| 1 | Urgent | `critical` |
| 2 | High | `high` |
| 3 | Medium | `medium` |
| 4 | Low | `low` |

## File Structure

All new files isolated per fork discipline:

| File | Purpose |
|---|---|
| `server/src/routes/linear-webhook.ts` | Webhook endpoint route |
| `server/src/services/linear-integration.ts` | Label cache, OAuth token management, Linear API client |
| `packages/db/src/schema/shq-linear.ts` | `shq_linear_config` + `shq_linear_label_routes` + `shq_linear_issue_map` tables |
| `server/src/app.ts` | Mount point: `app.use("/api/webhooks/linear", ...)` (upstream file modification) |

## Configuration

### Environment Variables

None required — all config stored in `shq_linear_config` DB table (with secrets in `company_secrets`). This avoids Railway redeployments for config changes.

### Initial Setup (one-time, manual)

1. **Create Linear OAuth app:**
   - Go to `linear.app/settings/api/applications/new`
   - Name: "Paperclip", enable `client_credentials` grant, scopes: `read`, `write`
   - Copy `client_id` and `client_secret`

2. **Create Linear webhook:**
   - Go to Linear settings → API → Webhooks → New webhook
   - URL: `https://paperclip-production-e0fa.up.railway.app/api/webhooks/linear`
   - Resource types: `Issue`, `IssueLabel`
   - Copy the signing secret

3. **Obtain IDs:**
   - `workspaceId`: visible in Linear settings → API, or via GraphQL: `query { organization { id } }`
   - `linearLabelId` for each department label: visible in Linear settings → Labels, or via GraphQL: `query { issueLabels { nodes { id name } } }`
   - `agentId` for each chief of staff: visible in Paperclip UI on the agent detail page, or via API: `GET /api/companies/:companyId/agents`

4. **Insert config rows:**
   - Store `oauthClientSecret` and `webhookSecret` via Paperclip's secrets API (`POST /api/companies/:companyId/secrets`)
   - Insert row into `shq_linear_config` with `workspaceId`, `oauthClientId`, and FK references to the stored secrets
   - Insert rows into `shq_linear_label_routes` mapping each label UUID to the correct agent

5. **Verify:** Paperclip fetches labels on next boot. Create a test Linear issue with a department label and check that a Paperclip task appears.

A setup CLI command can automate steps 3-4 in future.

## Error Handling

| Scenario | Behavior |
|---|---|
| Invalid HMAC signature | Return 401, log warning |
| Stale timestamp (>5min) | Return 401, log warning |
| Duplicate delivery (LRU hit) | Return 200, skip processing |
| Duplicate delivery (DB constraint) | Return 200, treat as no-op |
| Unknown label ID (not in routes) | Not a department label — ignore for routing. Defer cache update via Linear API (non-blocking). |
| Linear API down (deferred calls) | Log error. Does not block task creation since routing uses `shq_linear_label_routes` directly. Conflict comments will be skipped — acceptable, user sees the issue in Linear regardless. |
| Task creation fails | Return 500, Linear retries (1min, 1hr, 6hr) |
| No matching `workspaceId` in config | Return 200, ignore (integration not configured for this workspace) |
| Route points to inactive agent | Log warning, create task but skip heartbeat wakeup. Task is visible in Paperclip UI for manual intervention. |
| Excessive requests | HMAC verification + dedup cache provide sufficient protection for initial single-instance deployment. Rate limiting deferred — Linear's own IP allowlist and retry limits (max 3) bound inbound traffic. |

## Out of Scope

- Outbound sync: Paperclip → Linear (DEV-394)
- Bidirectional status mapping (DEV-395)
- Comment sync between Linear and Paperclip
- Multi-workspace support (one workspace per company for now)
- Multi-instance / horizontal scaling (single Railway instance assumed)
- UI for managing Linear integration settings (API/DB only for now)

## Dependencies

- Linear OAuth app created in Superuser HQ workspace
- Linear webhook pointing at Paperclip's Railway URL
- Chief of staff agents (Rem, Kani) registered in Paperclip with agent IDs
