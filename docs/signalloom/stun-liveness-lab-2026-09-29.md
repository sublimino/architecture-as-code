# Stun vs liveness probes: measurement lab (2026-09-29)

Measured on `kind-osramp` (single node `osramp-control-plane`, cgroup v2, Cilium v1.16.7, Flux source-controller v1.9.5) between 22:40 and 22:59 BST, in the throwaway namespace `kusari-liveness-lab`. Nothing outside that namespace was mutated, with one stated exception: a `port-forward` to `registry/zot` to push, then delete, one lab-only artifact (`acme/lab/kusari-liveness-lab-e4`). Raw evidence lives in `evidence/stun-liveness-lab/`. All wall-clock times are local (BST, UTC+1); Kubernetes event times are UTC with one-second resolution.

**Question.** Agents we own must keep liveness probes. The stun freezes the pod cgroup, and the kubelet then kills the container. Which alternative keeps probes green without losing the forensic subject?

## Cgroup paths resolved

The kind layout matches the engine's `kubelet.slice/kubelet-kubepods.slice` root (`d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go`, `kubepodsRoots`/`candidatePaths`), with the QoS child and the pod UID mangled to underscores:

```
/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/
  kubelet-kubepods-burstable-pod<uid_with_underscores>.slice/          <- pod slice (what the stun freezes today)
    cri-containerd-<containerID>.scope                                  <- one per container, plus the pause sandbox
```

E1 pod slice: `...kubelet-kubepods-burstable-pod09d1a66b_5428_4a81_9b59_144430a833b9.slice`. Container scope is `.status.containerStatuses[name==X].containerID` minus `containerd://`. All per-experiment paths are in `e*-paths.txt`.

## E1: pod-slice freeze under the Kusari stub's probe config

Copy of `fe-signalloom-agents/agent-kusari`: liveness `/healthz` period 15 s, failureThreshold 3, timeout 1 s; readiness period 5 s; terminationGracePeriodSeconds 30 (default). Only deviation: CPU request 10m instead of 5m. Freeze: `echo 1 > <pod slice>/cgroup.freeze` at **22:41:23.663**.

| Metric | Value | Timestamp | Raw |
|---|---|---|---|
| First readiness `Unhealthy` event | +2.3 s | 21:41:26Z | `e1-events.txt` |
| `kubectl get pod` shows `0/1 Running 0` | +13.4 s | 22:41:37.090 | `e1-monitor.log` |
| First liveness `Unhealthy` event | +10.3 s | 21:41:34Z | `e1-events.txt` |
| `Killing` ("failed liveness probe, will be restarted") | **+40.3 s** | 21:42:04Z | `e1-events.txt` |
| Readiness error changes to `connection reset` | +70.3 s, which equals Killing + 30 s grace, consistent with SIGKILL at grace expiry | 21:42:34Z | `e1-events.txt` |
| Original agent PID 3793558 | **gone**; `lastState` later overwritten, so the kill record is lost | checked 22:45:02 | `e1-frozen-state.txt` |
| Replacement container | created inside the frozen slice; its `runc` init is frozen too; CRI start fails `context deadline exceeded` | 21:44:34Z | `e1-kubelet.log` |
| `restartCount` 0 to 1 visible | +192.7 s; status `RunContainerError`, phase `Pending` | 22:44:36.390 | `e1-monitor.log` |
| Ready again while slice frozen | **never**, observed for 234.7 s | to 22:45:18 | `e1-monitor.log` |
| Frozen-state scopes | pause plus two stuck replacement attempts, all `frozen 1` | 22:45:02 | `e1-frozen-state.txt` |
| Thaw to Ready | 2.2 s; `restartCount` 2; `lastState` = `StartError` exit 128 | 22:45:18.357 to 22:45:20.576 | `e1-after-thaw.txt`, `e1-thaw-monitor.log` |

**Reading.** SIGKILL reaches frozen tasks on cgroup v2, so the frozen agent is destroyed about 70 s after the stun. The kubelet then wedges the pod in `RunContainerError` until thaw. The stun loses exactly the process it exists to preserve.

## E2: container-scope freeze with a guardian sidecar

Same pod plus a `guardian` container (perl responder on :8081). The agent container's liveness and readiness probes both target :8081; pod IP is shared. Only the agent's `cri-containerd-<id>.scope` was frozen, from **22:46:22.407** to **22:47:47.092** (84.7 s, 5.6 liveness periods).

| Metric | Value | Timestamp | Raw |
|---|---|---|---|
| Pod `READY`/`RESTARTS` throughout | `2/2`, `0` | 22:46:20 to 22:47:39 | `e2-monitor.log` |
| `Unhealthy` events during freeze | 0; the only one is guardian startup at 21:46:09Z, before the freeze | n/a | `e2-events.txt` |
| Agent `cpu.stat usage_usec` over 14 samples | 31855, static | 22:46:24 to 22:47:19 | `e2-samples.log` |
| Agent :8080 from another pod | read timeout every sample | same | `e2-samples.log` |
| Guardian :8081 | 200 OK every sample | same | `e2-samples.log` |
| Pod slice `cgroup.freeze` | 0 throughout; only the scope was frozen | same | `e2-samples.log` |
| Thaw | agent :8080 200 OK, `usage_usec` 33843, PID 3801910 unchanged, restarts 0 | 22:47:47.659 | `e2-after-thaw.txt` |

**What the probe now measures.** The guardian's liveness, not the agent's. A hung or dead agent would no longer be restarted by the kubelet. That trade must be made explicitly, for example by having the guardian proxy the agent's `/healthz` except while stunned.

## E3: label-driven Cilium quarantine, no freeze

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: stun-quarantine, namespace: kusari-liveness-lab}
spec:
  endpointSelector:
    matchLabels: {signalloom.io/stunned: "true"}
  ingress:
  - fromEntities: [host]        # kubelet probes only
  egressDeny:
  - toEntities: [all]           # everything, DNS included; deny beats any allow
```

Pod: stub agent with its original probes on :8080, plus a test-only `shell` sidecar that shares the netns and originates egress. Labelled at **22:48:50.539**. Connection loops ran every ~0.25 s with 1 s timeouts.

| Metric | Value | Timestamp | Raw |
|---|---|---|---|
| Baseline egress: `10.96.0.1:443`, `kubernetes.default.svc.cluster.local:443`, `1.1.1.1:443`, `1.1.1.1:80` | all reachable | 22:48:39 to 22:48:41 | `e3-egress.log` |
| Label to first blocked ingress (other pod to agent :8080) | **5.186 s** | 22:48:55.725 | `e3-ingress-loop.log` |
| Label to first blocked egress (pod to apiserver) | **5.235 s** | 22:48:55.774 | `e3-egress-loop.log` |
| Stunned egress to apiserver IP, `1.1.1.1:443`, `1.1.1.1:80` | connect timed out | 22:49:57 to 22:50:25 | `e3-egress.log` |
| Stunned egress to the apiserver by DNS name | name resolution failed, so DNS is blocked | 22:50:00 | `e3-egress.log` |
| Pod state while quarantined, 66 s, 4.4 liveness periods | `2/2 Running 0`; zero `Unhealthy` events | 22:48:42 to 22:49:56 | `e3-monitor.log`, `e3-events.txt` |
| Unlabel to egress restored | 5.517 s | from 22:50:46.370 | `e3-restore-egress-loop.log` |
| Unlabel to ingress restored (second cycle) | 5.067 s | from 22:51:35.395 | `e3-restore-ingress-loop.log` |
| DNS egress after restore | OK | 22:51:07 | `e3-egress.log` |

The first ingress-restore loop died because the client pod's `sleep 300` expired (`e3-restore-ingress-loop-attempt1-failed.log`), so that cycle was repeated.

## E4: `kustomize.toolkit.fluxcd.io/reconcile: disabled`

This ran without touching `flux-system`. A lab-only artifact was pushed to zot. Then a lab-namespace `OCIRepository` and `Kustomization` were created, with a lab `ServiceAccount/flux` bound to a lab-only Role, because the controller runs `--default-service-account=flux`. Manifests: `e4-flux.yaml`, `e4-artifact-deploy.yaml`.

| Step | `spec.replicas` | Timestamp | Raw |
|---|---|---|---|
| Baseline, Flux-applied | 1 | 22:52:46.371 | `e4-run.log` |
| Annotate Deployment `reconcile=disabled`, then `kubectl scale --replicas=2` | 2 | 22:52:46.707 | `e4-run.log` |
| `flux reconcile ks --with-source`, Ready "Applied revision" | **2, hand change survives** | 22:52:50.934 | `e4-run.log` |
| Second forced reconcile | **2** | 22:52:58.110 | `e4-run.log` |
| Remove annotation, then reconcile | **1, reverted by Flux** | 22:53:00.433 | `e4-run.log` |
| `signalloom.io/stunned=true` on a Flux-managed Pod, then reconcile | label kept, pod not replaced | 22:53:15.411 | `e4-podlabel.log` |

Flux manages the Deployment, not its Pods. A stun label on the Pod needs no `reconcile: disabled`. The annotation matters only if the stun edits the Deployment itself, for example `replicas` or the pod template. A template edit would also roll the pod and destroy the subject.

## E5: combined candidate

This is the E2 pod, with the E3 policy still present in the namespace. The agent scope freeze and the quarantine label are applied together at **22:56:39.611**, and the scope is thawed at **22:56:59.705** (a 20.09 s window). The guardian probe runs throughout. The label goes on at freeze time because E3 measured about 5.2 s for policy to take effect, so the quarantine is live well before the thaw. The table is from run 2.

| Metric | Value | Timestamp | Raw |
|---|---|---|---|
| Total non-Ready time | **0 s**. Ready `lastTransitionTime` is 21:53:41Z both before and after; the monitor shows `2/2` for 70 s | 22:56:34 to 22:57:43 | `e5-paths.txt`, `e5-monitor.log` |
| Restarts | 0, 0 before and after | same | `e5-paths.txt` |
| Agent `usage_usec` while frozen | 46322, static over 4 samples; rises after thaw to 47083, 47304, 47593 | 22:56:39 to 22:57:18 | `e5-samples.log` |
| Process tree: PID, comm, `/proc/<pid>/stat` starttime | identical (`diff` empty). pause 3811685, kusari-agent 3811710 at 217219483, perl 3811749 | before and after | `e5-proctree-*.txt` |
| Ingress while frozen | 5 read-timeouts, then connect-drop from +6.34 s | 22:56:39 to 22:56:59 | `e5-ingress-loop.log` |
| Ingress after thaw, agent running | 28 of 28 dropped, 0 OK | 22:56:59 to 22:57:34 | `e5-ingress-loop.log` |
| Egress from the unfrozen guardian after label | OK for the first 5.24 s, then 29 of 29 dropped after thaw | 22:56:39 onward | `e5-egress-loop.log` |
| Agent alive inside the pod after thaw (localhost:8080) | 200 OK; external egress to `1.1.1.1` timed out | 22:57:03 to 22:57:18 | `e5-samples.log` |

**Client defect found and corrected.** Run 1 used a loop client whose `alarm`-based read timeout recorded timeouts as OK. The tell was 1.25 s spacing, where real replies take about 0 ms (`e5-client-artefact-check.log`). The client was replaced with an `IO::Select` version, v2, verified against a frozen agent, and E5 was re-run. The E3 v1 logs were re-checked by inter-attempt gap and contain no masked timeouts (`v1-loop-reanalysis.txt`). Run 1's pod-level results agree with run 2: 0 restarts, identical process tree, Ready transition unchanged (`e5-run1-*`).

## Manifests

These are inline where short. The full files are under `evidence/stun-liveness-lab/`: `e1-manifest.yaml`, `e2-manifest.yaml` (E5 is the same file with `e2` renamed to `e5`), `e3-manifest.yaml`, `e3-cnp.yaml`, `e4-flux.yaml`, `e4-artifact-deploy.yaml`, `e2-configmap.yaml`, and the scripts `guardian.pl`, `client.pl`, `loop.pl`. The E2/E5 probe wiring:

```yaml
      - name: agent            # probes target the guardian's port; the pod IP is shared
        livenessProbe:  {httpGet: {path: /healthz, port: 8081}, periodSeconds: 15, failureThreshold: 3, timeoutSeconds: 1}
        readinessProbe: {httpGet: {path: /healthz, port: 8081}, periodSeconds: 5,  failureThreshold: 3, timeoutSeconds: 1}
      - name: guardian         # bitnamilegacy/kubectl:1.31, `perl /scripts/guardian.pl` on :8081
        livenessProbe:  {httpGet: {path: /healthz, port: 8081}, periodSeconds: 15, failureThreshold: 3, timeoutSeconds: 1}
```

## What this means for the stun design

1. **Stop freezing the pod slice while liveness probes point at the agent** (E1). The kubelet issues `Killing` at about 40 s, and SIGKILL destroys the frozen agent at about 70 s. The pod then sits in `RunContainerError` and is never Ready until thaw. The forensic subject is lost.
2. **Use the label-driven Cilium quarantine as the default stun** (E3). Probes stay green, restarts stay at 0, both directions are cut including DNS, and removal is clean. Budget about 5.2 s from label to enforcement, and the same again to restore. The sentinel must treat "label applied" as not yet contained.
3. **Freeze the agent's container scope, never the pod slice, when CPU halt is needed** (E2, E5). A 20 s scope freeze inside the quarantine gave zero non-Ready time, zero restarts, and an identical process tree. The resolver needs one more hop: the pod slice plus `cri-containerd-<containerID>.scope`.
4. **Apply the label at freeze time, not at thaw** (E5). Otherwise the agent thaws into an open network. Unfrozen sidecars keep egress for about 5 s after the label, which argues for keeping the `tc` veth drop as the instant layer while Cilium converges.
5. **The guardian pattern changes what liveness means** (E2). It makes the probe check the guardian, not the agent. The guardian should proxy the agent's `/healthz` and answer locally only while `signalloom.io/stunned=true`, otherwise a hung agent is never restarted. This proxy behaviour is not measured here.
6. **Label the Pod, not the Deployment** (E4). A Pod label survives Flux reconciles with no annotation needed. `reconcile: disabled` does work, surviving two forced reconciles and reverting once removed, but it is only needed if the stun edits the Deployment.
7. **Not measured:** the sentinel's own `tc` path, long freezes over 85 s at scope level, multi-container agents, and a guardian that proxies agent health.

## Observed, not caused by this lab

At 22:57 three pod slices in `fe-signalloom-agents` read `cgroup.freeze=1`: `agent-cardvault-bb57657-jlf8w`, `agent-sir-lancelot` and `agent-nono-evidenced-fccfbb-xp8v7`. They were left untouched (`foreign-frozen-cgroups-observed.txt`). Per E1, any of these with an agent-pointed liveness probe will be killed.

## Teardown proof

Every lab cgroup read `freeze=0` before deletion (`pre-teardown-freeze-state.txt`). Excerpt from `teardown.log`:

```
22:58:14.907459129 delete ns
namespace "kusari-liveness-lab" deleted
22:59:03.946869303 proof:
Error from server (NotFound): namespaces "kusari-liveness-lab" not found
22:59:10.615779232 delete lab artifact from zot
DELETE http=202
GET tag v1 after delete http=404
```
