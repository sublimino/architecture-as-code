# Signal Loom Phase 1 local lifecycle

Start the shared cluster foundation first:

```bash
make up
```

This performs a foundation health check and starts no demos. `make demo-signalloom-up`
then publishes the three Signalloom OCI artifacts and reconciles in this fixed order:

1. `inf-bao` controllers and configs (including the local SPIRE join token);
2. `inf-signalloom` controllers and configs;
3. `fe-signalloom` application Kustomization.

Run `make signalloom-check` first for the static delivery-contract gate.

The command waits for both Signalloom ResourceSets before accessing their tenant
namespaces. It starts only the requested Signalloom slice; OSRAMP and olly remain
inactive.

Use `make demo-signalloom-test` for Flux-only readiness checks and
`make demo-signalloom-runtime-test` for the canonical local acceptance surface.
The runtime test verifies reconciled tenant Kustomizations, available workloads
without persistent pod errors, the Discovery Portal `/health` and `/readyz`
paths, and bounded Bao/SPIRE positive and negative proof outcomes. The frontend
Flux Kustomization does not wait for workload health or the deliberately
failing negative SPIRE proof Job during reconciliation; the runtime acceptance
command evaluates those conditions separately.

For a fresh registry as well as a fresh cluster, run `make zot-cache-reset`
before `make demo-signalloom-up`.
