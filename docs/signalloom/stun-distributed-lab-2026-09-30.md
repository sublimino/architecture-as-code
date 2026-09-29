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

## Results before fix (`stun-sentinel:lab`, merged tree `9c08846c`)

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

## Results after fix (`stun-sentinel:lab2`, FIX-C tip `1c3dd8b8`)

The sentinel was rebuilt from `feat/kusari-e2e/fix-c-kernel-truth` at `1c3dd8b8`, using a detached worktree that was removed afterwards. That tip contains the netlink peer-index read (`192f26c8`), the owner stun record (`fe7efcef`), and `SYS_PTRACE` plus owner-chain `get` (`f2939e5d`). The image is `sha256:ae7bf780…`. It was deployed with FIX-C's own `infra/agent-swarm/signalloom-stun-sentinel/` manifests, changing only the image. The cluster `osramp-dist` was recreated with the same `kind.yaml`, created at 23:48 and deleted at 00:00:03 BST. Its node IPs differ from the first run: control-plane 172.18.0.9, A 172.18.0.8, B 172.18.0.10.

A drop filter counts as attached when `tc filter show dev <veth> ingress|egress` on the node shows the sentinel's `pref 49152` and `pref 49153` `matchall ... gact action drop`. The veth is found independently of the sentinel, from the pod's eth0 peer index read with `ip -o link` inside the pod netns (`vethof`/`tcshow` in `after-fix/manifests/lab2.sh`). Raw files are in `evidence/stun-distributed-lab/after-fix/`.

| Exp | Metric | Value | Timestamp (UTC) | tc drop attached | Raw |
|---|---|---|---|---|---|
| D1 | label → `frozen 1` on A | 203 ms | 22:49:37.948 → 22:49:38.151 | **yes**, ingress and egress on `veth9073a330`, which matches the sentinel's `host_veth`; `curl` from B gets 000 | `d1-*` |
| D1 | sentinel on B for A's pod | `freezer path not found`, no action | 22:49:29 onward | n/a | `d1-sentinel-osramp-dist-worker2.log` |
| D2 | pod-only record: replacement Ready | +1.41 s after delete | 22:50:01.752 → 22:50:03.166 | no, 0 filters | `d2-*` |
| D2 | replacement ever frozen | **never** in 36.4 s | to 22:50:38.168 | no | `d2-poll.log`, `d2-tc.txt` |
| D3 | Deployment annotated → running pod `frozen 1` | **25.9 s** (next 30 s resync; there is no Deployment/ReplicaSet informer) | 22:50:46.909 → 22:51:12.819 | **yes** on `vetha0a321d9` | `d3a-*` |
| D3 | label-free replacement first observed | already `frozen=1`, ≤288 ms after delete | 22:51:22.428 → 22:51:22.716 | **no**: born frozen, no pod netns yet (below) | `d3b-*` |
| D3 | replacement Ready | never, `ContainerCreating` at +20 s | 22:51:42.715 | no | `d3b-timestamps.txt` |
| D3 | annotation removed from the Deployment | pod still frozen 46 s later; the ReplicaSet keeps `signalloom.io/stunned: "true"` | 22:52:08.303 → 22:52:54.806 | no | `d3c-*`, `d3c-owner-annotations.txt` |
| D3 | annotation removed from the ReplicaSet | sentinel `frozen_unlabelled` +29.1 s, then unstun fails `find veth before unfreezing pod`; still frozen | 22:53:12.375 → 22:53:41.507 → 22:53:58.047 | no | `d3d-*` |
| D3 | manual `cgroup.freeze=0` (lab step) → Ready | 0.50 s | 22:54:08.641 → 22:54:09.139 | n/a | `d3e-manual-thaw.txt` |
| D4 | label → `frozen 1` on B | 68 ms | 22:54:18.486 → 22:54:18.554 | yes, 2 filters | `d4-pre-poll.log`, `d4-tc-before-restart.txt` |
| D4 | restart → slice back **unfrozen** | | 22:54:26.689 (agent procs 22:54:27.745) | the veth is new, so the old filters are gone with it | `d4-poll-hostside.log` |
| D4 | sentinel `started` → first list times out after 30 s → `stun` | | 22:54:27.845 → 22:54:57.855 → 22:54:59.271 | **yes**, re-attached on the new `vethf80a9cbf` | `d4-sentinel-B-after-restart.log`, `d4-tc-after-restart.txt` |
| D4 | **unfrozen window** | **32.7 s** (slice), **31.6 s** with agent processes | | | |
| D5-0 | connected revoke (partition rule targeted a stale IP; relabelled, not a partition) | unstun +49 ms, `frozen 0` **+63 ms** | 22:55:24.695 → 22:55:24.758 | removed, 0 filters | `d5-connected-revoke-*`, `d5-kind-network-ips.txt` |
| D5a | re-stun of the same pod | freeze ok; **tc failed** `tc add clsact ... Exclusivity flag on, cannot modify`, retried 53 s | 22:57:01.287 → 22:57:54 | **no** | `d5a-restun-sentinel-B.log`, `d5a-restun-qdisc.txt` |
| D5a | bidirectional partition to 172.18.0.9 (counters 187 out / 38 in dropped), revoke during it | freeze **held** 45.1 s | 22:57:05.316 / 22:57:07.769 → 22:57:52.885 | no (see previous row) | `d5a-timestamps.txt` |
| D5a | heal → unstun → `frozen 0` | **1.27 s** after heal | 22:57:53.072 → 22:57:54.305 → 22:57:54.343 | 0 filters after | `d5a-poll.log`, `d5a-sentinel-B.log` |
| D5b | stale `clsact` deleted by hand (lab step), partition (144 out / 40 in dropped), stun applied during it | `frozen 0`, 0 filters for 45 s | 22:58:47.407 / 22:58:47.508 → 22:59:32.569 | no | `d5b-timestamps.txt` |
| D5b | heal → `stun` → `frozen 1` | **7.66 s** after heal, 52.8 s after the API accepted the stun | 22:59:32.669 → 22:59:40.297 → 22:59:40.333 | **yes**, 2 filters at 22:59:42.771 | `d5b-poll.log`, `d5b-sentinel-B.log` |
| D6 | sentinels on A and control-plane for B's pod | 59 and 59 lines, all `freezer path not found`; 0 stun, unstun or `kernel_state` | | n/a | `d6-summary.txt` |

**Verdict on the netlink fix.** It passes every case where the pod has a network namespace: first stun, re-stun after a node restart on a new veth, stun after a partition, and unstun including thaw and filter removal. Three defects remain, all on FIX-C's branch:

1. **Re-stun of a previously released pod never attaches the drop.** `network.go:299` runs `tc qdisc add dev X clsact` and tolerates only `File exists`. Unstun deliberately leaves `clsact` in place, and the iproute2 in the sentinel image reports `Error: Exclusivity flag on, cannot modify. (exit status 2)` for an existing clsact. Result: freeze without network drop, retried indefinitely. The fix is to tolerate that message as well, or use `tc qdisc replace`.
2. **A born-frozen pod has no network, and it cannot be released.** When the owner record freezes a replacement before the sandbox exists, the slice's only process is the runtime init (`comm 6`, state `S`), still in the node netns (`net:[4026540144]`, same as PID 1). The netlink read therefore returns the node's eth0 peer (1269), which is correct behaviour for that process. Unstun still looks up the veth before unfreezing, so the pod stays frozen and `ContainerCreating` after the stun is revoked (`d3b-slice-procs.txt`, `d3d-*`). The fix is to unfreeze first, or to treat "PID in host netns" as "no pod network; skip tc".
3. **The owner stun is sticky on the ReplicaSet, and the owner path is resync-bound.** The Deployment controller copies `signalloom.io/stunned` onto the ReplicaSet and does not remove it when the Deployment annotation is removed. Changes to the owner record are seen only on the 30 s pod resync (25.9 s and 29.1 s measured), because the sentinel watches pods only.

## What state is authoritative and what is not

1. **The kernel freeze is not authoritative.** It is a cache of intent on one node. It vanished on node restart (D4: 32.2 s unfrozen), and it does not follow a pod to another node (D2).
2. **The Pod label is authoritative only for that pod UID.** It survived the restart and was re-applied (D4). A replacement pod starts without it and runs free with no bound (D2: ≥45.6 s observed, Ready in 0.79 s).
3. **An owner record is needed for "the agent stays stunned".** The Deployment annotation is ignored by the merged tree (D3a). With a lab patch it froze a label-free replacement within 160 ms of the delete (D3b). It also wedges the pod in `ContainerCreating` and blocks its deletion.
4. **During an API partition, the node keeps its last-known intent.** The freeze held for 45 s with the stun already revoked, and resyncs re-asserted it from the stale cache (D5a-2). A new stun issued during the partition did not land until 0.82 s after the heal (D5b: 46 s after the API accepted it). A partitioned node can neither be stunned nor released.
5. **Un-stun: before the fix, it never thawed** (D5a-1, D5a-2). **After the fix, it thaws in 63 ms connected, and 1.27 s after a partition heals** (D5-0, D5a). It still cannot release a born-frozen pod, and a released pod cannot be re-stunned with a network drop (after-fix defects 1 and 2).
6. So, to Andy's question: the freeze persists across hosts only as long as the API record exists, is attached to whatever runs next, and can reach the node. Distributed containment therefore needs the stun intent on the owner (Deployment/ReplicaSet, or an admission-time label on new pods). It also needs a sentinel that re-applies intent before the agent starts (D4's 32 s is a boot race), and a stated policy for partitioned nodes. Today the partition behaviour is fail-closed for revoke and fail-open for new stuns.

## Side findings (defects measured on the way)

- **tc drop never attaches, and unstun never unfreezes (before fix; fixed by `192f26c8`, see the after-fix section).** `apps/signalloom-stun-sentinel/network.go:191` reads `/sys/class/net/eth0/iflink` after `setns`. sysfs stays bound to the namespace that mounted it, so the sentinel reads the node's own eth0 peer index (1245) instead of the pod's (3) (`d1-veth-diagnosis.txt`). The stun path freezes first and then fails, so containment is freeze-only with no network drop. The unstun path fails *before* unfreezing, so it never thaws. The fix is to read the peer index over netlink (`RTM_GETLINK` in the pod netns) rather than sysfs.
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

After-fix run, from `evidence/stun-distributed-lab/after-fix/teardown-proof.txt`:

```
teardown_start 23:59:59.542360541
Deleted nodes: ["osramp-dist-control-plane" "osramp-dist-worker" "osramp-dist-worker2"]
teardown_end 00:00:03.077314000
$ kind get clusters
osramp
osramp-scaffold
$ docker ps -a --filter name=osramp-dist -q | wc -l
0
current-context: kind-osramp
worktree /tmp/kusari-e2e/w6-sentinel-src removed
```
