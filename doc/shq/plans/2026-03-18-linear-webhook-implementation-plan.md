# Linear → Paperclip Webhook Integration — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a webhook endpoint that receives Linear issue events and creates routed Paperclip tasks assigned to the correct chief of staff agent.

**Architecture:** New Express route (`/api/webhooks/linear`) with HMAC verification, backed by three SHQ-prefixed DB tables and a Linear API client service. Label resolution uses an in-memory cache populated at boot. All SHQ code is isolated from upstream per fork discipline.

**Tech Stack:** TypeScript, Express, Drizzle ORM, Zod, Vitest, Linear GraphQL API, `lru-cache` (for webhook dedup)

**Spec:** `doc/shq/plans/2026-03-18-linear-webhook-integration-design.md`

---

## File Structure

| File | Purpose |
|------|---------|
| `packages/db/src/schema/shq-linear.ts` | Drizzle schema: `shq_linear_config`, `shq_linear_label_routes`, `shq_linear_issue_map` |
| `packages/db/src/schema/index.ts` | Re-export new tables (modify) |
| `packages/shared/src/validators/shq-linear.ts` | Zod validators for webhook payload and config |
| `packages/shared/src/validators/index.ts` | Re-export new validators (modify) |
| `server/src/services/linear-integration.ts` | OAuth token management, Linear GraphQL client, label cache |
| `server/src/routes/linear-webhook.ts` | Webhook endpoint: HMAC verify, dispatch, task create/update |
| `server/src/app.ts` | Mount webhook route (modify) |
| `server/src/__tests__/linear-webhook.test.ts` | Unit tests for webhook handling |
| `server/src/__tests__/linear-integration.test.ts` | Unit tests for Linear API client and label cache |
| `doc/shq/UPSTREAM-MODIFICATIONS.md` | Track `app.ts` modification (modify) |

---

## Chunk 1: Database Schema

### Task 1: Create SHQ Linear schema

**Files:**
- Create: `packages/db/src/schema/shq-linear.ts`
- Modify: `packages/db/src/schema/index.ts`

- [ ] **Step 1: Create the schema file**

```typescript
// packages/db/src/schema/shq-linear.ts
import { pgTable, uuid, text, timestamp, index, uniqueIndex } from "drizzle-orm/pg-core";
import { companies } from "./companies.js";
import { agents } from "./agents.js";
import { issues } from "./issues.js";
import { companySecrets } from "./company_secrets.js";

export const shqLinearConfig = pgTable(
  "shq_linear_config",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    companyId: uuid("company_id").notNull().references(() => companies.id),
    workspaceId: text("workspace_id").notNull(),
    webhookSecretId: uuid("webhook_secret_id").references(() => companySecrets.id),
    oauthClientId: text("oauth_client_id").notNull(),
    oauthClientSecretId: uuid("oauth_client_secret_id").references(() => companySecrets.id),
    accessToken: text("access_token"),
    tokenExpiresAt: timestamp("token_expires_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    companyUq: uniqueIndex("shq_linear_config_company_uq").on(table.companyId),
  }),
);

export const shqLinearLabelRoutes = pgTable(
  "shq_linear_label_routes",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    companyId: uuid("company_id").notNull().references(() => companies.id),
    linearLabelId: text("linear_label_id").notNull(),
    linearLabelName: text("linear_label_name").notNull(),
    agentId: uuid("agent_id").notNull().references(() => agents.id),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    companyLabelUq: uniqueIndex("shq_linear_label_routes_company_label_uq").on(
      table.companyId,
      table.linearLabelId,
    ),
  }),
);

export const shqLinearIssueMap = pgTable(
  "shq_linear_issue_map",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    companyId: uuid("company_id").notNull().references(() => companies.id),
    linearIssueId: text("linear_issue_id").notNull(),
    linearIdentifier: text("linear_identifier").notNull(),
    issueId: uuid("issue_id").notNull().references(() => issues.id),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    companyIssueUq: uniqueIndex("shq_linear_issue_map_company_issue_uq").on(
      table.companyId,
      table.linearIssueId,
    ),
    issueIdx: index("shq_linear_issue_map_issue_idx").on(table.issueId),
  }),
);
```

- [ ] **Step 2: Export from schema index**

Add to `packages/db/src/schema/index.ts`:

```typescript
export { shqLinearConfig, shqLinearLabelRoutes, shqLinearIssueMap } from "./shq-linear.js";
```

- [ ] **Step 3: Generate migration**

```bash
pnpm db:generate
```

- [ ] **Step 4: Typecheck**

```bash
pnpm -r typecheck
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/db/src/schema/shq-linear.ts packages/db/src/schema/index.ts packages/db/drizzle/
git commit -m "feat: add SHQ Linear integration schema (config, label routes, issue map)"
```

---

## Chunk 2: Validators

### Task 2: Create webhook payload validators

**Files:**
- Create: `packages/shared/src/validators/shq-linear.ts`
- Modify: `packages/shared/src/validators/index.ts`

- [ ] **Step 1: Create validators**

```typescript
// packages/shared/src/validators/shq-linear.ts
import { z } from "zod";

export const linearWebhookPayloadSchema = z.object({
  action: z.enum(["create", "update", "remove"]),
  type: z.string(),
  organizationId: z.string().optional(),
  data: z.record(z.unknown()),
  updatedFrom: z.record(z.unknown()).optional().nullable(),
  webhookTimestamp: z.number().optional(),
  webhookId: z.string().optional(),
});

export type LinearWebhookPayload = z.infer<typeof linearWebhookPayloadSchema>;

export const LINEAR_PRIORITY_MAP: Record<number, string> = {
  0: "medium",
  1: "critical",
  2: "high",
  3: "medium",
  4: "low",
};
```

- [ ] **Step 2: Export from validators index**

Add to `packages/shared/src/validators/index.ts`:

```typescript
export {
  linearWebhookPayloadSchema,
  LINEAR_PRIORITY_MAP,
  type LinearWebhookPayload,
} from "./shq-linear.js";
```

- [ ] **Step 3: Typecheck**

```bash
pnpm -r typecheck
```

Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add packages/shared/src/validators/shq-linear.ts packages/shared/src/validators/index.ts
git commit -m "feat: add Linear webhook payload validators and priority mapping"
```

---

## Chunk 3: Linear Integration Service

### Task 3: Create Linear API client and label cache

**Files:**
- Create: `server/src/services/linear-integration.ts`
- Create: `server/src/__tests__/linear-integration.test.ts`

- [ ] **Step 1: Write failing test for label cache**

```typescript
// server/src/__tests__/linear-integration.test.ts
import { beforeEach, describe, expect, it, vi } from "vitest";

describe("LinearLabelCache", () => {
  it("returns label name for known ID", () => {
    // Will fail until we implement
  });

  it("returns undefined for unknown ID", () => {
    // Will fail until we implement
  });

  it("updates cache on IssueLabel webhook event", () => {
    // Will fail until we implement
  });

  it("removes entry on IssueLabel remove event", () => {
    // Will fail until we implement
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pnpm test:run -- server/src/__tests__/linear-integration.test.ts
```

Expected: FAIL

- [ ] **Step 3: Implement LinearLabelCache**

```typescript
// server/src/services/linear-integration.ts
export class LinearLabelCache {
  private cache = new Map<string, string>();

  populate(labels: Array<{ id: string; name: string }>) {
    this.cache.clear();
    for (const label of labels) {
      this.cache.set(label.id, label.name);
    }
  }

  get(id: string): string | undefined {
    return this.cache.get(id);
  }

  set(id: string, name: string) {
    this.cache.set(id, name);
  }

  delete(id: string) {
    this.cache.delete(id);
  }

  has(id: string): boolean {
    return this.cache.has(id);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pnpm test:run -- server/src/__tests__/linear-integration.test.ts
```

Expected: PASS

- [ ] **Step 5: Write failing test for OAuth token refresh**

Add to the test file:

```typescript
describe("LinearApiClient", () => {
  it("fetches a new token when expired", async () => {
    // Mock fetch, verify token exchange call
  });

  it("retries on 401 with fresh token", async () => {
    // Mock fetch: first call 401, second call success
  });

  it("fetches all labels via GraphQL", async () => {
    // Mock GraphQL response with label nodes
  });
});
```

- [ ] **Step 6: Run test to verify it fails**

```bash
pnpm test:run -- server/src/__tests__/linear-integration.test.ts
```

Expected: FAIL

- [ ] **Step 7: Implement LinearApiClient**

Add to `server/src/services/linear-integration.ts`:

```typescript
import type { Db } from "@paperclipai/db";
import { shqLinearConfig } from "@paperclipai/db";
import { eq } from "drizzle-orm";

export class LinearApiClient {
  private accessToken: string | null = null;
  private tokenExpiresAt: Date | null = null;

  constructor(
    private clientId: string,
    private clientSecret: string,
    private db: Db,
    private configId: string,
  ) {}

  async ensureToken(): Promise<string> {
    const now = new Date();
    const buffer = 24 * 60 * 60 * 1000; // 24 hours
    if (this.accessToken && this.tokenExpiresAt && this.tokenExpiresAt.getTime() - now.getTime() > buffer) {
      return this.accessToken;
    }
    return this.refreshToken();
  }

  private async refreshToken(): Promise<string> {
    const resp = await fetch("https://api.linear.app/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: this.clientId,
        client_secret: this.clientSecret,
        actor: "app",
      }),
    });
    if (!resp.ok) {
      throw new Error("Linear token refresh failed: " + resp.status);
    }
    const data = await resp.json() as { access_token: string; expires_in: number };
    this.accessToken = data.access_token;
    this.tokenExpiresAt = new Date(Date.now() + data.expires_in * 1000);

    // Persist token to DB
    await this.db
      .update(shqLinearConfig)
      .set({
        accessToken: data.access_token,
        tokenExpiresAt: this.tokenExpiresAt,
        updatedAt: new Date(),
      })
      .where(eq(shqLinearConfig.id, this.configId));

    return this.accessToken;
  }

  async graphql<T>(query: string, variables?: Record<string, unknown>): Promise<T> {
    const token = await this.ensureToken();
    const resp = await fetch("https://api.linear.app/graphql", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ query, variables }),
    });
    if (resp.status === 401) {
      // Token expired — refresh and retry once
      const freshToken = await this.refreshToken();
      const retry = await fetch("https://api.linear.app/graphql", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: freshToken,
        },
        body: JSON.stringify({ query, variables }),
      });
      if (!retry.ok) throw new Error("Linear GraphQL failed after token refresh: " + retry.status);
      const retryData = await retry.json() as { data: T };
      return retryData.data;
    }
    if (!resp.ok) throw new Error("Linear GraphQL failed: " + resp.status);
    const result = await resp.json() as { data: T };
    return result.data;
  }

  async fetchAllLabels(): Promise<Array<{ id: string; name: string }>> {
    const data = await this.graphql<{ issueLabels: { nodes: Array<{ id: string; name: string }> } }>(
      `query { issueLabels { nodes { id name } } }`,
    );
    return data.issueLabels.nodes;
  }

  async fetchLabel(id: string): Promise<{ id: string; name: string } | null> {
    const data = await this.graphql<{ issueLabel: { id: string; name: string } | null }>(
      `query($id: String!) { issueLabel(id: $id) { id name } }`,
      { id },
    );
    return data.issueLabel;
  }

  async postComment(issueId: string, body: string): Promise<void> {
    await this.graphql(
      `mutation($issueId: String!, $body: String!) {
        commentCreate(input: { issueId: $issueId, body: $body }) {
          success
        }
      }`,
      { issueId, body },
    );
  }
}
```

- [ ] **Step 8: Run tests to verify they pass**

```bash
pnpm test:run -- server/src/__tests__/linear-integration.test.ts
```

Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add server/src/services/linear-integration.ts server/src/__tests__/linear-integration.test.ts
git commit -m "feat: add Linear API client with OAuth token management and label cache"
```

---

## Chunk 4: Webhook Route — Signature Verification

### Task 4: Create webhook route with HMAC verification

**Files:**
- Create: `server/src/routes/linear-webhook.ts`
- Create: `server/src/__tests__/linear-webhook.test.ts`

- [ ] **Step 1: Write failing test for HMAC verification**

```typescript
// server/src/__tests__/linear-webhook.test.ts
import crypto from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

describe("Linear webhook HMAC verification", () => {
  it("accepts valid signature", () => {
    const secret = "test-secret";
    const body = JSON.stringify({ type: "Issue", action: "create", data: {} });
    const rawBody = Buffer.from(body);
    const signature = crypto.createHmac("sha256", secret).update(rawBody).digest("hex");
    // verifySignature(signature, rawBody, secret) should return true
  });

  it("rejects invalid signature", () => {
    // verifySignature("bad-sig", body, secret) should return false
  });

  it("rejects stale timestamp (>5 min)", () => {
    // verifyTimestamp(Date.now() / 1000 - 400) should return false
  });

  it("accepts fresh timestamp (<5 min)", () => {
    // verifyTimestamp(Date.now() / 1000 - 60) should return true
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pnpm test:run -- server/src/__tests__/linear-webhook.test.ts
```

Expected: FAIL

- [ ] **Step 3: Implement verification helpers**

```typescript
// server/src/routes/linear-webhook.ts
import crypto from "node:crypto";
import { Router } from "express";
import type { Db } from "@paperclipai/db";

const TIMESTAMP_TOLERANCE_SECONDS = 300; // 5 minutes

export function verifySignature(signature: string, rawBody: Buffer, secret: string): boolean {
  const computed = crypto.createHmac("sha256", secret).update(rawBody).digest();
  try {
    return crypto.timingSafeEqual(computed, Buffer.from(signature, "hex"));
  } catch {
    return false;
  }
}

export function verifyTimestamp(webhookTimestamp: number): boolean {
  const now = Math.floor(Date.now() / 1000);
  return Math.abs(now - webhookTimestamp) <= TIMESTAMP_TOLERANCE_SECONDS;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pnpm test:run -- server/src/__tests__/linear-webhook.test.ts
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/src/routes/linear-webhook.ts server/src/__tests__/linear-webhook.test.ts
git commit -m "feat: add Linear webhook HMAC signature and timestamp verification"
```

---

## Chunk 5: Webhook Route — Event Dispatch and Task Creation

### Task 5: Implement webhook event handling

**Files:**
- Modify: `server/src/routes/linear-webhook.ts`
- Modify: `server/src/__tests__/linear-webhook.test.ts`

- [ ] **Step 1: Write failing test for issue create flow**

Add to the test file:

```typescript
describe("Linear webhook issue handling", () => {
  it("creates a Paperclip task when issue has exactly one department label", async () => {
    // Mock DB with shq_linear_config, shq_linear_label_routes
    // Send webhook with valid signature + one department label
    // Assert: issue created with correct title prefix, assignee, status
  });

  it("ignores issues with no department labels", async () => {
    // Send webhook with labels that are not in shq_linear_label_routes
    // Assert: no issue created
  });

  it("posts comment on conflicting department labels", async () => {
    // Send webhook with two department labels
    // Assert: no issue created, comment posted
  });

  it("creates task on update when issue was previously unlabeled", async () => {
    // Send update webhook with department label, no existing mapping
    // Assert: issue created (late-labeling)
  });

  it("reassigns task when department label changes on update", async () => {
    // Send update webhook with new department label, existing mapping
    // Assert: task reassigned to new chief
  });

  it("cancels task on remove", async () => {
    // Send remove webhook, existing mapping
    // Assert: task status set to cancelled
  });

  it("deduplicates by linear-delivery header", async () => {
    // Send same webhook twice with same delivery ID
    // Assert: only one task created
  });

  it("treats DB unique constraint violation on shq_linear_issue_map as no-op", async () => {
    // Insert a mapping row first, then send create webhook for same Linear issue
    // Assert: returns 200, no error, no duplicate task
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pnpm test:run -- server/src/__tests__/linear-webhook.test.ts
```

Expected: FAIL

- [ ] **Step 3: Implement the full webhook route**

Add to `server/src/routes/linear-webhook.ts` — the full route handler with:
- Raw body parsing middleware
- HMAC + timestamp verification
- Company resolution via `shq_linear_config.workspaceId`
- LRU dedup cache (`lru-cache` with TTL 1 hour, max 10,000)
- Issue create/update/remove dispatch
- Label cache update on IssueLabel events
- Deferred work (comment posting) via `setImmediate`

Key implementation details:
- Use `(req as any).rawBody` for HMAC verification — `app.ts` already captures raw body via the `verify` callback of `express.json()`. Do NOT use `express.raw()` (it would prevent JSON parsing). See `server/src/routes/plugins.ts:1959` for the existing pattern.
- Filter `labelIds` against `shq_linear_label_routes` first (no API call needed for routing)
- Task title format: `"DEV-123: Original title"` using `data.identifier`
- Validate new issue data against `createIssueSchema` before insertion
- Validate new issue data against `createIssueSchema` before insertion
- Task creation must be **atomic**: wrap `shq_linear_issue_map` insert + `issueService.create()` in a `db.transaction()`. Insert the map row first — if the unique constraint fails, the transaction rolls back and no duplicate task is created. This is the durable dedup safety net.
- On update with no mapping: treat as create (late-labeling)
- On update with conflict: pause task (set status to `backlog`) AND cancel active heartbeat runs via `heartbeatService(db).cancelActiveForAgent(agentId)` to stop the agent from continuing work on a mis-routed task. Defer comment post.
- Wake agent via `heartbeatService(db).wakeup()` after task creation/reassignment
- Call `logActivity()` explicitly for all mutation paths: create, reassign, cancel, conflict-pause, resume. The issue service does NOT auto-log — routes must call `logActivity()` from `server/src/services/index.ts`.
- Defer Linear API calls (comment posting, fallback label queries) via `setImmediate` to stay within 5-second timeout

Route factory signature accepts dependencies from boot-time initialization:
```typescript
export function linearWebhookRoutes(
  db: Db,
  deps: {
    labelCache: LinearLabelCache;
    client: LinearApiClient | null;
    config: typeof shqLinearConfig.$inferSelect | null;
  },
) {
  const router = Router();
  // ... route implementation
  return router;
}
```

- [ ] **Step 4: Install lru-cache**

```bash
pnpm add lru-cache --filter @paperclipai/server
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
pnpm test:run -- server/src/__tests__/linear-webhook.test.ts
```

Expected: PASS

- [ ] **Step 6: Typecheck**

```bash
pnpm -r typecheck
```

Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add server/src/routes/linear-webhook.ts server/src/__tests__/linear-webhook.test.ts server/package.json
git commit -m "feat: implement Linear webhook event handling with task creation and routing"
```

---

## Chunk 6: Route Registration and Integration

**Depends on:** Chunk 7 (init function must exist before mounting). Implement Chunk 7 first, then this chunk.

### Task 6: Mount webhook route and update docs

**Files:**
- Modify: `server/src/app.ts`
- Modify: `doc/shq/UPSTREAM-MODIFICATIONS.md`

- [ ] **Step 1: Mount the route in app.ts**

In `server/src/app.ts`, add the import:

```typescript
import { linearWebhookRoutes } from "./routes/linear-webhook.js";
import { initializeLinearIntegration } from "./services/linear-integration.js";
```

Mount **before** `actorMiddleware` (the auth middleware at ~line 98). The `actorMiddleware` rejects unauthenticated requests, but webhooks use HMAC verification instead of session/bearer auth. Find the line where `actorMiddleware` is applied and mount the webhook route above it:

```typescript
// Linear webhook — before actorMiddleware (uses HMAC, not session/bearer auth)
const linearIntegration = await initializeLinearIntegration(db);
app.use("/api/webhooks/linear", linearWebhookRoutes(db, linearIntegration));

// ... existing actorMiddleware, boardMutationGuard, etc.
```

Note: This means the app initialization function must be `async` or use `.then()`. Check how `app.ts` handles async startup and follow the existing pattern.

- [ ] **Step 2: Update UPSTREAM-MODIFICATIONS.md**

Add entry for `app.ts`:

```markdown
| `server/src/app.ts` | Added Linear webhook route mount | Linear integration requires a pre-auth webhook endpoint | DEV-400 |
```

- [ ] **Step 3: Typecheck and test**

```bash
pnpm -r typecheck && pnpm test:run
```

Expected: PASS

- [ ] **Step 4: Build**

```bash
pnpm build
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/src/app.ts doc/shq/UPSTREAM-MODIFICATIONS.md
git commit -m "feat: mount Linear webhook route in app.ts"
```

---

## Chunk 7: Boot-Time Initialization

**Execute this chunk BEFORE Chunk 6.** Chunk 6 depends on the `initializeLinearIntegration()` function defined here.

### Task 7: Implement initialization function with secret resolution

**Files:**
- Modify: `server/src/services/linear-integration.ts`
- Create: `server/src/__tests__/linear-init.test.ts`

Note: The mount point in `app.ts` was already handled in Task 6 using `initializeLinearIntegration`. This task implements the initialization function itself.

- [ ] **Step 1: Write failing test for initialization**

```typescript
// server/src/__tests__/linear-init.test.ts
import { describe, expect, it, vi } from "vitest";

describe("initializeLinearIntegration", () => {
  it("returns null client when no config exists", async () => {
    // Mock empty DB query
    // Assert: client is null, labelCache is empty
  });

  it("resolves client secret from company_secrets and creates client", async () => {
    // Mock DB with shq_linear_config row + company_secrets row
    // Assert: client is created with correct credentials
  });

  it("populates label cache on boot without blocking startup on failure", async () => {
    // Mock client.fetchAllLabels to throw
    // Assert: no error thrown, labelCache is empty, warning logged
  });
});
```

- [ ] **Step 2: Implement initialization function**

Add to `linear-integration.ts`:

```typescript
import { eq } from "drizzle-orm";
import { shqLinearConfig } from "@paperclipai/db";
import { secretService } from "./secrets.js";

export async function initializeLinearIntegration(db: Db): Promise<{
  client: LinearApiClient | null;
  labelCache: LinearLabelCache;
  config: typeof shqLinearConfig.$inferSelect | null;
  webhookSecret: string | null;
}> {
  const labelCache = new LinearLabelCache();
  const secrets = secretService(db);

  // Find config (single-company assumption — config changes require restart)
  const configs = await db.select().from(shqLinearConfig).limit(1);
  if (configs.length === 0) {
    return { client: null, labelCache, config: null, webhookSecret: null };
  }

  const config = configs[0];

  // Resolve secrets via Paperclip's secretService (handles provider-specific decryption)
  let resolvedClientSecret = "";
  let resolvedWebhookSecret = "";

  if (config.oauthClientSecretId) {
    const secret = await secrets.getById(config.oauthClientSecretId);
    if (secret) {
      const bindings = await secrets.resolveEnvBindings(config.companyId, {
        LINEAR_CLIENT_SECRET: { type: "secret_ref", secretId: secret.id, version: "latest" },
      });
      resolvedClientSecret = bindings.LINEAR_CLIENT_SECRET ?? "";
    }
  }

  if (config.webhookSecretId) {
    const secret = await secrets.getById(config.webhookSecretId);
    if (secret) {
      const bindings = await secrets.resolveEnvBindings(config.companyId, {
        LINEAR_WEBHOOK_SECRET: { type: "secret_ref", secretId: secret.id, version: "latest" },
      });
      resolvedWebhookSecret = bindings.LINEAR_WEBHOOK_SECRET ?? "";
    }
  }

  if (!resolvedClientSecret) {
    console.warn("Linear OAuth client secret not found — Linear integration disabled");
    return { client: null, labelCache, config, webhookSecret: null };
  }

  const client = new LinearApiClient(
    config.oauthClientId,
    resolvedClientSecret,
    db,
    config.id,
  );

  // Populate label cache — don't block startup on failure
  try {
    const labels = await client.fetchAllLabels();
    labelCache.populate(labels);
  } catch (err) {
    console.warn("Failed to populate Linear label cache on boot:", err);
  }

  return { client, labelCache, config, webhookSecret: resolvedWebhookSecret || null };
}
```

- [ ] **Step 3: Run tests**

```bash
pnpm test:run
```

Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add server/src/services/linear-integration.ts server/src/__tests__/linear-init.test.ts
git commit -m "feat: add boot-time Linear integration initialization with secret resolution"
```

---

## Chunk 8: End-to-End Verification

### Task 8: Local integration test

- [ ] **Step 1: Start the server locally**

```bash
pnpm dev
```

- [ ] **Step 2: Test webhook signature verification**

```bash
# Generate a test signature
SECRET="test-secret"
BODY='{"type":"Issue","action":"create","data":{"id":"test","title":"Test","labelIds":[]},"organizationId":"test-org"}'
SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')

curl -X POST http://localhost:3100/api/webhooks/linear \
  -H "Content-Type: application/json" \
  -H "linear-signature: $SIG" \
  -H "linear-delivery: test-delivery-1" \
  -d "$BODY"
```

Expected: 200 (ignored — no matching workspace config)

- [ ] **Step 3: Verify typecheck, tests, build all pass**

```bash
pnpm -r typecheck && pnpm test:run && pnpm build
```

Expected: All PASS

- [ ] **Step 4: Final commit (if any remaining changes)**

```bash
git status
# Stage only relevant files — do not use git add -A
git commit -m "feat: Linear webhook integration complete (DEV-392, DEV-393, DEV-400)"
```

---

## Chunk 9: Deploy and Configure

### Task 9: Deploy to Railway and configure Linear

- [ ] **Step 1: Push branch and create PR**

```bash
git push
```

Create PR targeting `main`.

- [ ] **Step 2: After merge, verify Railway deployment**

```bash
curl https://paperclip-production-e0fa.up.railway.app/api/health
```

Expected: `{"status":"ok"}`

- [ ] **Step 3: Run migration on Railway**

Railway auto-runs migrations on boot. Verify the new tables exist by checking the Railway logs for migration output, or connect via `railway shell` and inspect the database.

- [ ] **Step 4: Create Linear OAuth app**

1. Go to `linear.app/settings/api/applications/new`
2. Name: "Paperclip", enable `client_credentials`, scopes: `read`, `write`
3. Note `client_id` and `client_secret`

- [ ] **Step 5: Create Linear webhook**

1. Linear settings → API → Webhooks → New webhook
2. URL: `https://paperclip-production-e0fa.up.railway.app/api/webhooks/linear`
3. Resource types: `Issue`, `IssueLabel`
4. Note signing secret

- [ ] **Step 6: Store secrets and config in DB**

Store OAuth client secret and webhook secret via Paperclip's secrets API, then insert `shq_linear_config` row. Insert `shq_linear_label_routes` rows mapping each department label to its chief of staff agent.

Details in the design spec's "Initial Setup" section.

- [ ] **Step 7: Test end-to-end**

1. Create a test Linear issue with the `engineering` label
2. Check Paperclip UI — a task should appear assigned to Rem
3. Update the Linear issue title — Paperclip task title should update
4. Remove the department label — Paperclip task should be cancelled

- [ ] **Step 8: Close tickets**

Mark DEV-392, DEV-393, and DEV-400 as Done in Linear.
