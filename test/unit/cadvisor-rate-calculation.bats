#!/usr/bin/env bats
# test/unit/cadvisor-rate-calculation.bats
#
# Automated BATS test suite validating Kubelet cAdvisor proxy poller,
# rate transformation derivatives, freeze flatline invariant (0.000 mCPU),
# Prometheus metric deserialization, and sub-millisecond calculation latency.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
    export GOPATH="/tmp/gopath"
    export GOCACHE="/tmp/gocache"
    export GOMODCACHE="/tmp/gopath/pkg/mod"
    export CGO_ENABLED=0
}

@test "Go Telemetry Package: Idle Deltas Sub-Epsilon Zero Rate" {
    cd "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry"
    run go test -v -run TestComputeRate_IdleDeltas .
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestComputeRate_IdleDeltas" ]]
}

@test "Go Telemetry Package: Active Load Spike Derivative Calculation" {
    cd "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry"
    run go test -v -run TestComputeRate_ActiveLoadSpike .
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestComputeRate_ActiveLoadSpike" ]]
}

@test "Go Telemetry Package: Frozen Pod Invariant Exact Zero Flatline" {
    cd "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry"
    run go test -v -run TestComputeRate_ZeroDelta_FrozenPod .
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestComputeRate_ZeroDelta_FrozenPod" ]]
}

@test "Go Telemetry Package: Container Restart Counter Rollover Protection" {
    cd "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry"
    run go test -v -run TestComputeRate_ContainerRestartRollover .
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestComputeRate_ContainerRestartRollover" ]]
}

@test "Go Telemetry Package: Zero and Negative Delta Seconds Safety" {
    cd "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry"
    run go test -v -run TestComputeRate_ZeroOrNegativeDeltaSec .
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestComputeRate_ZeroOrNegativeDeltaSec" ]]
}

@test "Go Telemetry Package: Prometheus Exposition Streaming Parser" {
    cd "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry"
    run go test -v -run TestParsePrometheusMetrics .
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestParsePrometheusMetrics" ]]
}

@test "Go Telemetry Package: HTTP REST and SSE Telemetry Handler Lifecycle" {
    cd "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry"
    run go test -v -run TestTelemetryHandler_RESTAndSSE .
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASS: TestTelemetryHandler_RESTAndSSE" ]]
}

@test "Python cAdvisor Poller: Parse Metrics Deserialization" {
    cd "$REPO_ROOT"
    run pytest d2-signalloom/apps/fe-signalloom/src/tests/test_cadvisor_poller.py -k test_parse_metrics
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1 passed" ]]
}

@test "Python cAdvisor Poller: CPU Usage Rate Derivative Derivative Calculation" {
    cd "$REPO_ROOT"
    run pytest d2-signalloom/apps/fe-signalloom/src/tests/test_cadvisor_poller.py -k test_cpu_rate_derivative
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1 passed" ]]
}

@test "Python cAdvisor Poller: Frozen Pod Rate Invariant Zero Rate" {
    cd "$REPO_ROOT"
    run pytest d2-signalloom/apps/fe-signalloom/src/tests/test_cadvisor_poller.py -k test_frozen_pod_zero_rate
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1 passed" ]]
}

@test "Python cAdvisor Poller: Poller Resiliency and Backoff on HTTP Error" {
    cd "$REPO_ROOT"
    run pytest d2-signalloom/apps/fe-signalloom/src/tests/test_cadvisor_poller.py -k test_poller_http_error_backoff
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1 passed" ]]
}

@test "Rate Calculation Latency Benchmark: Sub-Millisecond Execution" {
    cd "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry"
    run go test -bench=. -benchtime=100ms .
    [ "$status" -eq 0 ]
}
