# Signal Loom Phase 1 local lifecycle

`make demo-signalloom-up` is the deterministic local, clean-cluster path. It creates
Kind, starts zot, signs and publishes the three Signal Loom OCI artifacts,
bootstraps Flux, then reconciles in this fixed order:

1. `inf-bao` controllers and configs (including the local SPIRE join token);
2. `inf-signalloom` controllers and configs;
3. `fe-signalloom` application Kustomization.

Run `make signalloom-check` first for the static delivery-contract gate.

The command waits for both Signal Loom ResourceSets before accessing their
tenant namespaces, so it is safe on an otherwise empty Kind cluster. It does
not reuse `make up`, which starts unrelated OSRAMP and Olly workloads.

Use `make demo-signalloom-test` for Flux-only readiness checks and
`make demo-signalloom-runtime-test` for focused BATS/DETIK assertions against
the running slice. The runtime test verifies Flux reconciliation and deployment
presence only. It deliberately does **not** test portal behavior, persistent
state, identity, or network-policy acceptance; those belong to later phases.
The frontend Flux Kustomization therefore does not wait for workload health or
the deliberately failing negative SPIRE proof Job during Phase 1 delivery.

For a fresh registry as well as a fresh cluster, run `make zot-cache-reset`
before `make demo-signalloom-up`.
