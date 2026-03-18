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

## Authentication

### OAuth App (Linear API access)

Uses `client_credentials` grant with `actor=app` — a server-to-server flow with no user interaction.

**One-time setup:**

1. Create OAuth app at `linear.app/settings/api/applications/new`
2. Name: "Paperclip", enable `client_credentials` grant
3. Scopes: `read`, `write`
4. Copy `client_id` and `client_secret` → store in `shq_linear_config` table

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

### Request Flow

1. Read raw body (before JSON parsing) for HMAC verification
2. Verify signature + timestamp
3. Resolve company: match Linear workspace ID from payload against `shq_linear_config.workspaceId`. If no match, return 200 and ignore (integration not configured for this workspace). For SHQ's single-company setup, there is one row in `shq_linear_config`.
4. Check `linear-delivery` header against dedup cache — skip if already processed
5. Parse JSON payload
6. Dispatch by `type` field:
   - `Issue` with `action: "create"` → create Paperclip task
   - `Issue` with `action: "update"` → update Paperclip task
   - `Issue` with `action: "remove"` → cancel Paperclip task
   - `IssueLabel` → update label cache
7. Add `linear-delivery` to dedup cache
8. Return `200` (must respond within 5 seconds or Linear retries)

### Issue Event Handling

**On create:**

1. Extract `labelIds` from `data`
2. Resolve via label cache (fallback: query Linear API for unknown IDs, update cache)
3. Filter to department labels (those present in `shq_linear_label_routes`)
4. If zero department labels → ignore, return 200
5. If multiple department labels → post comment on Linear issue via API: "Conflicting department labels: [list]. Please use exactly one of: engineering, marketing, sales." Return 200.
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

1. Find existing Paperclip task via `shq_linear_issue_map` by `linearIssueId`
2. If not found → ignore (was probably an unlabeled ticket)
3. If `updatedFrom` contains `labelIds` change:
   - Re-evaluate department label
   - If conflicting → post comment, do not update
   - If changed to a different department → reassign to new chief
   - If department label removed → cancel the task
4. Update title, description, priority if changed

**On remove:**

1. Find existing Paperclip task via `shq_linear_issue_map` by `linearIssueId`
2. If found → set status to `cancelled`

### Idempotency

- `linear-delivery` header (UUID) stored in an LRU cache with 1-hour TTL and max 10,000 entries (e.g. `lru-cache` package)
- Duplicate deliveries (from Linear's retry mechanism) are silently skipped
- Task creation uses unique constraint on `(companyId, linearIssueId)` in `shq_linear_issue_map` as a second safety net

## Label Cache

**Purpose:** Translate Linear label UUIDs to names for routing decisions.

**Implementation:** In-memory `Map<string, string>` (label UUID → label name).

**Lifecycle:**

1. **Boot:** Fetch all labels from Linear GraphQL API (`issueLabels { nodes { id name } }`), populate map
2. **IssueLabel webhook:** On `create`/`update`/`remove` events, update the map entry
3. **Fallback:** If a webhook arrives with an unknown label ID, query Linear API for that specific label, add to cache
4. **Restart:** Cache rebuilt from Linear API on next boot (not persisted)

## Conflict Handling

When an issue has multiple department labels (e.g. both `engineering` and `marketing`):

1. Do NOT create a Paperclip task
2. Post a comment on the Linear issue via the OAuth app token:
   > "Conflicting department labels: engineering, marketing. Paperclip requires exactly one department label for routing. Please remove one."
3. The comment appears as posted by "Paperclip" (the OAuth app actor)
4. When the user fixes the labels and saves, Linear fires an update webhook, and normal processing resumes

## Data Model

### New Tables (SHQ-specific, prefixed)

**`shq_linear_config`** — per-company Linear integration settings

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `companyId` | uuid | FK → companies, unique |
| `workspaceId` | text | Linear workspace ID |
| `webhookSecret` | text | HMAC signing secret |
| `oauthClientId` | text | OAuth app client ID |
| `oauthClientSecret` | text | Encrypted at application layer using Paperclip's secrets adapter (`ENCRYPTION_KEY`) |
| `accessToken` | text | Encrypted at application layer using Paperclip's secrets adapter (`ENCRYPTION_KEY`) |
| `tokenExpiresAt` | timestamp | 30-day rolling expiry |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | |

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

**`shq_linear_issue_map`** — maps Linear issues to Paperclip tasks (avoids modifying upstream `issues` table)

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `companyId` | uuid | FK → companies |
| `linearIssueId` | text | Linear issue UUID |
| `linearIdentifier` | text | Linear identifier (e.g. "DEV-123") |
| `issueId` | uuid | FK → issues (Paperclip task) |
| `createdAt` | timestamp | |

Unique constraint on `(companyId, linearIssueId)`. Index on `issueId` for reverse lookups.

This avoids modifying the upstream `issues` schema, eliminating rebase conflicts. The upstream `plugin_entities` table was considered but not used — it's tied to the plugin lifecycle and registration system, which adds unnecessary coupling for this SHQ-specific integration.

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

## Configuration

### Environment Variables

None required — all config stored in `shq_linear_config` DB table. This avoids Railway redeployments for config changes.

### Initial Setup (one-time, manual)

1. Create Linear OAuth app → get `client_id` + `client_secret`
2. Create Linear webhook → get signing secret
3. Insert row into `shq_linear_config` with credentials
4. Insert rows into `shq_linear_label_routes` mapping labels to agents
5. Paperclip fetches labels on next boot and starts processing webhooks

A setup API or CLI command can automate step 3-4 in future.

## Error Handling

| Scenario | Behavior |
|---|---|
| Invalid HMAC signature | Return 401, log warning |
| Stale timestamp (>5min) | Return 401, log warning |
| Duplicate delivery | Return 200, skip processing |
| Unknown label ID | Query Linear API, update cache, continue |
| Linear API down (label query) | Log error, skip task creation, Linear will retry webhook |
| Task creation fails | Return 500, Linear retries (1min, 1hr, 6hr) |
| No `shq_linear_config` for company | Return 200, ignore (integration not configured) |
| Excessive requests | HMAC verification + dedup cache provide sufficient protection for initial deployment. Rate limiting deferred — Linear's own IP allowlist and retry limits (max 3) bound inbound traffic. |

## Out of Scope

- Outbound sync: Paperclip → Linear (DEV-394)
- Bidirectional status mapping (DEV-395)
- Comment sync between Linear and Paperclip
- Multi-workspace support (one workspace per company for now)
- UI for managing Linear integration settings (API/DB only for now)

## Dependencies

- Linear OAuth app created in Superuser HQ workspace
- Linear webhook pointing at Paperclip's Railway URL
- Chief of staff agents (Rem, Kani) registered in Paperclip with agent IDs
