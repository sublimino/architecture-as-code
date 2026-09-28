# SLED-P3-GOV resource inspection and unverified runtime gates

**Verdict: baseline observation only; zero leakage NOT CERTIFIED.**
Date: 2026-09-22, America/Chicago.

## Cluster resource inspection transcript

Read-only connectivity probes succeeded:

```text
kubectl config current-context
kind-osramp
kubectl --request-timeout=5s cluster-info
Kubernetes control plane is running at https://127.0.0.1:34777
CoreDNS is running at https://127.0.0.1:34777/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
docker ps --format '{{.Names}}\t{{.Status}}'
[selected row] osramp-control-plane  Up 2 weeks
```

JSON list calls were processed locally into counts, without retaining payloads:

| Query (`kubectl --request-timeout=5s … -o json`) | Exit | Total objects | EAP matches |
| --- | --- | --- | --- |
| `get namespaces` | 0 | 25 | 0 |
| `get httproutes -A` | 0 | 6 | 0 |
| `get pods -A` | 0 | 99 | 0 |
| `get pv` | 0 | 8 | 0 |

The predicate matched object name or namespace beginning `eap-`, PV claim
namespace beginning `eap-`, or route hostnames containing `sl-eap-`. Successful
API responses establish this bounded observation, not comprehensive discovery of
misnamed/unlabelled resources. No controlled tenant teardown preceded it. There
is no before-state inventory, tenant pod UID/IP set, or correlated deletion
receipt, so zero matches cannot prove successful reclamation.

## Kernel cgroup v2 accounting release audit artifact

**NOT VERIFIED.** No tenant pod UID/cgroup IDs were recorded before deletion.
The governor did not attribute arbitrary Kind cgroups to an absent tenant.
Re-certification requires before/after cgroup identity, cgroup disappearance,
empty task membership, and bounded CPU/memory accounting observations after an
actual authorized test teardown. Namespace absence alone cannot prove this.

## Iptables and conntrack table inspection transcript

**NOT EXECUTED; no zero-entry claim.** A tool lookup returned
`/sbin/conntrack`. That does not establish permissions or inspect the Kind node's
network namespace. No `iptables-save` or `conntrack -L` transcript was collected:
without a pre-teardown tenant IP/UID inventory, filtering current rules for a
namespace string would miss translated addresses and be misleading. No rule or
connection state was flushed. A future controlled run must inspect the correct
node namespace and match the recorded address set, including established flows.

## Deep storage inspection

**NOT VERIFIED.** The PV API list had no matches under the stated predicate;
this says nothing about abandoned directories. HostPath/local-path directories,
backups, and snapshots were not wiped or claimed wiped. Before-state volume
paths and mount ownership are required before targeted read-only inspection and
any approved destructive validation.

## SPIRE datastore monotonic decrease report

**NOT VERIFIED.** No SPIRE datastore counts or pruning passes were executed.
A total count can increase because of unrelated tenant registrations; useful
evidence must track the target identity's entry IDs over controlled pruning
passes and confirm removal, without treating unrelated churn as an error.

## Process namespace eviction verification log

**NOT EXECUTED.** No controlled container teardown, PID namespace inventory, or
auditd record sequence was collected. A host `auditctl` lookup yielded no path;
this is not proof that auditd is absent. The governor neither installed auditing
agents nor harvested unrelated audit records. Re-certification needs correlated
pre-teardown namespace/PID identities, exit observations, and no remaining
members after the sequence, with an explicit auditd permission/readiness check.

## Kernel ring buffer security assessment

**NOT VERIFIED.** No broad kernel ring-buffer dump was collected because that
would harvest unrelated workload data without establishing tenant attribution.
A negative substring search would not establish absence of all customer payload
traces. A controlled synthetic marker, bounded collection policy, known logging
paths, and stated retention limitations are required to make a defensible claim.

## Tailscale and identity boundaries

No live logout, route reset, DNS deletion, OpenBao key destruction, SPIRE pruning,
namespace deletion, finalizer removal, or shared-node cleanup was attempted.
The candidate Python wrapper defaults to mock and requires
`SIGNALLOOM_EAP_TAILSCALE_LIVE=1` to request live execution. The live script
suppresses errors and targets the local node; running it on a shared host would
risk unrelated services. A requested live run can also fall back to mock if
the shell cannot locate the Tailscale binary. This safety
boundary is deliberate, not evidence that the desired cleanup is implemented.
