---
title: Platform admin
description: Operate the demonstration estate and understand current control boundaries.
---

## Current workflow

Platform administrators operate the cluster through repository commands:

```bash
make up
make demo-signalloom-up
make doctor
make demo-signalloom-test
```

Use the dashboard to inspect workloads and evidence. Use the cluster diagnostic
before you diagnose a page failure.

## Current limit

`platform admin` is not an implemented Signal Loom authorization persona.
Cluster access remains separate from dashboard identity. The Fleet page is a
configured visualization and cascade simulation. Its mutation backend currently
uses a no-op client.

## Roadmap

- Define a platform-admin identity claim.
- Enforce administrative API permissions on the server.
- Replace simulated Fleet mutations with an authenticated cluster client.
- Record each administrative action in the audit trail.
- Add break-glass controls and expiry.
