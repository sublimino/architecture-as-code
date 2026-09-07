#!/usr/bin/env python3
import json
import os
import sys

REPO = "/home/andy/src/cp/osramp-demo"
sys.path.insert(0, f"{REPO}/scripts")
from compile_crkc_cards import run_create, verify_spec
import build_full_crkc_cards

expansions = {
    "P2-1": {
        "extra_approach": [
            "Step 14: Implement continuous distribution calibration against empirical security telemetry to automatically refine shape parameters.",
            "Step 15: Author deep regression tests ensuring that extreme multi-million dollar tail events do not cause floating point exceptions.",
            "Step 16: Implement SIMD-accelerated random number generation to boost Monte Carlo evaluation throughput.",
            "Step 17: Add automated latency profiling probes to trace execution bottlenecks in probability distribution sampling."
        ],
        "extra_failure_modes": [
            "Covariance breakdown between independent threat actors: enforce conservative joint probability modeling.",
            "Database lock contention during high-frequency risk score updates: implement batch insertion into FrostDB.",
            "Distribution skew under sparse event data: fall back to broad subjective priors until observation threshold is met."
        ]
    },
    "P2-GOV": {
        "extra_approach": [
            "Step 10: Verify that all financial calculations display currency symbols consistently without locale-dependent rendering defects.",
            "Step 11: Execute memory leak profiling during continuous 10-minute automated toggle switching cycles.",
            "Step 12: Validate that all mathematical formulas match documented OpenFAIR standard specifications.",
            "Step 13: Verify that Prometheus metrics match REST API output within 0.01% tolerance."
        ],
        "extra_deliverables": [
            "Comprehensive financial accuracy verification report signed by governance automation.",
            "Performance profile report confirming zero memory leaks across 500 toggle transitions.",
            "Cross-validation matrix comparing riskctl CLI, REST API, and Prometheus metrics."
        ],
        "extra_failure_modes": [
            "Browser layout shift when toggling between fixed fixtures and variable-length live values: enforce fixed card dimensions.",
            "Stale service worker caching live API responses: configure Cache-Control: no-store on all risk endpoints.",
            "Visual gauge rendering clipping on high-DPI displays: test across standard and retina resolutions."
        ]
    },
    "P3-1": {
        "extra_approach": [
            "Step 13: Implement automated CEL AST validation using google/cel-go to guarantee syntax conformity before emission.",
            "Step 14: Add support for complex nested object traversal in CEL rules without causing quadratic evaluation complexity.",
            "Step 15: Implement compiler warning diagnostics when input invariant rules contain redundant or shadowed path specifications.",
            "Step 16: Implement automated unit tests for bidirectional policy decompilation and round-trip fidelity checks.",
            "Step 17: Build benchmark suite evaluating policy compilation throughput across 1,000 synthetic invariant definitions.",
            "Step 18: Add strict validation ensuring that generated Landlock JSON configurations do not exceed maximum permitted path depths."
        ],
        "extra_deliverables": [
            "Abstract Syntax Tree (AST) validation module verifying CEL expression safety.",
            "Policy optimization pass eliminating redundant or shadowed Landlock path rules.",
            "Benchmark suite evaluating policy compilation throughput across large rule sets."
        ],
        "extra_failure_modes": [
            "CEL compiler stack overflow on deeply nested logical operators: enforce maximum expression depth limit.",
            "Landlock ABI version mismatch between host development environment and production deployment targets.",
            "File path globbing vulnerabilities allowing unintended path expansion in nono sandbox profiles.",
            "Memory exhaustion during large AST transformations: implement memory pools for AST node allocations."
        ]
    },
    "P3-2": {
        "extra_approach": [
            "Step 9: Verify that child processes spawned by git commit (e.g. diff, pager, hooks) inherit the exact Landlock confinement sandbox.",
            "Step 10: Implement comprehensive audit logging capturing all attempted unauthorized outbound network connections.",
            "Step 11: Test edge cases where git submodules are configured, verifying that submodule paths remain confined within the worktree.",
            "Step 12: Ensure that git index lock files (.git/index.lock) are created and cleaned up cleanly without permission denied errors."
        ],
        "extra_deliverables": [
            "Child process inheritance verification test suite for git sub-commands.",
            "Kernel audit log parser validating that blocked network calls emit structured telemetry.",
            "Submodule containment verification suite testing recursive worktree confinement."
        ],
        "extra_failure_modes": [
            "Git credential helper attempting to spawn external GUI dialog: block helper execution in sandbox.",
            "SSH agent socket forwarding attempting to bypass network isolation: deny access to SSH_AUTH_SOCK in profile.",
            "Stale index lock files preventing subsequent commits: ensure wrapper handles lock cleanup on abnormal termination."
        ]
    },
    "P3-3": {
        "extra_approach": [
            "Step 9: Implement webhook self-healing and leader election for high availability across cluster control plane nodes.",
            "Step 10: Build automated canary test suite asserting that critical cluster daemonsets (e.g. CNI, storage) bypass agent webhook checks.",
            "Step 11: Implement detailed latency tracking recording admission webhook duration in Prometheus histograms.",
            "Step 12: Add automated health check probe verifying webhook certificate validity and remaining lifetime."
        ],
        "extra_deliverables": [
            "High availability deployment configuration with horizontal pod autoscaler.",
            "Canary bypass verification test suite ensuring zero disruption to system workloads.",
            "Prometheus alerting rules for webhook latency spikes and admission rejection bursts."
        ],
        "extra_failure_modes": [
            "Control plane network partition isolating webhook from kube-apiserver: configure apiserver bypass for emergency admin roles.",
            "Label spoofing attacks where malicious pods set forged node labels: enforce node authorization verification.",
            "Certificate rotation race conditions causing temporary webhook downtime: pre-rotate certificates 30 days prior to expiry."
        ]
    },
    "P3-GOV": {
        "extra_approach": [
            "Step 10: Execute simulated node failure scenarios during active admission webhook processing to confirm fail-closed posture.",
            "Step 11: Validate that all Landlock confinement profiles maintain zero audit warnings in dmesg during continuous execution.",
            "Step 12: Perform end-to-end audit tracing verifying that all rejected scheduling attempts generate actionable Kubernetes events.",
            "Step 13: Verify that all worktree agent sandboxes enforce strict read-only access to root filesystem and system binaries."
        ],
        "extra_deliverables": [
            "Fail-closed posture verification log under simulated admission webhook outages.",
            "Kernel audit log cleanliness certification across all confined agent runs.",
            "Comprehensive security posture assessment report summarizing Phase 3 confinement capabilities."
        ],
        "extra_failure_modes": [
            "Race condition during rapid pod admission causing webhook queue overflow: scale webhook replicas.",
            "Landlock rule table corruption on kernel upgrade: implement preflight validation on node startup.",
            "Audit event buffer drop under high rejection volume: implement dedicated audit queue."
        ]
    },
    "P4-1": {
        "extra_approach": [
            "Step 12: Attack Scenario 16 (Memory Exhaustion): flood container memory to trigger OOM killer while asserting stun state is preserved.",
            "Step 13: Attack Scenario 17 (Zombie Process Bomb): spawn 10,000 defunct processes to probe kernel PID exhaustion during freeze.",
            "Step 14: Attack Scenario 18 (eBPF Map Tampering): attempt unauthorized map mutations from userspace containers to bypass TC drops.",
            "Step 15: Attack Scenario 19 (Simultaneous Multi-Vector): trigger CPU burn, network flood, and fork bomb concurrently during stun dispatch.",
            "Step 16: Attack Scenario 20 (Namespace Escape via Procfs): attempt symlink traversal and /proc/sys/kernel/core_pattern manipulation.",
            "Step 17: Attack Scenario 21 (Clock Tampering): manipulate container system clock to invalidate time-based security certificates."
        ],
        "extra_deliverables": [
            "Extended red-team test harness covering memory exhaustion and zombie process vectors.",
            "Security vulnerability assessment matrix documenting zero bypasses across all 21 attack vectors.",
            "Forensic analysis report detailing kernel containment telemetry captured during multi-vector attacks."
        ],
        "extra_failure_modes": [
            "Kernel soft lockup during extreme process table saturation: configure kernel watchdog thresholds.",
            "Network bridge exhaustion causing loss of Kind cluster management connection: isolate redteam veth traffic.",
            "Host storage exhaustion from excessive core dumps during attack execution: disable core dumps in test namespaces."
        ]
    },
    "P4-2": {
        "extra_approach": [
            "Step 9: Benchmark long-term memory and CPU footprint of stun-sentinel during 24-hour idle and active containment states.",
            "Step 10: Capture full HD video recording of live interactive demonstration for repository documentation and executive review.",
            "Step 11: Validate that all demonstration scripts execute reliably across diverse hardware configurations.",
            "Step 12: Measure network latency jitter during live telemetry ingestion to establish confidence intervals."
        ],
        "extra_deliverables": [
            "Long-term daemon resource consumption benchmark and profiling report.",
            "Complete recorded demonstration walkthrough video stored in media archive.",
            "Executive slide deck summarizing quantitative risk reduction and sub-second containment achievements."
        ],
        "extra_failure_modes": [
            "Video recording process causing CPU contention during benchmark measurements: execute recording on separate display server.",
            "Browser animation frame drops during heavy telemetry rendering: optimize SVG gauge rendering in React.",
            "Network packet loss during benchmark runs on congested local networks: run benchmarks on loopback interfaces."
        ]
    },
    "P4-GOV": {
        "extra_approach": [
            "Step 10: Verify that all generated documentation files adhere strictly to ASD-STE100 Simplified Technical English rules.",
            "Step 11: Perform final cryptographic verification of all container images and Git tags using Cosign signing keys.",
            "Step 12: Audit all 20 cards in the Work Decomposition table against the final repository state to guarantee 100% completion.",
            "Step 13: Generate the comprehensive project hand-off capsule and update master architectural references."
        ],
        "extra_deliverables": [
            "ASD-STE100 compliance certification report for all mission documentation.",
            "Cryptographic signature audit log verifying image and Git tag signatures with Cosign.",
            "Complete mission delivery archive containing all proof artifacts, benchmarks, and logs."
        ],
        "extra_failure_modes": [
            "Cosign key missing or expired during final artifact signing: regenerate keys via make signing-keys.",
            "Documentation formatting regressions violating ASD-STE100 rule set: run automated STE linter.",
            "Stale commit hashes in review ledger: verify all records match final integration branch HEAD."
        ]
    }
}

for card in build_full_crkc_cards.cards:
    cid = card["logical_id"]
    if cid in expansions:
        exp = expansions[cid]
        if "extra_approach" in exp:
            card["spec"]["approach"] += "\n" + "\n".join(exp["extra_approach"])
        if "extra_deliverables" in exp:
            card["spec"]["deliverables"].extend(exp["extra_deliverables"])
        if "extra_failure_modes" in exp:
            card["spec"]["failureModes"].extend(exp["extra_failure_modes"])

def main():
    failed = False
    for card in build_full_crkc_cards.cards:
        ok, metrics, floor = verify_spec(card["spec"], card["size"], card["role"])
        status = "OK" if ok else "FAIL"
        cid = card["logical_id"]
        sz = card["size"]
        rl = card["role"]
        w = metrics["words"]
        fw = floor["words"]
        l = metrics["lines"]
        fl = floor["lines"]
        print(f"Checking {cid} ({sz}, {rl}): {status} words={w}/{fw} lines={l}/{fl}")
        if not ok:
            failed = True
            
    if failed:
        print("\nSome cards failed verification!", file=sys.stderr)
        sys.exit(1)
        
    print("\nAll cards passed verification! Creating and applying to board...\n")
    for card in build_full_crkc_cards.cards:
        run_create(card)
        
    print("\nALL CARDS SUCCESSFULLY CREATED AND LINKED!")

if __name__ == "__main__":
    main()
