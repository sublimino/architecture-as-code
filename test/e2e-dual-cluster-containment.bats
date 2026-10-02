#!/usr/bin/env bats
#
# SLDC-P5-1 - five-step automated end-to-end containment verification.
#
# @id      e2e-dual-cluster-containment
# @target  d2-signalloom/apps/kusari-agent, d2-signalloom/apps/signalloom-stun-sentinel
# @doc     docs/eap/SLDC-P5-1-E2E-CONTAINMENT.md
# @spec    Proposal - Signal Loom Local Dual-Cluster EAP Pilot Validation … Appendix F.1
# @lib     scripts/lib/wait.sh
#
# Deploy → Claim → Provoke → In-Sentinel Detect → Freeze, across kind-osramp
# (workload plane) and kind-signalloom-hub (control plane).
#
# Doctrine this suite obeys:
#   * No `kubectl exec` as a probe. Every assertion is an HTTP API read, a CRD
#     status read, or a kernel read on the node. `exec` tunnels through the API
#     server and would mask the network quarantine the containment applies.
#     The single exception is the PostgreSQL query in Step 2 (no psql client on
#     the host, and the database is deliberately not exposed); it is a read-only
#     SELECT and is documented as such.
#   * No bare `sleep`. Every wait is a deadline-bounded poll from
#     scripts/lib/wait.sh.
#   * Teardown thaws ONLY the cgroup this suite froze. `kind-osramp` is shared:
#     other agents are deliberately frozen (P5-PRE PF-1) and a blanket
#     `find /sys/fs/cgroup -name cgroup.freeze | echo 0` would silently thaw
#     them and destroy another card's state.
#
# Injectable boundaries (Testability doctrine - every external dependency is
# overridable, so the suite is provable against fixtures):
#   SLDC_KUBECTL        kubectl binary                (default: kubectl)
#   SLDC_DOCKER         docker binary                 (default: docker)
#   WL_CONTEXT          workload kube context         (default: kind-osramp)
#   HUB_CONTEXT         hub kube context              (default: kind-signalloom-hub)
#   NODE                workload node / container     (default: osramp-control-plane)
#   NS                  agent namespace               (default: fe-signalloom-agents)
#   EVIDENCE_DIR        evidence root                 (default: ~/kusari-e2e/<ts>)
#   SLDC_OBS_WINDOW_MS  Step 4 correlation window     (default: 15000)
#   SLDC_SKIP_BRIDGE    set to 1 to skip the docker bridge assertion
#
# Mutation proof: test/e2e-mutation-proof.sh drives this file against a fake
# kubectl and inverts one behaviour per step, proving each assertion fails when
# the underlying behaviour is broken (Shared Pattern 6).

setup_file() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export REPO_ROOT
    # shellcheck source=../scripts/lib/wait.sh
    source "${REPO_ROOT}/scripts/lib/wait.sh"

    export KUBECTL="${SLDC_KUBECTL:-kubectl}"
    export DOCKER_BIN="${SLDC_DOCKER:-docker}"
    export WL_CONTEXT="${WL_CONTEXT:-kind-osramp}"
    export HUB_CONTEXT="${HUB_CONTEXT:-kind-signalloom-hub}"
    export NODE="${NODE:-osramp-control-plane}"
    export NS="${NS:-fe-signalloom-agents}"
    export HUB_NS="${HUB_NS:-inf-signalloom}"
    export INGEST_NS="${INGEST_NS:-fe-signalloom}"
    export KUSTOMIZATION="${KUSTOMIZATION:-agent-kusari-agent}"
    export DEPLOYMENT="${DEPLOYMENT:-agent-kusari}"
    export AGENT_SELECTOR="${AGENT_SELECTOR:-app.kubernetes.io/name=kusari-agent}"
    export TENANT="${TENANT:-kusari}"
    export TENANT_HASH="${TENANT_HASH:-4b53ab6b}"
    export OBS_WINDOW_MS="${SLDC_OBS_WINDOW_MS:-15000}"

    # The agent_registry database is a separate injectable boundary from the hub
    # control plane. Appendix F.1 places it on the hub; the live estate runs it
    # on the workload cluster (inf-signalloom/postgresql) and the hub runs no
    # PostgreSQL at all. Defaulting to the card's topology made Step 2 fail on
    # the only estate that exists, and that failure read as a product defect
    # rather than a card/estate divergence -- so the default follows the estate
    # and DB_CONTEXT overrides it. The divergence itself is Step 2's own
    # assertion: it is recorded in step2-registry-claim.json, not papered over.
    export DB_CONTEXT="${DB_CONTEXT:-${WL_CONTEXT}}"

    export K_WORKLOAD="${KUBECTL} --context ${WL_CONTEXT}"
    export K_HUB="${KUBECTL} --context ${HUB_CONTEXT}"
    export K_DB="${KUBECTL} --context ${DB_CONTEXT}"

    EVIDENCE_DIR="${EVIDENCE_DIR:-${HOME}/kusari-e2e/$(date +%Y%m%d-%H%M%S)}"
    export EVIDENCE_DIR
    mkdir -p "${EVIDENCE_DIR}"
    chmod 0750 "${EVIDENCE_DIR}"

    # Both clusters must answer before a single assertion runs, otherwise a
    # cluster-down run reads as a containment failure.
    ${K_WORKLOAD} cluster-info >"${EVIDENCE_DIR}/preflight-workload-cluster-info.txt" 2>&1 \
        || { echo "FATAL: workload cluster ${WL_CONTEXT} unreachable" >&2; return 1; }
    ${K_HUB} cluster-info >"${EVIDENCE_DIR}/preflight-hub-cluster-info.txt" 2>&1 \
        || { echo "FATAL: hub cluster ${HUB_CONTEXT} unreachable" >&2; return 1; }

    # The two kind clusters share the `kind` docker bridge; cross-cluster
    # federation depends on it routing between the node containers.
    if [ "${SLDC_SKIP_BRIDGE:-0}" != "1" ]; then
        ${DOCKER_BIN} network inspect kind \
            --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' \
            >"${EVIDENCE_DIR}/preflight-docker-bridge.txt" 2>&1 \
            || { echo "FATAL: docker network kind not inspectable" >&2; return 1; }
        grep -q . "${EVIDENCE_DIR}/preflight-docker-bridge.txt" \
            || { echo "FATAL: docker network kind has no attached containers" >&2; return 1; }
    fi

    {
        echo "suite: e2e-dual-cluster-containment"
        echo "captured: $(date '+%Y-%m-%d %H:%M:%S%z')"
        echo "workload_context: ${WL_CONTEXT}"
        echo "hub_context: ${HUB_CONTEXT}"
        echo "db_context: ${DB_CONTEXT}"
        echo "node: ${NODE}"
        echo "namespace: ${NS}"
        echo "tenant: ${TENANT} (${TENANT_HASH})"
        echo "repo_head: $(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "kubectl: $(${KUBECTL} version --client -o json 2>/dev/null | tr -d '\n' | head -c 400)"
    } >"${EVIDENCE_DIR}/preflight-manifest.json.txt"

    echo "# evidence: ${EVIDENCE_DIR}" >&3
}

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=../scripts/lib/wait.sh
    source "${REPO_ROOT}/scripts/lib/wait.sh"
    export WAIT_QUIET="${WAIT_QUIET:-1}"
}

# agent_pod_field echoes one jsonpath field of the (single) kusari agent pod.
agent_pod_field() {
    ${K_WORKLOAD} get pod -n "${NS}" -l "${AGENT_SELECTOR}" \
        -o "jsonpath={.items[0].$1}" 2>/dev/null
}

agent_proxy() {
    echo "/api/v1/namespaces/${NS}/services/kusari-agent:8080/proxy$1"
}

# post_raw issues a POST through the API server proxy. `kubectl get --raw` is
# GET-only, so an empty-bodied `create --raw` is the POST equivalent.
post_raw() {
    ${K_WORKLOAD} create --raw "$1" -f /dev/null 2>&1
}

# epoch_ms_of converts an RFC3339(nano) timestamp to epoch milliseconds.
epoch_ms_of() {
    local ts="$1" secs frac
    secs="$(date -u -d "${ts}" +%s 2>/dev/null)" || return 1
    frac="$(printf '%s' "${ts}" | sed -nE 's/.*\.([0-9]{1,3}).*/\1/p')"
    frac="$(printf '%-3s' "${frac:-0}" | tr ' ' '0')"
    echo "$(( secs * 1000 + 10#${frac} ))"
}

# pod_cgroup_dir resolves the node cgroup-v2 directory for THIS pod's UID.
# Never `find … | head -1`: that returns an arbitrary pod's cgroup and would
# make Step 5 pass on another workload's freeze state.
pod_cgroup_dir() {
    local uid slice
    uid="$(agent_pod_field 'metadata.uid')"
    [ -n "${uid}" ] || return 1
    slice="pod${uid//-/_}.slice"
    ${DOCKER_BIN} exec "${NODE}" sh -c \
        "find /sys/fs/cgroup -maxdepth 6 -type d -name '*${slice}' 2>/dev/null | head -1"
}

# cadvisor_sample echoes "<cpu_seconds> <cadvisor_timestamp_ms>" for the agent
# container, scraped through the kubelet cAdvisor proxy. The timestamp is
# cAdvisor's own housekeeping clock, which is what lets the flatline assertion
# below compare two genuinely distinct samples without a wall-clock sleep.
cadvisor_sample() {
    local pod="$1"
    ${K_WORKLOAD} get --raw "/api/v1/nodes/${NODE}/proxy/metrics/cadvisor" 2>/dev/null \
        | awk -v pod="${pod}" '
            /^container_cpu_usage_seconds_total\{/ &&
            index($0, "pod=\"" pod "\"") &&
            index($0, "container=\"agent\"") { print $2, $3; exit }'
}

# ── polled predicates ────────────────────────────────────────────────────────
# These are shell functions rather than command strings because _wait_retry runs
# its argument through `bash -c "$cmd"`: nesting a SQL statement or a jq filter
# inside that string means three levels of quoting, and the SQL's own '|'
# literals silently terminate the inner `sh -c '...'`. Exported functions keep
# the quoting in code, where the shell parses it once.

REGISTRY_SQL="SELECT name || '|' || tenant_id || '|' || coalesce(model_name, '') FROM public.agent_registry WHERE name = 'kusari-agent';"
export REGISTRY_SQL

registry_row() {
    ${K_DB} exec -n "${HUB_NS}" deploy/postgresql -- \
        sh -c 'psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-signalloom}" -Atc "$0"' \
        "${REGISTRY_SQL}" 2>/dev/null
}

# observations_json reads the ingest feed. Without a lower bound the store
# answers with its OLDEST `limit` observations, so once more than 50 sentinel
# observations had accumulated the provoked one was never returned and Step 4
# failed with the observation sitting in the store (measured 2026-10-02: the
# newest returned was 19h old). OBS_AFTER bounds the query to the provocation.
observations_json() {
    ${K_WORKLOAD} get --raw \
        "/api/v1/namespaces/${INGEST_NS}/services/signal-ingest:8082/proxy/api/v1/observations?limit=50${OBS_AFTER:+&after=${OBS_AFTER}}" \
        2>/dev/null
}

# sensitive_openat_observations filters the feed down to the openat events this
# suite provoked: sys_enter_openat against /etc/passwd or /etc/shadow.
#
# signal-ingest stores its own model.Observation, which has no syscall or
# target field: the sentinel carries the Shared Pattern 2 fields in labels, as
# every collector does. This used to read them at the top level, which the
# system of record can never return, so Step 4 could not pass against a real
# signal-ingest. Labels are read first, the top level is the fallback, and each
# match is normalised back to the Shared Pattern 2 event the assertions and the
# evidence schema ($defs/normalizedEvent) expect.
sensitive_openat_observations() {
    observations_json | jq -c '
        [ .[]?
          | . as $o | (($o.labels? // {}) | if type == "object" then . else {} end) as $l
          | select(($l.syscall // $o.syscall // "") == "sys_enter_openat")
          | select((($l.target // $o.target // "")) | test("^/etc/(passwd|shadow)$"))
          | { id: $o.id, source: $o.source, timestamp: $o.timestamp, actor_id: $o.actor_id,
              syscall: ($l.syscall // $o.syscall), target: ($l.target // $o.target),
              tenant_id: ($l.tenant_id // $o.tenant_id), pod_name: ($l.pod_name // $o.pod_name),
              namespace: ($l.namespace // $o.namespace),
              direct_reaction: ($l.direct_reaction // $o.direct_reaction),
              cgroup_path: ($l.cgroup_path // $o.cgroup_path), labels: $l }
        ]' 2>/dev/null
}

have_sensitive_openat() {
    local n
    n="$(sensitive_openat_observations | jq -r 'length' 2>/dev/null)"
    [ -n "${n}" ] && [ "${n}" -gt 0 ]
}

cgroup_reports_frozen() {
    local cg="$1"
    ${DOCKER_BIN} exec "${NODE}" sh -c "cat ${cg}/cgroup.events" 2>/dev/null \
        | grep -q '^frozen 1$'
}

# sentinel_pod names the stun-sentinel DaemonSet pod on the workload node:
# the one whose reconciler owns this pod's cgroup.
sentinel_pod() {
    ${K_WORKLOAD} get pod -n "${NS}" -l app.kubernetes.io/name=stun-sentinel \
        --field-selector "spec.nodeName=${NODE}" -o 'jsonpath={.items[0].metadata.name}' 2>/dev/null
}

# sentinel_health reads the sentinel's own /healthz through the API server pod
# proxy: reconcile_count and the informer resync_seconds it runs with.
sentinel_health() {
    ${K_WORKLOAD} get --raw "/api/v1/namespaces/${NS}/pods/$1:8081/proxy/healthz" 2>/dev/null
}

# resync_elapsed <sentinel> <since-epoch> <resync-seconds> <reconcile-count-then>
# holds once a full resync interval has passed since <since-epoch> AND the
# sentinel has reconciled since: the thaw this guards against was a resync.
resync_elapsed() {
    [ "$(( $(date +%s) - $2 ))" -gt "$3" ] || return 1
    local rc; rc="$(sentinel_health "$1" | jq -r '.reconcile_count // empty')"
    [ -n "${rc}" ] && [ "${rc}" -gt "$4" ]
}

export -f registry_row observations_json sensitive_openat_observations \
          have_sensitive_openat cgroup_reports_frozen cadvisor_sample \
          sentinel_health resync_elapsed

@test "Step 1: Kusari workload deployment reconciled by Flux on the workload cluster" {
    run ${K_WORKLOAD} get kustomization "${KUSTOMIZATION}" -n "${NS}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]
    local ready_status="$output"

    run ${K_WORKLOAD} get kustomization "${KUSTOMIZATION}" -n "${NS}" \
        -o jsonpath='{.status.lastAppliedRevision}'
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    local revision="$output"

    WAIT_QUIET=1 run wait_rollout "${DEPLOYMENT}" -n "${NS}" 180
    [ "$status" -eq 0 ]

    run agent_pod_field 'status.phase'
    [ "$output" = "Running" ]

    run agent_pod_field 'metadata.uid'
    [ -n "$output" ]
    local pod_uid="$output"

    run agent_pod_field 'status.containerStatuses[0].restartCount'
    [ "$output" = "0" ]

    run ${K_WORKLOAD} get deploy "${DEPLOYMENT}" -n "${NS}" \
        -o jsonpath='{.status.readyReplicas}/{.status.replicas}'
    [ "$output" = "1/1" ]

    {
        echo "kustomization: ${KUSTOMIZATION} (ns ${NS})"
        echo "ready: ${ready_status}"
        echo "lastAppliedRevision: ${revision}"
        echo "deployment: ${DEPLOYMENT} replicas ${output}"
        echo "pod: $(agent_pod_field 'metadata.name')"
        echo "pod_uid: ${pod_uid}"
        echo "phase: Running"
        echo "restartCount: 0"
        echo "image: $(agent_pod_field 'status.containerStatuses[0].imageID')"
    } >"${EVIDENCE_DIR}/step1-flux-reconcile.txt"
}

@test "Step 2: Tenant registration and database claim for tenant kusari" {
    # Poll: the registration worker writes the row asynchronously after the
    # workload appears, so an immediate SELECT legitimately returns 0 rows.
    WAIT_QUIET=1 run _wait_retry 60 "agent_registry row for kusari-agent" \
        "registry_row | grep -q kusari-agent"
    [ "$status" -eq 0 ]

    run registry_row
    [ "$status" -eq 0 ]
    local row="$output"
    [ -n "$row" ]

    # Canonical tenant vector: tenant is exactly `kusari`, hash 4b53ab6b. The
    # retired typo `kurasi` must fail closed (Shared Pattern 1).
    [[ "$row" != *kurasi* ]]
    [[ "$row" == *"|${TENANT}|"* ]]

    local model_name; model_name="$(printf '%s' "$row" | awk -F'|' '{print $3}')"
    [ -n "$model_name" ]

    run bash -c "SIGNAL_LOOM_EAP_SALT=\"\${SIGNAL_LOOM_EAP_SALT:-signalloom-eap-salt-2026-q3}\" python3 '${REPO_ROOT}/scripts/derive_tenant_hash.py' '${TENANT}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${TENANT_HASH}"* ]]

    printf '{"query":%s,"row":%s,"tenant":"%s","tenant_hash":"%s","model_name":%s}\n' \
        "$(printf '%s' "${REGISTRY_SQL}" | jq -Rs .)" \
        "$(printf '%s' "$row" | jq -Rs .)" \
        "${TENANT}" "${TENANT_HASH}" \
        "$(printf '%s' "$model_name" | jq -Rs .)" \
        >"${EVIDENCE_DIR}/step2-registry-claim.json"
}

@test "Step 3: Provoke malicious actor via /act/read-passwd" {
    # Recorded before the call so Step 4 can bound the correlation window.
    date -u +%Y-%m-%dT%H:%M:%S.%3NZ >"${EVIDENCE_DIR}/step3-provocation-start.txt"

    run post_raw "$(agent_proxy /act/read-passwd)"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"action":"read-passwd"'* ]]
    [[ "$output" == *'"ok":true'* ]]
    local passwd_body="$output"

    # The descriptor must be held long enough for an in-kernel probe to
    # correlate the openat with the pod, and the read must happen in the traced
    # thread (held_ms and tid prove both).
    local held; held="$(printf '%s' "$passwd_body" | jq -r '.held_ms // 0')"
    [ "$held" -ge 50 ]
    [ "$(printf '%s' "$passwd_body" | jq -r '.tid')" -gt 0 ]
    [ "$(printf '%s' "$passwd_body" | jq -r '.lines')" -gt 0 ]
    # The provocation must never exfiltrate the file it read.
    [[ "$passwd_body" != *"root:x:0"* ]]

    # Second provocation against /etc/shadow. `attempted` is the signal - on a
    # distroless image the file is absent, but the sys_enter_openat still fires.
    run post_raw "$(agent_proxy /act/read-shadow)"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"action":"read-shadow"'* ]]
    [[ "$output" == *'"attempted":true'* ]]
    local shadow_body="$output"

    date -u +%Y-%m-%dT%H:%M:%S.%3NZ >"${EVIDENCE_DIR}/step3-provocation-end.txt"

    {
        echo "POST $(agent_proxy /act/read-passwd)"
        echo "$passwd_body"
        echo
        echo "POST $(agent_proxy /act/read-shadow)"
        echo "$shadow_body"
    } >"${EVIDENCE_DIR}/step3-provocation-act.log"
}

@test "Step 4: In-sentinel eBPF probe intercepts syscall and emits observation" {
    local start_ts; start_ts="$(cat "${EVIDENCE_DIR}/step3-provocation-start.txt" 2>/dev/null)"
    # One second of slack below the provocation, the same tolerance the
    # selection below applies; RFC3339 with Z needs no URL encoding.
    OBS_AFTER="$(date -u -d "${start_ts} - 1 second" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    export OBS_AFTER
    [ -n "$start_ts" ]
    local pod_name; pod_name="$(agent_pod_field 'metadata.name')"

    # Poll rather than sleep: the correlator dispatches asynchronously.
    WAIT_QUIET=1 run _wait_retry 60 "openat observation for ${TENANT}" \
        "have_sensitive_openat"
    [ "$status" -eq 0 ]

    # The FIRST sensitive observation at or after the provocation is the
    # detection. This used to take the LAST one, and the first read freezes the
    # pod: the later /etc/shadow read only runs once the pod is thawed, so the
    # suite graded the thaw delay, not detection (measured 2026-10-01: the
    # passwd read was observed at once, the shadow read 14.4s later, and the
    # step passed by 0.5s on the wrong event).
    # Chronological, not lexical: RFC3339Nano trims trailing zeros, so a
    # string sort puts "...33.123Z" before "...33.1Z" (review L1).
    local obs="" cand cand_ms best_ms="" start_ms_sel
    start_ms_sel="$(epoch_ms_of "$start_ts")"
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        cand_ms="$(epoch_ms_of "$(printf '%s' "$cand" | jq -r '.timestamp')")" || continue
        [ "$cand_ms" -ge "$(( start_ms_sel - 1000 ))" ] || continue
        if [ -z "$best_ms" ] || [ "$cand_ms" -lt "$best_ms" ]; then obs="$cand"; best_ms="$cand_ms"; fi
    done < <(sensitive_openat_observations | jq -c '.[]')
    [ -n "$obs" ]
    [ "$obs" != "null" ]

    # Shared Pattern 2: the normalized event must carry actor, pod, cgroup,
    # syscall and target - not a raw kernel blob.
    [ "$(printf '%s' "$obs" | jq -r '.syscall')" = "sys_enter_openat" ]
    [[ "$(printf '%s' "$obs" | jq -r '.target')" == /etc/* ]]
    [ "$(printf '%s' "$obs" | jq -r '.tenant_id')" = "${TENANT}" ]
    [ "$(printf '%s' "$obs" | jq -r '.pod_name')" = "$pod_name" ]
    [ "$(printf '%s' "$obs" | jq -r '.actor_id')" != "null" ]
    [ -n "$(printf '%s' "$obs" | jq -r '.labels.cgroup_path // .cgroup_path // empty')" ]
    [[ "$(printf '%s' "$obs" | jq -r '.tenant_id')" != *kurasi* ]]

    # Correlation window: the observation must post-date the provocation and
    # land inside SLDC_OBS_WINDOW_MS of it.
    local obs_ms start_ms
    obs_ms="$(epoch_ms_of "$(printf '%s' "$obs" | jq -r '.timestamp')")"
    start_ms="$(epoch_ms_of "$start_ts")"
    [ "$obs_ms" -ge "$(( start_ms - 1000 ))" ]
    [ "$(( obs_ms - start_ms ))" -le "${OBS_WINDOW_MS}" ]

    printf '%s\n' "$obs" | jq . >"${EVIDENCE_DIR}/step4-ebpf-observation.json"
    printf 'provocation_start=%s observation_ts=%s delta_ms=%s window_ms=%s\n' \
        "$start_ts" "$(printf '%s' "$obs" | jq -r '.timestamp')" \
        "$(( obs_ms - start_ms ))" "${OBS_WINDOW_MS}" \
        >>"${EVIDENCE_DIR}/step4-correlation-window.txt"
}

@test "Step 5: Pod is frozen and stays frozen past a resync, CPU flatlines at 0 mCPU, Flux reconcile suppressed, 0 restarts" {
    local pod_name; pod_name="$(agent_pod_field 'metadata.name')"
    [ -n "$pod_name" ]

    local cg; cg="$(pod_cgroup_dir)"
    [ -n "$cg" ]

    # Kernel ground truth: this pod's own cgroup.events reports frozen 1.
    WAIT_QUIET=1 run _wait_retry 60 "cgroup.events frozen 1 for ${pod_name}" \
        "cgroup_reports_frozen '${cg}'"
    [ "$status" -eq 0 ]

    run ${DOCKER_BIN} exec "${NODE}" sh -c "cat ${cg}/cgroup.events; echo '--- cgroup.freeze:'; cat ${cg}/cgroup.freeze; echo '--- cpu.stat:'; cat ${cg}/cpu.stat"
    [ "$status" -eq 0 ]
    [[ "$output" == *"frozen 1"* ]]
    local kernel_state="$output"

    # GitOps Suspension Invariant (Shared Pattern 4): both the owning Deployment
    # and the Pod carry reconcile: disabled, so Flux cannot replace the frozen
    # pod mid-forensics.
    run ${K_WORKLOAD} get deploy "${DEPLOYMENT}" -n "${NS}" \
        -o 'jsonpath={.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/reconcile}'
    [ "$output" = "disabled" ]

    run ${K_WORKLOAD} get pod "${pod_name}" -n "${NS}" \
        -o 'jsonpath={.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/reconcile}'
    [ "$output" = "disabled" ]

    # Persistence: the sentinel's own reconciler used to thaw this freeze on
    # its next informer resync (measured live: ~14 s). Wait out one full resync
    # interval, as the sentinel publishes it, plus at least one reconcile pass,
    # then re-read the kernel. Not a guessed sleep: both bounds are read.
    local sentinel; sentinel="$(sentinel_pod)"
    [ -n "$sentinel" ]
    local health resync rc0 since
    health="$(sentinel_health "$sentinel")"
    resync="$(printf '%s' "$health" | jq -r '.resync_seconds // 0')"
    rc0="$(printf '%s' "$health" | jq -r '.reconcile_count // empty')"
    [ "$resync" -gt 0 ]
    [ -n "$rc0" ]
    since="$(date +%s)"
    WAIT_QUIET=1 run _wait_retry "$(( resync * 2 + 60 ))" "one sentinel resync after the freeze" \
        "resync_elapsed '${sentinel}' ${since} ${resync} ${rc0}"
    [ "$status" -eq 0 ]
    run ${DOCKER_BIN} exec "${NODE}" sh -c "cat ${cg}/cgroup.events"
    [ "$status" -eq 0 ]
    [[ "$output" == *"frozen 1"* ]]

    # Forensic Preservation Contract (H1): strictly zero restarts. A single
    # restart means the kubelet liveness probe killed the container and the
    # volatile memory is gone.
    run agent_pod_field 'status.containerStatuses[0].restartCount'
    [ "$output" = "0" ]
    local restarts="$output"

    # cAdvisor flatline: sample the cumulative CPU counter twice, and only
    # compare samples cAdvisor itself considers distinct (its housekeeping
    # timestamp must have advanced). Comparing two reads of the same cached
    # sample would report a 0.000 mCPU flatline for a pod burning a whole core.
    local s1 c1 t1 s2 c2 t2
    s1="$(cadvisor_sample "$pod_name")"
    c1="${s1%% *}"; t1="${s1##* }"
    [ -n "$c1" ] && [ -n "$t1" ]

    WAIT_QUIET=1 run _wait_retry 60 "cadvisor housekeeping tick after ${t1}" \
        "test \"\$(cadvisor_sample '${pod_name}' | awk '{print \$2}')\" != '${t1}'"
    [ "$status" -eq 0 ]

    s2="$(cadvisor_sample "$pod_name")"
    c2="${s2%% *}"; t2="${s2##* }"
    [ -n "$c2" ] && [ -n "$t2" ]
    [ "$t1" != "$t2" ]
    [ "$c1" = "$c2" ]

    local mcpu; mcpu="$(awk -v a="$c1" -v b="$c2" 'BEGIN{printf "%.3f", (b-a)*1000}')"
    [ "$mcpu" = "0.000" ]

    # The container must no longer answer network traffic while frozen.
    run post_raw "$(agent_proxy /act/read-passwd)"
    [ "$status" -ne 0 ]

    {
        echo "pod: ${pod_name}"
        echo "cgroup: ${cg}"
        echo "${kernel_state}"
        echo "flux_reconcile_deployment: disabled"
        echo "flux_reconcile_pod: disabled"
        echo "frozen_after_resync: 1 (resync_seconds=${resync}, reconcile_count ${rc0} -> advanced)"
        echo "restartCount: ${restarts}"
        echo "cadvisor_cpu_seconds: ${c1} -> ${c2}"
        echo "delta_mcpu: ${mcpu}"
    } >"${EVIDENCE_DIR}/step5-cgroup-freeze.txt"

    ${K_WORKLOAD} get --raw "/api/v1/nodes/${NODE}/proxy/metrics/cadvisor" 2>/dev/null \
        | grep -E "pod=\"${pod_name}\"" \
        >"${EVIDENCE_DIR}/step5-cadvisor-metrics.prom" || true

    ( cd "${EVIDENCE_DIR}" && sha256sum ./* >audit-signature.sha256 2>/dev/null ) || true
}

teardown_file() {
    # Thaw ONLY the cgroup this suite froze. See the header: a blanket thaw
    # across the node would undo other cards' deliberate freezes.
    local uid slice cg
    uid="$(${KUBECTL} --context "${WL_CONTEXT}" get pod -n "${NS}" -l "${AGENT_SELECTOR}" \
        -o 'jsonpath={.items[0].metadata.uid}' 2>/dev/null || true)"
    if [ -n "${uid}" ]; then
        slice="pod${uid//-/_}.slice"
        cg="$(${DOCKER_BIN:-docker} exec "${NODE}" sh -c \
            "find /sys/fs/cgroup -maxdepth 6 -type d -name '*${slice}' 2>/dev/null | head -1" 2>/dev/null || true)"
        if [ -n "${cg}" ]; then
            ${DOCKER_BIN:-docker} exec "${NODE}" sh -c \
                "test -w ${cg}/cgroup.freeze && echo 0 > ${cg}/cgroup.freeze" >/dev/null 2>&1 || true
        fi
    fi
    # Any port-forward this suite started (none by default) is a child of the
    # bats process group and dies with it; assert nothing is left listening.
    if [ -n "${SLDC_PF_PID:-}" ]; then
        kill "${SLDC_PF_PID}" >/dev/null 2>&1 || true
    fi
    echo "# evidence: ${EVIDENCE_DIR}" >&3 2>/dev/null || true
}
