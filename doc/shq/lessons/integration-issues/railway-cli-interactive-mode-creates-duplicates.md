---
title: "Railway CLI interactive prompt creates duplicate services when retried"
category: integration-issues
date: 2026-03-18
tags: [railway, cli, postgres, duplicate, non-interactive]
severity: low
---

# Railway CLI interactive prompt creates duplicate services when retried

## Problem

Running `railway add --database postgres` from Claude Code appeared to hang on an interactive prompt ("What do you need? Database") and returned without clear success/failure. Retrying created additional Postgres instances — ended up with 3 instead of 1.

## Root Cause

The Railway CLI's `--database` flag triggers non-interactive mode detection but still falls through to an interactive prompt in some environments. The service is actually created in the background before the prompt appears. Each retry creates another service.

## Solution

1. After any `railway add` command, immediately check what was created:
   ```sh
   railway status
   # or use the MCP tool: list-services
   ```
2. Delete duplicates via the Railway dashboard (no CLI delete command available).

## Prevention

- Always run `list-services` / `railway status` after the first `railway add` attempt before retrying.
- For Railway project setup via Claude Code, prefer the Railway MCP tools (`create-project-and-link`) over raw CLI commands — they handle non-interactive mode better.
- When a CLI command appears to hang on a prompt, assume it may have partially succeeded. Check state before retrying.
