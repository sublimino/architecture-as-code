# Signal Loom application components

Each subdirectory of this directory holds one application. The
[application table in `AGENTS.md`](../AGENTS.md#application-components) lists
each application, its path, and its purpose. That table is the one source for
the list. Do not copy it here.

These applications have their own README:

- [`fe-signalloom`](fe-signalloom/README.md): API backend, endpoints, database, and test tiers
- [`docs-signalloom`](docs-signalloom/README.md): Astro Starlight documentation service
- [`agentmaxxing-host-sensor`](agentmaxxing-host-sensor/README.md): coding agent host sensor

## Agent deep linking

The dashboard supports agent deep links with query selectors, such as `id:`,
`sa:`, `spiffe:`, and `k8s:sa:`.
[`agentQuerySelectors.ts`](dashboard-signalloom/src/data/agentQuerySelectors.ts)
is the parser and the source of the full list.
[`agent-deep-linking-and-selectors.md`](../../docs/signalloom/agent-deep-linking-and-selectors.md)
gives the specification.

## fe-signalloom-agents

The [`fe-signalloom-agents/`](fe-signalloom-agents/) directory holds only
[`probe-nono-capability.sh`](fe-signalloom-agents/probe-nono-capability.sh).
The `fe-signalloom-agents` namespace, the discovery RBAC, and the baseline
podinfo agent are in the fleet tenant file
[`signalloom.yaml`](../../d2-osramp-fleet/tenants/local/signalloom.yaml).
`make demo-signalloom-agents-up` and `make demo-signalloom-agents-down` manage
the ephemeral agent cohort.
