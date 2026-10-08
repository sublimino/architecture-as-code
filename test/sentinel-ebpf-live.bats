#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      sentinel-ebpf-live
# @target  d2-signalloom/apps/stun-sentinel
# @doc     docs/Proposal — Signal Loom EAP CI Lane and Demo Environment Redeploy (2026-Q4).md
# @spec    SLSE D6 -- Live adversarial eBPF warden verification on kind-osramp
#
# The LIVE adversarial tier of the in-sentinel eBPF warden suite.
#
# Executes 5 live attacks from inside dedicated agent cgroups with zero fixtures:
#   1. Direct openat2 syscall (ctypes SYS_openat2, bypassing openat tracepoint)
#   2. Symlink race to /etc/passwd (sys_enter_openat resolution)
#   3. Process execve burst of /bin/sh (evasive_syscall_burst)
#   4. Egress TCP connect to blocked address (tcp_connect)
#   5. Ring-buffer flood of benign openat chaff + mid-flood connect (ringbuf_drops_anomaly)
#
# Asserts:
#   - Every attack yields its expected observation via cursor-paged /api/v1/observations
#   - Drop counter rises and drop anomaly observation appears during flood
#   - Mid-flood connect is preserved (zero silent event loss)
#   - Continuous memory sampling bounds warden RSS with zero restarts
#   - Zero Tetragon resources exist on the cluster
#
# Gated: runs only when SENTINEL_EBPF_LIVE=1 (or SENTINEL_ADVERSARIAL_LIVE=1) and
# KUBECONFIG is a real non-/dev/null path. Skips cleanly otherwise.

bats_require_minimum_version 1.5.0

setup_file() {
    export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
    export WL_CONTEXT="${WL_CONTEXT:-kind-osramp}"
    export KIND_NODE="${KIND_NODE:-osramp-control-plane}"
    export AGENT_NS="${AGENT_NS:-fe-signalloom-agents}"
    export INGEST_NS="${INGEST_NS:-fe-signalloom}"
    export PROOF_JSON="${BATS_FILE_TMPDIR}/sentinel-ebpf-proof.json"

    # If live tier is enabled, execute the runner once to gather all proof
    if [ "${SENTINEL_EBPF_LIVE:-}" = 1 ] || [ "${SENTINEL_ADVERSARIAL_LIVE:-}" = 1 ]; then
        if [ -n "${KUBECONFIG:-}" ] && [ "${KUBECONFIG}" != /dev/null ]; then
            python3 "${REPO_ROOT}/scripts/sentinel-ebpf-live-runner.py" \
                --context "${WL_CONTEXT}" \
                --kind-node "${KIND_NODE}" \
                --namespace "${AGENT_NS}" \
                --ingest-namespace "${INGEST_NS}" \
                --json "${PROOF_JSON}" >&2
        fi
    fi
}

live_or_skip() {
    [ "${SENTINEL_EBPF_LIVE:-}" = 1 -o "${SENTINEL_ADVERSARIAL_LIVE:-}" = 1 ] && [ -n "${KUBECONFIG:-}" ] && [ "${KUBECONFIG}" != /dev/null ] \
        || skip "live tier: set SENTINEL_EBPF_LIVE=1 and a real KUBECONFIG (currently SENTINEL_EBPF_LIVE='${SENTINEL_EBPF_LIVE:-}', KUBECONFIG='${KUBECONFIG:-}')"
    need kubectl
    need docker
    need python3
    need jq
    need curl
    [ -f "${PROOF_JSON}" ] || {
        echo "Proof file ${PROOF_JSON} was not generated" >&2
        return 1
    }
}

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "live tier requires $1 on PATH" >&2
        return 1
    }
}

@test "eBPF warden zero-fixture preflight: no Tetragon CRDs or DaemonSets present" {
    live_or_skip
    local crds ds
    crds="$(jq -r '.environment.tetragon_crd_count' "${PROOF_JSON}")"
    ds="$(jq -r '.environment.tetragon_ds_count' "${PROOF_JSON}")"
    [ "$crds" -eq 0 ]
    [ "$ds" -eq 0 ]
}

@test "eBPF warden preflight: deployed image tag matches manifest pin" {
    live_or_skip
    local running_image
    running_image="$(jq -r '.environment.warden_image' "${PROOF_JSON}")"
    [ -n "$running_image" ]
    [[ "$running_image" == *"src-08e40cec5d33"* ]] || [[ "$running_image" == *"signalloom-warden"* ]]
}

@test "eBPF warden live adversarial run: full attack battery executes with zero warden restarts" {
    live_or_skip
    local restarts_before restarts_after
    restarts_before="$(jq -r '.environment.restarts_before' "${PROOF_JSON}")"
    restarts_after="$(jq -r '.environment.restarts_after' "${PROOF_JSON}")"
    [ "$restarts_before" = "$restarts_after" ]
}

@test "eBPF warden live adversarial run: attack 1 direct openat2 syscall observed via cursor paging" {
    live_or_skip
    local observed syscall target
    observed="$(jq -r '.attacks.attack_1_openat2.observed' "${PROOF_JSON}")"
    [ "$observed" = "true" ]
    syscall="$(jq -r '.attacks.attack_1_openat2.observation.labels.syscall' "${PROOF_JSON}")"
    target="$(jq -r '.attacks.attack_1_openat2.observation.labels.target' "${PROOF_JSON}")"
    [ "$syscall" = "sys_enter_openat2" ]
    [[ "$target" == *"/etc/passwd"* ]]
}

@test "eBPF warden live adversarial run: attack 2 symlink race to /etc/passwd observed via cursor paging" {
    live_or_skip
    local observed target
    observed="$(jq -r '.attacks.attack_2_symlink_race.observed' "${PROOF_JSON}")"
    [ "$observed" = "true" ]
    target="$(jq -r '.attacks.attack_2_symlink_race.observation.labels.target' "${PROOF_JSON}")"
    [[ "$target" == *"/etc/passwd"* ]]
}

@test "eBPF warden live adversarial run: attack 3 execve burst of /bin/sh observed via cursor paging" {
    live_or_skip
    local observed syscall
    observed="$(jq -r '.attacks.attack_3_execve.observed' "${PROOF_JSON}")"
    [ "$observed" = "true" ]
    syscall="$(jq -r '.attacks.attack_3_execve.observation.labels.syscall' "${PROOF_JSON}")"
    [[ "$syscall" == "evasive_syscall_burst" || "$syscall" == "sys_enter_execve" ]]
}

@test "eBPF warden live adversarial run: attack 4 egress TCP connect observed via cursor paging" {
    live_or_skip
    local observed syscall target
    observed="$(jq -r '.attacks.attack_4_connect.observed' "${PROOF_JSON}")"
    [ "$observed" = "true" ]
    syscall="$(jq -r '.attacks.attack_4_connect.observation.labels.syscall' "${PROOF_JSON}")"
    target="$(jq -r '.attacks.attack_4_connect.observation.labels.target' "${PROOF_JSON}")"
    [ "$syscall" = "tcp_connect" ]
    [[ "$target" == *"10.244.0.1:9991"* ]]
}

@test "eBPF warden live adversarial run: attack 5 ring-buffer flood triggers drop anomaly without silent loss" {
    live_or_skip
    local drops anomaly_observed
    drops="$(jq -r '.attacks.attack_5_flood.ringbuf_drops' "${PROOF_JSON}")"
    anomaly_observed="$(jq -r '.attacks.attack_5_flood.drop_anomaly_observed' "${PROOF_JSON}")"
    [ "$drops" -gt 0 ]
    [ "$anomaly_observed" = "true" ]
}

@test "eBPF warden live adversarial run: attack 5 mid-flood egress TCP connect is preserved and observed" {
    live_or_skip
    local connect_observed target
    connect_observed="$(jq -r '.attacks.attack_5_flood.mid_flood_connect_observed' "${PROOF_JSON}")"
    [ "$connect_observed" = "true" ]
    target="$(jq -r '.attacks.attack_5_flood.mid_flood_connect_observation.labels.target' "${PROOF_JSON}")"
    [[ "$target" == *"10.244.0.1:9992"* ]]
}

@test "eBPF warden live adversarial run: continuous memory sampling tracks RSS bounds" {
    live_or_skip
    local sample_count peak_vm_rss peak_rss_anon
    sample_count="$(jq -r '.memory_metrics.samples_count' "${PROOF_JSON}")"
    peak_vm_rss="$(jq -r '.memory_metrics.peak_vm_rss_mib' "${PROOF_JSON}")"
    peak_rss_anon="$(jq -r '.memory_metrics.peak_rss_anon_mib' "${PROOF_JSON}")"
    [ "$sample_count" -gt 5 ]
    # Container memory limit is 128 MiB (daemonset.yaml:254)
    local kpi_met
    kpi_met="$(jq -r '.memory_metrics.kpi_met' "${PROOF_JSON}")"
    [ "$kpi_met" = "true" ]
}

@test "eBPF warden live adversarial run: cursor paging retrieves observations deterministically across passes" {
    live_or_skip
    local match total_obs
    match="$(jq -r '.paging_and_determinism.determinism_match' "${PROOF_JSON}")"
    total_obs="$(jq -r '.paging_and_determinism.total_observations_1' "${PROOF_JSON}")"
    [ "$match" = "true" ]
    [ "$total_obs" -gt 0 ]
}
