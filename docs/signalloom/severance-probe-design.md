# Severance probe contract for a target that cannot answer

> **Recovered record (2026-10-06).** Harvested verbatim from the abandoned
> `integration/stun-under-flux` branch (tip `5482e79b`). The design reasoning
> below (silence has six causes; a frozen target cannot supply its own
> positive control) is architecture-independent and still holds. Its live
> implementation (the stun-sentinel probe job, `scripts/stun/measure-severance.sh`)
> was never finished — see `docs/signalloom/stun-dod-evidence.md` item 3 — and
> is **not** ported: `test/tc-ebpf-drop.bats` (CRKC-P1-3) already solves this
> exact problem for the current tc/netlink severance mechanism, with its own
> live positive control. What IS ported and still live is the one
> CNI-agnostic, offline-testable piece: the pure classifier
> `scripts/stun/severance-verdict.sh` and its fixture contract, proven by
> `d2-signalloom/test/severance-probe-contract.bats`.

## Purpose

This document defines the evidence contract consumed by every phase 4 and phase
5 severance probe. It deliberately does not implement the stun sentinel or make
target that cannot answer.

The machine-readable companion is
[`evidence/severance-probe-contract.json`](evidence/severance-probe-contract.json).
The pure classifier is
[`scripts/stun/severance-verdict.sh`](../../scripts/stun/severance-verdict.sh).

## Hard constraint: a frozen process cannot answer

A process stopped by its cgroup freezer cannot run instructions. It cannot emit
a heartbeat, reply to a request, write probe output, or host an in-process
inspection command. Any design that requires the target to answer after the
freeze is unrunnable by construction.

Silence at a receiver is therefore consistent with six mutually exclusive
worlds:

1. **The network was severed.** A byte was offered to the dataplane and dropped.
2. **The sender was frozen.** It never executed the write that would offer a byte.
3. **The probe never started.** No sender existed during the observation window.
4. **The sender pod was evicted or restarted.** The observed flow's subject disappeared.
5. **The receiver died.** Bytes may have left the sender but no observer remained.
6. **The name never resolved.** No destination was obtained and no packet left.

Target silence alone cannot distinguish these worlds and can never earn
`SEVERED`.

## Why the usual positive control is unavailable

The repository's normal negative-probe rule is to wait until a permitted path
succeeds from the same pod, then test the denied path. That pattern establishes
that the sender, resolver, receiver, and dataplane were ready before interpreting
a failure.

After this target is frozen, no permitted path can succeed from that target.
The same cgroup freeze stops both the negative probe and its positive control.
Moving the permitted destination does not help: the frozen process still cannot
perform the write. The missing target-sourced positive control is a hard
constraint, not a test-harness inconvenience.

The replacement is an independently scheduled witness that stays runnable
throughout the target's silent window.

## Observation topology

The topology has three pod roles plus a node observer:

| Role | Fate | Responsibility |
|---|---|---|
| Receiver / peer | Never frozen | Holds the socket, timestamps every arrival, keeps peer-to-target traffic flowing |
| Target sender | Frozen subject | Emits monotonic sequence numbers before freezing; answers nothing while frozen |
| Witness sender | Never frozen | Emits the same monotonic sequence cadence to the same receiver |
| Node observer | Outside Kubernetes pod cgroups | Reads cgroup, veth filter, conntrack, pod identity, and restart state |

The witness is a separate Pod, cgroup, and process. It does not carry the
target's stun-selection labels. It reaches the same receiver Service through the
same namespace CNI dataplane at one sequence number per second. The receiver
uses one clock to stamp arrivals from both senders. Sender clocks are never
compared.

The node read is performed with:

```console
docker exec kind-osramp-control-plane <read-only kernel observation>
```

This crosses neither the target process nor its frozen cgroup. It must not be
replaced by an in-pod execution probe.

## Measurement protocol

The collector performs the following observations. These steps define evidence
dependencies, not the freeze-first ordering owned by phase 5.

1. Resolve and record `targetPod`, immutable `targetUID`, `targetIP`,
   `vethIfindex`, and `cgroupPath` before the observation window.
2. Read the target container's stored `restartCount` into
   `restartCount.before`.
3. Establish the receiver, target, and witness streams. Confirm receiver-stamped
   monotonic arrivals before interpreting a later absence.
4. Record `conntrackBefore.present=true` for the target flow.
5. Record `tcDropCounters.beforePackets` from `tc -s filter show dev VETH ingress`.
6. Read `cgroup.events` at the resolved cgroup. Set `frozen=true` only when the
   file reports `frozen 1`.
7. Keep the unfrozen peer sending toward the frozen target at a fixed rate while
   the witness keeps sending to the receiver.
8. At window end, record target and witness arrivals using the receiver's clock.
9. Record `tcDropCounters.afterPackets` from the same veth ingress filter.
10. Record `conntrackAfter.present` for the same target flow.
11. Read the stored target container status into `restartCount.after`.
12. Re-read target UID, IP, veth ifindex, and cgroup path. Identity drift makes
    the record `UNVERIFIED` rather than silently changing subjects.

An immediate denial at time zero is not evidence. CNI filters attach
asynchronously and a newly started Pod may be briefly unconfined. The receiver
and witness must already be producing receiver-stamped monotonic arrivals, and
the node observer must have a before-state for the exact target flow, before a
silent window can be classified.

## Independent evidence channels

No one observation carries the verdict:

1. **Receiver channel:** witness arrivals prove the receiver, resolver,
   observation process, and shared path remained usable.
2. **Target stream:** target arrivals distinguish a surviving flow from target
   silence, but silence has no independent meaning.
3. **Freezer state:** node-side `cgroup.events` proves the subject was frozen.
4. **Dataplane counter:** the same target veth ingress filter must report an
   increasing drop count for `SEVERED`.
5. **Conntrack state:** the exact target flow must be present before the window
   and absent afterward for `SEVERED`.
6. **Lifecycle state:** the target UID must remain stable and restart counts must
   be equal across the window.

This is intentionally stronger than “no bytes arrived.” It makes the kernel and
an independent receiver answer about a subject that cannot answer for itself.

## Verdict contract

The vocabulary is closed:

- `SEVERED` — exit 0
- `SURVIVED` — exit 0
- `UNVERIFIED` — exit 3

There is no fourth value, empty success, or default pass. A malformed,
incomplete, contradictory, or otherwise unclassifiable record is
`UNVERIFIED`.

### SEVERED

`SEVERED` requires every condition below:

- the record conforms to the required field shape;
- `frozen` is true from node-side `cgroup.events`;
- `restartCount.before` equals `restartCount.after`;
- the witness stream reaches its expected monotonic count;
- the target stream has no receiver-stamped arrivals;
- conntrack was present before and absent after;
- the same ingress filter's packet counter increased;
- the embedded verdict and reason agree with the classifier.

### SURVIVED

`SURVIVED` requires a healthy witness, stable restart count, receiver-stamped
target arrivals, conntrack still present, unchanged drop counters, and a matching
embedded verdict plus reason.

### UNVERIFIED

Every other record is `UNVERIFIED`, including:

- missing, malformed, incomplete, or null witness evidence;
- both streams stopping;
- an unhealthy receiver or resolver;
- a target that was not proven frozen;
- any target restart, replacement, eviction, or identity drift;
- sequence gaps, duplicate sequence numbers, or mixed receiver clocks;
- conflicting tc, conntrack, or stream evidence;
- an embedded verdict that disagrees with the computed result.

## SILENCE SCORED AS SEVERANCE

The probe records no bytes arriving and concludes the network was cut, when the true cause was the freeze halting the sender, the probe never starting, the sender being evicted, the receiver dying, or DNS failing before a packet left.

This false-pass is structurally attractive because silence is the expected visual
shape of successful severance. The witness and node evidence exist to make that
shape insufficient.

## Witness-channel failure modes

The witness is a control, not an oracle. Its failures are classified explicitly:

- **Shared pod or cgroup:** freezing the target also freezes the witness.
- **Shared stun selection:** a quarantine label or selector severs both senders.
- **Different receiver:** witness health says nothing about the target's peer.
- **Different path:** a bypass route does not establish the measured CNI path.
- **Receiver restart:** old and new logs describe different observation windows.
- **Resolution failure:** no witness packet reaches the intended receiver.
- **Sequence gap or duplicate:** the witness did not sustain the declared cadence.
- **Null or foreign timestamp:** the receiver did not produce usable evidence.
- **Missing witness field:** the record cannot rule out receiver or probe death.

Any witness failure produces `UNVERIFIED`, never `SEVERED`.

## Kubelet liveness probes can erase the subject

A frozen process cannot answer a liveness probe. Once the configured failure
threshold is reached, kubelet can restart the container into a fresh, unfrozen,
unstunned instance while observation continues. The old flow genuinely stops,
but “old flow died” is not equivalent to “network was severed.” Without lifecycle
evidence, the result would satisfy the visual symptoms of `SEVERED` while making
the wrong inference.

The dedicated target in
`d2-signalloom/apps/stun-severance-probe/job.yaml` has `restartPolicy: Never`
and declares no liveness, readiness, or startup probe. That prevents kubelet's
liveness manager from replacing this controlled subject. For later probes
against real workloads, the contract detects rather than assumes prevention:
the collector samples the target UID and target-container restart count before
and after the window. Any restart-count change or UID change invalidates the run
as `UNVERIFIED`.

The collector observes lifecycle state at four points:

1. Before the window: target UID and `restartCount.before`.
2. At freeze confirmation: exact cgroup path reports `frozen 1`.
3. During the window: witness arrivals continue on the receiver clock.
4. After the window: the same target UID and `restartCount.after` are read.

### Stored probe surface on the measured cluster

The following is a direct, normalized API read from context `kind-osramp` at
`2026-08-31 18:15:00+01:00`. It is stored-object evidence, not an inference from
repository manifests. The command selected every stored Pod carrying
`signalloom.ai/agent=true` and printed each container's probe presence.

```console
$ kubectl get pods -A -l signalloom.ai/agent=true -o json | jq '<normalize container probe presence>'
fe-signalloom-agents/agent-sir-lancelot uid=b672a1b7-63d6-4196-a3e2-302002577f81 container=agent liveness=no readiness=no startup=no
fe-signalloom-agents/cpai-engineer-0 uid=f0671580-c8ab-4eb5-bc25-adc017057b10 container=agent liveness=yes readiness=yes startup=no
fe-signalloom-agents/cpai-engineer-0 uid=f0671580-c8ab-4eb5-bc25-adc017057b10 container=openbao-agent liveness=no readiness=no startup=no
fe-signalloom-agents/hosted-daytona-coder-5cff6bf5d-8z9k6 uid=76c39698-2148-49a6-8c0d-a083f5367cef container=manager liveness=yes readiness=yes startup=no
fe-signalloom-agents/nono-containment-probe-fpq5w uid=9f19ec50-ec81-4980-8b2a-14cfca091ef6 container=probe liveness=no readiness=no startup=no
fe-signalloom-agents/prod-deploy-gate-64d55dd7b9-dnrr8 uid=c8334577-9bb3-40d3-8e69-22c5c26ffd80 container=prod-deploy-gate liveness=yes readiness=yes startup=no
fe-signalloom-agents/prod-deploy-gate-64d55dd7b9-dnrr8 uid=c8334577-9bb3-40d3-8e69-22c5c26ffd80 container=openbao-agent liveness=no readiness=no startup=no
fe-signalloom-agents/prod-deploy-gate-68dffb7594-75hsp uid=9cc55110-4d53-4d58-a226-52112eb71d96 container=prod-deploy-gate liveness=yes readiness=yes startup=no
fe-signalloom-agents/prod-deploy-gate-68dffb7594-75hsp uid=9cc55110-4d53-4d58-a226-52112eb71d96 container=openbao-agent liveness=no readiness=no startup=no
fe-signalloom-agents/stun-sentinel-pjm9x uid=4c8f193b-c144-490c-a695-14fa9b0040c5 container=sentinel liveness=no readiness=no startup=no
fe-signalloom-agents/swarm-governor-576f6945f9-6mp68 uid=8ff597e6-06a4-4573-8e90-3fb2f7405d3a container=swarm-governor liveness=yes readiness=yes startup=no
fe-signalloom-agents/swarm-governor-576f6945f9-6mp68 uid=8ff597e6-06a4-4573-8e90-3fb2f7405d3a container=openbao-agent liveness=no readiness=no startup=no
fe-signalloom-agents/swarm-governor-5df5dbcbfd-6rdj7 uid=3239284c-7b8a-4735-ba66-88dd32d796c3 container=swarm-governor liveness=yes readiness=yes startup=no
fe-signalloom-agents/swarm-governor-5df5dbcbfd-6rdj7 uid=3239284c-7b8a-4735-ba66-88dd32d796c3 container=openbao-agent liveness=no readiness=no startup=no
fe-signalloom-agents/zulip-chat-agent-674998cb45-7r24c uid=f8c4ab7e-d68d-4d22-9dc5-b5b473a63a20 container=zulip-chat-agent liveness=no readiness=no startup=no
fe-signalloom-agents/zulip-chat-agent-674998cb45-7r24c uid=f8c4ab7e-d68d-4d22-9dc5-b5b473a63a20 container=openbao-agent liveness=no readiness=no startup=no
fe-signalloom-agents/zulip-chat-agent-748864ffc8-kw5cd uid=8aa09b8f-feca-49b8-9ae5-f4a2079543f3 container=zulip-chat-agent liveness=no readiness=no startup=no
fe-signalloom-agents/zulip-chat-agent-748864ffc8-kw5cd uid=8aa09b8f-feca-49b8-9ae5-f4a2079543f3 container=openbao-agent liveness=no readiness=no startup=no
```

The stored estate therefore contains both kinds of subject: containers with
HTTP liveness probes and containers without them. No selected container declared
a startup probe. A severance run must inspect the stored target, not assume its
probe surface from source YAML.

## Machine-readable record

Every phase 4 and phase 5 probe emits one JSON object containing:

`schemaVersion`, `capturedAt`, `cni`, `cniVersion`, `targetPod`, `targetUID`,
`targetIP`, `vethIfindex`, `cgroupPath`, `frozen`, `witnessStream`,
`targetStream`, `conntrackBefore`, `conntrackAfter`, `tcDropCounters`, `verdict`,
`verdictReason`, `clockId`, and `restartCount`.

`restartCount` has required non-negative integer members `before` and `after`.
Both stream objects identify sender and receiver Pods, declare an expected count,
and carry receiver-stamped `{sequence, receivedAt}` arrivals. The schema rejects
unknown top-level fields and closes `verdict` to exactly the three values above.

## Fixed mission facts

This contract consumes rather than re-derives the mission's measured facts:

- kustomize-controller is `v1.9.4`;
- flux-operator is `v0.58.1`;
- `ResourceSet.spec` has no ignore field;
- `policy.networking.k8s.io` is not served.

None changes the evidentiary constraint: a frozen process cannot answer.

## Downstream obligation

P4-2, P4-3, P5-1, and P5-2 must emit this record shape and classify it through
the pure function. A downstream collector may gather richer evidence, but it
cannot weaken required fields, invent another verdict, treat silence as a pass,
or classify a changed restart count as severance.
