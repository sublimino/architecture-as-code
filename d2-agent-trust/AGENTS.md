# AGENTS.md — d2-agent-trust

This additive slice demonstrates a **contract-first** SPIFFE Agent Trust
Hierarchy. It does not deploy another SPIRE server, OpenBao, trust domain, or
reusable credential. Its runtime seam consumes the existing
`d2-signalloom/infra/inf-bao` SPIRE Workload API and OpenBao JWT auth backend.

## Commands

```bash
make -C d2-agent-trust test       # deterministic contracts and A2A verifier
make demo-agent-trust-up          # requires existing inf-bao readiness
make demo-agent-trust-test-config # contracts, fleet and fake lifecycle tests
make demo-agent-trust-test        # readiness plus enforced NetworkPolicy proof
make demo-agent-trust-network-test # runtime-proves allow/deny dataplane policy
make demo-agent-trust-down        # removes only six Agent Trust namespaces
make -C d2-agent-trust render     # optional kubectl rendering check
```

## Truthfulness matrix

| Area | State | Evidence |
|---|---|---|
| A2A JWT signature, replay and receiver policy | authentic unit implementation | `a2a/service.py` tests |
| SPIRE Workload API issuance | authentic runtime adapter | needs mounted existing socket |
| Kubernetes boundary manifests | authentic GitOps runtime after `demo-agent-trust-up` | signed OCI artifact + Flux readiness |
| OpenBao role configuration | authentic local-demo lifecycle | exact five-minute roles applied and removed by `agent-trust-local.sh` |
| SPIFFE/OpenBao A2A request | authentic runtime | helper fetches planner JWT-SVID; triage validates through OpenBao |
| Lambda, Cloud Run, Azure enrollment | modeled | `contracts/external-enrollment.v1.json` |

Never call NetworkPolicy identity or authorization: it only constrains L3/L4
reachability. The receiver owns A2A authorization.

## Lifecycle and rollback

`demo-agent-trust-up` first proves `signalloom-infra`, `inf-bao/infra-configs`,
OpenBao and SPIRE readiness, then activates its otherwise-empty ResourceSet.
The ResourceSet has a dedicated `agent-trust-flux` service account. Its six
namespaced RoleBindings permit only ConfigMaps, Secrets, ServiceAccounts,
Services, Deployments and NetworkPolicies in the owned namespaces. Its narrow
ClusterRole is only for Namespace operations; Kubernetes cannot
`resourceName`-limit `create`, which is documented in the manifest.

`demo-agent-trust-down` restores `inputs: []`, waits for Flux, deletes only the
six `agent-trust-*` namespaces, and verifies their absence. It never deletes or
changes `inf-bao`, OpenBao, SPIRE, or the Signal Loom ResourceSets.

The ResourceSet owns an additive `inf-bao` policy that admits only Acme
Payments planner and triage pods to OpenBao TCP/8200. It is pruned with Agent
Trust and does not alter existing same-namespace rules.

Network evidence is runtime-proven only by the positive and negative dataplane
probes. A present CNI daemonset and NetworkPolicy API are preconditions, not
proof: no implementation is trusted by name alone. The current Kind
`kindnetd:v20260528-9350166c` cluster passed planner→triage, the denied triage
paths, both permitted OpenBao paths, denied risk→OpenBao, and denied arbitrary
egress. Generic compatibility remains runtime-tested; absent prerequisites fail
`UNVERIFIED` and never skip. No CNI is installed or replaced by this slice.

## Production gaps

Cloud workload attestors, cloud key custody, trust-bundle delivery and
de-enrollment must be wired to each cloud account. The local SPIRE bootstrap
is intentionally unsuitable for production.
