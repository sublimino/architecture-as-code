# SPIFFE Agent Trust Hierarchy — Project Proposal

## Implementation disposition

The additive `d2-agent-trust/` slice contracts the hierarchy as a versioned
JSON topology and uses deterministic Kubernetes namespaces for platform,
tenant-control and projects. It proves one narrow planner → triage A2A path;
it does not claim live cloud attestation or production SPIRE bootstrap.

The existing `d2-signalloom/infra/inf-bao` deployment remains the only OpenBao
and SPIRE foundation. The slice supplies exact intended selectors, subjects,
audience and five-minute non-renewable role semantics, but leaves `inf-bao`
network policy unchanged. A live demo requires the existing SPIRE Workload API
socket and OpenBao JWT backend. External-cloud enrolments are explicitly
modeled contracts, not deployments.
