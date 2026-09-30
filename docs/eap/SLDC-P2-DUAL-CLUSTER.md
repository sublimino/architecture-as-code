# SLDC-P2-1 : Dual Kind Cluster Topology and Cross-Cluster DNS

**Card:** SLDC-P2-1. **Consumes:** SLDC-P2-PRE (`docs/eap/SLDC-P2-TOPOLOGY-AUDIT.md`).
**Tests:** `test/dual-cluster-networking.bats`. **Evidence:** `ci-evidence/sldc-p2-1-dual-cluster.txt`.

```
            fortuna ── docker network signalloom-bridge 172.19.0.0/16 (gw .1)
                 │                                   │
   kind-osramp  172.19.0.10 (eth1)        kind-signalloom-hub  172.19.0.20 (eth1)
   API 127.0.0.1:34777, Cilium KPR        API 127.0.0.1:34788, kindnet + kube-proxy iptables
   sldc-bridge-dns ─ osramp.local         sldc-bridge-dns ─ signalloom.hub
                                          host 127.0.0.1:31443/30080 → Envoy NodePorts
```

## Use

```bash
scripts/dual-cluster-up.sh [--reclaim-subnet]   # idempotent; ~50 s cold, ~13 s warm
scripts/dual-cluster-down.sh                    # deletes the hub, unwires osramp
scripts/dual-cluster-down.sh --delete-osramp --remove-bridge   # full, destructive
source scripts/lib/dual-cluster.sh; kosr get nodes; khub get nodes
bats test/dual-cluster-networking.bats          # SLDC_DUAL_CLUSTER_LIVE=1 makes absence fail
SLDC_LIVE_MUTATION=1 bats test/dual-cluster-networking.bats   # + live DNS-stub mutation
```

`--reclaim-subnet` removes a docker network that already holds `172.19.0.0/16`, but only when that network has zero containers. It creates the bridge in the same step, so Docker's allocator never hands the /16 to anything else.

## Design decisions

- **Attach, don't recreate.** `kind-osramp` is the shared demo cluster, created on the `kind` network. The up script creates a cluster only when it is absent, and gives each node a *second* interface on the bridge at its fixed IP. API endpoints, certificates and kubelet node IPs keep the first interface, because kubeadm pins it. `infra/kind/cluster-osramp.yaml` is used only for a fresh build, which then gets Cilium 1.16.7.
- **DNS answers with bridge node IPs, not ClusterIPs.** ClusterIPs do not route across the bridge. The live osramp Cilium IPAM pool is also `10.0.0.0/8`, which contains the hub's `10.97/16` service CIDR and `10.245/16` pod CIDR, so the non-overlapping-CIDR premise holds only for the kubeadm fields and not for Cilium's allocation. Names in `signalloom.hub` resolve to `172.19.0.20`, where Envoy Gateway's NodePorts route by Host header (Phase 3). Names in `osramp.local` resolve to `172.19.0.10`.
- **`sldc-bridge-dns`: a hostNetwork CoreDNS bound to the bridge IP.** Each cluster runs one, and it is authoritative for its own zone. Each main CoreDNS forwards *both* SLDC zones to the owner's `<bridge-ip>:53`. A NodePort would not work: Cilium kube-proxy replacement serves NodePorts only on the devices it detected at start (`eth0`), so `172.19.0.10:<nodePort>` is dark. That was measured, and it is the same reason any osramp service reached from the hub needs a hostNetwork/hostPort listener or a Cilium device reconfiguration.
- **Loop safety is enforced by lint, not by convention.** `sldc_lint_stub_block` rejects any block that has a non-SLDC zone, a `fallthrough`, a forward to anything but the zone owner's bridge responder, or a zone that is both templated and forwarded. A query crosses the bridge at most once.
- **GitOps overwrite.** The managed block sits between `# BEGIN/END sldc-cross-cluster` markers and is spliced from the in-cluster `sldc-cross-cluster-stubs` ConfigMap, which is applied from Git. Re-running the up script heals an overwrite. Live bats test 33 detects one.
- **osramp `default` is default-deny.** The probe ships a NetworkPolicy that allows only kube-dns and `172.19.0.0/16` egress.

## Consequences for P2-2 / P3

- Cross-cluster data-plane calls from osramp target `*.signalloom.hub` → `172.19.0.20:<hub NodePort>`. Hub iptables NodePorts answer on the bridge NIC, as the live TCP test shows.
- Hub → osramp traffic reaches only host-stack listeners on `172.19.0.10`, because Cilium BPF does not serve Services on `eth1`. Plan the SPIRE bundle endpoint and any OIDC/JWKS exposure accordingly.
- The kubeconfig current-context is preserved across `kind create`.
