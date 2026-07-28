# Signal Loom NetworkPolicy Remediation Backlog

**Status:** deferred pending post-TEST-1 dedicated change

`inf-signalloom/allow-dependency-traffic` currently permits unrestricted
same-namespace ingress and egress through empty `podSelector` peers. This is
broader than the Phase 3 least-privilege contract.

## Required follow-up

1. Replace the broad peers with explicit workload labels and declared ports.
2. Retain only portal-to-PostgreSQL, Redis, and MinIO flows required by the
   deployed design.
3. Preserve DNS egress as an explicit, port-scoped rule.
4. Add a negative regression proving an unintended local peer and port remain
   denied.
5. Re-run the live negative NetworkPolicy assertions before closing Phase 3.

This record deliberately makes no policy change: TEST-1 runtime recovery is
being validated first, so a policy edit cannot obscure the registry fix.
