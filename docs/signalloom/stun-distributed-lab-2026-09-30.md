# Stun state across nodes: distributed lab (2026-09-30)

Question (Andy): "the pod-slice freeze -- will that persist across hosts? we need distributed systems proof".

Short answer: **no**. The freeze is node-local kernel state and survives nothing that replaces the pod or reboots the node. The only replicated stun record today is the Pod label, and it dies with the pod. Every number below is a measurement from raw files in `evidence/stun-distributed-lab/`.

## Setup

- Throwaway kind cluster `osramp-dist`: 1 control-plane, 2 workers (`osramp-dist-worker` = **A**, `osramp-dist-worker2` = **B**), kindnet CNI, kube-proxy `mode: iptables`, cgroup v2, Kubernetes v1.36.1, containerd 2.3.1. Created 23:30:20, deleted 23:46:17 BST. No other cluster or context was touched. `kind create` switched the shared kubeconfig's current context. It was restored to `kind-osramp` immediately, and every lab command pinned `--context kind-osramp-dist`.
- Sentinel `stun-sentinel:lab`, built from the merged tree at base `9c08846c`. The in-tree `docker build apps/signalloom-stun-sentinel/` cannot work: go.mod replaces `../stun-sentinel`, which is outside that context. The lab used a scratch context holding both modules (`manifests/Dockerfile.lab-build`). The Go code is unchanged.
- DaemonSet `20-daemonset.yaml` is the in-tree manifest with two changes only. The image is `stun-sentinel:lab`, and `SYS_PTRACE` is added to the capabilities.
- Stub `kusari-agent:latest` (image `21eaf389c8c1`) runs as a Deployment with a readiness probe only and no liveness probe (`30-kusari-stub.yaml`).
- Stun label set: `signalloom.io/stunned=true`, `signalloom.ai/state=stunned`, `signalloom.io/containment-mode=frozen`.
- Freeze truth comes from `cgroup.events` on the pod slice (`kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/kubelet-kubepods-burstable-pod<uid_>.slice`). It is read by a 50 ms poll loop that runs inside the node container and logs each transition (`manifests/lab.sh`, `poll`). Resolution is roughly 50 to 100 ms.
- **Clocks.** Host-side stamps (`*-timestamps.txt`) are BST. Node pollers and sentinel logs are UTC. All tables below are in **UTC**, with host stamps converted by subtracting one hour. Every container shares the host clock.

## Results

### D1 Baseline: stun on A, sentinel on B stays out

| Metric | Value | Timestamp (UTC) | Raw |
|---|---|---|---|
| Label call issued / returned | | 22:32:27.323 / 22:32:27.370 | `d1-timestamps.txt` |
| Pod slice on A `frozen 1` | **64 ms** after label call, 17 ms after it returned | 22:32:27.387 | `d1-poll.log`, `d1-cgroup-events-after.txt` |
| Sentinel on B, same pod | `reconcile_failed: freezer path not found`, no freeze | 22:32:27.386 onward | `d1-sentinel-B-worker2.log` |
| Sentinel on A after freezing | `find veth after freezing pod: no host interface has pod peer index 1245`, requeued | 22:32:27.369 onward | `d1-sentinel-A-worker.log` |

The last row is a defect, described under Side findings. The freeze lands, but the tc drop filter never attaches under kindnet.

### D2 Replacement with a pod-only record: the gap

A was cordoned and the frozen pod deleted.

| Metric | Value | Timestamp (UTC) | Raw |
|---|---|---|---|
| Delete issued | | 22:33:13.355 | `d2-timestamps.txt` |
| Replacement bound to B | +99 ms | 22:33:13.454 | same |
| Replacement pod slice exists | +181 ms, `frozen=0` | 22:33:13.537 | `d2-poll.log` |
| Replacement Ready | **+0.79 s** | 22:33:14.146 | `d2-timestamps.txt` |
| Replacement labels | `app`, `pod-template-hash`, `signalloom.ai/agent` only, no stun label | | same |
| Frozen at any point in the observation window | **never** (one transition, to `frozen=0`) | 22:33:13.537 to 22:33:59.179 | `d2-poll.log` |
| "Stunned" agent running free | **≥45.6 s observed, unbounded**: nothing in the system will ever re-stun it | | |

The sentinel on B made 15 reconcile attempts for the replacement and none was a stun. Attempts before the slice existed failed resolution, and the rest took the **unstun** path (`d2-sentinel-B-worker2.log`).

### D3 Replacement with an owner record (`signalloom.io/stunned: "true"` on the Deployment)

**D3a, merged tree (labelled: TODAY).**

| Metric | Value | Timestamp (UTC) | Raw |
|---|---|---|---|
| Deployment annotated | | 22:34:12.077 | `d3a-timestamps.txt` |
| Pod annotations / labels after | none / no stun label (Deployment annotations do not propagate to pods) | | same |
| Frozen during 40 s, spanning one 30 s informer resync | **never** | to 22:34:52.195 | `d3a-poll.log` |

**D3b, lab patch (labelled: NOT MERGED, `stun-sentinel:lab-owner`).** The patch is 50 added lines, full diff in `d3b-sentinel-owner.patch`. It adds `ownerStunned()`, which reads the controlling ReplicaSet and its Deployment, and it treats an API error as a reconcile error, never as "not stunned". It also needs the lab-only Role `40-lab-owner-rbac.yaml` (`get` on `replicasets`, `deployments`).

| Metric | Value | Timestamp (UTC) | Raw |
|---|---|---|---|
| Patched sentinel on B `started` → existing pod `frozen 1` | **134 ms** | 22:36:29.676 → 22:36:29.810 | `d3b1-poll.log`, `d3b1-sentinel-B.log` |
| Replacement: delete issued → bound to B | +98 ms | 22:37:12.673 → 22:37:12.771 | `d3b3-timestamps.txt` |
| Replacement first observed | already `frozen=1`, **≤160 ms after delete**, no stun label on the pod | 22:37:12.833 | `d3b3-poll.log` |
| Replacement Ready | **never**, container stuck `ContainerCreating` | | `d3b3-container-state.txt` |
| Replacement deletion | stuck: `t7mtk` still present 66 s after `deletionTimestamp` 22:37:14; cleared only after the D4 node restart wiped the freeze (exact time not measured) | 22:38:20 check | `d3b-stuck-terminating.txt`, `d3b-wedge-final.txt` |

The owner record closes the D2 gap: the agent binary never executed. However, freezing a slice before the container starts freezes the runtime's init process (process `6`, state `S`, pod still `ContainerCreating`), so the pod can be neither started nor deleted until it is thawed. Any owner-record design has to handle this "born frozen" state.

### D4 Node restart with the pod frozen on B (merged tree)

| Metric | Value | Timestamp (UTC) | Raw |
|---|---|---|---|
| Pod labelled and `frozen 1` on B | 71 ms after label | 22:38:20.649 → 22:38:20.720 | `d4-pre-poll.log` |
| `docker restart -t 1 osramp-dist-worker2` issued / returned | | 22:38:33.978 / 22:38:35.696 | `d4-timestamps.txt` |
| Pod slice re-created | **`frozen=0`** (kernel state gone) | 22:38:38.373 | `d4-poll-hostside.log` |
| Agent processes running in the unfrozen slice | 2 procs, container `restartCount 1` | 22:38:38.989 | same, `d4-agent-status.txt` |
| Sentinel on B restarted (`started`) | | 22:38:39.099 | `d4-sentinel-B-after-restart.log` |
| Informer first list | **timed out after 30 s** (`Get https://10.96.0.1:443/...`: the Service VIP was not routable yet on the rebooted node) | 22:39:09.110 | same |
| Pod slice `frozen 1` again | | 22:39:10.529 | `d4-poll-hostside.log` |
| **Unfrozen window** | **32.2 s** (slice), **31.5 s** with a fresh agent process running free | | |

The label survived, so the re-freeze did happen. The window is dominated by the client-go 30 s dial timeout, not by the sentinel's logic. The host-side poll ran at about 100 ms intervals plus `docker exec` overhead.

### D5 API partition of B (merged tree)

The partition rules were run inside the node container. The API server is `172.18.0.8:6443`, and the sentinel's `10.96.0.1:443` is rewritten to that address in nat OUTPUT before the filter chain.

```
iptables -I OUTPUT -d 172.18.0.8 -p tcp --dport 6443 -j DROP
iptables -I INPUT  -s 172.18.0.8 -p tcp --sport 6443 -j DROP   # needed; see D5a-1
```

**D5a-1, OUTPUT-only rule (the rule as briefed): NOT a partition.**

| Metric | Value | Timestamp (UTC) | Raw |
|---|---|---|---|
| Rule inserted; new connections from B fail (`curl` 000), A fine (200) | | 22:40:01.267 | `d5a-timestamps.txt` |
| Labels removed via API | | 22:40:03.494 | same |
| Sentinel on B saw the removal | **+49 ms** (the server's watch stream still arrives inbound; only ACKs are dropped) | 22:40:03.543 | `d5a-sentinel-B.log` |
| Watch finally broke | +45 s | 22:40:48.542 | same |
| Thaw | **never**: still `frozen 1` 105 s after the unlabel | 22:41:48.759 | `d5a-timestamps.txt` |

**D5a-2, bidirectional partition: remove the stun during the partition.**

| Metric | Value | Timestamp (UTC) | Raw |
|---|---|---|---|
| Partition inserted | | 22:42:11.075 | `d5a2-timestamps.txt` |
| Labels removed via API | | 22:42:13.198 | same |
| Sentinel resyncs during partition | 22:42:20.376 and 22:42:50.378, both re-applied the **freeze** from the stale cache | | `d5a2-sentinel-B-timeline.txt` |
| Freeze held for the whole partition | **yes**, `frozen 1`; node `Ready=Unknown` at the check | 22:42:58.271 | `d5a2-timestamps.txt` |
| Heal | | 22:42:58.383 | same |
| Sentinel observed the unlabel | **+0.876 s** after heal | 22:42:59.259 | `d5a2-sentinel-B-timeline.txt` |
| Thaw | **never**: still `frozen 1` 75 s after heal; every unstun fails `find veth before unfreezing pod` | 22:44:13.511 | same |

**D5b, bidirectional partition: apply the stun during the partition.** The slice was first thawed by hand with `echo 0 > cgroup.freeze` as a stated lab step at 22:44:34.672, because the D5a defect had left it frozen.

| Metric | Value | Timestamp (UTC) | Raw |
|---|---|---|---|
| Partition inserted / labels applied via API | | 22:44:37.314 / 22:44:37.362 | `d5b-timestamps.txt` |
| Frozen during partition | **no**, `frozen 0` for all 45 s | 22:45:22.415 | same, `d5b-poll.log` |
| Heal | | 22:45:22.510 | same |
| `frozen 1` | **+0.823 s** after heal (45.97 s after the API accepted the stun) | 22:45:23.333 | `d5b-poll.log`, `d5b-sentinel-B-timeline.txt` |

### D6 Two sentinels, one pod

| Sentinel | Log lines for B's pod `fbsvn` | Error | stun/unstun events | Raw |
|---|---|---|---|---|
| A (`osramp-dist-worker`) | 44 | all `resolve cgroup ... freezer path not found: pod e35aade2-... under /host-cgroup` | **0** | `d6-sentinel-osramp-dist-worker.log` |
| control-plane | 45 | same | **0** | `d6-sentinel-osramp-dist-control-plane.log` |

Resolution fails before any mutation, so the wrong-node sentinel is safe. The cost is noise. Every sentinel watches every agent pod in the namespace, with no `spec.nodeName` field selector, and requeues the failure indefinitely, backing off and then retrying on each 30 s resync. The first line is at 22:38:10.485 in `d6-summary.txt`.

## What state is authoritative and what is not

1. **The kernel freeze is not authoritative.** It is a cache of intent on one node. It vanished on node restart (D4: 32.2 s unfrozen), and it does not follow a pod to another node (D2).
2. **The Pod label is authoritative only for that pod UID.** It survived the restart and was re-applied (D4). A replacement pod starts without it and runs free with no bound (D2: ≥45.6 s observed, Ready in 0.79 s).
3. **An owner record is needed for "the agent stays stunned".** The Deployment annotation is ignored by the merged tree (D3a). With a lab patch it froze a label-free replacement within 160 ms of the delete (D3b). It also wedges the pod in `ContainerCreating` and blocks its deletion.
4. **During an API partition, the node keeps its last-known intent.** The freeze held for 45 s with the stun already revoked, and resyncs re-asserted it from the stale cache (D5a-2). A new stun issued during the partition did not land until 0.82 s after the heal (D5b: 46 s after the API accepted it). A partitioned node can neither be stunned nor released.
5. **Today, un-stun never thaws.** The unstun path looks up the veth before unfreezing, and that lookup always fails under kindnet (D5a-1, D5a-2: still frozen 75 s to 105 s after the unlabel). Release currently requires a node restart or a manual write to `cgroup.freeze`.
6. So, to Andy's question: the freeze persists across hosts only as long as the API record exists, is attached to whatever runs next, and can reach the node. Distributed containment therefore needs the stun intent on the owner (Deployment/ReplicaSet, or an admission-time label on new pods). It also needs a sentinel that re-applies intent before the agent starts (D4's 32 s is a boot race), and a stated policy for partitioned nodes. Today the partition behaviour is fail-closed for revoke and fail-open for new stuns.

## Side findings (defects measured on the way)

- **tc drop never attaches, and unstun never unfreezes.** `apps/signalloom-stun-sentinel/network.go:191` reads `/sys/class/net/eth0/iflink` after `setns`. sysfs stays bound to the namespace that mounted it, so the sentinel reads the node's own eth0 peer index (1245) instead of the pod's (3) (`d1-veth-diagnosis.txt`). The stun path freezes first and then fails, so containment is freeze-only with no network drop. The unstun path fails *before* unfreezing, so it never thaws. The fix is to read the peer index over netlink (`RTM_GETLINK` in the pod netns) rather than sysfs.
- **RBAC files conflict.** `infra/agent-swarm/ebpf-sentinel-rbac.yaml` defines Role and RoleBinding `stun-sentinel` bound to the non-existent service account `signalloom-stun-sentinel`. Applied after the kustomization's `rbac.yaml`, it overwrote the binding's subject, and the sentinel lost pod access (`setup-rolebinding-after-ebpf-rbac.json`). Last writer wins.
- **The in-tree image build is broken.** `docker build apps/signalloom-stun-sentinel/` (Makefile:237) cannot resolve `replace ../stun-sentinel`.
- **The sentinel watches itself.** Its own DaemonSet pods carry `signalloom.ai/agent=true`, so they match its informer selector and are reconciled down the unstun path (`d3b1-sentinel-B.log`).

## Manifests used

All manifests are in `evidence/stun-distributed-lab/manifests/`: `00-namespace.yaml`, `10-service-account.yaml`, `11-rbac.yaml`, `12-ebpf-sentinel-rbac.yaml`, `20-daemonset.yaml`, `30-kusari-stub.yaml`, `40-lab-owner-rbac.yaml` (D3b only), `kind.yaml`, `Dockerfile.lab-build`, `lab.sh`. The two that differ from the tree are shown inline.

DaemonSet delta against `infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml`:

```diff
-          image: stun-sentinel:latest
+          image: stun-sentinel:lab
@@ capabilities.add
                 - SYS_ADMIN
                 - NET_ADMIN
+                - SYS_PTRACE
```

Kusari stub (`30-kusari-stub.yaml`):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: kusari-agent, namespace: fe-signalloom-agents}
spec:
  replicas: 1
  selector: {matchLabels: {app: kusari-agent}}
  template:
    metadata:
      labels: {app: kusari-agent, signalloom.ai/agent: "true"}
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: agent
          image: kusari-agent:latest
          imagePullPolicy: Never
          env:
            - {name: QUOTE_URL, value: "http://127.0.0.1:1/unreachable"}
            - {name: QUOTE_TIMEOUT, value: "200ms"}
          ports: [{containerPort: 8080, name: http}]
          # readiness only: no livenessProbe, so the kubelet never restarts a frozen container
          readinessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 5, failureThreshold: 1, timeoutSeconds: 1}
          securityContext: {readOnlyRootFilesystem: true, allowPrivilegeEscalation: false}
          resources: {requests: {cpu: 10m, memory: 16Mi}}
          volumeMounts: [{name: tmp, mountPath: /tmp}]
      volumes: [{name: tmp, emptyDir: {}}]
```

## Teardown proof

From `evidence/stun-distributed-lab/teardown-proof.txt`:

```
teardown_start 23:46:15.204430468
Deleted nodes: ["osramp-dist-worker2" "osramp-dist-control-plane" "osramp-dist-worker"]
teardown_end 23:46:17.182224471
$ kind get clusters
osramp
osramp-scaffold
$ docker ps -a --filter name=osramp-dist -q | wc -l
0
current-context: kind-osramp
```
