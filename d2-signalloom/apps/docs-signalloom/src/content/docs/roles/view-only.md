---
title: View-only user
description: Understand the current read-oriented workflow and its authorization limit.
---

## Current workflow

Sign in as `viewer@signalloom.local`. You can inspect:

- the agent inventory;
- agent details;
- compliance views;
- the audit trail;
- available evidence views.

## Important authorization limit

The `viewer` account is not technically view-only. The API treats authenticated
non-superadmins as operators. That role can reach mutation endpoints, including
agent registration and credential operations.

Use this account only to demonstrate a read-oriented journey. Do not use it as
proof of least-privilege enforcement.

## Roadmap

- Enforce viewer permissions in backend dependencies.
- Reject mutation requests from viewer identities.
- Add negative API tests for each protected mutation.
- Hide mutation controls only after server enforcement exists.
