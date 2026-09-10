---
title: Advanced user
description: See the intended elevated workflow and the current implementation boundary.
---

## Current state

Signal Loom does not implement an `advanced user` identity or authorization
role. The current API exposes an authenticated operator and a superadmin
allowlist.

An authenticated operator can currently:

- register an agent;
- inspect governance data;
- request credential operations;
- request compliance reassessment.

These permissions are not a stable advanced-user contract.

## Roadmap

1. Define the advanced-user tasks.
2. Define the required API permissions.
3. Map an identity claim to the new role.
4. Enforce the role in backend dependencies.
5. Add allow tests for advanced operations.
6. Add deny tests for superadmin operations.
7. Add a dedicated demonstration account.
