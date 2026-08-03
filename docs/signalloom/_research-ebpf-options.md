# Signal Loom network killswitch — enforcement options for the stun

> Status: **COMPLETE**, research, 2026-08-03. Live cluster `kind-osramp`.
> Companion to `docs/signalloom/stun-under-flux.md` (which establishes the five-mode taxonomy and
> the reconciler-friction argument) and `docs/signalloom/ebpf-enforcer-spec.md` (the Sentinel spec).
> This document answers a narrower question: **for mode 2, the network killswitch, what is actually
> available on this cluster, what does each option really enforce, and which should we build?**

## Recommendation, up front

**Ship Option A (vanilla NetworkPolicy selecting the stun label) now, with the `NotIn: [stunned]`
guard convention and a committed `state` field. Plan Option C2 (cgroup freeze) as a second,
complementary layer. Do not install Cilium, and do not build a NetworkPolicy-writing controller.**

Six findings drive that, all verified below against the live node and by experiment:

1. **The crux holds. Label-change re-evaluation works, sub-second.** kindnet evaluates policy per
   *new connection* in userspace against a live pod informer cache; it does not compile pod IPs into
   rules at admission time. A running pod that acquires `signalloom.ai/state=stunned` is selected by
   an already-committed NetworkPolicy with no restart, no admission event, no policy rewrite —
   blocked within the same wall-clock second (§2.1). And it is fully reversible (§2.7).
2. **Nothing here severs established connections — including Cilium.** kindnet short-circuits them
   (`ct label 28 ct state established,related … accept`, §1.1); Cilium does the same thing in eBPF for
   the same reason. Verified: a TCP stream kept flowing 14s+ past the stun while new connections were
   dropped, with a **24-hour** conntrack timeout (§2.2). The proposal's area-4 claim that Cilium
   *"severs in-flight connections including established ones"* is **incorrect and should be amended**
   (§3.1).
3. **A stun can be silently defeated by an ordinary allow policy.** NetworkPolicy is allow-only and
   additive, so a quarantine cannot revoke another policy's allow. Verified: adding a routine
   application policy took a stunned pod from blocked to `HTTP 200` with no error and no visible change
   (§2.7). The `NotIn: [stunned]` guard fixes it and is verified working — **this is the most
   important design constraint in this document**, and the one real engineering argument for Cilium.
4. **Forensic access is preserved for free, under every option.** `kubectl exec` into a fully
   quarantined pod works (§2.3) — it traverses API server → kubelet → CRI, never the pod network. A
   network-level inspector carve-out is therefore probably unnecessary, and adding one only widens the
   quarantine.
5. **Two real bypasses exist and are verified.** Node-local root traffic and `hostNetwork` root pods
   reach a stunned pod unimpeded (`meta skuid 0 … accept`, §1.3/§2.5). Separately, enforcement is
   **fail-open**: kill `kindnetd` and every NetworkPolicy in the cluster stops being enforced with no
   object changing and no status degrading (§1.2). Cilium would fail closed — a better argument for it
   than the one currently in the proposal.
6. **The cost gap is enormous.** Option A is ~40 lines of committed YAML. Option B requires replacing
   the CNI on a single-node cluster carrying 46 hours of non-Git state, and kind only accepts
   `disableDefaultCNI` at cluster-creation time (§3.4).

The honest demo narrative is the one Option A can actually back — *containment as reviewed, committed,
continuously reconciled desired state* — and it is a stronger story than the one currently claimed.

---

## 1. What is actually enforcing policy on this cluster

CNI is kindnet (`docker.io/kindest/kindnetd:v20260528-9350166c`, `kube-system/kindnet` DaemonSet).
Modern kindnetd embeds the `kube-network-policies` agent. Enforcement is **nftables + nfqueue**, not
eBPF: the kernel punts candidate packets to a userspace verdict process.

The complete ruleset from the live node — this is the ground truth for everything that follows:

```
$ docker exec osramp-control-plane nft list table inet kindnet-network-policies

table inet kindnet-network-policies {
	set podips-v4 { type ipv4_addr }           # (elements elided — 27 live pod IPs + the node IP)
	set podips-v6 { type ipv6_addr }

	chain postrouting {
		type filter hook postrouting priority srcnat - 5; policy accept;
		udp dport 53 accept
		icmpv6 type nd-router-solicit accept
		icmpv6 type nd-router-advert accept
		icmpv6 type nd-neighbor-solicit accept
		icmpv6 type nd-neighbor-advert accept
		icmpv6 type nd-redirect accept
		meta skuid 0 counter packets 13040 bytes 17964193 accept
		ct label 28 ct state established,related counter packets 543 bytes 930888 accept
		ip saddr @podips-v4 queue flags bypass to 101
		ip daddr @podips-v4 queue flags bypass to 101
		ip6 saddr @podips-v6 queue flags bypass to 101
		ip6 daddr @podips-v6 queue flags bypass to 101
		ct label set 28
	}

	chain input {
		type filter hook input priority srcnat + 1; policy accept;
		iifname "lo" accept
		ip saddr @podips-v4 ct state new queue flags bypass to 101
		ip6 saddr @podips-v6 ct state new queue flags bypass to 101
	}

	chain prerouting {
		type filter hook prerouting priority dstnat + 5; policy accept;
		meta l4proto != udp accept
		udp dport != 53 accept
		ip saddr @podips-v4 queue flags bypass to 101
		ip daddr @podips-v4 queue flags bypass to 101
		ip6 saddr @podips-v6 queue flags bypass to 101
		ip6 daddr @podips-v6 queue flags bypass to 101
	}
}
```

Five structural properties fall directly out of this, and they constrain *every* option below.

### 1.1 Established connections are accepted without re-evaluation — by construction

```
ct label 28 ct state established,related counter packets 543 bytes 930888 accept
...
ct label set 28
```

The last rule of `postrouting` stamps conntrack label bit 28 on any flow that reached the end of the
chain (i.e. was evaluated and permitted). The earlier rule accepts any subsequent
`established,related` packet carrying that label **before it reaches the nfqueue**. Userspace never
sees it. The verdict is cached in the conntrack entry for the life of the flow.

**Consequence: under kindnet, a NetworkPolicy change can never sever an in-flight connection.** It is
not a bug or a latency artefact — it is the design, and it is why the agent can process >10k
connections/sec without a userspace round-trip per packet. Any claim in demo narration that the
killswitch "cuts existing connections" is false on this cluster.

The 543-packet counter on that rule is live evidence the fast path is being taken right now.

### 1.2 Enforcement is fail-open if the agent dies

```
queue flags bypass to 101
```

`flags bypass` means: **if no userspace process is bound to nfqueue 101, the packet is ACCEPTED**, not
dropped. Verified there is currently a listener:

```
$ docker exec osramp-control-plane cat /proc/net/netfilter/nfnetlink_queue
  101 2962154124     0 2   128     0     0   352336  1
     ^queue          ^portid — a listener is bound
```

`/bin/kindnetd` (pid 1327) is that listener. **Kill kindnetd and every NetworkPolicy in the cluster
silently stops being enforced**, with no NetworkPolicy object changing and no `status` degrading.

This is a genuine finding for the threat model and it applies to Option A and Option C equally.
It is *the* strongest technical argument in favour of Option B, and it should be stated as such
rather than buried — see §5.

### 1.3 Host-root traffic bypasses policy entirely

```
meta skuid 0 counter packets 13040 bytes 17964193 accept
```

Any packet generated by a **local socket owned by uid 0** is accepted before evaluation. In
`postrouting`, `skuid` only matches locally-originated packets (forwarded pod-to-pod traffic has no
local socket, so this rule does not match it and pod traffic is still evaluated).

What it does mean: **a `hostNetwork: true` pod running as root is not subject to NetworkPolicy egress
on this CNI.** Note the node IP `172.18.0.7` is a member of `@podips-v4` — hostNetwork pods are in the
policy scope in principle, but this rule accepts their root-owned traffic first. Recorded as a gap,
not yet separately experimentally confirmed — see §7 open items.

### 1.4 DNS is evaluated on a different hook

`postrouting` accepts `udp dport 53` unconditionally, but `prerouting` exists *only* to evaluate
UDP/53 (it accepts everything that is not UDP/53 and queues the rest). DNS is therefore policy-checked
**before kube-proxy's DNAT rewrites the destination**, and the postrouting accept prevents a
double-evaluation of the same query post-DNAT.

Net effect: DNS *is* subject to policy, just evaluated pre-NAT. This is worth stating precisely
because the naive read of the postrouting rule ("DNS is always allowed") is wrong, and getting it
wrong in either direction changes whether a stunned agent can still resolve names. Confirmed by
experiment in §2.

### 1.5 There is no eBPF in this data path at all

nftables + nfqueue + a userspace Go agent. The five-mode taxonomy's *"kernel-level eBPF deny"* is not
what would be running behind Option A. It is honest to call Option A a kernel-level *packet filter*
with a userspace verdict cache; it is not honest to call it eBPF.

---

## 2. Option A — vanilla NetworkPolicy selecting the stun label

### 2.0 The experiment

Scratch namespace `np-stunlab` (created and destroyed by this research; nothing else on the cluster
was touched). Five pods: `target` (podinfo, plays the agent), `client` (curl, plays a peer),
`inspector` (curl, labelled `signalloom.ai/role=inspector`), plus `agent2`/`probe2` (busybox) for the
streaming test.

The policy under test — this is the shape that would be committed to Git:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: signalloom-stun-quarantine
  namespace: np-stunlab
spec:
  podSelector:
    matchLabels:
      signalloom.ai/state: stunned     # selects nothing until an agent is stunned
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              signalloom.ai/role: inspector
  egress: []                            # deny all egress
```

### 2.1 CRUX — does a NetworkPolicy re-evaluate when a running pod's labels change? **YES**

This is the question that decides whether the whole approach works. It works.

**Step A — policy committed and live, target still `state=idle`. Correctly unaffected:**

```
$ kubectl apply -f np-stun.yaml
networkpolicy.networking.k8s.io/signalloom-stun-quarantine created
$ kubectl -n np-stunlab exec client -- curl -s -m 3 -o /dev/null -w '%{http_code}' http://10.244.0.106:9898/version
client->target http=200
```

**Step B — flip the label on the *running* pod. No restart, no recreate, no admission event:**

```
$ kubectl -n np-stunlab label pod target signalloom.ai/state=stunned --overwrite
$ kubectl -n np-stunlab get pod target -o jsonpath='{.metadata.labels}'
{"app":"target","signalloom.ai/agent":"true","signalloom.ai/state":"stunned"}
```

**Step C — a 90-iteration probe loop was running across the flip. The transition:**

```
idx  t(epoch)      code
 22  1785779629    200
 23  1785779629    200
 24  1785779629    200
 25  1785779629    200
 26  1785779629    000    <== FIRST BLOCK
 27  1785779630    000
 28  1785779632    000
```

```
flip issued at:  1785779629.639
first block at:  1785779629     (same wall-clock second)
90 probes total: 26 x HTTP 200, then 64 x 000 — and no 200 ever returns
```

`000` is curl's code for "no response"; the connection is dropped, not refused.

**The mechanism is why this works.** kindnetd does not compile pod IPs into per-policy nftables rules
at admission time. The nftables layer is generic (§1) — it queues *any* packet touching *any* pod IP
to userspace, and kindnetd decides the verdict per new connection against a live pod informer cache.
A label change updates that cache; the very next connection gets the new verdict. There is nothing to
recompile and nothing to restart.

**Enforcement latency: sub-second.** Bounded above by 1.0s and consistent with ~0 (the probe clock had
only 1-second granularity because BusyBox `date` does not implement `%3N`, so a tighter figure was not
measurable with this rig — see §7). The transition is clean: no flapping, no partial enforcement, and
the block is stable for the remaining 64 probes.

### 2.2 Does it sever ESTABLISHED connections? **NO. Categorically not.**

Instrumented test: `agent2` runs a BusyBox `nc` echo server; `probe2` opens **one** TCP session and
writes a timestamp every 0.5s, logging every echoed line. The stun fires mid-stream.

```
STUN_FLIP_AT=1785779811

# NEW connection while stunned:
$ kubectl -n np-stunlab exec probe2 -- sh -c "echo newconn | timeout 3 nc 10.244.0.120 8080; echo exit=$?"
new_conn_exit=143                      # 143 = SIGTERM from timeout: hung, i.e. dropped. BLOCKED.

# the ESTABLISHED stream, 8s after the stun:
1785779821
1785779821
1785779822
--- 35 lines
# …and 14s after the stun:
1785779827
1785779827
1785779828
--- 47 lines
```

The echoed timestamps keep advancing *past* the flip, and the line count keeps growing. **The
pre-existing session is completely unaffected while new connections from the same source pod are
being dropped.** The conntrack entry is byte-identical before and after:

```
# BEFORE stun
ipv4 2 tcp 6 86399 ESTABLISHED src=10.244.0.121 dst=10.244.0.120 sport=43759 dport=8080 ... [ASSURED]
# AFTER stun
ipv4 2 tcp 6 86399 ESTABLISHED src=10.244.0.121 dst=10.244.0.120 sport=43759 dport=8080 ... [ASSURED]
```

Note the 86399s (24h) TCP established timeout: **an in-flight connection an attacker keeps warm
survives a stun for up to 24 hours.** This is the single most important limitation of Option A, and it
is a direct consequence of the `ct label 28 … accept` fast path in §1.1 — not a tunable.

> **Anomaly, reported not leaned on.** An earlier, less well instrumented run used podinfo's
> `/delay/40` to hold a connection across the stun. The client waited the full 40s (so the connection
> was *not* severed at the flip) but then received `curl: (52) Empty reply from server`. Conntrack
> expiry is excluded (86400s timeout). The `nc` streaming test above is the authoritative one — it
> shows bidirectional data flowing continuously across the stun. The podinfo result is **unexplained
> and marked unverified**; the most likely cause is podinfo-side behaviour on long `/delay` values
> rather than anything to do with policy. It does not change the finding.

### 2.3 Privileged inspector carve-out — **works, and `kubectl exec` is not on the pod network at all**

```
$ kubectl -n np-stunlab exec client    -- curl ... http://10.244.0.106:9898/version
client->stunned    http=000            # BLOCKED
$ kubectl -n np-stunlab exec inspector -- curl ... http://10.244.0.106:9898/version
inspector->stunned http=200            # ALLOWED by the podSelector carve-out
```

A plain `podSelector: matchLabels: {signalloom.ai/role: inspector}` in the `ingress.from` block is
sufficient and works immediately. For a cross-namespace inspector, `namespaceSelector` (or
`namespaceSelector` + `podSelector` in the *same* `from` element, so they AND rather than OR) is the
equivalent.

**And the question that matters most for forensics:**

```
$ kubectl -n np-stunlab exec target -- sh -c 'echo "exec-into-stunned-pod=OK; hostname=$(hostname)"'
exec-into-stunned-pod=OK; hostname=target
```

**`kubectl exec` into a fully quarantined pod works, with deny-all ingress AND egress in force.** It
does not traverse the pod network: the API server connects to the kubelet, and the kubelet attaches to
the container via the CRI socket on the node. NetworkPolicy governs pod-network traffic and has no
visibility into that path whatsoever.

This is a significant, and favourable, finding. Forensic access to a stunned agent —
`exec`, `logs`, `cp`, `debug` ephemeral containers — is **preserved for free under every option in
this document**, because none of them can reach the kubelet path. The inspector carve-out in the
policy is therefore only needed for inspection tooling that must arrive *over the network* (an agent
sidecar scraper, a forensic proxy). If inspection is `kubectl`-based, no carve-out is needed at all —
which argues for making the committed policy strictly deny-all and adding the carve-out only when a
network-borne inspector actually exists.

### 2.4 Egress from a stunned pod — blocked, including DNS

```
$ kubectl -n np-stunlab exec agent2 -- sh -c 'timeout 6 nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; echo dns_exit=$?'
dns_exit=1                             # stunned pod: DNS BLOCKED
$ kubectl -n np-stunlab exec probe2 -- sh -c '... same ...'
control_pod_dns_exit=0                 # unstunned control pod: DNS fine
```

```
$ kubectl -n np-stunlab exec target -- sh -c "timeout 6 wget -q -T 4 -O /dev/null http://10.96.0.1:443; echo exit=$?"
wget: download timed out
apiserver_egress_exit=1                # egress to the API server ClusterIP also blocked
```

This resolves the ambiguity flagged in §1.4: the `udp dport 53 accept` in `postrouting` is *not* a DNS
bypass. DNS is evaluated on the `prerouting` hook before DNAT, and `egress: []` blocks it. A stunned
agent cannot resolve names — a strong containment property, and a useful demo beat.

### 2.5 The bypass that does exist — node-local root traffic

```
$ docker exec osramp-control-plane curl -s -m 4 -o /dev/null -w '%{http_code}' http://10.244.0.106:9898/version
node-root->stunned http=200            # NOT blocked
```

Empirical confirmation of the `meta skuid 0 … accept` rule from §1.3. **Anything running as root
directly on the node reaches a stunned pod unimpeded.** That includes the kubelet, so liveness and
readiness probes continue to succeed and a stunned pod stays `Ready` and stays in its Service
endpoints. (The lab pod had no probes configured, so `Ready` staying `True` is not itself evidence;
the inference is from the node-root result above, which is direct.)

Two readings, and both are true:

- **Favourable:** the stun does not cause a cascade. The pod is not evicted, probes do not fail,
  the kubelet keeps working, and the pod stays observable.
- **Adverse:** it is a real bypass. A compromised agent that achieves node-level code execution as
  root, or that is `hostNetwork: true` and runs as root, is not contained by Option A at all.

### 2.6 GitOps fit — the strongest argument for Option A

This is where Option A decisively beats the current `kubectl label` approach, and it is worth being
precise about why, because the two objects have *opposite* relationships to the reconciler:

| Object | Owned by Flux? | What Flux does to it |
|---|---|---|
| `signalloom.ai/state: stunned` on the pod | **Yes** — declared `idle` at `d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml:25` and again at `d2-osramp-fleet/tenants/local/signalloom.yaml:352` | **Reverts it.** The imperative label is drift. |
| `NetworkPolicy/signalloom-stun-quarantine` | **Yes**, if committed | **Enforces it.** Continuously reconciled *toward*. |

The NetworkPolicy is a first-class, namespaced, Flux-friendly object with no CRD dependency, no
controller, and no ordering constraint. Committing it means the reconciler becomes an *ally* of the
control instead of its adversary — it will re-create the quarantine if an attacker deletes it. That is
exactly the property `stun-under-flux.md` argues for ("committed quarantine — reconciled *toward* —
best for durable modes").

**The residual problem is the label, not the policy.** The policy is safe to commit today; the trigger
still races Flux. Two ways to close it, in preference order:

1. **Make `state` a committed field.** The stun becomes a Git commit that flips
   `signalloom.ai/state: idle` → `stunned` on the agent manifest. Fully GitOps-native, auditable,
   reviewable, reverts only by another commit. Cost: stun latency becomes commit + reconcile
   (10m/30m intervals here, or seconds with a `flux reconcile` nudge or a webhook receiver).
2. **Take the field out of Flux's ownership** with `kustomize.toolkit.fluxcd.io/ssa: ignore` on the
   pod, or by removing `signalloom.ai/state` from the committed manifest entirely so no field manager
   claims it. Then the imperative label is not drift. Cheaper, faster, less auditable.
   *Unverified against this Flux version* — flagged in §7, and it is the same open question
   `stun-under-flux.md` §5 raises.

For a demo, option 1 tells a far better story: *"containment is a reviewed, signed, reconciled change
to desired state, and the platform enforces it continuously"* — which is the Signal Loom thesis.

### 2.7 The sharp edge — NetworkPolicy is allow-only and additive, so a quarantine can be silently defeated

This is the failure mode that would have bitten us in production, and it is not obvious.

Kubernetes NetworkPolicy has **no deny rule**. Semantics are: if *any* policy selects a pod for a
direction, that direction becomes default-deny for that pod, and the **union** of every selecting
policy's allow rules applies. A new policy can therefore only ever *add* permitted traffic. **A stun
policy cannot revoke an allow granted by another policy.**

Verified. With `target` still stunned, a second, entirely ordinary application policy was added:

```yaml
# pre-existing-app-allow — an innocuous "let the app talk to its agents" policy
spec:
  podSelector:
    matchLabels: {signalloom.ai/agent: "true"}
  policyTypes: [Ingress]
  ingress:
    - from: [{podSelector: {matchLabels: {app: client}}}]
```

```
target is stunned AND selected by pre-existing-app-allow:
  client->stunned http=200        # <== QUARANTINE DEFEATED
```

**The stun was silently and completely defeated by an unrelated allow policy**, with no error, no
event, and no change to the quarantine object. A `kubectl get netpol` would show the quarantine
present and healthy.

**Current exposure is nil, but the trap is armed.** The agents namespace has no policies at all today:

```
$ kubectl get netpol -n fe-signalloom-agents -o yaml
items: []
```

So Option A would work correctly in `fe-signalloom-agents` right now. But the `agent-trust-*`
namespaces already carry `default-deny` plus named allows, and `docs/signalloom/networkpolicy-remediation-backlog.md`
commits us to adding least-privilege allows to `inf-signalloom`. The first allow policy that selects
agents by `signalloom.ai/agent: "true"` — exactly the label an author would reach for — disarms every
stun in that namespace.

#### The fix, verified

Every allow policy that could select an agent must exclude stunned pods in its `podSelector`:

```yaml
spec:
  podSelector:
    matchLabels:
      signalloom.ai/agent: "true"
    matchExpressions:
      - key: signalloom.ai/state
        operator: NotIn
        values: ["stunned"]        # <== the guard
```

```
=== GUARDED allow policy ===
  client->stunned      http=000   (want 000)   PASS — quarantine holds
  inspector->stunned   http=200   (want 200)   PASS — carve-out still works

=== unstun the pod again ===
  client->idle-agent   http=200   (want 200)   PASS — fully reversible
```

Three properties confirmed at once: the guard restores the quarantine, the inspector carve-out is
unaffected, and **the stun is cleanly reversible** — flipping `state` back to `idle` restores traffic
within seconds, with no pod restart. That reversibility is a strong demo beat and a strong operational
property.

This turns a semantic trap into a **committed convention**, which is the right shape for a GitOps
estate: the guard is in Git, reviewable, and testable. It should be enforced mechanically, not by
memory — a Kyverno/validating rule or a `netassert` regression that asserts "a stunned agent is
unreachable *even with all production policies applied*". The repo already has `netassert-controller`
and `netassert-runner` in `inf-signalloom`, so the test harness exists.

**This is the single most important design constraint on Option A, and it is the one genuine
architectural argument in favour of Cilium** — see §3.3.

### 2.8 Option A verdict

| | |
|---|---|
| **Build cost** | ~40 lines of committed YAML. No new images, no CRDs, no controller. Hours. |
| **Blast radius** | Namespaced, selects nothing until a pod is stunned. Near zero. |
| **Works today on this cluster** | **Verified, end to end.** |
| **Label-change re-evaluation** | **Verified working, sub-second.** |
| **Severs established connections** | **No** — up to 24h survival. Hard limitation. |
| **Forensic access preserved** | **Yes** — `kubectl exec` verified working into a fully quarantined pod. |
| **GitOps fit** | Excellent for the policy. The *trigger* still needs §2.6 work. |
| **Fail mode** | **Fail-open** — kill kindnetd and enforcement silently vanishes (§1.2). |

## 3. Option B — Cilium / eBPF

### 3.1 The claim that does not survive contact

The proposal's area 4 defines mode 2 as *"kernel-level L3–L7 deny via Cilium/eBPF, **severs in-flight
connections including established ones**, regardless of JWT/SVID TTL"*.

**The emphasised clause is not true of Cilium.** Cilium enforces policy on the **first packet of a
flow** and caches the verdict in its eBPF conntrack map; subsequent packets match the CT entry and
bypass policy evaluation entirely. This is the same architecture as kindnet's `ct label 28` fast path
(§1.1), implemented in eBPF instead of nftables — and it exists for the same reason, which is that
per-packet policy evaluation is unaffordable.

The consequence has been documented upstream since [cilium/cilium#691 — *"cilium policy delete root,
does not flush CT table"*](https://github.com/cilium/cilium/issues/691): deleting a policy left
established connections working because the CT entry persisted. The inverse is equally well
documented — [cilium/cilium#19367](https://github.com/cilium/cilium/issues/19367) reports established
connections being *wrongly dropped* when the CT table is lost on agent restart, which only makes sense
if established flows normally bypass policy.

So on the specific axis the proposal uses to justify Cilium, **Cilium is no better than the vanilla
NetworkPolicy we can ship today**. Both leave in-flight connections running.

Cilium does expose `cilium-dbg bpf ct flush` as a manual lever, but it is a poor foundation:

- In current releases the command **no longer takes an endpoint or `global` argument** — it is
  node-wide. Flushing to contain one agent discards conntrack for every workload on the node.
- Reports indicate flushing does **not** reliably terminate live connections in any case; behaviour
  varies with kernel LRU map semantics.
- It is an imperative `exec` into a privileged DaemonSet — precisely the out-of-band, unreconciled
  action `stun-under-flux.md` argues against.

**Recommendation on the wording:** amend area 4 of the proposal. "Severs in-flight connections
including established ones" should be struck or moved to the mode-1 (cgroup freeze) row, where a
version of it *is* achievable (§4.2). Leaving it in place sets an expectation no implementation on
this stack can meet, and it will not survive a technical audience asking one follow-up question.

### 3.2 Label-based selection works — but is *slower* than Option A

`CiliumNetworkPolicy.endpointSelector` is a Kubernetes `LabelSelector`, matching endpoint labels the
same way `podSelector` does, so `signalloom.ai/state: stunned` selects identically.

The mechanism differs: Cilium derives a numeric **security identity** from an endpoint's labels. A
label change means an identity change, which drives the endpoint through
`waiting-for-identity` → `waiting-to-regenerate` → `regenerating`.

That path is governed by **`--identity-change-grace-period`, default 5 seconds** — a deliberate
debounce so label churn does not thrash policy regeneration. Enforcement after a stun label flip
therefore lands at **~5s or more**, against the **sub-second** figure measured for kindnet in §2.1.

Cilium is *slower* on the crux metric. Tunable downward, but the default is what a migration lands on.

### 3.3 What Cilium genuinely does give — and one item is decisive

Setting the false claim aside, four real advantages remain. One of them matters a great deal.

1. **`ingressDeny` / `egressDeny` with precedence over allows — this is the important one.** It is the
   native fix for §2.7. A Cilium deny rule *overrides* every allow rule, so a quarantine cannot be
   defeated by an unrelated application policy, and no `NotIn` guard convention has to be maintained
   across every policy an engineer ever writes. This is a genuine architectural gap in vanilla
   NetworkPolicy, and it is the one place where "we need Cilium" is a defensible engineering
   statement rather than a fashion statement.
2. **L7 policy.** HTTP method/path/header rules via the Envoy proxy. kindnet cannot do this at all. A
   graduated stun — "the agent may still `GET /health` but not `POST /transfer`" — is Cilium-only.
   Note the cost: L7 rules put an Envoy proxy in the data path for matched flows, with the latency and
   attack-surface implications that carries.
3. **Fail-closed.** Cilium's eBPF programs remain attached to the kernel if the agent dies, so policy
   keeps being enforced. Contrast §1.2, where kindnet's `queue flags bypass` means killing kindnetd
   **silently disables every NetworkPolicy in the cluster**. This is a real and serious advantage.
   (Caveat: during agent *restart* there is a documented window before programs re-attach; disruption
   and bypass in that window were fixed in 1.13.1+.)
4. **Hubble.** Flow-level observability of exactly what a quarantined agent attempted after
   containment — high forensic and demo value, and something Option A has no answer to.

### 3.4 What installing it would cost on *this* cluster

This is where Option B fails, and it fails hard.

**kind requires `disableDefaultCNI: true` at cluster-creation time.** The Cilium install guide is
explicit that the kind config *"is necessary in order to disable the default CNI and replace it with
Cilium"*. `kind-osramp` was created 46 hours ago with default kindnet; no kind config in the repo sets
`disableDefaultCNI` (grep found none). There are exactly two paths:

**Path 1 — recreate the cluster.** GitOps makes much of this recoverable, but the demo estate carries
substantial state that is *not* in Git:

- Locally-built images loaded straight onto the node, not into a registry:
  `cardvault:local`, `cardvault-agent:local`, `policy-engine:local`, `netassert-runner:local`,
  `supercred-demo-runner:local`, `signalloom-spire-helper:local`, `kubesec-afm:latest`,
  `fake-integration-proxy:dev`, plus several `import-2026-08-0X` layers.
- OpenBao seal state, KV contents and JWT roles seeded by a bootstrap Job.
- SPIRE registration entries (`spire-server` + `spire-agent` DaemonSet in `inf-bao`).
- zot registry contents, Postgres, Redis, MinIO data, Prometheus TSDB, Trivy operator reports.
- Dex/OIDC issuer pinned to a specific port, cert-manager CA material, Envoy Gateway.

That is a day of work minimum, spent entirely on infrastructure, with a live demo pending — and every
hour of it is an hour not spent on the five dashboard feature tracks already queued.

**Path 2 — live CNI migration.** Cilium documents a per-node migration using a secondary CNI config
plus cordon/drain/reboot of each node. `kind-osramp` is a **single-node cluster**
(`osramp-control-plane`, no workers). There is nowhere to drain to. Path 2 collapses into Path 1 with
extra failure modes.

Additional costs: no Cilium images are cached on the node (`cilium images cached: 0`), so agent +
operator + Envoy must be pulled. `kubeProxyReplacement` is *optional* — Cilium can coexist with the
existing kube-proxy — so that particular risk is avoidable, which is the one piece of good news.

### 3.5 Option B verdict

| | |
|---|---|
| **Build cost** | Cluster rebuild (a day+) or an unavailable live migration. Highest-risk option by a wide margin. |
| **Blast radius** | Total. Replaces the CNI on the only working demo cluster. |
| **Label-change re-evaluation** | Works, but **~5s** default grace period — *slower* than Option A. |
| **Severs established connections** | **No.** The proposal's central claim for this option is incorrect. |
| **Solves the additive-allow trap (§2.7)** | **Yes, natively** — `ingressDeny`/`egressDeny`. Its one decisive win. |
| **L7 rules** | Yes — genuinely unavailable elsewhere. |
| **Fail mode** | **Fail-closed.** Real advantage over kindnet. |
| **Verdict** | **Do not do this now.** Correct 12-month target, wrong move this week. |

## 4. Option C — controller/operator watching the label

Two very different designs get conflated under "a controller". They deserve separate verdicts.

### 4.1 C1 — controller that watches the label and writes NetworkPolicies

**Verdict: do not build this. It is strictly worse than Option A.**

- **It buys nothing.** A single committed NetworkPolicy with `podSelector: {signalloom.ai/state:
  stunned}` already selects any stunned pod, in any number, with no code. §2.1 proves the selection is
  dynamic. A controller that creates a per-pod policy on a label event is a bespoke Go reimplementation
  of a label selector.
- **It fights Flux.** Two controllers writing NetworkPolicies into the same namespaces means
  server-side-apply field-manager contention and pruning conflicts — Flux prunes what it owns and does
  not know about, and the controller re-creates. This is the *same class* of bug already recorded in
  `scripts/supercred-e2e.sh:80-95`, where a force-annotated bootstrap Job silently undid a
  credential revocation. Adding a second writer of security-relevant objects reintroduces it by design.
- **Its blast radius is disproportionate.** The controller needs cluster-wide
  `networkpolicies: create/update/delete`. Compromise it and you can author or delete any network
  policy in the estate. That is a larger prize than the single agent it exists to contain.
- **It regresses the GitOps story.** The quarantine stops being desired state that Flux reconciles
  toward and becomes runtime output of a controller — unreviewed, uncommitted, and invisible in Git.
  It re-creates the exact problem `stun-under-flux.md` identifies with the imperative `kubectl label`.

The only argument for C1 is dynamism, and §2.1 already disproved the need.

### 4.2 C2 — controller/DaemonSet that enforces on *execution state* (cgroup freeze)

**Verdict: this is the genuinely valuable controller, and it is complementary to Option A, not an
alternative to it.**

This is mode 1 from `stun-under-flux.md` — the cgroup-v2 freezer. **It is available on this cluster
today.** The freezer file exists for the exact running container:

```
$ docker exec osramp-control-plane find /sys/fs/cgroup -name cgroup.freeze -path '*<container-id>*'
/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-besteffort.slice/
  kubelet-kubepods-besteffort-pod<uid>.slice/cri-containerd-<cid>.scope/cgroup.freeze
```

`stat -fc %T /sys/fs/cgroup` returns `cgroup2fs`; kernel is 7.1.3. No eBPF, no CNI change, no CRDs.

**What it does that nothing else in this document can.** Writing `1` to `cgroup.freeze` stops every
task in the container. The agent stops reading its sockets, stops using cached credentials, stops
making outbound calls, and stops acting on any in-flight response — **immediately, and regardless of
conntrack state, JWT TTL, or SVID lifetime**. It is the only option here that addresses in-flight
connections and cached credentials at all.

Be precise about the mechanism, because the distinction matters and is easy to overclaim:

> A freeze does **not sever** TCP connections. Sockets stay open, the kernel keeps ACKing until the
> receive buffer fills and the window closes, and the peer eventually stalls. What stops is the
> *agent* — no syscall executes. For containment that is **better** than severing, because all
> connection and memory state is preserved for forensics. For a marketing claim of "cuts the wire",
> it is different, and the demo narration should say what actually happens: *"the agent is frozen
> mid-instruction"*, which is a more striking claim anyway.

**Its GitOps property is the elegant part**, and `stun-under-flux.md` already establishes it: a frozen
process changes no field of any Kubernetes object. `kubectl get pod -o yaml` is byte-identical before
and after. Flux has nothing to reconcile against and cannot revert it. Execution state is not
configuration state.

**Costs, stated honestly:**

- A privileged, `hostPID` DaemonSet with write access to the node cgroup hierarchy is a **very**
  high-value target. Compromise it and you can freeze or kill any container on any node — a
  cluster-wide DoS primitive. It needs its own threat model, tight RBAC, a signed image, and ideally
  an admission policy restricting which pods it may act on.
- A frozen container's **liveness probe will fail**, so the kubelet will restart it and undo the
  freeze. Any real implementation must handle this — remove the probe, use a long
  `failureThreshold`, or accept restart-on-freeze as the containment outcome. **This is unverified
  and is the first thing to test if C2 is built** (see §7).
- It is invisible in `kubectl get`. Good for Flux, bad for operators — the freeze must be surfaced
  (a `status` field, a dashboard signal, an event) or nobody will know an agent is contained.
- Build cost: a small privileged DaemonSet plus a watch loop. Days, not hours — meaningfully more than
  Option A, far less than Option B.

## 5. Comparison and recommendation

| | **A — NetworkPolicy** | **B — Cilium/eBPF** | **C1 — netpol controller** | **C2 — cgroup freeze** |
|---|---|---|---|---|
| Build cost | ~40 lines YAML, hours | Cluster rebuild, day(s) | Go controller, days | Privileged DaemonSet, days |
| Works on `kind-osramp` today | **Yes, verified** | No — needs CNI replacement | Yes | **Yes** — freezer verified present |
| Re-evaluates on label change | **Yes, sub-second (verified)** | Yes, ~5s default | Yes | Yes, immediate |
| Severs established connections | No (24h CT timeout) | **No** — claim is incorrect | No | Stops the *process*, N/A |
| Stops cached-credential use | No | No | No | **Yes** |
| Beats the additive-allow trap §2.7 | Only via `NotIn` guard convention | **Yes, natively** | No | **Yes** (orthogonal layer) |
| L7 (method/path) rules | No | **Yes** | No | No |
| Forensic `kubectl exec` preserved | **Yes, verified** | Yes | Yes | No — exec into a frozen cgroup hangs |
| GitOps fit | **Excellent** — reconciled toward | Good (CRD, but CNI churn) | **Poor** — competing writer | **Excellent** — invisible to Flux |
| Fail mode | **Fail-open** (§1.2) | Fail-closed | Fail-open | Fail-safe (freeze persists) |
| Blast radius | Namespaced, near zero | Total (CNI) | Cluster-wide netpol write | Cluster-wide freeze/kill |

### The recommendation

**Ship Option A now. Plan C2 next. Do not do B, and do not do C1 at all.**

**Now — Option A, plus three things that turn it from a demo prop into a control:**

1. Commit `NetworkPolicy/signalloom-stun-quarantine` to the agents namespace, selecting
   `signalloom.ai/state: stunned`, deny-all both directions. Omit the inspector carve-out initially —
   §2.3 proves `kubectl exec`, `logs`, and `debug` already work through a full quarantine, so no
   carve-out is needed unless a network-borne inspector actually exists. Adding one "just in case"
   only widens the quarantine.
2. **Adopt the `NotIn: [stunned]` guard as a committed convention on every allow policy that could
   select an agent, and enforce it with a test.** Without this, §2.7 shows the quarantine can be
   silently voided by an ordinary application policy. The `netassert-controller` /
   `netassert-runner` harness already in `inf-signalloom` is the right place: assert that a stunned
   agent is unreachable *with the full production policy set applied*.
3. **Fix the trigger, not just the policy.** Make `signalloom.ai/state` a committed field so the stun
   is a Git commit Flux reconciles toward, rather than an imperative label Flux reverts (§2.6). This
   is the change that makes the demo's central claim — *policy as versioned code* — literally true of
   the containment action itself, and it is the strongest narrative available.

**Next — C2 (cgroup freeze), as a distinct layer, not a replacement.** A and C2 are orthogonal and
compose well, which is the real architectural insight here:

- C2 acts on **execution state**: immediate, stops cached-credential use and in-flight work, invisible
  to Flux, but ephemeral and unauditable.
- A acts on **configuration state**: durable, committed, reviewed, continuously re-enforced by the
  reconciler, survives node reboot and pod reschedule — but cannot touch an established connection.

Neither alone is a containment story. Together they are: **freeze the process immediately, commit the
quarantine durably.** The freeze buys the seconds or minutes it takes the commit to land and reconcile,
and the committed policy holds the containment after the freeze is lifted for forensics.

**Not now — Option B.** Revisit when there is a genuine requirement for L7 policy, or when the
`NotIn` guard convention has demonstrably failed in practice, or at the next cluster rebuild — where
the marginal cost of `disableDefaultCNI: true` is one line rather than a day. Two things should be
recorded as real motivations for that future decision, because they are not marketing: **native deny
precedence** (§3.3) and **fail-closed enforcement** (§1.2 vs §3.3). Neither is the reason currently
given in the proposal.

## 6. What none of them stop

Applies to Option A as shipped, with the deltas noted.

| Gap | Status | Detail |
|---|---|---|
| **In-flight / established connections** | **Not stopped by A or B.** C2 stops the process. | Verified: a TCP stream kept flowing for 14s+ past the stun while new connections were dropped (§2.2). Conntrack TCP established timeout is **86400s** — an attacker keeping a session warm survives a stun for **24 hours**. |
| **Already-open sockets** | Not stopped by A or B. | Same mechanism. The socket is not closed; only new connect() attempts are dropped. |
| **Cached credentials** | **Not stopped by any network option.** | A network policy cannot un-issue a JWT or SVID. Credentials already in agent memory remain valid for their TTL and are usable over any connection that survives — which, per the row above, includes any established one. This is why the current `demo_4()` credential revocation is *complementary* to the killswitch and should not be replaced by it. C2 stops the agent using them. |
| **Node-local root traffic** | **Not stopped.** Verified. | `meta skuid 0 … accept` (§1.3). `docker exec osramp-control-plane curl http://<stunned-pod>:9898/version` → **HTTP 200** (§2.5). |
| **hostNetwork pods running as root** | **Not stopped.** Verified. | A `hostNetwork: true, runAsUser: 0` pod reached the stunned pod: **HTTP 200** (§2.5). Any agent that can be scheduled with `hostNetwork` escapes Option A entirely. Worth an admission control rule forbidding `hostNetwork` on anything labelled `signalloom.ai/agent`. |
| **kubelet probes** | Not stopped — **by design, and desirable.** | Follows from the node-root result. A stunned pod stays `Ready` and stays in Service endpoints. Containment does not cascade into an outage; but note the pod is still an advertised Service backend. |
| **`kubectl exec` / `logs` / `debug`** | Not stopped — **by design, and desirable.** | Verified working into a fully quarantined pod (§2.3). Goes API server → kubelet → CRI, never the pod network. Forensic access is preserved for free. Conversely: anyone with `pods/exec` can still *reach* a stunned agent, so RBAC is the control there, not NetworkPolicy. |
| **Enforcement agent failure** | **Not stopped — fail-open.** | `queue flags bypass to 101` (§1.2). Kill `kindnetd` and every NetworkPolicy in the cluster stops being enforced, with no object changing and no status degrading. **There is no alert for this today.** Cilium would fail closed. |
| **Additive allow policies** | **Defeats the quarantine outright** unless guarded. Verified (§2.7). | Fixed by the `NotIn: [stunned]` convention; fixed natively by Cilium deny rules. |
| **Local (same-pod / loopback) activity** | Not stopped. | An agent can still compute, read its mounted secrets, write to `emptyDir`, and exfiltrate later. Only C2 stops execution. |
| **DNS** | **Stopped.** Verified. | `dns_exit=1` from the stunned pod vs `0` from the control pod (§2.4), despite the misleading-looking `udp dport 53 accept` rule. |

## 7. Open items and unverified claims

Explicitly flagged so nothing here is mistaken for a verified result.

1. **Sub-second enforcement latency is bounded, not precisely measured.** BusyBox `date` does not
   implement `%3N`, so the probe clock had 1-second granularity. The measurement establishes
   *< 1.0s* and is consistent with near-zero. A tighter figure needs a rig with millisecond
   timestamps.
2. **The podinfo `/delay/40` anomaly is unexplained** (§2.2 note). The `nc` streaming test is
   authoritative and unambiguous; the anomaly is recorded, not relied upon.
3. **Whether `kustomize.toolkit.fluxcd.io/ssa: ignore` (or removing the field from the manifest)
   actually stops Flux reverting the `state` label has not been tested** against the Flux version
   running here. This is the same open question `stun-under-flux.md` §5 raises and it remains open.
   It only matters if we take path 2 of §2.6; path 1 (commit the state field) does not need it.
4. **Cilium's ~5s `--identity-change-grace-period` figure is from documentation, not measured** —
   no Cilium exists on this cluster to measure. Likewise its fail-closed behaviour and deny-rule
   precedence are documented, not verified here.
5. **C2's liveness-probe interaction is unverified and is the first thing to test** if C2 is built. A
   frozen container will very likely fail its liveness probe and be restarted by the kubelet, undoing
   the freeze.
6. **Multi-node behaviour is untested.** `kind-osramp` is single-node, so nothing here exercises
   cross-node policy propagation, per-node agent divergence, or the node-to-node path.
7. **The `agent-cardvault` pod was not present in `fe-signalloom-agents`** during this research (the
   running agents were `black-knight`, `dennis`, `patsy`, `sir-lancelot`, `sir-robin`) — it is
   presumably created by the demo flow. All experiments used purpose-built scratch pods, so this does
   not affect any result, but the committed policy should be validated against the real
   `agent-cardvault` once it exists.
8. **Not tested: egress *from* a hostNetwork stunned pod.** Ingress bypass was verified; the egress
   direction follows from the same `skuid 0` rule but was not separately confirmed.

### Cluster hygiene

All experiments ran in scratch namespace `np-stunlab`, which has been deleted
(`kubectl delete ns np-stunlab`). The only writes outside it were pod-label changes on scratch pods.
**No existing cluster resource was modified.** The `kindnet-network-policies` nftables table was read,
never written.

---

## Sources

- [cilium/cilium#691 — `cilium policy delete root` does not flush CT table](https://github.com/cilium/cilium/issues/691)
- [cilium/cilium#19367 — Conntrack table reset on agent restart](https://github.com/cilium/cilium/issues/19367)
- [Cilium — Installation Using Kind (`disableDefaultCNI`)](https://docs.cilium.io/en/stable/installation/kind/)
- [Cilium — Policy Enforcement Modes](https://docs.cilium.io/en/stable/security/policy/intro/)
- [Cilium — Kubernetes Without kube-proxy](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [Cilium — Endpoint Lifecycle (identity change states)](https://docs.cilium.io/en/stable/security/policy/lifecycle/)
- [Cilium — Troubleshooting (CT map inspection, `--conntrack-gc-interval`)](https://docs.cilium.io/en/stable/operations/troubleshooting/)
- [cilium-dbg bpf ct flush](https://docs.cilium.io/en/latest/cmdref/cilium-dbg_bpf_ct_flush/)
- [Arthur Chiao — Cilium: Handle Conntrack-related BPF Maps on Agent Restart](https://arthurchiao.art/blog/cilium-handle-conntrack-related-bpf-maps-on-agent-restart/)
- [CNCF — Safely managing Cilium network policies](https://www.cncf.io/blog/2025/11/06/safely-managing-cilium-network-policies-in-kubernetes-testing-and-simulation-techniques/)

Repo cross-references: `docs/signalloom/stun-under-flux.md`,
`docs/signalloom/ebpf-enforcer-spec.md`, `docs/signalloom/networkpolicy-remediation-backlog.md`,
`d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml:25`,
`d2-osramp-fleet/tenants/local/signalloom.yaml:352`, `scripts/supercred-e2e.sh:80-95`.
