# SLDC-P2-PRE :  Dual Kind Cluster Topology Audit

**Card:** SLDC-P2-PRE (Phase 2 pre-flight, diagnostic only)
**Base:** `integration/sldc-v0.1.0` @ `ab89bffe81a3fcff1c766783be9a51694c07bc50`
**Host:** fortuna (Linux 7.1.3+deb13-amd64, Docker 29.7.1, kind v0.32.0, kubectl v1.36.0)
**Date:** 2026-09-30
**Verdict:** preflight complete, **Phase 2 does not proceed as specified.** There are 3 blockers and 7 drift findings, and each blocker needs a principal decision before SLDC-P2-1 provisions.

Evidence: `ci-evidence/p2-preflight-audit.json` (produced by `scripts/p2-dualcluster-preflight.sh --l3-probe`).
Tests: `test/p2-dualcluster-preflight.bats` (23 tests: 20 hermetic, 3 live).

## Target topology (Appendix B)

| Element | Specified | Observed on fortuna | Verdict |
| :-- | :-- | :-- | :-- |
| Docker bridge | `signalloom-bridge`, `172.19.0.0/16`, gw `172.19.0.1` | absent; `172.19.0.0/16` allocated to `clawdbot_default` (0 containers, compose project `clawdbot`, route `linkdown`) | **blocker** |
| Non-docker routes in 172.19/16 | none | none (Tailscale is `100.64.0.0/10`, table 52) | pass |
| Workload node IP | `172.19.0.10` | unheld | pass |
| Hub node IP | `172.19.0.20` | unheld | pass |
| Workload API port | host `127.0.0.1:34777` | bound by `osramp-control-plane` (the existing `kind-osramp`) | **blocker** |
| Hub API port | host `127.0.0.1:34788` | free | pass |
| Hub Envoy HTTPS | host `31443` | free | pass |
| Hub Envoy HTTP | host `30080` | free | pass |
| Kind cluster `osramp` | new, on `signalloom-bridge` | **exists** on `kind` (172.18.0.5), node v1.36.1, Cilium | **blocker** |
| Kind cluster `signalloom-hub` | new | absent | pass |
| `infra/kind/cluster-osramp.yaml` | consumed as existing | absent (no `infra/` dir) | drift |
| `infra/kind/cluster-signalloom-hub.yaml` | consumed as existing | absent | drift |
| Workload trust domain | `osramp.local` | SPIRE server declares only `signalloom.demo` | drift |
| Hub trust domain | `signalloom.hub` | not declared anywhere in the repo | drift |
| CoreDNS stub for hub names | required | `kind-osramp` Corefile has only `.:53` → `/etc/resolv.conf` | drift |
| OpenBao `bound_claims_type: glob` | required | present in `openbao-supercred-bootstrap.yaml` | pass |
| OpenBao bound `sub` domain | `spiffe://osramp.local/...` | `spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/*cardvault*` | drift |
| OpenBao JWKS | must verify `osramp.local` SVIDs from the hub | `http://spire-oidc.inf-bao.svc.cluster.local:8008/keys` (cluster-local) | drift |

### Host ports outside the Appendix B host surface (advisory)

The Appendix B diagram's `443`, `8080`, `8082` and `8200` are **in-cluster** ports, and B.2 does not publish them on the host. They only matter if someone port-forwards them.

| Port | Bound by |
| :-- | :-- |
| 443 | a non-docker listener on the Tailscale addresses `100.92.129.16` / `fd7a:115c:a1e0::1535:8110` |
| 8082 | `archivista-archivista-1` (`0.0.0.0:8081-8082`) |
| 8200 | a non-docker listener on `127.0.0.1:8200` |
| 8080 | free |

### Host resources (hard-blocker gates, not triggered)

- RAM: MemTotal 61 GiB, well above the 8 GiB floor.
- inotify: `max_user_watches=1048576`, `max_user_instances=10240`. Both are already above the 524288/8192 remediation values, so no sysctl change is needed.
- sudo: unavailable in the agent context (`no new privileges`). It is not needed. The user is in the `docker` group, which is enough for bridge management, and no sysctl needs raising. The "lacks root or sudo" hard blocker is therefore **not** triggered.

### L3 reachability (false-green guard)

`--l3-probe` created a disposable bridge on the first free `/16` (`172.31.0.0/16`) and started two `alpine:3.20` containers with `--ip .10` and `--ip .20`. It confirmed that Docker honoured both static IPs, pinged in both directions, and then removed everything; no residue was left. This proves the mechanism P2-1 depends on, a user-defined bridge with fixed container IPs and direct L3, on this host. It does not prove it on `172.19.0.0/16` itself, which is taken.

## Blockers and recommended resolutions

**B1. `172.19.0.0/16` is held by `clawdbot_default`.**
- Recommendation: P2-1's setup step removes the empty network and creates the bridge in one step:
  ```bash
  docker network rm clawdbot_default
  docker network create --driver bridge --subnet 172.19.0.0/16 --gateway 172.19.0.1 signalloom-bridge
  ```
- `clawdbot_default` has 0 containers, and `docker compose up` in `clawdbot` recreates it on the next free `/16`.
- The two steps must be adjacent. Docker's allocator hands the lowest free `/16` to the next network created, so pruning without creating immediately just gives 172.19 away again. That is why this preflight did not prune on its own.
- Alternative: re-spec the bridge to a free `/16`. Of 172.25-31, `172.31.0.0/16` was confirmed free (the L3 probe used it), and `ip -4 route` shows no routes in 172.25-30.

**B2/B3. `kind-osramp` already exists on the `kind` network and owns `127.0.0.1:34777`.**
It is the live shared cluster: the Kusari demo, Cilium, Flux and the persisted Zot cache. P2-1's out-of-scope line reserves *creating* it, but the name is taken.
- Recommendation (an unverified intuitive leap, to test in P2-1): **attach, don't recreate.** Leave both clusters on the default `kind` network and add a second interface on the bridge:
  ```bash
  docker network connect --ip 172.19.0.10 signalloom-bridge osramp-control-plane
  KIND_EXPERIMENTAL_DOCKER_NETWORK=kind kind create cluster --config infra/kind/cluster-signalloom-hub.yaml
  docker network connect --ip 172.19.0.20 signalloom-bridge signalloom-hub-control-plane
  ```
- Why this shape works:
  - API access keeps going through `127.0.0.1:34777` and `:34788`, so certificates, kubeconfigs and `kind-osramp` state are untouched.
  - Cross-cluster data-plane traffic (sentinel → hub Envoy NodePort `30080`/`31443`) uses the connected route on the new interface.
  - It can be reversed with `docker network disconnect`.
- Rejected alternative: delete and recreate `osramp` on the bridge. That destroys live shared state and is Andy's decision, not a pre-flight's.
- Do **not** re-IP a node after `kind create`. Kind/kubeadm record the node's original address in the kubelet config and the API server certificate (not re-verified live this run). Assign at creation, add a second interface, or resolve IPs with `docker inspect`, never by hard-coding the first interface.

## Spec tightening for P2-1 / P2-2 (drift)

1. **Manifests.** `infra/kind/` does not exist. P2-1 authors both files from B.2. Two problems in the B.2 text:
   - `kindest/node:v1.31.0` is not cached locally and is five minors behind kubectl v1.36.0, outside the ±1 skew policy. The live `osramp` node runs `v1.36.1`, which is cached. **Pin `v1.36.1`.**
   - `disableDefaultCNI: true` is only correct if P2-1 also installs Cilium, as the live `osramp` does.
2. **Trust domains.** This is a re-domain, not a configuration tweak.
   - The repo runs one SPIRE server, `trust_domain = "signalloom.demo"`, in `d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-config.yaml`.
   - `fleet-config.yaml` uses `signalloom.local`, and `d2-agent-trust/contracts/spire-registrations.v1.json` uses `signalloom.demo`.
   - `osramp.local` appears only in `fleet-manager` attestation test fixtures, and `signalloom.hub` appears nowhere.
   - Moving the workload domain to `osramp.local` invalidates every existing SVID. It also breaks every `bound_subject` / `bound_claims` in the `openbao-*-bootstrap.yaml` files and the pinned assertions in `d2-signalloom/test/kagent-contract.bats` and `d2-signalloom/test/fleet-agents-contract.bats`. P2-2 must carry those edits.
3. **B.3 JWKS URL is wrong for this repo.** `http://spire-server.spire.svc.cluster.local:8081/keys` names a `spire` namespace that does not exist on `kind-osramp`, and 8081 is the SPIRE server gRPC port. The repo's JWKS is served by `spire-oidc.inf-bao.svc.cluster.local:8008/keys`. The hub verifies `osramp.local` tokens, so it needs that domain's bundle: through SPIRE federation (bundle endpoint over the bridge), or through a workload-side OIDC endpoint reachable at `172.19.0.10`.
4. **B.3 bound `sub` namespace.** The spec uses `spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault*`, but the repo binds `.../ns/fe-signalloom-agents/sa/*cardvault*`. P2-2 must pick one. The glob already exists and needs no change.
5. **CoreDNS.** `kind-osramp` forwards `.` to the node's `/etc/resolv.conf` (Docker embedded DNS). Once both nodes share `signalloom-bridge`, Docker DNS resolves container names across it, but not hub **service** names. P2-1 adds a `signalloom.hub:53` server block, either `hosts`-mapping hub gateway names to `172.19.0.20`, or forwarding to hub CoreDNS exposed on a NodePort.
6. **Transit.** No `inf-bao` bootstrap manifest enables a transit engine, although `fe-signalloom/src/tenant_transit.py` consumes one. If P2-2 relies on transit, the mount belongs in the GitOps bootstrap.

## Card Required Tests (run verbatim)

| Test | Result | Note |
| :-- | :-- | :-- |
| Docker Bridge Subnet Availability | fail | Inspects the existing `kind` network (`172.18.0.0/16`). Its `\|\| echo 172.19.0.0/16` fallback prints the expected value whenever `kind` is absent, so that branch is vacuous. The real verdict is `bridge.overlap.docker`. |
| Port Conflict Pre-Flight Scan | fail | `127.0.0.1:34777` held by `osramp-control-plane`. |
| Kind Multi-Cluster Manifest Syntax Verification | fail | `infra/kind/*.yaml` absent. |
| Deliberate Mutation Testing Check (nc on 34777) | pass, **vacuous** | `nc -l 34777` fails with `EADDRINUSE`, so the scan sees the pre-existing holder, not nc. The non-vacuous replacement is BATS test 22, which binds free port 34788 and asserts a blocker. |

## How to re-run

```bash
scripts/p2-dualcluster-preflight.sh              # read-only, exit 1 while blockers remain
scripts/p2-dualcluster-preflight.sh --l3-probe   # + disposable bridge reachability probe
bats test/p2-dualcluster-preflight.bats          # tier 1 + live tier
P2_LIVE_L3=1 bats test/p2-dualcluster-preflight.bats
```

Every host dependency is injectable (`DOCKER_BIN`, `KIND_BIN`, `KUBECTL_BIN`, `SS_BIN`, `IP_BIN`, `SUDO_BIN`, `MEMINFO_FILE`, `INOTIFY_*_FILE`, `REPO_ROOT`, `AUDIT_JSON`), and every expected value can be overridden (`P2_BRIDGE_CIDR`, `P2_HOST_PORTS`, `P2_WORKLOAD_TD`, …). If the principal re-specs the subnet, the same script gates the new value.

Mutation evidence: six gates were mutated (CIDR overlap, socket scan, existing-cluster, trust-domain, RAM and node-IP), and each mutant turned its matching test red. A live nc listener on free port 34788 is detected as a blocker.
