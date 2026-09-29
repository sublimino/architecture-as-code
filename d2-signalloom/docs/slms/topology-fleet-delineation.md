# Topology and Fleet Demo architectural delineation

This document defines the formal boundary between the Agent Trust Topology
(Surface 4) and the Fleet Demo (Surface 12) in the Signal Loom platform.

## Purpose and scope

Signal Loom provides two distinct visual surfaces for cluster workloads. Each
surface serves a specific operational purpose and presents a distinct data model.

| Dimension | Surface 4: Agent Trust Topology | Surface 12: Fleet Demo |
| :--- | :--- | :--- |
| **Primary role** | Cryptographic identity, trust boundaries, mTLS enforcement | Operational workload health, pod lifecycle, cascade containment |
| **Route** | `/topology` (alias `/agent-trust-topology`) | `/fleet` (alias `/fleet/audience`) |
| **Data source** | `/api/v1/trust/topology` via fe-signalloom | `/fleet-api/v1/fleet/*` via Fleet Manager |
| **Visual model** | Multi-plane hierarchical trust graph and attestation states | Workload dependency blast radius graph and FAIR risk gauges |
| **Key metrics** | Collector freshness, assurance levels, mTLS verification | Node CPU/memory saturation, pod phases, ALE and VaR95 loss figures |
| **Control actions** | Policy inspection, SPIFFE trust domain verification | Deploy, Scan, Stun, Recover, Reset fleet operations |

## Surface 4: Agent Trust Topology

Surface 4 visualises the cryptographic identity layer across the estate:

1. **Identity verification:** Displays SPIFFE IDs, SPIRE trust domains, and
   X.509 SVID attestation states for every governed agent.
2. **mTLS enforcement:** Highlights encrypted transport boundaries, mutual TLS
   enforcement policies, and protocol denials between services.
3. **Multi-plane hierarchy:** Groups workloads into platform, tenant, service,
   project, agent, and external trust planes.
4. **Collector health:** Monitors observability collectors (eBPF, Envoy,
   KubeSec-AFM, network probes) and reports collection freshness.

Surface 4 does not perform mutating fleet operations. It is an analytical and
auditing surface for security architects and compliance officers.

## Surface 12: Fleet Demo

Surface 12 provides operational observability and active demonstration controls:

1. **Workload lifecycle:** Streams live pod lifecycle events and node resource
   saturation metrics across cluster nodes.
2. **GitOps status:** Displays Flux reconciliation state, Git revision hashes,
   and synchronisation status.
3. **Deterministic containment:** Executes 5-stage agent containment controls
   (Deploy, Scan, Stun, Recover, Reset) with immediate cluster feedback.
4. **Cascade blast radius:** Draws dependency hierarchies where revoking an
   agent credential cascades to dependent downstream workloads.
5. **FAIR risk quantification:** Calculates real-time Annual Loss Expectancy
   (ALE) and 95th percentile Value at Risk (VaR95) from active workload states.

Surface 12 delegates SPIFFE trust domain analysis and mTLS enforcement details
to Surface 4. It does not duplicate SPIRE server configuration tables.

## Offline demo fixture resiliency

The Fleet Demo view supports offline execution when a live Kubernetes cluster
is absent. When the Fleet Manager API is unreachable, the view automatically
falls back to the static demo fixture in `api/fakeData.ts`.

Operators can also manually switch between Live Cluster and Demo Fixture modes
using the connection mode toggle in the Fleet Demo header.
