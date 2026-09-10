---
title: Superadmin demonstrations
description: Run and verify the SuperCredential demonstration phases.
---

## Prerequisites

1. Start Signal Loom.
2. Sign in as `demo-user@signalloom.local`.
3. Confirm that the **SuperCredential** navigation item is visible.

The superadmin allowlist enables the instructor controls. The navigation toggle
is not a complete authorization boundary.

## Run the complete terminal demonstration

```bash
make demo-signalloom-supercred-all
```

## Run one phase at a time

```bash
make demo-signalloom-supercred-1
make demo-signalloom-supercred-2
make demo-signalloom-supercred-3
make demo-signalloom-supercred-4
make demo-signalloom-supercred-5
```

| Phase | Demonstration result |
| :--- | :--- |
| 1 | Deploy the services, agent, secrets, and SPIRE entry. |
| 2 | Run the SPIFFE-to-OpenBao-to-Cardvault credential chain. |
| 3 | Detect a missing `securityContext`. |
| 4 | Revoke credentials and stun the agent. |
| 5 | Remove demo resources and check the cleanup. |

## Run from the dashboard

1. Open **SuperCredential**.
2. Select a phase.
3. Start the run.
4. Watch the live log.
5. Check each audience projection.
6. Reset the demo before a new presentation.

The instructor mutation routes enforce the superadmin check on the server.

## Verify the credential chain

```bash
make demo-signalloom-supercred-evidence
```

Run `make doctor` first if a phase fails. Restart port-forwards after an image
rollout.
