---
title: Architecture diagrams
description: Read the deployment architecture diagrams for each Signal Loom target platform.
---

This page publishes the deployment architecture diagrams for each Signal Loom
target platform. Each diagram is available as a rendered SVG, an editable
Draw.io SVG, the native Draw.io XML, and a high-resolution PNG.

:::caution[Known limitation: these diagrams are not access-controlled]
The documentation portal serves every page and asset to callers that reach it.
This includes callers on the public tunnel. These diagrams are
therefore readable without a superadmin role, and without any role at all.

Gate this page behind the superadmin check before production go-live. The
`/fleet-api/` and `/dashboard/` routes in `d2-signalloom/apps/dashboard-signalloom/nginx.conf`
already show the pattern. They send an `auth_request` subrequest to
`GET /api/v1/auth/check`. The endpoint answers 204 for a superadmin and 403 for every
other caller. Tracked in [Current limits and roadmap](/docs/reference/roadmap/).
:::

## Platform baseline (available now)

### Sovereign Kind, air-gapped

The single-node foundation that `make up` builds.
The platform operates without cloud control plane dependencies.

![Sovereign Kind air-gapped architecture](/docs/diagrams/osramp-kind-sovereign-airgap.svg)

- Editable vector SVG: [osramp-kind-sovereign-airgap.drawio.svg](/docs/diagrams/osramp-kind-sovereign-airgap.drawio.svg)
- Native Draw.io XML: [osramp-kind-sovereign-airgap.drawio](/docs/diagrams/osramp-kind-sovereign-airgap.drawio)
- High-resolution raster PNG: [osramp-kind-sovereign-airgap.png](/docs/diagrams/osramp-kind-sovereign-airgap.png)

#### Sovereign ingress with zero outbound WAN egress

The single-node foundation operates with zero outbound WAN egress to protect data sovereignty and maintain a local control plane.
All control planes, evaluators, and data stores operate inside the local cluster.
The ingress perimeter supports unidirectional telemetry ingress from external audit sources.
Supported sources include AWS CloudTrail, GCP Audit (gcpaudit) logs, and Kubernetes audit (K8s Audit) streams.
External telemetry enters the cluster without permitting outbound egress to the public internet.

#### Inbound receiver protocols

The `signal-ingest` service exposes dedicated receivers for external telemetry ingestion.
These receivers accept three primary protocols:
- OpenTelemetry Protocol (OTLP) gRPC and HTTP endpoints for structured metric and trace feeds.
- RFC 5424 Syslog listeners for host and network event streams.
- Audit Webhook endpoints for direct push deliveries from external audit services.

The receivers normalise incoming event payloads before downstream evaluation and storage in FrostDB.

#### Core governance platform

The core platform coordinates identity, admission, inspection, and policy evaluation:
- Envoy Gateway serves as the TLS reverse proxy and API gateway with cert-manager TLS certificates.
- Automated certificates issue from an in-cluster cert-manager issuer.
- The Signal Loom API (`api-signalloom`, hosted in `fe-signalloom`) handles configuration and telemetry queries.
- The Dashboard single-page application (SPA) renders audit visualizations, active swarms, and incident timelines.
- Fleet Manager reconciles multi-tenant agent fleets and cluster registrations.
- Policy Engine evaluates Common Expression Language (CEL) governance bundles across incoming telemetry and agent actions.

#### Governed agent workloads under Landlock LSM

Autonomous agent workloads run in the `fe-signalloom-agents` namespace under strict isolation.
Deterministic Landlock LSM sandboxing (`#nono`) restricts local file system paths and process privileges.
The warden continuously monitors agent pods through eBPF telemetry, cgroups freeze controllers, and traffic control tc stun network actions.
SPIRE provides workload identity by issuing short-lived SVIDs and securing mTLS communication across platform components.

#### Dual storage tiering

The platform uses a dual storage model tailored for governance records:
- In-cluster PostgreSQL persists the `audit_events` audit trail, tenant policies, and session state.
- FrostDB provides a native columnar store for high-throughput time-series telemetry.

This division keeps transactional policy records distinct from analytical event streams.

#### Cert-manager PKI foundation

An in-cluster self-signed cluster issuer provides the Public Key Infrastructure (PKI) foundation.
It automatically provisions and renews TLS certificates for Envoy Gateway and cluster workloads without external Certificate Authority dependencies.

Component-level call diagrams from the repository are in [Internal Architecture](/dev-docs/reference/internal-architecture/).

## Roadmap platforms

The three cloud diagrams below describe planned deployment targets. They are
design records, not descriptions of a running estate. Read
[Current limits and roadmap](/docs/reference/roadmap/) for the phase that owns
each target.

### Microsoft Azure, AKS

![Azure multi-tenant SaaS architecture](/docs/diagrams/osramp-azure-multitenant-saas.svg)

- Editable vector SVG: [osramp-azure-multitenant-saas.drawio.svg](/docs/diagrams/osramp-azure-multitenant-saas.drawio.svg)
- Native Draw.io XML: [osramp-azure-multitenant-saas.drawio](/docs/diagrams/osramp-azure-multitenant-saas.drawio)
- High-resolution raster PNG: [osramp-azure-multitenant-saas.png](/docs/diagrams/osramp-azure-multitenant-saas.png)

### Amazon Web Services, EKS

![AWS multi-tenant SaaS architecture](/docs/diagrams/osramp-aws-multitenant-saas.svg)

- Editable vector SVG: [osramp-aws-multitenant-saas.drawio.svg](/docs/diagrams/osramp-aws-multitenant-saas.drawio.svg)
- Native Draw.io XML: [osramp-aws-multitenant-saas.drawio](/docs/diagrams/osramp-aws-multitenant-saas.drawio)
- High-resolution raster PNG: [osramp-aws-multitenant-saas.png](/docs/diagrams/osramp-aws-multitenant-saas.png)

### Google Cloud Platform, GKE

![GCP multi-tenant SaaS architecture](/docs/diagrams/osramp-gcp-multitenant-saas.svg)

- Editable vector SVG: [osramp-gcp-multitenant-saas.drawio.svg](/docs/diagrams/osramp-gcp-multitenant-saas.drawio.svg)
- Native Draw.io XML: [osramp-gcp-multitenant-saas.drawio](/docs/diagrams/osramp-gcp-multitenant-saas.drawio)
- High-resolution raster PNG: [osramp-gcp-multitenant-saas.png](/docs/diagrams/osramp-gcp-multitenant-saas.png)

## Where the diagram files live

Every diagram has one home in the repository:
`d2-signalloom/apps/docs-signalloom/public/diagrams/`. The documentation image
build context is that application directory, so a diagram published here must
live inside it. The repository specification documents link to the same files
from that path.

To change a diagram, edit the `.drawio` source and regenerate the `.drawio.svg`,
`.svg`, and `.png` outputs from it.
