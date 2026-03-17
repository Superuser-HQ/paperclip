# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Project Isengard** is Superuser HQ's fork of [Paperclip](https://github.com/paperclipai/paperclip), an open-source multi-agent orchestration platform. SHQ runs its company on Paperclip with AI agents as the workforce and humans (Yao as CEO, Gerald as CTO) as the board.

This repo **is** the Paperclip fork — it contains the full Paperclip codebase plus SHQ-specific customisations (Linear integration, custom adapters, agent persona configs).

## Key Resources

- **Design Spec**: `../operating-system/docs/plans/2026-03-16-project-isengard-paperclip-design.md`
- **ADR**: [Notion ADR-001](https://www.notion.so/superuser-hq/ADR-001-Paperclip-Org-Design-for-Superuser-HQ-32592b961aa5819992f4f1d0afea6d12)
- **Linear Project**: [Project Isengard](https://linear.app/superuser-hq/project/project-isengard-bc1c252d10d8) (tickets DEV-392 to DEV-421)
- **Shared Agent Utilities**: `../superagents-commons/` (framework-agnostic scripts, identity patterns, security guardrails)
- **SHQ docs**: `doc/shq/` — all SHQ-specific plans, designs, and ADRs go here (keeps fork docs separate from upstream `doc/`)
- **Read before making changes**: `doc/GOAL.md` → `doc/PRODUCT.md` → `doc/SPEC-implementation.md` → `doc/DEVELOPING.md` → `doc/DATABASE.md`

## Build & Development Commands

```sh
pnpm install              # install all dependencies
pnpm dev                  # start API + UI in watch mode (http://localhost:3100)
pnpm dev:once             # start without file watching
pnpm build                # build all packages
pnpm -r typecheck         # typecheck all packages
pnpm test:run             # run all tests (vitest)
pnpm test                 # run tests in watch mode
pnpm test:e2e             # run Playwright E2E tests
pnpm test:e2e:headed      # run E2E tests with browser visible
```

### Database

```sh
pnpm db:generate          # generate Drizzle migration after schema changes
pnpm db:migrate           # apply pending migrations
pnpm db:backup            # one-off DB backup
```

Leave `DATABASE_URL` unset for dev — Paperclip auto-starts embedded PGlite, persisting to `~/.paperclip/instances/default/db/`. Reset by deleting that directory.

### CLI

```sh
pnpm paperclipai run              # bootstrap + doctor + start server
pnpm paperclipai doctor           # health checks
pnpm paperclipai issue list       # list issues (set context first)
pnpm paperclipai issue create     # create issue
pnpm paperclipai heartbeat run    # trigger agent heartbeat
pnpm paperclipai context set      # set default company/API base
```

### Verification (run before claiming done)

```sh
pnpm -r typecheck
pnpm test:run
pnpm build
```

### Docker

```sh
docker compose -f docker-compose.quickstart.yml up --build   # quickstart
docker build -t paperclip-local .                              # manual build
```

## Repo Structure (Monorepo)

```
server/             Express REST API + orchestration services
  src/routes/       API endpoints (issues, agents, companies, approvals, costs, etc.)
  src/services/     Business logic
  src/adapters/     Server-side adapter registry (process, http)
  src/middleware/    Auth, error handling
ui/                 React 19 + Vite + Tailwind v4 + shadcn/ui board UI
packages/
  db/               Drizzle ORM schema, migrations, DB clients
  shared/           Shared types, constants, validators, API path constants
  adapters/         Per-runtime adapter packages:
    claude-local/     Claude Code adapter
    codex-local/      Codex adapter
    cursor-local/     Cursor adapter
    gemini-local/     Gemini adapter
    openclaw-gateway/ OpenClaw adapter
    opencode-local/   OpenCode adapter
    pi-local/         Pi adapter
  adapter-utils/    Shared adapter utilities
cli/                Paperclip CLI (`paperclipai` command)
doc/                Product specs, developing guides, deployment modes
tests/e2e/          Playwright E2E tests
scripts/            Dev runner, release, backup, smoke tests
.claude/skills/     Agent skills (paperclip heartbeat, design-guide)
```

### Package Manager

pnpm 9+ with workspaces. Node.js 20+. **Do not commit `pnpm-lock.yaml`** — CI owns the lockfile.

## Architecture

### Control Plane + Execution Services

Paperclip is a **control plane** — it doesn't run agents, it orchestrates them. Agents run externally (OpenClaw, Claude Code, Codex, Cursor, etc.) and phone home via **heartbeats**.

- **Server**: Express REST API (`/api`) with company-scoped domain entities
- **UI**: React board dashboard served by the API server in dev
- **Database**: PostgreSQL via Drizzle ORM (embedded PGlite for dev, external Postgres for prod)
- **Adapters**: Each runtime has an adapter package in `packages/adapters/` that translates Paperclip's heartbeat model into the runtime's native execution format

### Core Invariants

1. All domain entities are **company-scoped** — enforce in routes/services
2. **Single-assignee** task model with atomic checkout semantics
3. **Approval gates** for governed actions (hires, strategy)
4. **Budget hard-stop** auto-pause at 100%
5. **Activity logging** for all mutating actions
6. Keep contracts synchronised across `packages/db` → `packages/shared` → `server` → `ui`

### Agent Auth

- Board access: full-control operator (session-based in authenticated mode, implicit in local_trusted)
- Agent access: bearer API keys (`agent_api_keys`), hashed at rest, company-scoped

### Database Schema Change Workflow

1. Edit `packages/db/src/schema/*.ts`
2. Export new tables from `packages/db/src/schema/index.ts`
3. `pnpm db:generate` (compiles `packages/db` first, then generates migration)
4. `pnpm db:migrate` to apply the migration
5. `pnpm -r typecheck` to validate

## SHQ-Specific Context

### Org Chart

```
Board (Yao + Gerald)
├── Kani (OpenClaw) — Yao's Chief of Staff (Marketing, Sales)
│   ├── Content Writer (Claude)
│   ├── Social Media Analyst (Gemini)
│   ├── Designer (Claude + image gen)
│   └── Sales Rep (OpenClaw)
└── Rem (OpenClaw) — Gerald's Chief of Staff (Dev)
    ├── Frontend Dev (Cursor)
    ├── Backend Dev (Codex)
    ├── DevOps Engineer (Claude)
    └── Mika (Mika/Rust)
```

### Infrastructure (3-server model)

| Server | Role | Runs |
|--------|------|------|
| Server A (existing) | Orchestration | Kani + Rem (chiefs of staff only) |
| Server B (new) | Control plane | Paperclip API + UI + Postgres |
| Server C (new) | Workers | All specialist agents |

All three connected via Tailscale. Cloudflare Tunnel on Server B for Linear webhook ingress.

### Linear ↔ Paperclip Integration

Custom development in the fork — the largest piece of work. Does not exist upstream.

- **Inbound**: Linear webhook → Cloudflare Tunnel → Paperclip (creates/routes tasks by department tag)
- **Outbound**: Agents call Linear API directly via bot credentials
- Linear ticket IDs are canonical across all surfaces

| Surface | Format |
|---------|--------|
| Git branch | `<type>/<ticket>-<short-description>` |
| PR title | `<ticket>: Description` |
| Commits | Conventional commits (ticket already in branch name) |

### PR Governance

Cross-runtime review mandatory — never review your own model's output:

| Coder | Reviewer |
|-------|----------|
| Frontend Dev (Cursor) | Backend Dev (Codex) |
| Backend Dev (Codex) | DevOps Engineer (Claude) |
| DevOps Engineer (Claude) | Backend Dev (Codex) |
| Mika (Mika/Rust) | Frontend Dev (Cursor) |

All PRs require human merge (protected branches).

### Routing

- Linear tickets tagged `dev` → Rem → specialist
- Linear tickets tagged `marketing` or `sales` → Kani → specialist
- Untagged → ignored by agents

### Boundary Rule

Kani decides **what** to build and **why**. Rem decides **how** to build it. Specialists execute. Board overrides any of them.

## Fork Strategy

- `origin` → `github.com:Superuser-HQ/paperclip.git` (SHQ fork)
- `upstream` → `github.com:paperclipai/paperclip.git` (original)
- `main` → SHQ working branch, periodically rebased onto upstream releases
- SHQ changes isolated in separate files/directories to minimise merge conflicts
- Linear webhook integration kept modular, isolated from core Paperclip server code
- Custom adapters in separate directories under `packages/adapters/`
- Document every upstream file modified and why
- Rem (DevOps) manages upstream sync

## Sequencing

1. **Milestone 0**: Linear ↔ Paperclip integration design (prerequisite, blocks most work)
2. **Stream 1**: Infrastructure (deploy Paperclip, Tailscale, Cloudflare Tunnel, webhook)
3. **Stream 2 Phase 1**: Chiefs + Dev specialists
4. **Stream 2 Phase 2**: Marketing + Sales specialists
5. **Stream 3**: Department skeletons (org chart, personas, skills, workflows)

Each phase proves the loop before the next begins. Target: 2026-04-17.

## Extension Points for SHQ Work

- **New webhook routes**: Add to `server/src/routes/` — keep Linear integration modular in its own route file
- **New adapters**: Create a new package under `packages/adapters/` and register in `server/src/adapters/registry.ts`
- **Agent persona schemas**: Standardised YAML config translated by each adapter into runtime-specific format
- **Skills**: `.claude/skills/` for agent skills. The `paperclip` skill defines the heartbeat procedure all agents follow
