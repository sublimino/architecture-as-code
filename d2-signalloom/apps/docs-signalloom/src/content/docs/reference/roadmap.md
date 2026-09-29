---
title: Current limits and roadmap
description: Separate verified demonstration behaviour from planned platform behaviour.
---

## Platform Baseline (Available Now)

- Single-node Sovereign Kind foundation (`make up`) and Zot OCI registry.
- Dex OIDC identity provider with role-based claim mappings.
- In-memory FrostDB columnar event ingestion with Apache Arrow pushdown.
- Signal Loom core inventory, posture, compliance, and audit dashboard.
- SuperCredential demonstration phases and token issuance.
- CNCF Kagent declarative agent swarms (`make demo-kagent-up`).
- CPAI OpenAI-compatible proxy to Google Cloud Vertex AI.
- FAIR quantitative cyber-risk simulation engine.
- KubeSec-AFM formal-methods Z3 RBAC privilege analysis (`make demo-k8s-afm-up`).

---

## Phase 1: Q4 2026 Production Go-Live & Pilot Estate

### Target Infrastructure & State
- **Single-Tenant GKE Standard**: Dedicated production deployment target on Google Cloud Platform with private VPC peering and Workload Identity Federation (`SL-EP-02`).
- **Sovereign Kind on GCE VM**: Air-gapped fallback deployment target with durable host-path PVCs (`SL-EP-01`).
- **Managed Stateful Persistence**: GCP Cloud SQL (PostgreSQL 16 HA TLS) + Memorystore Redis + GCS audit bucket, eliminating ephemeral `emptyDir` storage (`SL-EP-01`).

### Active Containment & Cyber Resilience (SLER)
- **3-Plane Deterministic Containment**: Execution Freeze, Dynamic Credential Revocation, and eBPF TC Packet Severance (`SL-EP-03`).
- **Stun-Sentinel Healthz Replay**: Behavioral probe recording & simulation with a 300s forensic investigation lease and fail-closed eviction (`SL-EP-03`).
- **Live BATS Red-Team Harness**: Dynamic verification suite asserting sub-50ms containment under live load (`SL-EP-04`).

### Data Protection & Supply Chain
- **Subject-DEK Cryptographic Erasure Saga**: 3-tier Keyed HMAC (`Tenant KEK -> Subject DEK -> HMAC KeyRing`) enabling instant GDPR Article 17 erasure without destroying < 5ms Arrow vectorization (`SL-EP-05`).
- **Base Collector Activation**: Base deployment manifests hard-wire Tier 1 baseline collectors active by default (`SL-EP-06`).
- **Cloud KMS & Supply Chain Hardening**: Migration of Cosign signing keys to GCP Cloud KMS HSM; SLSA Level 3 provenance; immutable image digest pinning (`SL-EP-13`).
- **EU Jurisdiction Geo-Guard**: Automated feature flag suppressing employee monitoring in Germany, France, and the Netherlands (`SL-EP-10`).
- **Cluster Preflight Tooling**: `signalloom-preflight` CLI auditing target cluster CNI, node privileges, and kernel compatibility prior to installation (`SL-EP-12`).

---

## Phase 2: Q1 2027 Multi-Cloud & Enterprise Governance

- **Multi-Cloud Distro Packaging (`SL-EP-14`)**: Helm charts and Flux kustomizations for AWS EKS and Red Hat OpenShift.
- **SaaS Workspace Ingestion**: SaaS collectors for GitHub Enterprise, Slack, and Google Workspace.
- **Turnkey DPIA & Legal Automation (`SL-EP-11`)**: Enterprise Data Processing Agreement (DPA) generator and automated Article 30 records.
- **Independent Security Attestation**: CREST-accredited penetration testing and SOC 2 Type 1 certification.

---

## Phase 3: Q2 2027 Workstation Sensors & Global Scale

- **Developer Workstation Sensor (`SL-EP-15`)**: Packaging eBPF workstation sensor for developer macOS and Linux laptops.
- **Works Council Co-Determination**: Formal Works Council deployment frameworks for DACH and EU enterprises.
- **Autonomous Fleet Remediation**: Closed-loop policy auto-tuning driven by FAIR risk engine exposure scores.
