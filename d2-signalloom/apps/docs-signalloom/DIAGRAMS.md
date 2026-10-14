# Diagram focus notes

These notes govern every architecture diagram in the documentation portal.
That covers the Draw.io platform diagrams in `public/diagrams/` and the
SeeCode component diagrams on the Internal Architecture page. Read them before you
change a diagram. `test/diagram-focus.bats` enforces the exclusion and
inclusion lists below, so a diagram that drifts fails the suite.

Recorded 2026-10-13 from AJM's direction ahead of a partner architecture
meeting.

## Show these components

Every platform diagram shows each of these components. Each is backed by code
in this repository, so a reader can trace the box to a directory.

| Component | What it does | Code |
| :-- | :-- | :-- |
| OpenBao | Secrets and per-plane tokens. Cloud diagrams show auto-unseal through the provider KMS or HSM. | `d2-signalloom/apps/fleet-manager/openbao_client.go` |
| SPIRE | Workload identity (SVIDs) and the mTLS mesh between components. | `signal-ingest/collectors/spirea`, fleet-manager mesh client |
| KubeSec AFM | Formal RBAC analysis with the Z3 SMT solver. | `d2-k8s-afm/` |
| The warden | Per-node eBPF capture, cgroup freeze and tc network stun; reports to the fleet hub. | `d2-signalloom/apps/signalloom-warden/` |
| Collectors from external systems | signal-ingest collectors that pull audit and telemetry from systems outside the cluster. | `d2-signalloom/apps/signal-ingest/collectors/` |

Draw the warden with the Signal Loom logo (`scripts/diagrams/assets/signal-loom-logo-96.png`). It is our component, not a CNCF project. `scripts/diagrams/diagram-layout.test.ts` enforces this.

Name the collectors by the system they read, not by package name:

- AWS CloudTrail and GuardDuty, through SQS and EventBridge (`awslogs`).
- Google Cloud audit logs (`gcpaudit`).
- Kubernetes audit (`k8saudit`).
- OpenBao audit (`baoaudit`).
- SPIRE SVID issuance (`spirea`).
- Workspace SaaS, Google Workspace and Microsoft 365 (`workspacesaas`). Live mode is deferred, so label it planned.

On a cloud diagram, draw the provider-native audit source as an input to the
collectors, for example Azure Event Hubs or Activity Log on Azure. The Azure
collector is a roadmap item: no Azure collector exists in code yet, and the
cloud diagrams are design records, so that is consistent. Do not claim it
runs today.

The core platform stays on every diagram. That is Envoy Gateway, the Signal
Loom API (`fe-signalloom`), the dashboard, fleet-manager and policy-engine.
It also includes signal-ingest with FrostDB, Flux, and the Zot registry.

## Leave these out

Remove these from every platform diagram and every component card, including
sub-labels such as "signal-ingest (& Kagent D5)":

- Kagent D5 agents, and the Kagent collector.
- Supply chain ingestion: the PURL Listener, Witness Processor and Archiver
  pipeline.
- O11y Sentinel SRE ("Olly Sentinel SRE").

Prometheus and Grafana were not named for removal. Keep them only where they
already appear and the layout has room.

## How to change a diagram

The `.drawio` file is the source. Regenerate the three outputs from it and
never edit them by hand:

```bash
bun scripts/diagrams/drawio-render.ts d2-signalloom/apps/docs-signalloom/public/diagrams/<name>.drawio
```

This writes `<name>.svg`, `<name>.drawio.svg` and `<name>.png` beside the source.
