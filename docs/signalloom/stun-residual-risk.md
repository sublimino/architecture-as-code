# STUN residual-risk statement

> **Recovered record (2026-10-06).** This is the STUN-P7-1 published statement
> from the abandoned `integration/stun-under-flux` mission (tip `5482e79b`),
> harvested verbatim as a historical record per
> `docs/signalloom/stun-dod-evidence.md`. It is pinned to merged revision
> `3ae13b0d7465fa6a3e050323676ec225624f0374` and is **not** a current-state
> claim. Status of its content against today's base:
>
> - **Moot by architecture change.** `policy.networking.k8s.io` /
>   `AdminNetworkPolicy` dependence (BYPASS-006 through BYPASS-018, the whole
>   CNI comparison matrix) assumed containment was a Cilium/kindnet
>   NetworkPolicy. The current containment path severs the pod's veth directly
>   with a host-side TC filter and does not depend on any NetworkPolicy API —
>   see `d2-signalloom/apps/signalloom-stun-sentinel/network.go` and
>   `test/tc-ebpf-drop.bats` (CRKC-P1-3), which already carries the hard
>   positive-control precondition this statement's CNI matrix was built to
>   motivate. Quarantine admin-deny itself was never carried forward:
>   `d2-signalloom/apps/fleet-manager/enforcement.go:94-99` records that the
>   proposal's `isolated`/`quarantined` containment-mode values are "nothing
>   writes and nothing reads" today; only `frozen`/`none` exist.
> - **Resolved.** BYPASS-026 (the live PostgreSQL `Deployment` had no PVC, so
>   pod recreation erased `public.audit_events`) was fixed by
>   `d396b8ee` "feat(signalloom): add host-backed postgres persistence and
>   lifecycle targets" (2026-10-01), after this record was written.
> - **Open, unretested against current code — owner to re-verify.**
>   BYPASS-001/002/004/005 (credential TTL/lease non-revoke, audit
>   non-atomicity) predate the current `fleet-manager`
>   `RotateAgentCredentials` / `RevokeCredentials` cascade and the
>   `attestation_event_contract.go` Witness-attested pipeline
>   (`d2-signalloom/apps/fleet-manager/openbao_client.go:707-760`), which look
>   like they address the same concerns but were never checked against this
>   register. BYPASS-017/019-025 (cgroup/veth/sentinel-state loss on pod
>   reschedule, node reboot, or sentinel restart) are about the freeze
>   mechanism itself and are architecture-independent; nothing in this repo's
>   current tests exercises them.
> - The companion input census this statement cites below,
>   `stun-residual-risk-frame.md` (P7-PRE, 2026-09-01), was not recovered: it
>   is superseded working notes feeding this already-published matrix, and the
>   consuming suite named below (`d2-signalloom/test/residual-risk-completeness.bats`)
>   does not exist on this base either. The cross-reference is left as plain
>   text rather than a link.

<!-- STUN-CNI-RISK-MATRIX:v1 BEGIN -->

| CNI | New-connection denial | Established-connection severance | AdminNetworkPolicy support | Policy programming latency after pod start | Fail-open when `policy.networking.k8s.io` is absent |
| --- | --- | --- | --- | --- | --- |
| Cilium | Selected policy denies fresh flows.<br>**Class: VENDOR-DOCUMENTED**<br>Evidence: [V1] | Ordinary selected endpoint traffic is re-evaluated on the next packet, so the parent's severance claim is correct for that scope; proxy, hairpin, loopback, host-network, and unselected-endpoint paths remain exceptions.<br>**Class: VENDOR-DOCUMENTED**<br>Evidence: [V2] | The captured Cilium 1.16.7 estate serves neither Kubernetes administrative-policy CRD; its separate `CiliumClusterwideNetworkPolicy` CRD exists.<br>**Class: MEASURED**<br>Evidence: [M1] | The lifecycle exposes identity allocation and eBPF regeneration, but no bounded pod-start-to-enforcement latency was measured or documented.<br>**Class: UNVERIFIED**<br>Evidence: [U1] | A design depending on the absent Kubernetes group is open; a Cilium-specific deny can substitute only when stored, and the captured estate stores none.<br>**Class: MEASURED**<br>Evidence: [M1] |
| Calico | Non-established traffic traverses Felix policy chains.<br>**Class: VENDOR-DOCUMENTED**<br>Evidence: [V3] | Felix accepts `RELATED,ESTABLISHED` traffic before endpoint policy evaluation, so a policy transition does not sever the existing flow.<br>**Class: VENDOR-DOCUMENTED**<br>Evidence: [V3] | Network Policy API lists Calico support for the standard administrative-policy fields in named releases.<br>**Class: VENDOR-DOCUMENTED**<br>Evidence: [V4] | No admissible source establishes a pod-start-to-policy bound for the relevant Calico dataplanes.<br>**Class: UNVERIFIED**<br>Evidence: [U2] | The Kubernetes administrative tier cannot exist without its API; whether Calico-native policy substitutes was not measured on a Calico estate.<br>**Class: UNVERIFIED**<br>Evidence: [U3] |
| AWS VPC CNI | The Network Policy Agent attaches eBPF policy enforcement to the pod host veth.<br>**Class: VENDOR-DOCUMENTED**<br>Evidence: [V5] | The agent maintains its own conntrack cache and documents cleanup rather than policy-change invalidation, so the parent's unconditional severance claim is wrong for this dataplane.<br>**Class: VENDOR-DOCUMENTED**<br>Evidence: [V5] | EKS documents an AWS-specific `networking.k8s.aws/v1alpha1` `ClusterNetworkPolicy`, not the Kubernetes `policy.networking.k8s.io` resource used by the parent design.<br>**Class: VENDOR-DOCUMENTED**<br>Evidence: [V6] | Controller resolution, `PolicyEndpoint` publication, and agent programming are documented, but no bounded pod-start latency is stated or measured.<br>**Class: UNVERIFIED**<br>Evidence: [U4] | Absence of the Kubernetes group does not disable an already-configured AWS-specific admin tier; absence of both administrative mechanisms leaves only ordinary policy.<br>**Class: VENDOR-DOCUMENTED**<br>Evidence: [V6] |
| kindnet | A fresh TCP connection from the positive-control pod timed out after deny policy application.<br>**Class: MEASURED**<br>Evidence: [M2] | The established stream carried sequences 6 through 25 after policy application while the fresh connection was denied, so the parent claim is wrong for kindnet.<br>**Class: MEASURED**<br>Evidence: [M2] | The captured version served no administrative-policy API and its kindnet principal could not list administrative policies.<br>**Class: MEASURED**<br>Evidence: [M3] | The measured policy-transition interval is not pod-start programming latency; no pod-start measurement exists.<br>**Class: UNVERIFIED**<br>Evidence: [U5] | With the API unserved and no kindnet permission, a design depending on that administrative tier was open.<br>**Class: MEASURED**<br>Evidence: [M3] |

<!-- STUN-CNI-RISK-MATRIX:v1 END -->

**Matrix accounting:** 20 cells: **6 MEASURED**, **9 VENDOR-DOCUMENTED**, **5 UNVERIFIED**.

The attack surface is pinned to merged integration revision
`3ae13b0d7465fa6a3e050323676ec225624f0374`. `MEASURED` means the command and
raw output are pasted below. `VENDOR-DOCUMENTED` means the verdict comes from a
named vendor document or upstream implementation source rather than this
cluster. `UNVERIFIED` means neither admissible measurement nor sufficiently
specific vendor evidence establishes the cell. No blank cell is an implied
pass.

## Numbered bypass register

The expected identifiers are not maintained here independently. The guard in
`d2-signalloom/test/residual-risk-completeness.bats` extracts them from the
delimited canonical register in
`stun-residual-risk-frame.md` (not recovered — see the note above), validates its
ordinal/suffix sequence, positively asserts a non-zero parse, then compares that
derived set with this delimited publication.

<!-- STUN-PUBLISHED-BYPASS-REGISTER:v1 BEGIN -->

1. `STUN-BYPASS-001` — **OPEN; repository premise verified.** A token issued before role and KV deletion can remain usable to its TTL because `stun-agent.sh` performs no token or lease revoke.
2. `STUN-BYPASS-002` — **OPEN; not executed.** Restarting in-memory OpenBao followed by bootstrap can recreate the deleted role or KV path without changing the stunned target.
3. `STUN-BYPASS-003` — **SOURCE-CONFIRMED.** The fake proxy patches `state=stunned`, emits an Event, and reports “credentials revoked” without calling OpenBao; it also omits the sentinel's `stun-request`, so the ordinary proxy path does not invoke T3.
4. `STUN-BYPASS-004` — **OPEN; repository premise verified.** The proxy side effect precedes the application audit transaction, so cluster mutation and audit persistence are not atomic.
5. `STUN-BYPASS-005` — **OPEN; not executed.** Deleting the caller-owned freeze-first JSONL removes its record without restoring deleted OpenBao state.
6. `STUN-BYPASS-006` — **PRECONDITION MEASURED.** `policy.networking.k8s.io` is unserved and neither administrative CRD exists, so a control depending on that group is fail-open here.
7. `STUN-BYPASS-007` — **STATE MEASURED.** The Cilium cluster-wide policy CRD exists while `stun-quarantine-admin-deny` is absent.
8. `STUN-BYPASS-008` — **STATE MEASURED by P7-PRE.** `ResourceSet/agent-swarm` and its generated Kustomization are absent, so their intended controls are not stored.
9. `STUN-BYPASS-009` — **OPEN; not executed.** Without an administrative deny, a post-stun ordinary allow policy can reopen traffic outside the build-time `NotIn` convention.
10. `STUN-BYPASS-010` — **OPEN; not executed.** A CNI-native allow outside the ordinary-NetworkPolicy checker can reopen traffic when no higher deny tier applies.
11. `STUN-BYPASS-011` — **OPEN; not executed.** A higher-priority Admin Allow or exclusion can prevent the intended administrative deny from containing the target.
12. `STUN-BYPASS-012` — **UNVERIFIED.** No available kindnet estate test stops the NFQUEUE listener after proving positive-before, denied-before-loss, and reachable-after-loss behavior.
13. `STUN-BYPASS-013` — **MEASURED historically.** On kindnet, an established stream survived the deny transition while a fresh connection from the same pod was denied [M2].
14. `STUN-BYPASS-014` — **VENDOR-DOCUMENTED.** Calico's iptables/nftables rule renderer accepts established traffic before policy evaluation [V3].
15. `STUN-BYPASS-015` — **VENDOR-DOCUMENTED, not locally measured.** AWS documents a local conntrack cache and cleanup rather than policy-change invalidation [V5].
16. `STUN-BYPASS-016` — **VENDOR-DOCUMENTED with unmeasured exceptions.** Cilium re-evaluates ordinary selected endpoint traffic, but proxy, hairpin, loopback, host-network, and unselected paths prevent a flat guarantee [V2].
17. `STUN-BYPASS-017` — **OPEN; not executed.** Pod replacement or loss of `signalloom.ai/state=stunned` removes label selection until equivalent containment reaches the replacement.
18. `STUN-BYPASS-018` — **SCHEMA MEASURED.** `ResourceSet.spec` has no `ignore`, so its managed objects cannot use Kustomization field-survival semantics [R1].
19. `STUN-BYPASS-019` — **OPEN; repository premise verified.** Replacement or reschedule creates a new cgroup and veth without the old freeze or TC filter.
20. `STUN-BYPASS-020` — **OPEN; repository premise verified.** Node reboot destroys the target cgroup and TC state even when Kubernetes metadata later reconstructs the pod.
21. `STUN-BYPASS-021` — **PARTIALLY UNVERIFIED.** A kubelet-triggered target-container restart destroys the frozen target; a bare kubelet daemon restart remains unmeasured and is not claimed equivalent.
22. `STUN-BYPASS-022` — **OPEN; repository premise verified.** Node-root can write `0` to `cgroup.freeze` or delete the TC qdisc without changing the stun label.
23. `STUN-BYPASS-023` — **OPEN; repository premise verified.** Unsupported cgroup/PID/veth layout or a host-network target can make node-local resolution fail.
24. `STUN-BYPASS-024` — **SOURCE-CONFIRMED configuration risk.** `STUN_CONNTRACK=off`, deletion failure, or CNI-owned conntrack outside netfilter can preserve established state despite node-local mutation.
25. `STUN-BYPASS-025` — **OPEN; repository premise verified.** Sentinel restart loses the in-memory `stunnedPods` map and old stdout while kernel state can remain active.
26. `STUN-BYPASS-026` — **LIVE PRECONDITION MEASURED by P7-PRE; destructive test not run.** The running PostgreSQL Deployment has no PVC, so pod recreation can erase `public.audit_events`.
27. `STUN-BYPASS-027` — **TTL AND AGGREGATION MEASURED; ordering UNVERIFIED.** Events have a one-hour effective TTL and aggregate repeated observations into one object with a count; no measurement proves which enforcement outlives which Event [E1].
28. `STUN-BYPASS-028` — **SOURCE-CONFIRMED reader ambiguity; enforcement overlap unmeasured.** After metadata reversion, SuperCred reads current pod state and cannot distinguish “stun erased” from “never stunned” [S1].

<!-- STUN-PUBLISHED-BYPASS-REGISTER:v1 END -->

## Fail-open CNI case

`policy.networking.k8s.io` is not served here. No `AdminNetworkPolicy` or
`ClusterNetworkPolicy` CRD exists. The current authorization census contains no
kindnet service account, ClusterRole, or binding, and a hypothetical
`system:serviceaccount:kube-system:kindnet` cannot read the absent resource. The
historical kindnet capture independently records the same API and RBAC result.
Consequently, any admin-tier deny **whose design depends on that group** is
fail-open wherever the group and an enforcing implementation are absent.
Cilium's and AWS's separate vendor APIs are possible substitutes, not evidence
that the Kubernetes-group object exists; they protect nothing unless a deny is
actually stored.

```console
$ kubectl get --raw /apis/policy.networking.k8s.io
Error from server (NotFound): the server could not find the requested resource
target_group_rc=1
$ kubectl get crd adminnetworkpolicies.policy.networking.k8s.io
Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "adminnetworkpolicies.policy.networking.k8s.io" not found
admin_crd_rc=1
$ kubectl get crd clusternetworkpolicies.policy.networking.k8s.io
Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "clusternetworkpolicies.policy.networking.k8s.io" not found
cluster_crd_rc=1
$ kubectl get serviceaccounts -A -o json | jq kindnet-census
serviceaccount_total=93
kindnet_serviceaccount_matches=0
$ kubectl get clusterroles -o json | jq policy-group-census
clusterrole_total=105
kindnet_clusterrole_matches=0
exact_policy_group_rule_count=0
wildcard_api_group_rule_count=9
$ kubectl get clusterrolebindings -o json | jq kindnet-census
clusterrolebinding_total=85
kindnet_binding_matches=0
$ kubectl auth can-i get clusternetworkpolicies.policy.networking.k8s.io --as=system:serviceaccount:kube-system:kindnet --all-namespaces
Warning: the server doesn't have a resource type 'clusternetworkpolicies' in group 'policy.networking.k8s.io'
no
kindnet_cluster_policy_rc=1
```

## ResourceSet bypass

The served `ResourceSet.spec` schema has ten fields and no `ignore` field.
Therefore no ResourceSet-managed object can use the field-survival mechanism
shipped for Kustomization-managed pods at
`d2-osramp-fleet/tenants/base/apps.yaml:143-152`. A separate generated
Kustomization can own an `ignore`, but that changes the owner; it does not add
the field to ResourceSet.

```console
$ kubectl get crd -o json | jq -r '.items[] | select(.spec.names.kind == "ResourceSet") | .metadata.name'
resourcesets.fluxcd.controlplane.io
$ kubectl get crd resourcesets.fluxcd.controlplane.io -o json | jq -r '.spec.versions[] | select(.served == true) | "VERSION=" + .name, (.schema.openAPIV3Schema.properties.spec.properties | keys[])'
VERSION=v1
commonMetadata
dependsOn
inputStrategy
inputs
inputsFrom
resources
resourcesTemplate
serviceAccountName
steps
wait
```

## Evidence-lifetime bypass

Kubernetes Events are an expiring, aggregating reader surface rather than a
durable one-action-per-object store. The running apiserver has no explicit
`--event-ttl`; its running binary reports the effective default as `1h0m0s`.
The live census found 55 aggregated objects among 713 Events, including objects
whose `count` exceeded 400. Any residual claim resting on Events carries that
one-hour expiry and loses per-action cardinality when repeated observations are
folded into one object.

```console
$ kubectl -n kube-system get pod -l component=kube-apiserver -o json | jq event-ttl-args
apiserver_pod_count=1
pod=kube-apiserver-osramp-control-plane event_ttl_arg_count=0
$ docker exec osramp-control-plane crictl exec 9c2e7f2341541b32252d48510bed46c7ff8b7ef192eb5663c1e049a620fdafb6 kube-apiserver --help | filter event TTL
      --event-ttl duration                               Amount of time to retain events. (default 1h0m0s)
$ kubectl get events -A -o json | jq aggregation-census
event_object_total=713
aggregated_object_total=55
event=agent-trust-acme-payments/agent-trust-planner-76545c7b94-h6672.18d0decf3fb6ea19 count=431 series_count=null reason=FailedMount
```

## Process-tier bypass

A cgroup v2 freeze or TC attachment is bound to the target pod's node-local
cgroup and veth. It does not survive pod replacement/reschedule or node reboot.
A kubelet-triggered target-container restart also destroys that target; a bare
kubelet daemon restart remains **UNVERIFIED** and is not silently promoted to
the same verdict.

The inherited card text describing `network.go` as stub-grade, without
conntrack handling, and without a test file is stale at the merged review SHA.
The merged implementation resolves the host veth by exact `iflink`, installs
bidirectional TC drops, deletes source and destination netfilter conntrack
entries, and has five top-level tests in `network_test.go`. Those are mock-runner
unit tests, not live node-dataplane or long-lived-flow evidence. The residual
risk is unsupported layouts, disabled/failed/wrong conntrack cleanup, target
replacement, and loss of in-memory/log evidence—not absence of the shipped
code.

```console
$ for base in freezer network; do test source and test; done
freezer source=present test=present test_path=d2-signalloom/apps/signalloom-stun-sentinel/freezer_test.go
network source=present test=present test_path=d2-signalloom/apps/signalloom-stun-sentinel/network_test.go
$ grep -n conntrack d2-signalloom/apps/signalloom-stun-sentinel/network.go
182:// conntrack directions. Flushing before the filters would let an established
202: if out, err := t.command("conntrack", "-D", "-s", podIP); err != nil {
205: if out, err := t.command("conntrack", "-D", "-d", podIP); err != nil {
$ grep -c '^func Test' d2-signalloom/apps/signalloom-stun-sentinel/network_test.go
5
```

The ordinary fake-proxy stun path is a second process-tier boundary. It patches
`signalloom.ai/state=stunned` but does not set the sentinel's
`signalloom.ai/stun-request=stunned`. Only the composed freeze-first shell path
requests T3. A UI/API “stun” therefore must not imply node-local freeze or TC
severance unless the observed sentinel event proves that separate path ran.

## Reader-not-store bypass

`scripts/supercred-evidence.sh:424` derives its annotation verdict from a live
pod query:

```bash
if grep -qE 'state=stunned|stunned-at=[0-9]' <<<"$ann_out"; then annotated=1; fi
```

After a reconcile or replacement removes that metadata, the next invocation
reports not annotated. The reader has no historical record, so “stun erased” is
indistinguishable from “never stunned”. OpenBao or node-local enforcement can
still apply while the reader projects reassuring live metadata.

## Measured matrix evidence

### [M1] Captured Cilium estate and absent Kubernetes administrative API

```console
$ kubectl config current-context
kind-osramp
$ kubectl -n kube-system get daemonsets -o custom-columns=NAME:.metadata.name,READY:.status.numberReady,DESIRED:.status.desiredNumberScheduled,IMAGE:.spec.template.spec.containers[0].image
NAME           READY   DESIRED   IMAGE
cilium         1       1         quay.io/cilium/cilium:v1.16.7@sha256:294d2432507fed393b26e9fbfacb25c2e37095578cb34dabac7312b66ed0782e
cilium-envoy   1       1         quay.io/cilium/cilium-envoy:v1.31.5-1739264036-958bef243c6c66fcfd73ca319f2eb49fff1eb2ae@sha256:fc708bd36973d306412b2e50c924cd8333de67e0167802c9b48506f9d772f521
$ kubectl get crd ciliumclusterwidenetworkpolicies.cilium.io
NAME                                         CREATED AT
ciliumclusterwidenetworkpolicies.cilium.io   2026-08-30T23:05:13Z
$ kubectl get ciliumclusterwidenetworkpolicies.cilium.io -A
No resources found
```

The Kubernetes-group NotFound transcript and RBAC census are pasted in
“Fail-open CNI case” above; [M1] comprises both transcript blocks.

### [M2] Historical kindnet paired-flow capture

```console
$ jq kindnet-dataplane evidence/kindnet-baseline/20260830T215227Z/cluster.json
cni=docker.io/kindest/kindnetd:v20260528-9350166c
established_verdict=SURVIVED
seq_before=5
seq_after=25
fresh_probe_verdict=denied
fresh_probe_stderr=Connection error: timed out
$ jq kindnet-probes evidence/kindnet-baseline/20260830T215227Z/probes.json
established-connection-stream-survival permitted 0 2026-08-30T21:52:29.185662+00:00 2026-08-30T21:52:57.195169+00:00
fresh-connection-post-policy-denial denied 1 2026-08-30T21:52:29.185662+00:00 2026-08-30T21:52:40.188816+00:00 Connection error: timed out
```

### [M3] Historical kindnet administrative-policy capture

```console
$ jq kindnet-admin-policy evidence/kindnet-baseline/20260830T215227Z/cluster.json
cni=docker.io/kindest/kindnetd:v20260528-9350166c
policy_group_served=false
kindnet_rbac_adminnetworkpolicies=no,no
```

## Scoped parent-proposal erratum

<!-- STUN-SCOPED-ERRATUM:v1 BEGIN -->

The parent proposal's “severs in-flight connections” claim is **correct for
Cilium** ordinary selected endpoint traffic according to the cited upstream
dataplane source, subject to the named proxy, hairpin, loopback, host-network,
and unselected-endpoint exceptions. The same claim is **wrong for Calico, AWS
VPC CNI, and kindnet**, whose established-flow behavior is scoped separately in
the matrix above. This erratum scopes the claim per CNI rather than correcting
it globally; a flat retraction would have introduced an error.

<!-- STUN-SCOPED-ERRATUM:v1 END -->

## Completeness-guard falsification transcripts

Each filter selected exactly one declared Bats test before mutation. The four
cycles below changed the real deliverable or canonical register, observed a red
guard, restored the original content, and observed green.

### Missing published bypass

Mutation: remove `STUN-BYPASS-028` from the published register.

```console
$ bats --tap --filter 'P7 completeness: published bypasses equal derived register' d2-signalloom/test/residual-risk-completeness.bats
1..1
not ok 1 P7 completeness: published bypasses equal derived register
# bypass mismatch: missing=STUN-BYPASS-028 extra=(none)
exit=1

$ # restore STUN-BYPASS-028, then rerun the same command
1..1
ok 1 P7 completeness: published bypasses equal derived register
exit=0
```

### Blank per-CNI matrix cell

Mutation: blank the Cilium new-connection-denial cell.

```console
$ bats --tap --filter 'P7 matrix: four CNIs and twenty cells are classified' d2-signalloom/test/residual-risk-completeness.bats
1..1
not ok 1 P7 matrix: four CNIs and twenty cells are classified
# per-CNI matrix: Cilium has a blank data cell
exit=1

$ # restore the Cilium cell, then rerun the same command
1..1
ok 1 P7 matrix: four CNIs and twenty cells are classified
exit=0
```

### Flat severance retraction

Mutation: replace the scoped erratum with a global severance retraction.

```console
$ bats --tap --filter 'P7 erratum: severance claim is scoped per CNI' d2-signalloom/test/residual-risk-completeness.bats
1..1
not ok 1 P7 erratum: severance claim is scoped per CNI
# scoped erratum: missing CNI Cilium
exit=1

$ # restore the scoped erratum, then rerun the same command
1..1
ok 1 P7 erratum: severance claim is scoped per CNI
exit=0
```

### Canonical-register growth

Mutation: append `STUN-BYPASS-029` inside the canonical register delimiters
without changing the publication or guard source.

```console
$ bats --tap --filter 'P7 completeness: published bypasses equal derived register' d2-signalloom/test/residual-risk-completeness.bats
1..1
not ok 1 P7 completeness: published bypasses equal derived register
# bypass mismatch: missing=STUN-BYPASS-029 extra=(none)
exit=1

$ # restore the canonical register to 28 entries, then rerun the same command
1..1
ok 1 P7 completeness: published bypasses equal derived register
exit=0
```

## Evidence references

- **[V1]** Kubernetes NetworkPolicy semantics and Cilium policy documentation:
  <https://kubernetes.io/docs/concepts/services-networking/network-policies/> and
  <https://docs.cilium.io/en/stable/security/policy/>.
- **[V2]** Cilium upstream `bpf/bpf_lxc.c`, where `CT_ESTABLISHED` ordinary
  selected traffic falls through policy evaluation, plus explicit proxy and
  hairpin exceptions:
  <https://github.com/cilium/cilium/blob/main/bpf/bpf_lxc.c>.
- **[V3]** Calico Felix endpoint rule rendering accepts
  `RELATED,ESTABLISHED` before subsequent policy rules:
  <https://github.com/projectcalico/calico/blob/master/felix/rules/endpoints.go>.
- **[V4]** Network Policy API implementation status:
  <https://github.com/kubernetes-sigs/network-policy-api/blob/main/site-src/implementations.md>.
- **[V5]** AWS Network Policy Agent architecture and conntrack cache:
  <https://github.com/aws/aws-network-policy-agent/blob/main/README.md>.
- **[V6]** EKS standard and AWS-specific administrative network policy:
  <https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html>.
- **[U1]** Cilium documents lifecycle states through eBPF regeneration but no
  bounded latency: <https://docs.cilium.io/en/stable/security/policy/lifecycle/>.
- **[U2]**, **[U3]**, **[U4]**, **[U5]**: no version-matched measurement or
  sufficiently specific vendor bound/estate behavior was found; these cells
  stay `UNVERIFIED` rather than inheriting another CNI's behavior.
- **[R1]** Live ResourceSet schema transcript in this statement and
  `d2-osramp-fleet/tenants/base/apps.yaml:143-152`.
- **[E1]** Running apiserver/default transcript plus live Event aggregation
  census in this statement.
- **[S1]** `scripts/supercred-evidence.sh:421-425` at review SHA.

## Publication boundary

This statement names residual risks; it does not remediate them. A registered
bypass remains a risk until a separately reviewed card supplies the named
falsification and an owner accepts the result. Source-backed possibility is not
runtime proof, and absence of a measurement is never converted into a pass.
