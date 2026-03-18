---
title: "gh pr create targets upstream repo instead of fork"
category: integration-issues
date: 2026-03-17
tags: [github-cli, fork, pr, security, confidential-leak]
severity: critical
---

# gh pr create targets upstream repo instead of fork

## Problem

When running `gh pr create` in a forked repository, the GitHub CLI defaults to creating the PR on the **upstream** (parent) repo, not the fork. In our case, this leaked confidential SHQ deployment plans, org charts, and infrastructure details to the public `paperclipai/paperclip` repo.

## Root Cause

GitHub CLI resolves the PR target by walking up the fork graph. In a fork, `gh pr create` defaults to the parent repository unless explicitly told otherwise. This is by design for open-source contribution workflows, but dangerous for private forks containing confidential content.

## Solution

Two layers of protection applied:

### 1. Set `gh` default repo (CLI-level guard)

```sh
gh repo set-default Superuser-HQ/paperclip
```

This persists in `.git/config` and makes all `gh` commands target the fork by default.

### 2. Add warning to CLAUDE.md (agent-level guard)

Added to the Fork Strategy section:

> **CRITICAL: Never create PRs, push branches, or interact with the upstream repo (`paperclipai/paperclip`). All PRs go to `Superuser-HQ/paperclip`. The `gh` default repo is set to `Superuser-HQ/paperclip` — do not override it. Upstream is public and SHQ content is confidential.**

## Prevention

- Always run `gh repo set-default` when setting up a fork for private work
- Any AI agent or automation working in a fork must check `gh repo set-default --view` before creating PRs
- Closing a leaked PR is NOT sufficient — closed PRs remain publicly visible on GitHub. Contact repo admins or GitHub support to delete.

## Cleanup

If a PR is accidentally created on upstream:
1. `gh pr close <number> --repo <upstream>` — close immediately
2. Contact upstream repo admins to **delete** the PR (closing doesn't remove it from public view)
3. Audit what was exposed and rotate any secrets if applicable
