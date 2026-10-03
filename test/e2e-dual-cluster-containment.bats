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
#     SELECT and is documented as such. Step 2's claim, when it makes one, runs
#     scripts/demo-agent-autoclaim.sh, which reaches the API from inside the
#     dashboard pod; that is the product's claim path, not a probe.
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
#   SLDC_FLEET_URL      fleet-manager base URL for Step 6's recovery (default:
#                       a kubectl port-forward to svc/fleet-manager)
#   FLEET_AGENT_ID      the kusari agent's fleet DAG id (default: agent-kusari-agent)
#   SLDC_SKIP_BRIDGE    set to 1 to skip the docker bridge assertion
#   SLDC_CLAIM_CMD      Step 2 claim command   (default: scripts/demo-agent-autoclaim.sh)
#   SLDC_CLAIM_USER     Dex user that claims   (default: kusari-operator@signalloom.local)
#   SLDC_CLAIM_PASSWORD its password           (default: the local-demo kusari-operator)
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
    # Clock slack below the ordered open (stub and sentinel share the kind
    # node's clock; this covers the stub's sleep returning early by a tick).
    export OBS_SLACK_MS="${SLDC_OBS_SLACK_MS:-250}"
    export FLEET_NS="${FLEET_NS:-fe-signalloom}"
    export FLEET_AGENT_ID="${FLEET_AGENT_ID:-agent-kusari-agent}"

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

# claim_kusari_agent claims kusari-agent through the product, as the one Dex
# subject mapped to tenant kusari. The model and harness come from the pod's own
# labels inside the claim script. The registry row is NEVER written with SQL:
# the row Step 2 once passed on was, and nothing in the product could recreate it.
claim_kusari_agent() {
    SLAC_KUBE_CONTEXT="${WL_CONTEXT}" \
    AGENT_NAMESPACE="${NS}" \
    DEMO_DEX_USER="${SLDC_CLAIM_USER:-kusari-operator@signalloom.local}" \
    DEX_DEMO_PASSWORD="${SLDC_CLAIM_PASSWORD:-kusari-operator}" \
    SLAC_DEMO_RESULT_FILE="${EVIDENCE_DIR}/step2-claim-result.json" \
        "${SLDC_CLAIM_CMD:-${REPO_ROOT}/scripts/demo-agent-autoclaim.sh}" --workload kusari-agent
}

# observations_json reads the ingest feed. Without a lower bound the store
# answers with its OLDEST `limit` observations, so once more than 50 sentinel
# observations had accumulated the provoked one was never returned and Step 4
# failed with the observation sitting in the store (measured 2026-10-02: the
# newest returned was 19h old). OBS_AFTER bounds the query to the provocation.
observations_json() {
    # Every signal-ingest route is authenticated and the apiserver service proxy
    # cannot carry a credential for it. Read through a port-forward with the
    # sldc-evidence-reader key (kusari, observations:read only), handed to curl
    # as a header FILE: never argv, removed after. 3>&- keeps the background
    # port-forward off bats' fd 3, which would otherwise hold the run open.
    local port="${INGEST_EVIDENCE_PORT:-28092}" hdr pf rc=0 key
    key="$(${K_WORKLOAD} -n "${INGEST_NS}" get secret signal-ingest-key-sldc-evidence-reader \
        -o 'jsonpath={.data.token}' 2>/dev/null | base64 -d 2>/dev/null)" || return 1
    [ -n "$key" ] || { echo "no sldc-evidence-reader key; run scripts/sldc-ingest-bearer.sh --key sldc-evidence-reader" >&2; return 1; }
    hdr="$(mktemp "${BATS_TEST_TMPDIR:-/tmp}/evidence-auth.XXXXXX")"
    ( umask 077; printf 'Authorization: Bearer %s\n' "$key" >"$hdr" )
    ${K_WORKLOAD} -n "${INGEST_NS}" port-forward svc/signal-ingest "${port}:8082" >/dev/null 2>&1 3>&- &
    pf=$!
    for _ in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:${port}/" && break; sleep 0.25; done
    curl -fsS -m 10 -H @"$hdr" \
        "http://127.0.0.1:${port}/api/v1/observations?limit=50${OBS_AFTER:+&after=${OBS_AFTER}}" || rc=$?
    kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null; rm -f "$hdr"
    return $rc
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

# sentinel_pod names the signalloom-warden DaemonSet pod on the workload node:
# the one whose reconciler owns this pod's cgroup.
sentinel_pod() {
    ${K_WORKLOAD} get pod -n "${NS}" -l app.kubernetes.io/name=signalloom-warden \
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

cgroup_reports_thawed() {
    ${DOCKER_BIN} exec "${NODE}" sh -c "cat $1/cgroup.events" 2>/dev/null \
        | grep -q '^frozen 0$'
}

# fleet_operator_header writes fleet-manager's operator caller key, as an
# Authorization header, to a 0600 file in this run's private tmpdir and echoes
# the path. The key moves only through files and pipes, never argv: it is the
# break-glass credential that may /recover.
fleet_operator_header() {
    local dir="${BATS_FILE_TMPDIR}" b64 hdr
    b64="${dir}/fleet-operator.b64"; hdr="${dir}/fleet-operator.hdr"
    (
        umask 077
        ${K_WORKLOAD} get secret fleet-manager-caller-keys -n "${FLEET_NS}" \
            -o 'jsonpath={.data.operator}' >"${b64}" 2>/dev/null || exit 1
        [ -s "${b64}" ] || exit 1
        { printf 'Authorization: Bearer '; base64 -d <"${b64}"; printf '\n'; } >"${hdr}" || exit 1
    ) || { rm -f "${b64}" "${hdr}"; return 1; }
    rm -f "${b64}"
    echo "${hdr}"
}

# fleet_url echoes fleet-manager's base URL: SLDC_FLEET_URL, or a port-forward
# this suite starts (its PID is recorded for teardown_file).
fleet_url() {
    if [ -n "${SLDC_FLEET_URL:-}" ]; then echo "${SLDC_FLEET_URL}"; return 0; fi
    local log="${BATS_FILE_TMPDIR}/fleet-pf.log" port="" i
    if [ -s "${BATS_FILE_TMPDIR}/fleet-pf.port" ]; then
        echo "http://127.0.0.1:$(cat "${BATS_FILE_TMPDIR}/fleet-pf.port")"; return 0
    fi
    ${K_WORKLOAD} port-forward -n "${FLEET_NS}" svc/fleet-manager :8082 >"${log}" 2>&1 &
    echo $! >"${BATS_FILE_TMPDIR}/fleet-pf.pid"
    for i in $(seq 1 50); do
        port="$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) .*/\1/p' "${log}" | head -1)"
        [ -n "${port}" ] && break
        sleep 0.2
    done
    [ -n "${port}" ] || return 1
    echo "${port}" >"${BATS_FILE_TMPDIR}/fleet-pf.port"
    echo "http://127.0.0.1:${port}"
}

# fleet_recover_kusari asks fleet-manager to recover exactly this suite's
# agent (an explicit agent_ids list never touches other cards' stuns) and
# echoes the HTTP status. The body lands in fleet-recover.json.
fleet_recover_kusari() {
    local hdr url
    hdr="$(fleet_operator_header)" || { echo "no-operator-key"; return 1; }
    url="$(fleet_url)" || { rm -f "${hdr}"; echo "no-fleet-url"; return 1; }
    curl -sS --max-time 60 -o "${BATS_FILE_TMPDIR}/fleet-recover.json" -w '%{http_code}' \
        -X POST -H @"${hdr}" -H 'Content-Type: application/json' \
        --data "{\"agent_ids\":[\"${FLEET_AGENT_ID}\"]}" \
        "${url}/api/v1/fleet/recover"
    local rc=$?
    rm -f "${hdr}"
    return "${rc}"
}

# stun_recorded <pod> holds once fleet-manager's stun record is complete: the
# Deployment and Pod Flux pins and a sentinel-detection stun reason.
stun_recorded() {
    [ "$(${K_WORKLOAD} get deploy "${DEPLOYMENT}" -n "${NS}" \
        -o 'jsonpath={.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/reconcile}')" = "disabled" ] || return 1
    [ "$(${K_WORKLOAD} get pod "$1" -n "${NS}" \
        -o 'jsonpath={.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/reconcile}')" = "disabled" ] || return 1
    [[ "$(${K_WORKLOAD} get pod "$1" -n "${NS}" \
        -o 'jsonpath={.metadata.annotations.signalloom\.io/stun-reason}')" == "stun-sentinel detection: "* ]]
}

# agent_pod_rows lists the agent's pods as "<uid>|<phase>|<ready>" lines.
agent_pod_rows() {
    ${K_WORKLOAD} get pod -n "${NS}" -l "${AGENT_SELECTOR}" \
        -o 'jsonpath={range .items[*]}{.metadata.uid}{"|"}{.status.phase}{"|"}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null
}

# agent_pod_gone <uid> holds once no agent pod has that UID.
agent_pod_gone() {
    local rows; rows="$(agent_pod_rows)" || return 1
    [[ $'\n'"${rows}"$'\n' != *$'\n'"$1|"* ]]
}

# replacement_ready <old-uid> holds when exactly one agent pod exists, it is
# not the old one, and it is Running and Ready.
replacement_ready() {
    local rows; rows="$(agent_pod_rows)" || return 1
    [ -n "${rows}" ] && [ "$(printf '%s\n' "${rows}" | wc -l)" -eq 1 ] || return 1
    [[ "${rows}" != "$1|"* && "${rows}" == *"|Running|true" ]]
}

# replacement_clean <pod> asserts the replacement carries no containment of
# any kind: no stun label, no Flux pin, no stun reason, an unfrozen cgroup and
# no restart.
replacement_clean() {
    local pod="$1" v cg
    v="$(${K_WORKLOAD} get pod "${pod}" -n "${NS}" -o 'jsonpath={.metadata.labels.signalloom\.io/stunned}')"
    [ "${v}" != "true" ] || { echo "replacement ${pod} is stunned"; return 1; }
    v="$(${K_WORKLOAD} get pod "${pod}" -n "${NS}" -o 'jsonpath={.metadata.labels.signalloom\.ai/state}')"
    [ "${v}" != "stunned" ] || { echo "replacement ${pod} has state=stunned"; return 1; }
    v="$(${K_WORKLOAD} get pod "${pod}" -n "${NS}" -o 'jsonpath={.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/reconcile}')"
    [ -z "${v}" ] || { echo "replacement ${pod} is Flux-pinned: ${v}"; return 1; }
    v="$(${K_WORKLOAD} get pod "${pod}" -n "${NS}" -o 'jsonpath={.metadata.annotations.signalloom\.io/stun-reason}')"
    [ -z "${v}" ] || { echo "replacement ${pod} carries a stun reason: ${v}"; return 1; }
    cg="$(pod_cgroup_dir)"
    [ -n "${cg}" ] || { echo "no cgroup for ${pod}"; return 1; }
    cgroup_reports_thawed "${cg}" || { echo "replacement ${pod} cgroup is frozen"; return 1; }
    [ "$(agent_pod_field 'status.containerStatuses[0].restartCount')" = "0" ] || { echo "replacement ${pod} restarted"; return 1; }
}

export -f registry_row claim_kusari_agent observations_json sensitive_openat_observations \
          have_sensitive_openat cgroup_reports_frozen cgroup_reports_thawed cadvisor_sample \
          sentinel_health resync_elapsed agent_pod_rows agent_pod_gone replacement_ready stun_recorded

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
    local replicas="$output"

    # Forensic Preservation (H1) needs a frozen container nobody restarts. A
    # frozen agent fails an httpGet liveness probe, and nothing answers it in
    # its place (the sentinel's probe preservation records the probes only),
    # so the kubelet kills it: live, 2026-10-03, 45 s into the hold. The
    # containment target therefore carries no liveness probe (decision K4).
    run ${K_WORKLOAD} get deploy "${DEPLOYMENT}" -n "${NS}" \
        -o 'jsonpath={.spec.template.spec.containers[?(@.name=="agent")].livenessProbe}'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "the containment target declares a liveness probe: ${output}"; return 1; }

    {
        echo "kustomization: ${KUSTOMIZATION} (ns ${NS})"
        echo "ready: ${ready_status}"
        echo "lastAppliedRevision: ${revision}"
        echo "deployment: ${DEPLOYMENT} replicas ${replicas}"
        echo "liveness_probe: none (H1)"
        echo "pod: $(agent_pod_field 'metadata.name')"
        echo "pod_uid: ${pod_uid}"
        echo "phase: Running"
        echo "restartCount: 0"
        echo "image: $(agent_pod_field 'status.containerStatuses[0].imageID')"
    } >"${EVIDENCE_DIR}/step1-flux-reconcile.txt"
}

@test "Step 2: Tenant registration and database claim for tenant kusari" {
    # The model the claim must record is the one the workload declares.
    local label_model
    label_model="$(agent_pod_field 'metadata.labels.signalloom\.ai/model')"
    [ -n "$label_model" ]

    # No worker claims on its own, so when there is no row yet Step 2 makes the
    # claim through the product. A row left by an earlier run is not re-claimed;
    # it is held to the same assertions below. The claim script also grades
    # compliance and audit, which are not Step 2's contract, so its exit code is
    # recorded as evidence and the row decides.
    local claimed=false claim_rc=null
    if ! registry_row | grep -q kusari-agent; then
        claimed=true
        run claim_kusari_agent
        claim_rc="$status"
        printf '%s\n' "$output" >"${EVIDENCE_DIR}/step2-claim.log"
    fi

    # Poll: the API commits the row in its own transaction.
    WAIT_QUIET=1 run _wait_retry 60 "agent_registry row for kusari-agent" \
        "registry_row | grep -q kusari-agent"
    [ "$status" -eq 0 ]

    run registry_row
    [ "$status" -eq 0 ]
    local row="$output"
    [ -n "$row" ]
    # Exactly one: a second row in another tenant is a split claim.
    [ "$(grep -c . <<<"$row")" -eq 1 ]

    # Canonical tenant vector: tenant is exactly `kusari`, hash 4b53ab6b. The
    # retired typo `kurasi` must fail closed (Shared Pattern 1).
    [[ "$row" != *kurasi* ]]
    [[ "$row" == *"|${TENANT}|"* ]]

    # Read from the workload, never invented: autoclaim once wrote
    # claude-3-5-sonnet for a pod labelled signalloom.ai/model=deterministic.
    local model_name; model_name="$(printf '%s' "$row" | awk -F'|' '{print $3}')"
    [ -n "$model_name" ]
    [ "$model_name" = "$label_model" ]

    run bash -c "SIGNAL_LOOM_EAP_SALT=\"\${SIGNAL_LOOM_EAP_SALT:-signalloom-eap-salt-2026-q3}\" python3 '${REPO_ROOT}/scripts/derive_tenant_hash.py' '${TENANT}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${TENANT_HASH}"* ]]

    printf '{"query":%s,"row":%s,"tenant":"%s","tenant_hash":"%s","model_name":%s,"label_model":%s,"claimed_this_run":%s,"claim_exit":%s}\n' \
        "$(printf '%s' "${REGISTRY_SQL}" | jq -Rs .)" \
        "$(printf '%s' "$row" | jq -Rs .)" \
        "${TENANT}" "${TENANT_HASH}" \
        "$(printf '%s' "$model_name" | jq -Rs .)" \
        "$(printf '%s' "$label_model" | jq -Rs .)" \
        "${claimed}" "${claim_rc}" \
        >"${EVIDENCE_DIR}/step2-registry-claim.json"
}

@test "Step 3: Provoke malicious actor via /act/read-passwd" {
    # Recorded before the call so Step 4 can bound the correlation window.
    date -u +%Y-%m-%dT%H:%M:%S.%3NZ >"${EVIDENCE_DIR}/step3-provocation-start.txt"

    # The order is answered BEFORE the act. The sentinel freezes the agent
    # ~1 ms after its openat, inside any request that performs it, so a
    # synchronous provocation's answer can never be written: live, both runs
    # on 2026-10-03 got "connection reset by peer". (Earlier greens only got
    # one because the freeze used to be thawed by a resync.) ?defer=1s makes
    # the stub answer 202 with the order and open /etc/passwd one second
    # later; Step 4 proves the open from the kernel, not from the agent.
    #
    # There is no second provocation: a contained agent cannot act again
    # without a thaw, and a test that needs it to grades the thaw.
    local pod_name; pod_name="$(agent_pod_field 'metadata.name')"
    [ -n "$pod_name" ]
    run post_raw "$(agent_proxy '/act/read-passwd?defer=1s')"
    [ "$status" -eq 0 ]
    local order="$output"
    [ "$(printf '%s' "$order" | jq -r '.action')" = "read-passwd" ]
    [ "$(printf '%s' "$order" | jq -r '.ok')" = "true" ]
    [ "$(printf '%s' "$order" | jq -r '.scheduled')" = "true" ]
    [ "$(printf '%s' "$order" | jq -r '.path')" = "/etc/passwd" ]
    # The order was taken by the pod this suite tracks, not some other replica.
    [ "$(printf '%s' "$order" | jq -r '.pod')" = "$pod_name" ]
    local scheduled_for; scheduled_for="$(printf '%s' "$order" | jq -r '.scheduled_for')"
    epoch_ms_of "$scheduled_for" >/dev/null
    printf '%s\n' "$scheduled_for" >"${EVIDENCE_DIR}/step3-provocation-scheduled-for.txt"
    # The provocation must never exfiltrate the file it reads.
    [[ "$order" != *"root:x:0"* ]]

    date -u +%Y-%m-%dT%H:%M:%S.%3NZ >"${EVIDENCE_DIR}/step3-provocation-end.txt"
    {
        echo "POST $(agent_proxy '/act/read-passwd?defer=1s')"
        echo "$order"
    } >"${EVIDENCE_DIR}/step3-provocation-act.log"
}

@test "Step 4: In-sentinel eBPF probe intercepts syscall and emits observation" {
    # The open was ordered for scheduled_for (Step 3), so it cannot precede
    # it: the window starts there, not at the request. That also shuts out
    # the container runtime's own /etc/passwd lookups at pod start, which the
    # sentinel reports for every new pod.
    local start_ts; start_ts="$(cat "${EVIDENCE_DIR}/step3-provocation-scheduled-for.txt" 2>/dev/null)"
    [ -n "$start_ts" ]
    # The feed query only needs a coarse lower bound; the selection is exact.
    OBS_AFTER="$(date -u -d "${start_ts} - 1 second" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    export OBS_AFTER
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
        [ "$cand_ms" -ge "$(( start_ms_sel - OBS_SLACK_MS ))" ] || continue
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

    # Correlation window: the observation must post-date the ordered open and
    # land inside SLDC_OBS_WINDOW_MS of it.
    local obs_ms start_ms
    obs_ms="$(epoch_ms_of "$(printf '%s' "$obs" | jq -r '.timestamp')")"
    start_ms="$(epoch_ms_of "$start_ts")"
    [ "$obs_ms" -ge "$(( start_ms - OBS_SLACK_MS ))" ]
    [ "$(( obs_ms - start_ms ))" -le "${OBS_WINDOW_MS}" ]

    printf '%s\n' "$obs" | jq . >"${EVIDENCE_DIR}/step4-ebpf-observation.json"
    printf 'provocation_scheduled_for=%s observation_ts=%s delta_ms=%s window_ms=%s\n' \
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

    # The kernel freeze is immediate; fleet-manager's stun record (both Flux
    # pins and the reason) lands when its cascade finishes, after the freeze.
    # Wait for it, bounded, as for the freeze: live, 2026-10-03, the pin was
    # read ~4 s before it existed and Step 5 failed both runs.
    WAIT_QUIET=1 run _wait_retry 60 "fleet-manager's stun record for ${pod_name}" \
        "stun_recorded '${pod_name}'"
    [ "$status" -eq 0 ]

    # GitOps Suspension Invariant (Shared Pattern 4): both the owning Deployment
    # and the Pod carry reconcile: disabled, so Flux cannot replace the frozen
    # pod mid-forensics.
    run ${K_WORKLOAD} get deploy "${DEPLOYMENT}" -n "${NS}" \
        -o 'jsonpath={.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/reconcile}'
    [ "$output" = "disabled" ]

    run ${K_WORKLOAD} get pod "${pod_name}" -n "${NS}" \
        -o 'jsonpath={.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/reconcile}'
    [ "$output" = "disabled" ]

    # Whose stun is it: the sentinel's detection, recorded by fleet-manager's
    # cascade (the one pin writer), names the syscall and the provoked target.
    run ${K_WORKLOAD} get pod "${pod_name}" -n "${NS}" \
        -o 'jsonpath={.metadata.annotations.signalloom\.io/stun-reason}'
    [[ "$output" == "stun-sentinel detection: sys_enter_openat /etc/"* ]]
    local stun_reason="$output"

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
        echo "stun_reason: ${stun_reason}"
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

@test "Step 6: Authorised recovery replaces the contained pod with a clean one and lifts the Flux pin" {
    # A recorded stun outlives the suite: fleet-manager pinned the Pod and the
    # Deployment and the sentinel holds the freeze until an authorised resume.
    # /resume needs a dual-signed operator token no estate provisions, so the
    # authorised path is /recover with the operator caller key, naming only
    # this suite's agent.
    #
    # Recover REPLACES the contained pod (fleet-manager's default): thawing it
    # resumes the compromised process mid-attack. Live, 2026-10-03, a thawed
    # kusari reopened /etc/passwd within 2 s and was re-stunned. So the
    # outcome asserted here is: the frozen pod is gone, never thawed, and a
    # clean pod from the declared template runs and stays clean.
    local old_name old_uid
    old_name="$(agent_pod_field 'metadata.name')"
    old_uid="$(agent_pod_field 'metadata.uid')"
    [ -n "$old_name" ] && [ -n "$old_uid" ]

    run fleet_recover_kusari
    [ "$status" -eq 0 ]
    [ "$output" = "200" ] || [ "$output" = "207" ]
    local recover_status="$output"

    # The release lands whatever the credential planes do; credential restore
    # is best effort and REPORTED, so it must be a boolean either way.
    local body="${BATS_FILE_TMPDIR}/fleet-recover.json" target
    target="$(jq -c --arg a "${FLEET_AGENT_ID}" '.targets[]? | select(.agent_id == $a)' "${body}")"
    [ -n "$target" ]
    [ "$(jq -r '.state_write.succeeded' <<<"$target")" = "true" ]
    [ "$(jq -r '.to_state' <<<"$target")" = "replaced" ]
    local credentials_restored
    credentials_restored="$(jq -r '.credential.succeeded | if type == "boolean" then tostring else "unreported" end' <<<"$target")"
    [ "$credentials_restored" = "true" ] || [ "$credentials_restored" = "false" ]

    # fleet-manager retired exactly the pod this suite froze.
    run jq -r --arg a "${FLEET_AGENT_ID}" \
        '[.planes[]? | select(.details.action == "replace_pod" and .details.agent_id == $a) | .details.pod_uid] | join(",")' "${body}"
    [ "$status" -eq 0 ]
    [ "$output" = "$old_uid" ]

    # The contained pod is gone, and exactly one clean replacement serves.
    WAIT_QUIET=1 run _wait_retry 120 "contained pod ${old_name} gone" "agent_pod_gone '${old_uid}'"
    [ "$status" -eq 0 ]
    WAIT_QUIET=1 run _wait_retry 180 "a replacement for ${old_name} Running and Ready" "replacement_ready '${old_uid}'"
    [ "$status" -eq 0 ]
    local new_name new_uid
    new_name="$(agent_pod_field 'metadata.name')"
    new_uid="$(agent_pod_field 'metadata.uid')"
    [ -n "$new_uid" ] && [ "$new_uid" != "$old_uid" ]

    # Flux reconciles the Deployment again: the pin is removed, not blanked.
    run ${K_WORKLOAD} get deploy "${DEPLOYMENT}" -n "${NS}" \
        -o 'jsonpath={.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/reconcile}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # Clean now, and still clean after one full sentinel resync: a thawed pod
    # was re-stunned within 2 s, so "clean once" proves nothing.
    replacement_clean "$new_name"
    local sentinel; sentinel="$(sentinel_pod)"
    [ -n "$sentinel" ]
    local health resync rc0 since
    health="$(sentinel_health "$sentinel")"
    resync="$(printf '%s' "$health" | jq -r '.resync_seconds // 0')"
    rc0="$(printf '%s' "$health" | jq -r '.reconcile_count // empty')"
    [ "$resync" -gt 0 ]
    [ -n "$rc0" ]
    since="$(date +%s)"
    WAIT_QUIET=1 run _wait_retry "$(( resync * 2 + 60 ))" "one sentinel resync after the replacement" \
        "resync_elapsed '${sentinel}' ${since} ${resync} ${rc0}"
    [ "$status" -eq 0 ]
    replacement_clean "$new_name"
    [ "$(agent_pod_field 'metadata.uid')" = "$new_uid" ]

    {
        echo "recover_status: ${recover_status}"
        echo "credentials_restored: ${credentials_restored}"
        echo "retired_pod: ${old_name} (${old_uid})"
        echo "replacement_pod: ${new_name} (${new_uid})"
        echo "flux_reconcile_deployment: (absent)"
        echo "replacement: unstunned, unpinned, no stun reason, kernel frozen 0, restartCount 0"
        echo "still_clean_after_resync: yes (resync_seconds=${resync})"
    } >"${EVIDENCE_DIR}/step6-recovery.txt"
}

teardown_file() {
    # Safety net for a run that failed before Step 6: recover this suite's
    # agent (idempotent, never anyone else's), then thaw ONLY the cgroup this
    # suite froze. See the header: a blanket thaw across the node would undo
    # other cards' deliberate freezes.
    fleet_recover_kusari >/dev/null 2>&1 || true
    if [ -s "${BATS_FILE_TMPDIR}/fleet-pf.pid" ]; then
        kill "$(cat "${BATS_FILE_TMPDIR}/fleet-pf.pid")" >/dev/null 2>&1 || true
    fi
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
