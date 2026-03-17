# Paperclip Development Rules

## Contract Synchronization

When changing schema or API behavior, update **all** impacted layers in order:

1. `packages/db/` — schema and exports
2. `packages/shared/` — types, constants, validators
3. `server/` — routes, services
4. `ui/` — API clients, pages

Failing to propagate changes across all four layers causes silent breakage. Run `pnpm -r typecheck` after changes to catch mismatches.

## Company-Scoping

Every domain entity must be scoped to a company. When adding new routes or services:

- Include `companyId` in queries and access checks
- Enforce company boundaries — agents must not access other companies' data
- Board access is full-control within a company, not across companies

## Database Schema Changes

1. Edit `packages/db/src/schema/*.ts`
2. Export new tables from `packages/db/src/schema/index.ts`
3. Run `pnpm db:generate` (compiles first, then generates migration)
4. Run `pnpm -r typecheck` to validate
