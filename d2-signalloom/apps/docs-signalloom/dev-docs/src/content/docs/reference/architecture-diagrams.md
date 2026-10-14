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

#### Multi-region topology and edge routing

Azure Front Door provides global routing across deployed regions.
Azure WAF inspects inbound requests at the network edge.
Azure DNS resolves regional service endpoints for external clients.
Per-region Application Gateways distribute traffic to internal cluster nodes.

#### Core governance platform

The core governance services operate inside regional AKS clusters:
- The Dashboard SPA serves user interfaces for fleet observability and control.
- FastAPI Core (`api-signalloom`) coordinates telemetry processing and tenant administration.
- Fleet Manager reconciles multi-cluster agent fleets and runtime policies.

#### Runtime, identity, and isolation

The platform deploys containerised agent workloads on managed AKS clusters.
OpenBao protects cryptographic secrets with Azure Key Vault HSM auto-unseal.
A SPIRE mTLS mesh secures intra-cluster traffic and provides workload identity.
The warden monitors containers with eBPF probes, cgroups freeze controllers, and tc stun actions.
KubeSec AFM runs formal RBAC analysis to detect privilege escalation risks.

#### Ingestion and event sourcing

Azure Event Hubs streams Azure Activity Logs and Diagnostic streams directly to `signal-ingest` collectors.
The pipeline ingests platform security events continuously.
The collectors normalise incoming audit events for downstream policy evaluation.

#### Model governance and inference proxy

The CPAI runtime proxy mediates all agent interactions with foundation models.
The proxy controls access to Azure OpenAI Service endpoints.
Policy filters inspect model prompts and token usage to prevent data leaks.

#### Dual storage tiering

The Azure deployment uses a dual storage model for compliance and telemetry:
- Azure Database for PostgreSQL Flexible Server stores transactional audit trail data and tenant policies.
- Azure Blob Storage and Azure Data Lake store FrostDB telemetry partitions.

This separation isolates relational compliance records from analytical event streams.

### Amazon Web Services, EKS

![AWS multi-tenant SaaS architecture](/docs/diagrams/osramp-aws-multitenant-saas.svg)

- Editable vector SVG: [osramp-aws-multitenant-saas.drawio.svg](/docs/diagrams/osramp-aws-multitenant-saas.drawio.svg)
- Native Draw.io XML: [osramp-aws-multitenant-saas.drawio](/docs/diagrams/osramp-aws-multitenant-saas.drawio)
- High-resolution raster PNG: [osramp-aws-multitenant-saas.png](/docs/diagrams/osramp-aws-multitenant-saas.png)

#### Multi-region topology and edge routing

The Amazon CloudFront edge CDN serves static portal assets and routes global user traffic.
AWS WAF blocks malicious traffic at edge points of presence.
Amazon Route 53 delivers high-availability DNS failover across regions.
Per-region Application Load Balancers terminate client connections and forward traffic to compute nodes.

#### Core governance platform

The Signal Loom governance stack deploys into regional EKS clusters:
- The Dashboard SPA visualises agent fleets, posture scores, and active alerts.
- FastAPI Core (`api-signalloom`) handles telemetry ingestion APIs and operational controls.
- Fleet Manager controls agent deployments across registered tenant clusters.

#### Runtime, identity, and isolation

EKS clusters run Bottlerocket worker nodes with AWS Nitro Enclaves for isolation.
OpenBao secures platform credentials using AWS KMS CMK auto-unseal.
A SPIRE mTLS mesh secures inter-service traffic and issues workload identities.
The warden enforces workload isolation with eBPF tracing, cgroups freeze limits, and tc stun rules.
KubeSec AFM performs formal RBAC analysis across cluster permissions.

#### Ingestion and event sourcing

Amazon EventBridge collects Amazon CloudTrail and Amazon GuardDuty findings.
EventBridge delivers these streams to Amazon SQS queues for buffered ingestion.
The `signal-ingest` collectors stream events from Amazon SQS and normalise payloads.

#### Model governance and inference proxy

The CPAI Gateway intercepts and governs all model invocation requests.
The gateway enforces policy boundaries on Amazon Bedrock foundation model endpoints.
Governance rules filter prompts, track token consumption, and mask sensitive attributes.

#### Dual storage tiering

The AWS deployment divides storage across relational and object tiers:
- Amazon Aurora PostgreSQL persists relational tenant state and tamper-evident audit events.
- Amazon S3 Standard and Amazon S3 Glacier Vault store FrostDB Lake telemetry records.

Glacier Vault enforces WORM evidence retention compliance for long-term audit archives.

### Google Cloud Platform, GKE

![GCP multi-tenant SaaS architecture](/docs/diagrams/osramp-gcp-multitenant-saas.svg)

- Editable vector SVG: [osramp-gcp-multitenant-saas.drawio.svg](/docs/diagrams/osramp-gcp-multitenant-saas.drawio.svg)
- Native Draw.io XML: [osramp-gcp-multitenant-saas.drawio](/docs/diagrams/osramp-gcp-multitenant-saas.drawio)
- High-resolution raster PNG: [osramp-gcp-multitenant-saas.png](/docs/diagrams/osramp-gcp-multitenant-saas.png)

#### Multi-region topology and edge routing

Cloud CDN caches user interface assets at points of presence worldwide.
Cloud Armor provides DDoS mitigation and web application firewall filtering.
Cloud DNS routes global domain queries to healthy endpoints.
Global External HTTPS Load Balancers per region distribute traffic across regional backends.

#### Core governance platform

The governance plane runs as managed deployments across GKE clusters:
- The Dashboard SPA renders live containment graphs and compliance status.
- FastAPI Core (`api-signalloom`) exposes administrative and policy interfaces.
- Fleet Manager synchronises agent policies across multiple tenant clusters.

#### Runtime, identity, and isolation

GKE clusters run Container-Optimized OS nodes with gVisor sandboxes for kernel-level agent isolation.
OpenBao manages secrets and uses Google Cloud KMS auto-unseal for master keys.
A SPIRE mTLS mesh authenticates services and secures intra-cluster traffic.
The warden monitors pods with eBPF probes, cgroups freeze controllers, and tc stun netfilter rules.
KubeSec AFM performs formal RBAC analysis to prevent privilege misconfigurations.

#### Ingestion and event sourcing

Google Cloud Pub/Sub receives Cloud Audit Logs and Security Command Center findings.
Pub/Sub streams security events into `signal-ingest` collectors for normalisation.
The collectors transform diverse platform events into unified schemas.

#### Model governance and inference proxy

The CPAI Gateway controls access to foundation model APIs.
The proxy checks calls to Vertex AI endpoints against governance constraints.
Runtime policies inspect model prompts and token usage within private networks.

#### Dual storage tiering

The GCP deployment separates transactional state from analytical telemetry:
- Cloud SQL for PostgreSQL persists structured configuration, tenant profiles, and audit events.
- A Cloud Storage Dual-Region bucket stores immutable FrostDB Lake event segments.

This separation isolates relational compliance records from analytical event streams.

## Where the diagram files live

Every diagram has one home in the repository:
`d2-signalloom/apps/docs-signalloom/public/diagrams/`. The documentation image
build context is that application directory, so a diagram published here must
live inside it. The repository specification documents link to the same files
from that path.

To change a diagram, edit the `.drawio` source and regenerate the `.drawio.svg`,
`.svg`, and `.png` outputs from it.
