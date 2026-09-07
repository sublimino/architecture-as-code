#!/usr/bin/env python3
import json
import sys
from compile_crkc_cards import run_create

cards_phase1 = [
    {
        "logical_id": "P1-2",
        "role": "implementation",
        "title": "Implement stun-sentinel daemon cgroup.freeze controller halting container CPU execution instantly upon stun signal",
        "size": "M",
        "agent": "daily",
        "depends_on": ["P1-PRE"],
        "spec": {
            "objective": "Implement the stun-sentinel daemon cgroup.freeze controller in Go to provide sub-50 millisecond in-kernel execution freezing of compromised agent containers upon receiving an emergency stun signal. The daemon must discover container cgroup-v2 paths via container runtime interfaces and procfs, write '1' to the target cgroup.freeze control file, verify process transition to D-state (uninterruptible sleep / frozen), and emit structured telemetry events to Signal Loom.",
            "approach": (
                "Step 1: Implement cgroup-v2 tree discovery in Go within d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go by locating /sys/fs/cgroup/kubepods.slice paths for target pod UIDs.\n"
                "Step 2: Add atomic cgroup.freeze write handler that opens /sys/fs/cgroup/.../cgroup.freeze and writes '1' when a stun event is dispatched by Sentinel.\n"
                "Step 3: Implement post-freeze state verification loop reading /sys/fs/cgroup/.../cgroup.events to confirm 'frozen 1' within a strict 50ms deadline.\n"
                "Step 4: Implement unfreeze handler writing '0' to cgroup.freeze when an authorized resume action is received with valid governance credentials.\n"
                "Step 5: Integrate stun-sentinel with Signal Loom event bus, emitting StunExecutionHalted and StunExecutionResumed telemetry records.\n"
                "Step 6: Author comprehensive unit tests in d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer_test.go mocking cgroupfs via temp directories.\n"
                "Step 7: Build BATS integration test test/cgroup-freeze-stun.bats verifying that active CPU-bound loops in target test containers halt immediately upon stun invocation.\n"
                "Step 8: Handle edge cases where child processes are created during freeze initiation by re-checking cgroup.procs after freeze confirmation.\n"
                "Step 9: Add automated benchmarks measuring freeze latency across single-process and multi-process agent worker containers."
            ),
            "deliverables": [
                "Go implementation of cgroup-v2 freezer controller in d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go",
                "Unit test suite with 100% path coverage in d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer_test.go",
                "Integration test test/cgroup-freeze-stun.bats verifying CPU freeze within 50ms on running Kind pods",
                "Structured event emitter publishing cgroup transition telemetry into Signal Loom",
                "DaemonSet manifest configuring host cgroupfs mounts for stun-sentinel in d2-signalloom/deploy/",
                "Operational documentation in docs/signalloom/cgroup-v2-freeze-architecture.md",
                "Benchmark suite measuring freezer response time under simulated heavy CPU load in test/bench-cgroup-freezer.sh",
                "Healthcheck probe confirming stun-sentinel can write to host cgroupfs hierarchy"
            ],
            "evidence": [
                "BATS test output demonstrating container CPU utilization dropping from 100% to 0% in under 50ms",
                "Kernel /sys/fs/cgroup/.../cgroup.events inspection showing 'frozen 1'",
                "Go test run log showing all freezer unit tests passing cleanly",
                "Signal Loom telemetry stream capture containing StunExecutionHalted event with timestamp and PID list",
                "Recorded proof artifact in docs/signalloom/evidence/cgroup-freeze-proof.json",
                "Benchmark report showing p99 freeze latency under 25ms across 100 iterations"
            ],
            "keyFacts": [
                "cgroup-v2 provides /sys/fs/cgroup/.../cgroup.freeze where writing 1 halts all processes in the cgroup without sending SIGSTOP",
                "Processes frozen via cgroup-v2 cannot intercept or trap the freeze signal, preventing userspace evasions",
                "Frozen processes remain visible to ps and top but consume 0 CPU cycles and cannot execute instructions",
                "cgroup.events exposes 'frozen 1' once all tasks in the subtree have settled into the frozen state",
                "Kind clusters mount host cgroups inside the node container, accessible at /sys/fs/cgroup"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P1-PRE verified host cgroup-v2 freezer controller availability",
                "integration/crkc-v0.1.0 baseline containing Signal Loom Go packages"
            ],
            "outOfScope": [
                "TC eBPF network packet dropping (assigned to CRKC-P1-3)",
                "Flux drift ignore rules (handled in CRKC-P1-1)",
                "Tetragon TracingPolicy configuration (assigned to CRKC-P1-4)",
                "CEL policy compilation (Phase 3)",
                "Modifying Kubernetes pod lifecycle controller or kubelet eviction logic",
                "Implementing userspace SIGSTOP or ptrace debugging controls"
            ],
            "priorErrata": [
                "CRKC-P1-PRE: Confirmed /sys/fs/cgroup/cgroup.controllers contains 'freezer' and 'cpu'"
            ],
            "sharedFileRisks": [
                "stun-sentinel package structure is shared with CRKC-P1-3; coordinate package naming and daemon main.go initialization"
            ],
            "failureModes": [
                "Forking race condition: new child process created while freeze is being asserted; cgroup-v2 freezer handles this atomically in-kernel",
                "Cgroup path mismatch: container runtime cgroup driver (systemd vs cgroupfs) altering directory hierarchy; resolve via container ID prefix",
                "Permission denied writing to cgroup.freeze: DaemonSet missing required hostPath mount or privileged securityContext",
                "Deadlock on unfreeze: unfreezing without validating credential state leading to unauthorized resumption",
                "Kernel memory pressure: cgroup controllers blocked during heavy page cache writeback; ensure freezer runs with elevated priority",
                "Stale cgroup directory lookup after pod termination: implement filesystem watch cleanup loop"
            ],
            "loopOn": [
                "Poll /sys/fs/cgroup/.../cgroup.events until 'frozen 1' is asserted or 50ms timeout expires",
                "Read container process state from /proc/<pid>/stat until state changes to D"
            ],
            "stopAndReport": [
                "cgroup.freeze write fails with EACCES or ENOENT",
                "cgroup.events fails to report frozen within 50ms deadline",
                "Target container processes continue executing CPU cycles after freeze assertion"
            ],
            "testSurface": [
                "go test -v ./d2-signalloom/apps/stun-sentinel/pkg/cgroup/...",
                "bats test/cgroup-freeze-stun.bats",
                "cat /sys/fs/cgroup/kubepods.slice/.../cgroup.events",
                "scripts/test-cgroup-freezer.sh",
                "test/bench-cgroup-freezer.sh"
            ],
            "mergeBoundary": "Isolates to d2-signalloom/apps/stun-sentinel/ and test/cgroup-freeze-stun.bats. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P1-3",
        "role": "implementation",
        "title": "Implement host-side veth eBPF TC classifier drop program and conntrack table flush severing ingress/egress packets",
        "size": "L",
        "agent": "deep",
        "deep_rationale": "Requires low-level eBPF C programming for Traffic Control (TC) clsact subsystem, libbpf Go bindings, host network namespace veth pair resolution, and conntrack table flushing to cleanly sever active TCP sessions.",
        "depends_on": ["P1-PRE"],
        "spec": {
            "objective": "Implement a high-performance host-side eBPF Traffic Control (TC) classifier program attached to container peer veth devices that immediately drops all ingress and egress packets upon agent stun. The implementation must flush existing conntrack connection tracking state entries for target container IP addresses to terminate existing established TCP sessions, ensuring full network isolation in under 100 milliseconds without requiring pod recreation.",
            "approach": (
                "Step 1: Author eBPF C program in d2-signalloom/apps/stun-sentinel/bpf/tc_drop.bpf.c using SEC('classifier/drop') that inspects packet headers and returns TC_ACT_SHOT when an isolation map entry matches the interface or target container IP.\n"
                "Step 2: Compile eBPF program to ELF object using clang and llvm targeting bpf architecture with BTF type information.\n"
                "Step 3: Implement Go loader and map controller in d2-signalloom/apps/stun-sentinel/pkg/tc/loader.go using cilium/ebpf to attach clsact qdisc and filter to container veth interfaces on the host.\n"
                "Step 4: Implement conntrack state flush in d2-signalloom/apps/stun-sentinel/pkg/tc/conntrack.go using netlink socket protocol to delete all established conntrack entries matching target container IP.\n"
                "Step 5: Implement dynamic veth interface discovery mapping Kubernetes pod sandbox netns to host-side veth device names via sysfs and netlink.\n"
                "Step 6: Build CLI and gRPC trigger endpoints in stun-sentinel allowing immediate activation and deactivation of TC network isolation.\n"
                "Step 7: Author unit tests in pkg/tc/ asserting correct eBPF bytecode generation, map manipulation, and netlink message formatting.\n"
                "Step 8: Construct BATS test suite test/tc-ebpf-drop.bats verifying that active HTTP streaming connections and TCP sockets to target containers are severed within 100ms of stun activation.\n"
                "Step 9: Benchmark isolation latency under high packet rates and author performance report in docs/signalloom/tc-ebpf-confinement.md."
            ),
            "deliverables": [
                "eBPF C source program d2-signalloom/apps/stun-sentinel/bpf/tc_drop.bpf.c returning TC_ACT_SHOT",
                "Compiled eBPF ELF artifact and generated Go BPF bindings via bpf2go",
                "Go TC qdisc and filter management package in d2-signalloom/apps/stun-sentinel/pkg/tc/loader.go",
                "Conntrack TCP table flushing module using netlink sockets in pkg/tc/conntrack.go",
                "Host veth discovery service mapping pod namespaces to peer network interfaces",
                "Automated test suite test/tc-ebpf-drop.bats proving connection severance in under 100ms",
                "Comprehensive architecture and operational guide docs/signalloom/tc-ebpf-confinement.md"
            ],
            "evidence": [
                "BATS test log showing curl/netcat TCP stream terminated with connection reset or timeout upon stun",
                "tc filter show dev <veth> egress/ingress showing active clsact filter program",
                "conntrack -L output verifying zero remaining active sessions for target IP",
                "Benchmark metrics confirming packet drop activation in under 100 milliseconds",
                "Clean compilation log of eBPF C program without Clang warnings",
                "Recorded evidence artifact in docs/signalloom/evidence/tc-drop-proof.json"
            ],
            "keyFacts": [
                "TC clsact allows attaching eBPF programs to both ingress and egress hook points of network devices",
                "TC_ACT_SHOT causes the Linux network stack to immediately drop packets without passing them to userspace",
                "Dropping packets via TC does not automatically reset existing TCP connections in the kernel conntrack table without explicit netlink deletion",
                "Netlink conntrack flush deletes ct_entry structures, causing subsequent TCP packets to be treated as invalid and dropped",
                "Container veth pairs connect the pod network namespace to the root network namespace on the host"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P1-PRE verified Clang/LLVM toolchain and TC clsact kernel capabilities",
                "Running Kind cluster with active veth network pairs"
            ],
            "outOfScope": [
                "cgroup freeze execution (handled in CRKC-P1-2)",
                "Flux selective drift ignore rules (handled in CRKC-P1-1)",
                "Tetragon TracingPolicy configuration (assigned to CRKC-P1-4)",
                "Admission webhook validation (Phase 3)"
            ],
            "priorErrata": [
                "CRKC-P1-PRE: Confirmed TC clsact queuing discipline can be attached to host interfaces"
            ],
            "sharedFileRisks": [
                "d2-signalloom/apps/stun-sentinel daemon shares entrypoint with freezer; ensure clean modular initialization between cgroup and TC packages"
            ],
            "failureModes": [
                "Interface disappearance: container terminates during veth lookup; gracefully ignore ENOENT and clean up maps",
                "Conntrack socket permission error: missing CAP_NET_ADMIN; verify DaemonSet securityContext possesses necessary Linux capabilities",
                "TC filter attachment collision: existing qdisc on interface; ensure clsact qdisc replacement is idempotent",
                "eBPF verifier rejection: unbounded loops or uninitialized stack reads in C program; strictly follow BPF verifier constraints"
            ],
            "loopOn": [
                "Loop over curl or nc connection attempts to target container until connection refused or timed out",
                "Poll conntrack table for target IP until entry count equals zero",
                "Verify tc filter show returns active filter attached to interface"
            ],
            "stopAndReport": [
                "eBPF program rejected by in-kernel BPF verifier during attachment",
                "Host kernel lacks clsact qdisc support",
                "Packets continue traversing veth interface after TC_ACT_SHOT filter activation"
            ],
            "testSurface": [
                "go test -v ./d2-signalloom/apps/stun-sentinel/pkg/tc/...",
                "bats test/tc-ebpf-drop.bats",
                "tc filter show dev eth0 ingress",
                "conntrack -L -p tcp",
                "scripts/test-tc-ebpf.sh"
            ],
            "mergeBoundary": "Isolates to d2-signalloom/apps/stun-sentinel/bpf/, pkg/tc/, and test/tc-ebpf-drop.bats. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P1-4",
        "role": "implementation",
        "title": "Decouple Tetragon from active enforcement, configure TracingPolicy for process/socket/file tracepoints, and wire gRPC into signal-ingest NetEBPF collector",
        "size": "M",
        "agent": "daily",
        "depends_on": ["P1-PRE"],
        "spec": {
            "objective": "Decouple Tetragon from active security enforcement roles to eliminate kernel LSM hook conflicts, configure non-blocking TracingPolicy CRDs capturing agent process executions, socket connects, and sensitive file accesses, and stream real-time JSON/gRPC telemetry into the Signal Fusion signal-ingest NetEBPF collector.",
            "approach": (
                "Step 1: Inspect existing Tetragon DaemonSet and TracingPolicy configurations in d2-infra/ and d2-signalloom/ to ensure no Sigkill or active enforcement actions are declared.\n"
                "Step 2: Author updated TracingPolicy manifests in d2-signalloom/deploy/tetragon-agent-telemetry.yaml targeting sys_enter_execve, tcp_connect, and sys_enter_openat tracepoints for agent namespaces.\n"
                "Step 3: Configure Tetragon exporter to publish events over local gRPC socket /var/run/cilium/tetragon/tetragon.sock.\n"
                "Step 4: Update signal-ingest NetEBPF collector in d2-signalloom/apps/signal-ingest/collectors/ebpf/ to ingest Tetragon InboundFlowEvent messages over gRPC.\n"
                "Step 5: Normalize Tetragon process and network telemetry into canonical Signal Fusion InboundFlowEvent schema.\n"
                "Step 6: Author unit tests in signal-ingest asserting clean parsing of Tetragon JSON and protobuf streams without data loss.\n"
                "Step 7: Build BATS verification suite test/tetragon-telemetry-stream.bats verifying that container exec and curl events trigger flow events in signal-ingest within 500ms."
            ),
            "deliverables": [
                "Updated Tetragon TracingPolicy manifest in d2-signalloom/deploy/tetragon-agent-telemetry.yaml",
                "Tetragon gRPC streaming client integrated into signal-ingest NetEBPF collector",
                "Event normalizer mapping Tetragon raw flows to InboundFlowEvent schema in Go",
                "Unit test suite in d2-signalloom/apps/signal-ingest/collectors/ebpf/tetragon_test.go",
                "Automated BATS test test/tetragon-telemetry-stream.bats verifying real-time telemetry streaming",
                "Documentation in docs/signalloom/tetragon-telemetry-pipeline.md"
            ],
            "evidence": [
                "BATS test output showing live Tetragon events successfully ingested by signal-ingest",
                "Tetragon status showing zero LSM enforcement errors or dropped events",
                "Go test run log showing 100% pass across Tetragon event normalizers",
                "Log capture from signal-ingest demonstrating InboundFlowEvent publishing to FrostDB store",
                "Clean verification artifact recorded in docs/signalloom/evidence/tetragon-stream-proof.json"
            ],
            "keyFacts": [
                "Tetragon operates as an eBPF-based security observability and runtime enforcement framework",
                "Decoupling enforcement prevents Tetragon from killing processes that are intentionally frozen by stun-sentinel",
                "Tetragon TracingPolicy allows granular filtering by namespace, pod label, and binary path",
                "signal-ingest NetEBPF collector ingests kernel flow records and transforms them into time-series signals",
                "Tetragon exposes gRPC event streams at tetragon.cilium.io/v1 for low-overhead local export"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P1-PRE verified eBPF toolchain and running Kind cluster",
                "Existing signal-ingest collectors in d2-signalloom/apps/signal-ingest/"
            ],
            "outOfScope": [
                "cgroup freezer implementation (handled in CRKC-P1-2)",
                "TC packet drop filter implementation (handled in CRKC-P1-3)",
                "Flux selective drift ignore (handled in CRKC-P1-1)",
                "FAIR quantitative risk calculations (Phase 2)"
            ],
            "priorErrata": [
                "CRKC-P1-PRE: Verified running cluster environment and baseline branch"
            ],
            "sharedFileRisks": [
                "signal-ingest collectors directory is shared with other telemetry feeds; maintain isolated subpackage for Tetragon"
            ],
            "failureModes": [
                "Tetragon socket permission denied: ensure signal-ingest has read access to /var/run/cilium/tetragon/",
                "Event buffer overflow: high network churn causing Tetragon ringbuffer drops; tune buffer size parameters in Helm values",
                "Namespace filtering omission: capturing whole-cluster kernel flows leading to CPU starvation; enforce strict namespace selectors",
                "gRPC connection drop: transient Tetragon restart; implement automatic reconnection loop with exponential backoff"
            ],
            "loopOn": [
                "Poll signal-ingest metrics endpoint /metrics until tetragon_events_received_total > 0",
                "Check tetragon pod logs until 'Listening on /var/run/cilium/tetragon/tetragon.sock' is observed"
            ],
            "stopAndReport": [
                "Tetragon DaemonSet fails to schedule or crashes during startup",
                "Tetragon emits LSM denial errors indicating active enforcement collision",
                "signal-ingest fails to parse Tetragon protobuf events"
            ],
            "testSurface": [
                "go test -v ./d2-signalloom/apps/signal-ingest/collectors/ebpf/...",
                "bats test/tetragon-telemetry-stream.bats",
                "kubectl -n kube-system logs -l app.kubernetes.io/name=tetragon -c tetragon",
                "scripts/test-tetragon-stream.sh"
            ],
            "mergeBoundary": "Isolates to d2-signalloom/deploy/tetragon-agent-telemetry.yaml, apps/signal-ingest/collectors/ebpf/, and test/tetragon-telemetry-stream.bats. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P1-GOV",
        "role": "governor",
        "title": "Phase 1 Governor reconciliation: merge Phase 1 deliverables, run live containment suite, and verify Tier 0 + Tier 1 integration",
        "size": "M",
        "agent": "daily",
        "depends_on": ["P1-1", "P1-2", "P1-3", "P1-4"],
        "spec": {
            "objective": "Perform Phase 1 Governor reconciliation by integrating all Phase 1 deliverables into integration/crkc-v0.1.0, executing the unified Tier 0 (cgroup freeze + TC drop) and Tier 1 (Flux drift ignore) end-to-end containment verification suite, certifying that agent execution halts in under 1 second with 100% label survival, and authoring the Phase 1 Governor Certification proof artifact.",
            "approach": (
                "Step 1: Verify clean completion and test passes for all prerequisite Phase 1 implementation cards (CRKC-P1-1, CRKC-P1-2, CRKC-P1-3, CRKC-P1-4).\n"
                "Step 2: Merge deliverable branches into integration/crkc-v0.1.0 without regressions.\n"
                "Step 3: Execute unified live stun test harness test/crkc-phase1-unified-stun.bats combining cgroup freeze, TC packet drop, and forced Flux reconciliation.\n"
                "Step 4: Assert end-to-end containment SLA: CPU execution frozen in < 50ms, network connections severed in < 100ms, total stun confirmation < 1s, and label persists across 50 Flux reconciles.\n"
                "Step 5: Verify that Tetragon telemetry stream captures all stun execution events without LSM errors.\n"
                "Step 6: Author certified Phase 1 governance proof artifact docs/signalloom/crkc-p1-governor-proof.md detailing test results, commit SHAs, and latency benchmarks.\n"
                "Step 7: Update Obsidian proposal errata section with Phase 1 completion ledger and stop in Review state per Rule SP-5."
            ),
            "deliverables": [
                "Unified Phase 1 integration on integration/crkc-v0.1.0 with all Phase 1 tests passing",
                "End-to-end integration test suite test/crkc-phase1-unified-stun.bats validating Tier 0 and Tier 1 containment",
                "Phase 1 Governor Certification proof artifact in docs/signalloom/crkc-p1-governor-proof.md",
                "Telemetry verification log confirming Tetragon ingest during active containment",
                "Updated proposal errata ledger in Obsidian documenting Phase 1 milestone certification",
                "Pre-flight verification checklist for Phase 2 readiness"
            ],
            "evidence": [
                "Full test execution log of test/crkc-phase1-unified-stun.bats with 100% pass rate",
                "Latency telemetry proving sub-second containment (CPU halt < 50ms, TC drop < 100ms)",
                "Git log showing clean integration of CRKC-P1-1 through CRKC-P1-4 without conflict markers",
                "Recorded proof artifact docs/signalloom/crkc-p1-governor-proof.md with execution timestamps",
                "Review ledger entry in .kanban-review-ledger.json recording governor sign-off"
            ],
            "keyFacts": [
                "Rule SP-2 defines the Two-Tier Containment Lifetime Invariant (Tier 0 in-kernel execution halt, Tier 1 GitOps configuration persistence)",
                "Rule SP-5 mandates that Phase Governors strictly stop in Review and never auto-advance to Done without human operator sign-off",
                "Tier 0 containment executes without touching the Kubernetes API server to prevent cluster control plane latency delays",
                "Tier 1 containment ensures operational state is visible to operators and survives GitOps drift remediation",
                "Phase 1 Governor unblocks Phase 2 and Phase 4 preflight cards upon certification"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P1-PRE preflight proof",
                "CRKC-P1-1 Flux drift ignore implementation",
                "CRKC-P1-2 cgroup freezer controller",
                "CRKC-P1-3 TC eBPF drop program",
                "CRKC-P1-4 Tetragon telemetry decoupling"
            ],
            "outOfScope": [
                "Executing Phase 2 FAIR quantitative risk engine implementation",
                "Authoring CEL policy compiler (Phase 3)",
                "Auto-advancing past Review state into Done (strictly reserved for human governor)"
            ],
            "priorErrata": [
                "CRKC-P1-PRE: Preflight capabilities verified on host and cluster",
                "CRKC-P1-1: 50 consecutive Flux reconciliations verified with label intact",
                "CRKC-P1-2: cgroup freeze sub-50ms CPU suspension verified",
                "CRKC-P1-3: TC eBPF packet drop sub-100ms verified",
                "CRKC-P1-4: Tetragon non-blocking telemetry stream verified"
            ],
            "sharedFileRisks": [
                "Governor reconciles all Phase 1 files; verify zero unresolved merge conflicts across d2-signalloom manifests and Go packages"
            ],
            "failureModes": [
                "End-to-end latency exceeding 1 second SLA: diagnose kernel scheduling delays or netlink socket queuing",
                "Flux reconciliation wiping stun label during concurrent freeze test: re-verify RFC 6901 pointer in spec.ignore",
                "Merge regression in Go packages: run make test-signal-ingest and make test-signalfusion-bats to verify zero regressions"
            ],
            "loopOn": [
                "Run bats test/crkc-phase1-unified-stun.bats until 100% pass rate achieved",
                "Verify git status on integration/crkc-v0.1.0 is clean"
            ],
            "stopAndReport": [
                "Any Phase 1 implementation card fails its acceptance criteria",
                "End-to-end containment SLA exceeds 1.0 second threshold",
                "Flux reconciliation strips stun label during unified test execution"
            ],
            "testSurface": [
                "bats test/crkc-phase1-unified-stun.bats",
                "bats test/flux-drift-ignore.bats",
                "bats test/cgroup-freeze-stun.bats",
                "bats test/tc-ebpf-drop.bats",
                "bats test/tetragon-telemetry-stream.bats"
            ],
            "mergeBoundary": "Merges Phase 1 deliverables into integration/crkc-v0.1.0. Governor card stops in Review state awaiting operator sign-off."
        }
    }
]

for card in cards_phase1:
    run_create(card)

print("Phase 1 cards successfully compiled and created!")
