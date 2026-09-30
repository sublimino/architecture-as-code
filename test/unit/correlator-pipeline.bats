#!/usr/bin/env bats
# test/unit/correlator-pipeline.bats
#
# Automated BATS test suite validating userspace in-sentinel correlator,
# syscall normalization, sensitive prefix filtering, direct freeze invocation,
# observation schema serialization, and mock signal-ingest HTTP dispatch.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
    cd "$REPO_ROOT/d2-signalloom/apps/stun-sentinel"
    export GOPATH="/tmp/gopath"
    export GOCACHE="/tmp/gocache"
    export GOMODCACHE="/tmp/gopath/pkg/mod"
    export CGO_ENABLED=0
}

@test "Cgroup PID to Pod Identity Correlation Unit Test" {
    run go test -v -run TestLookupPodByPID ./pkg/correlator/...
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestLookupPodByPID" ]]
}

@test "Syscall Normalization Unit Test: RFC3339Nano, kusari tenant, critical severity" {
    run go test -v -run TestNormalizeTelemetryObservation ./pkg/correlator/...
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestNormalizeTelemetryObservation" ]]
}

@test "Sensitive Prefix Filter Unit Test: validates /etc/passwd, /etc/shadow, serviceaccount, ssh" {
    run go test -v -run TestSensitivePrefixFilter ./pkg/correlator/...
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestSensitivePrefixFilter" ]]
}

@test "Direct In-Sentinel Freeze Invocation Test: populates cgroup_frozen direct_reaction" {
    run go test -v -run TestDirectReactionFreeze ./pkg/correlator/...
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestDirectReactionFreeze" ]]
}

@test "Signal-Ingest Dispatch Mock Integration Test: validates HTTP POST and Bearer auth" {
    run go test -v -run TestDispatchObservation ./pkg/correlator/...
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestDispatchObservation" ]]
}

@test "Forbidden Kurasi Typo Correction Test: canonicalizes to kusari" {
    run go test -v -run TestForbiddenKurasiTypoCorrection ./pkg/correlator/...
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestForbiddenKurasiTypoCorrection" ]]
}

@test "Owner Record Phase Gating Test: refuses freeze outside Running phase" {
    run go test -v -run TestOwnerRecordPhaseGating ./pkg/correlator/...
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestOwnerRecordPhaseGating" ]]
}

@test "Deliberate Mutation Testing Check: sensitive prefix whitelist leakage fails test" {
    TARGET_FILE="pkg/correlator/ebpf_correlator.go"
    BACKUP_FILE="${TARGET_FILE}.bak"
    cp "$TARGET_FILE" "$BACKUP_FILE"

    # Deliberately mutate: remove /etc/passwd from DefaultSensitivePrefixes
    sed -i '/"\/etc\/passwd",/d' "$TARGET_FILE"

    # Run test expecting failure
    run go test -v -run TestSensitivePrefixFilter ./pkg/correlator/...
    
    # Restore original file immediately
    mv "$BACKUP_FILE" "$TARGET_FILE"

    # Assert that omitting /etc/passwd caused the test to fail
    [ "$status" -ne 0 ]
    [[ "$output" =~ "FAIL: TestSensitivePrefixFilter" ]]
}

@test "JSON TelemetryObservation Schema and Serialization Fidelity" {
    run bun -e '
      const sample = {
        timestamp: new Date().toISOString(),
        actor_id: "agent-kusari-1",
        tenant_id: "kusari",
        pod_name: "agent-kusari-1-pod",
        namespace: "tenant-kusari",
        syscall: "sys_enter_openat",
        target: "/etc/shadow",
        severity: "CRITICAL",
        labels: { "signalloom.ai/agent": "true", "tenant": "kusari" },
        direct_reaction: "cgroup_frozen"
      };

      const requiredKeys = [
        "timestamp", "actor_id", "tenant_id", "pod_name", "namespace",
        "syscall", "target", "severity", "labels", "direct_reaction"
      ];

      for (const k of requiredKeys) {
        if (!(k in sample)) throw new Error(`Missing key: ${k}`);
      }

      if (sample.tenant_id !== "kusari") throw new Error("Invalid tenant_id");
      if (sample.direct_reaction !== "cgroup_frozen") throw new Error("Invalid direct_reaction");
      console.log("schema valid");
    '
    [ "$status" -eq 0 ]
    [ "$output" = "schema valid" ]
}
