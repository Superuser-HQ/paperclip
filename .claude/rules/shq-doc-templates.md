# SHQ Doc Templates

## ADR Format

Filename: `doc/shq/adrs/NNN-kebab-case-title.md` (sequential numbering)

```markdown
# ADR-NNN: Title

**Status:** Proposed | Accepted | Deprecated | Superseded by ADR-NNN
**Date:** YYYY-MM-DD
**Author:** Name

## Context

What problem or decision are we facing? Include constraints and background.

## Options Considered

### Option 1: Name

**Pros:**
- ...

**Cons:**
- ...

### Option 2: Name
...

## Decision

The chosen option and rationale.

## Consequences

What follows from this decision — tradeoffs, work created, risks accepted.
```

## PRD Format

Filename: `doc/shq/prds/NNN-kebab-case-title.md` (sequential numbering)

```markdown
# PRD-NNN: Title

**Status:** Draft | In Review | Approved
**Date:** YYYY-MM-DD
**Author:** Name
**Linear:** DEV-XXX (if applicable)

## Problem Statement

What problem are we solving and for whom?

## Goals

What does success look like? Measurable outcomes.

## Non-Goals

What is explicitly out of scope?

## Proposed Solution

High-level approach. Architecture diagrams or flow descriptions where helpful.

## Requirements

### Functional
- ...

### Non-Functional
- ...

## Open Questions

Unresolved decisions or areas needing research.
```

## Implementation Plan Format

Filename: `doc/shq/plans/YYYY-MM-DD-kebab-case-title.md` (date-prefixed)

Plans use frontmatter:

```yaml
---
title: 'Description'
status: draft | active | completed
date: YYYY-MM-DD
---
```
