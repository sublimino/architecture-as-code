# AGENTS.md — d2-agent-trust

This slice demonstrates a contract-first SPIFFE Agent Trust Hierarchy.
It reuses existing infrastructure from `d2-signalloom/infra/inf-bao`.
It consumes the SPIRE Workload API and the OpenBao JWT authentication backend.

## Commands

```bash
make -C d2-agent-trust test       # Run contracts and A2A verifier tests
make demo-agent-trust-up          # Deploy slice (requires inf-bao ready)
make demo-agent-trust-test-config # Run contract and lifecycle tests
make demo-agent-trust-test        # Run readiness and NetworkPolicy proofs
make demo-agent-trust-network-test # Test allow and deny dataplane policies
make demo-agent-trust-down        # Remove the six Agent Trust namespaces
make -C d2-agent-trust render     # Test manifest rendering
```

## Truthfulness Matrix

| Area | State | Evidence |
|---|---|---|
| A2A JWT signature, replay, and receiver policy | Authentic unit implementation | Tests in `a2a/service.py` |
| SPIRE Workload API token issuance | Authentic runtime adapter | Tested using mounted SPIRE socket |
| Kubernetes boundary manifests | Authentic GitOps runtime | Signed OCI artifact and Flux readiness |
| OpenBao role configuration | Authentic local lifecycle | Five-minute temporary roles via `agent-trust-local.sh` |
| SPIFFE and OpenBao A2A request flow | Authentic runtime | Planner gets JWT-SVID; triage checks via OpenBao |
| Cloud provider enrollment (Lambda, Cloud Run) | Modeled contract | `contracts/external-enrollment.v1.json` |

Note: NetworkPolicy controls L3 and L4 network reachability only.
The receiving application service enforces application-level authorization.

## Lifecycle and Rollback

The command `demo-agent-trust-up` confirms readiness of `signalloom-infra`,
`inf-bao`, OpenBao, and SPIRE. It then activates its ResourceSet.

The ResourceSet uses a dedicated `agent-trust-flux` service account.
RoleBindings permit only ConfigMaps, Secrets, ServiceAccounts, Services,
Deployments, and NetworkPolicies in owned namespaces.

The command `demo-agent-trust-down` sets `inputs: []`, waits for Flux,
and removes the six `agent-trust-*` namespaces. It does not modify `inf-bao`,
OpenBao, SPIRE, or Signal Loom ResourceSets.

Dataplane probes test network enforcement at runtime. A present CNI plugin
does not prove policy enforcement. The Kind test cluster verifies:
- Planner connects to triage.
- Denied triage paths fail.
- Permitted OpenBao paths succeed.
- Denied paths to OpenBao fail.
- Arbitrary egress traffic is blocked.

## Common Pitfalls

Every entry here records a defect found on 2026-08-12.
In this slice, you must verify that policy denials operate correctly.

### `nc` Cannot Distinguish Firewalls from Typos

The busybox `nc` tool returns exit code 1 for blocked IPs, bad hostnames, and stopped containers.
Only standard error output shows the difference.
Do not evaluate policy denial with the exit status code alone.
Always check standard error and report failures as `UNVERIFIED`.

### New Pods Are Unconfined During Initialization

The CNI plugin applies NetworkPolicy rules after container startup.
A probe at container start can access external endpoints before the CNI finishes configuration.
Always wait for a positive control before you test denial.
Proving that permitted paths work confirms that the CNI configured the rules.

### NetworkPolicies Match Labels, Not Workload Identity

Network policies select pods by labels, not by ServiceAccount or SPIFFE ID.
Probe jobs must include the workload label `app.kubernetes.io/name`.
To prevent test conflicts, add `app.kubernetes.io/component: probe` to test pods.
Exclude this component label when searching for active application pods.

### Persistence Does Not Repair Broken Identity State

Persistent volumes store SPIRE state across restarts.
Persistence cannot renew an expired SVID or fix a changed Certificate Authority.
If trust anchors change, compare cached anchors with current server certificates.

Do not attempt automated node recovery.
Follow this manual recovery sequence:
1. Stop reconciliation on the `flux-system/signalloom-infra` ResourceSet.
2. Suspend the child configuration `inf-bao/infra-configs`.
3. Delete the SPIRE agent DaemonSet.
4. Quarantine `/var/lib/spire-agent/data` on the host node.
5. Set permissions on the quarantined directory to mode `0700`.
6. Resume the child configuration and run `make demo-bao-up`.
7. Verify agent attestation before you unpause the parent ResourceSet.

### Read Probe Output from Termination Logs

Probe pods use `terminationMessagePolicy: File`.
Standard container logs remain empty after execution.
Run this command to inspect probe output:

```bash
kubectl -n agent-trust-acme-payments get pod <probe-pod> \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.message}'
```

## Production Gaps

Production environments require external attestors, key management, and trust bundle distribution.
The local SPIRE bootstrap is suitable only for development and demonstration.
