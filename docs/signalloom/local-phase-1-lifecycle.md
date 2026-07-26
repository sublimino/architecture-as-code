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
`make demo-signalloom-runtime-test` for focused BATS/DETIK assertions against
the running slice. The runtime test verifies Flux reconciliation and deployment
presence only. It deliberately does **not** test portal behavior, persistent
state, identity, or network-policy acceptance; those belong to later phases.
The frontend Flux Kustomization therefore does not wait for workload health or
the deliberately failing negative SPIRE proof Job during Phase 1 delivery.

For a fresh registry as well as a fresh cluster, run `make zot-cache-reset`
before `make demo-signalloom-up`.
