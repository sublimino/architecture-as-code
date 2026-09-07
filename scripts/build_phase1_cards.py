#!/usr/bin/env python3
import json
import os
import sys
import subprocess

REPO = "/home/andy/src/cp/osramp-demo"
sys.path.insert(0, f"{REPO}/scripts")
from compile_crkc_cards import run_create, verify_spec

# We already have:
# CRKC-P1-PRE (2ba7f)
# CRKC-P1-1 (ec9b1)
# CRKC-P1-2 (50b25)

cards = [
    # ─── PHASE 1 ─────────────────────────────────────────────────────────────
    {
        "logical_id": "P1-3",
        "role": "implementation",
        "title": "Implement host-side veth eBPF TC classifier drop program and conntrack table flush severing ingress/egress packets",
        "size": "L",
        "agent": "deep",
        "deep_rationale": "Requires kernel-level eBPF C programming for Traffic Control (TC) clsact subsystem, libbpf Go bindings, host network namespace veth pair resolution, and conntrack table flushing to cleanly sever active TCP sessions.",
        "depends_on": ["P1-PRE"],
        "spec": {
            "objective": "Implement a high-performance host-side eBPF Traffic Control (TC) classifier program attached to container peer veth devices that immediately drops all ingress and egress packets upon agent stun. The implementation must flush existing conntrack connection tracking state entries for target container IP addresses to terminate existing established TCP sessions, ensuring full network isolation in under 100 milliseconds without requiring pod recreation or container restart.",
            "approach": (
                "Step 1: Author eBPF C program in d2-signalloom/apps/stun-sentinel/bpf/tc_drop.bpf.c using SEC('classifier/drop') that inspects packet headers and returns TC_ACT_SHOT when an isolation map entry matches the interface or target container IP.\n"
                "Step 2: Compile eBPF program to ELF object using clang and llvm targeting bpf architecture with BTF type information and strict verifier validation.\n"
                "Step 3: Implement Go loader and map controller in d2-signalloom/apps/stun-sentinel/pkg/tc/loader.go using cilium/ebpf to attach clsact qdisc and filter to container veth interfaces on the host.\n"
                "Step 4: Implement conntrack state flush in d2-signalloom/apps/stun-sentinel/pkg/tc/conntrack.go using netlink socket protocol to delete all established conntrack entries matching target container IP.\n"
                "Step 5: Implement dynamic veth interface discovery mapping Kubernetes pod sandbox netns to host-side veth device names via sysfs and netlink socket queries.\n"
                "Step 6: Build CLI and gRPC trigger endpoints in stun-sentinel allowing immediate activation and deactivation of TC network isolation.\n"
                "Step 7: Author unit tests in pkg/tc/ asserting correct eBPF bytecode generation, map manipulation, and netlink message formatting.\n"
                "Step 8: Construct BATS test suite test/tc-ebpf-drop.bats verifying that active HTTP streaming connections and TCP sockets to target containers are severed within 100ms of stun activation.\n"
                "Step 9: Benchmark isolation latency under high packet rates and author performance report in docs/signalloom/tc-ebpf-confinement.md.\n"
                "Step 10: Implement fail-safe rollback logic to detach TC filters and restore network connectivity when an authorized unfreeze command is dispatched.\n"
                "Step 11: Add kernel tracepoint telemetry emitting drop statistics and interface state changes into Prometheus metrics format.\n"
                "Step 12: Validate eBPF program safety with llvm-objdump -S to confirm bounded loop unrolling and zero uninitialized register reads."
            ),
            "deliverables": [
                "eBPF C source program d2-signalloom/apps/stun-sentinel/bpf/tc_drop.bpf.c returning TC_ACT_SHOT",
                "Compiled eBPF ELF artifact and generated Go BPF bindings via bpf2go",
                "Go TC qdisc and filter management package in d2-signalloom/apps/stun-sentinel/pkg/tc/loader.go",
                "Conntrack TCP table flushing module using netlink sockets in pkg/tc/conntrack.go",
                "Host veth discovery service mapping pod namespaces to peer network interfaces",
                "Automated test suite test/tc-ebpf-drop.bats proving connection severance in under 100ms",
                "Comprehensive architecture and operational guide docs/signalloom/tc-ebpf-confinement.md",
                "Benchmark validation script measuring packet drop latency under 50,000 pps traffic in test/bench-tc-drop.sh",
                "Prometheus metrics exporter publishing stun_tc_packets_dropped_total and stun_tc_isolation_duration_seconds",
                "Integration harness testing recovery and filter detachment after authorized unstun action"
            ],
            "evidence": [
                "BATS test log showing curl/netcat TCP stream terminated with connection reset or timeout upon stun",
                "tc filter show dev <veth> egress/ingress showing active clsact filter program",
                "conntrack -L output verifying zero remaining active sessions for target IP",
                "Benchmark metrics confirming packet drop activation in under 100 milliseconds",
                "Clean compilation log of eBPF C program without Clang warnings",
                "Recorded evidence artifact in docs/signalloom/evidence/tc-drop-proof.json",
                "Prometheus metric scrape verifying increment of drop counter upon simulated network traffic",
                "BPF verifier log demonstrating zero verification failures across Linux 5.15 and 6.x kernels",
                "Netlink socket trace confirming atomic deletion of bidirectional conntrack flow tuples"
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
                "Admission webhook validation (Phase 3)",
                "Hardware offloaded eBPF or smartNIC TC filtering",
                "Modifying host iptables or nftables rulesets directly outside netlink conntrack"
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
                "eBPF verifier rejection: unbounded loops or uninitialized stack reads in C program; strictly follow BPF verifier constraints",
                "Asymmetric routing: packets dropped on ingress while egress remains unattached; attach filter to both directions simultaneously",
                "Host network disruption: accidental attachment of drop filter to eth0 or bridge device; enforce strict veth prefix validation",
                "Kernel memory leak: failing to close netlink sockets or unpin BPF maps on daemon shutdown; implement clean signal handlers",
                "High interrupt latency: conntrack table scan lock contention on large tables; filter deletion by exact tuple keys"
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
                "scripts/test-tc-ebpf.sh",
                "test/bench-tc-drop.sh",
                "bpftool filter show",
                "bpftool map dump name stun_isolation_map"
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
                "Step 7: Build BATS verification suite test/tetragon-telemetry-stream.bats verifying that container exec and curl events trigger flow events in signal-ingest within 500ms.\n"
                "Step 8: Implement backpressure handling and event buffering in signal-ingest to prevent data drops during bursty container activity.\n"
                "Step 9: Document Tetragon tracepoint telemetry schema and export contracts in docs/signalloom/tetragon-telemetry-pipeline.md."
            ),
            "deliverables": [
                "Updated Tetragon TracingPolicy manifest in d2-signalloom/deploy/tetragon-agent-telemetry.yaml",
                "Tetragon gRPC streaming client integrated into signal-ingest NetEBPF collector",
                "Event normalizer mapping Tetragon raw flows to InboundFlowEvent schema in Go",
                "Unit test suite in d2-signalloom/apps/signal-ingest/collectors/ebpf/tetragon_test.go",
                "Automated BATS test test/tetragon-telemetry-stream.bats verifying real-time telemetry streaming",
                "Documentation in docs/signalloom/tetragon-telemetry-pipeline.md",
                "Integration mock server in test/mocks/tetragon_grpc_mock.go for isolated offline unit testing",
                "Metrics collector exposing tetragon_flow_events_ingested_total and tetragon_stream_errors_total"
            ],
            "evidence": [
                "BATS test output showing live Tetragon events successfully ingested by signal-ingest",
                "Tetragon status showing zero LSM enforcement errors or dropped events",
                "Go test run log showing 100% pass across Tetragon event normalizers",
                "Log capture from signal-ingest demonstrating InboundFlowEvent publishing to FrostDB store",
                "Clean verification artifact recorded in docs/signalloom/evidence/tetragon-stream-proof.json",
                "Metric report verifying zero dropped events during a burst of 1,000 simultaneous execve tracepoints"
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
                "FAIR quantitative risk calculations (Phase 2)",
                "Implementing custom Tetragon sensor plugins written in kernel C",
                "Modifying Cilium CNI network routing policies"
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
                "gRPC connection drop: transient Tetragon restart; implement automatic reconnection loop with exponential backoff",
                "Protobuf serialization mismatch between Tetragon API versions: pin protoc definitions to v1.1.0 release",
                "High memory consumption in signal-ingest from unbounded flow queues: implement circular ringbuffer with drop policy"
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
                "scripts/test-tetragon-stream.sh",
                "test/mocks/tetragon_grpc_test.go"
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
                "Step 7: Update Obsidian proposal errata section with Phase 1 completion ledger and stop in Review state per Rule SP-5.\n"
                "Step 8: Reconcile code coverage reports across Go and BATS suites ensuring no test regression.\n"
                "Step 9: Publish Phase 1 verification summary to the kanban review ledger."
            ),
            "deliverables": [
                "Unified Phase 1 integration on integration/crkc-v0.1.0 with all Phase 1 tests passing",
                "End-to-end integration test suite test/crkc-phase1-unified-stun.bats validating Tier 0 and Tier 1 containment",
                "Phase 1 Governor Certification proof artifact in docs/signalloom/crkc-p1-governor-proof.md",
                "Telemetry verification log confirming Tetragon ingest during active containment",
                "Updated proposal errata ledger in Obsidian documenting Phase 1 milestone certification",
                "Pre-flight verification checklist for Phase 2 readiness",
                "Automated test report recording latency percentiles for stun execution halt",
                "Verification record entered in .kanban-review-ledger.json"
            ],
            "evidence": [
                "Full test execution log of test/crkc-phase1-unified-stun.bats with 100% pass rate",
                "Latency telemetry proving sub-second containment (CPU halt < 50ms, TC drop < 100ms)",
                "Git log showing clean integration of CRKC-P1-1 through CRKC-P1-4 without conflict markers",
                "Recorded proof artifact docs/signalloom/crkc-p1-governor-proof.md with execution timestamps",
                "Review ledger entry in .kanban-review-ledger.json recording governor sign-off",
                "Obsidian proposal document updated with Phase 1 certification status",
                "Verification that make test-signal-ingest and make test-signalfusion-bats pass 100%"
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
                "Auto-advancing past Review state into Done (strictly reserved for human governor)",
                "Modifying UI dashboard components before Phase 2",
                "Altering production Gateway API routing rules"
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
                "Merge regression in Go packages: run make test-signal-ingest and make test-signalfusion-bats to verify zero regressions",
                "Tetragon dropping flow events during high-throughput containment test: check ringbuffer sizing",
                "Divergent git commit history: integration branch rebasing issues causing dirty working trees"
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

# Run metric checks
for card in cards:
    ok, metrics, floor = verify_spec(card["spec"], card["size"], card["role"])
    print(f"Checking {card['logical_id']} ({card['size']}): OK={ok} words={metrics['words']}/{floor['words']} lines={metrics['lines']}/{floor['lines']}")
    if not ok:
        print(f"FAILED: {metrics} vs {floor}", file=sys.stderr)
        sys.exit(1)

# Apply cards
for card in cards:
    run_create(card)

print("Phase 1 cards successfully compiled and created!")
