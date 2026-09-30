#!/usr/bin/env bash
#
# e2e-mutation-proof.sh - SLDC-P5-1 falsifiability proof (Shared Pattern 6).
#
# @id     e2e-mutation-proof
# @target test/e2e-dual-cluster-containment.bats
# @doc    docs/eap/SLDC-P5-1-E2E-CONTAINMENT.md
#
# A green test suite proves nothing until you have watched it go red for the
# right reason. This script drives the five-step containment suite against a
# hermetic fake kubectl/docker pair, first with a baseline fixture set where all
# five steps pass, then once per mutation - each mutation breaking exactly one
# piece of the underlying behaviour and expected to fail exactly the step that
# guards it.
#
# It needs no cluster. That is the point: the assertions are proven
# non-vacuous independently of whether the live estate can currently satisfy
# them, so a red live run is unambiguously a finding about the estate rather
# than a suspicion about the suite.
#
# Output is TAP version 13 for CI ingestion.
#
# Usage: test/e2e-mutation-proof.sh [--verbose] [--only MUTATION_ID]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="${REPO_ROOT}/test/e2e-dual-cluster-containment.bats"

VERBOSE=0
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose) VERBOSE=1; shift ;;
        --only)    ONLY="${2:?--only requires a mutation id}"; shift 2 ;;
        -h|--help) sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

command -v bats >/dev/null 2>&1 || { echo "Bail out! bats not on PATH"; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "Bail out! jq not on PATH"; exit 2; }
[ -f "${SUITE}" ] || { echo "Bail out! suite not found: ${SUITE}"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── the fake cluster ─────────────────────────────────────────────────────────
# One script answers every kubectl shape the suite uses; MUT selects the single
# behaviour to break. State lives in $SLDC_FAKE_STATE so the fake can model the
# detect→freeze cascade ordering: the agent answers /act/* until the observation
# query fires, and is unreachable afterwards.

mkdir -p "${WORK}/bin"

cat >"${WORK}/bin/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -uo pipefail
ARGS="$*"
MUT="${MUT:-none}"
STATE="${SLDC_FAKE_STATE:?SLDC_FAKE_STATE required}"
POD="agent-kusari-5685ff664b-kv25k"
UID_="e02fe214-5d7c-423b-9fa9-f933932d6679"

frozen() { [ -f "${STATE}/frozen" ]; }

case "${ARGS}" in
  *"version --client"*)   echo '{"clientVersion":{"gitVersion":"v1.31.0"}}'; exit 0 ;;
  *cluster-info*)         echo "Kubernetes control plane is running at https://127.0.0.1:1"; exit 0 ;;
esac

# ── Step 1: Flux Kustomization + Deployment + Pod ────────────────────────────
case "${ARGS}" in
  *"get kustomization"*'type=="Ready"'*)
      if [ "${MUT}" = "step1_not_ready" ]; then echo -n "False"; else echo -n "True"; fi; exit 0 ;;
  *"get kustomization"*lastAppliedRevision*)
      echo -n "latest@sha256:82ef76a05850f30583639956ea64f7b23b2ea465ea0bd74f3d43d4e824893248"; exit 0 ;;
  *"rollout status"*)     echo "deployment \"agent-kusari\" successfully rolled out"; exit 0 ;;
  *"get deploy"*readyReplicas*) echo -n "1/1"; exit 0 ;;
  *"get deploy"*reconcile*)
      [ "${MUT}" = "step5_no_flux_suppression" ] && exit 0
      echo -n "disabled"; exit 0 ;;
  *"get deploy"*)         exit 0 ;;
esac

case "${ARGS}" in
  *"get pod"*"metadata.uid"*)   echo -n "${UID_}"; exit 0 ;;
  *"get pod"*"metadata.name"*)  echo -n "${POD}"; exit 0 ;;
  *"get pod"*"status.phase"*)   echo -n "Running"; exit 0 ;;
  *"get pod"*restartCount*)
      if [ "${MUT}" = "step5_restart_h1_breach" ] && frozen; then echo -n "1"
      elif [ "${MUT}" = "step1_dirty_restart" ]; then echo -n "1"
      else echo -n "0"; fi; exit 0 ;;
  *"get pod"*imageID*)          echo -n "docker.io/library/kusari-agent:latest"; exit 0 ;;
  *"get pod"*reconcile*)
      [ "${MUT}" = "step5_no_pod_suppression" ] && exit 0
      echo -n "disabled"; exit 0 ;;
esac

# ── Step 2: agent_registry claim ─────────────────────────────────────────────
case "${ARGS}" in
  *"deploy/postgresql"*)
      case "${MUT}" in
        step2_no_row)        exit 0 ;;
        step2_wrong_tenant)  echo "kusari-agent|tenant-demo|claude-3-5-sonnet" ;;
        step2_legacy_typo)   echo "kusari-agent|kurasi|deterministic" ;;
        step2_no_model)      echo "kusari-agent|kusari|" ;;
        *)                   echo "kusari-agent|kusari|deterministic" ;;
      esac
      exit 0 ;;
esac

# ── Step 3: provocation (POST via create --raw) ──────────────────────────────
case "${ARGS}" in
  *"create --raw"*"/act/read-passwd"*)
      # Containment invariant: a frozen pod must not answer.
      if frozen && [ "${MUT}" != "step5_still_serving" ]; then
          echo "Error from server: error trying to reach service: dial tcp: i/o timeout" >&2; exit 1
      fi
      held=100; ok=true
      [ "${MUT}" = "step3_descriptor_not_held" ] && held=0
      [ "${MUT}" = "step3_act_failed" ] && ok=false
      printf '{"action":"read-passwd","ok":%s,"path":"/etc/passwd","attempted":true,"bytes":149,"lines":3,"held_ms":%s,"pid":1,"tid":18,"started_at":"%s","finished_at":"%s"}\n' \
          "${ok}" "${held}" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
      exit 0 ;;
  *"create --raw"*"/act/read-shadow"*)
      if frozen; then echo "Error from server: i/o timeout" >&2; exit 1; fi
      attempted=true
      [ "${MUT}" = "step3_shadow_not_attempted" ] && attempted=false
      printf '{"action":"read-shadow","ok":false,"error":"open /etc/shadow: no such file or directory","path":"/etc/shadow","attempted":%s,"pid":1,"tid":18,"started_at":"%s","finished_at":"%s"}\n' \
          "${attempted}" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
      exit 0 ;;
esac

# ── Step 4: signal-ingest observations; emitting one arms the freeze ─────────
case "${ARGS}" in
  *"get --raw"*observations*)
      case "${MUT}" in
        step4_probe_removed)
            # eBPF hook gone: only unrelated observations exist.
            echo '[{"id":"net-egress-001","layer":"network_egress","source":"prod-api-7b3c"}]'; exit 0 ;;
        step4_not_sensitive)  target="/etc/hosts" ;;
        *)                    target="/etc/passwd" ;;
      esac
      case "${MUT}" in
        step4_stale_timestamp) ts="2026-01-01T00:00:00.000Z" ;;
        *)                     ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" ;;
      esac
      case "${MUT}" in
        step4_wrong_tenant) tenant="tenant-demo" ;;
        step4_legacy_typo)  tenant="kurasi" ;;
        *)                  tenant="kusari" ;;
      esac
      # The observation is the containment trigger; arm the freeze exactly as
      # the in-sentinel correlator does.
      [ "${MUT}" = "step5_freeze_disabled" ] || touch "${STATE}/frozen"
      [ "${MUT}" = "step5_freeze_disabled" ] && touch "${STATE}/freeze_attempted"
      printf '[{"timestamp":"%s","actor_id":"spiffe://osramp.local/ns/fe-signalloom-agents/sa/kusari-agent","tenant_id":"%s","pod_name":"%s","namespace":"fe-signalloom-agents","syscall":"sys_enter_openat","target":"%s","severity":"high","labels":{"cgroup_path":"/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/pod%s.slice"},"direct_reaction":"cgroup_frozen"}]\n' \
          "${ts}" "${tenant}" "${POD}" "${target}" "${UID_//-/_}"
      exit 0 ;;
esac

# ── Step 5: cAdvisor scrape ──────────────────────────────────────────────────
case "${ARGS}" in
  *"get --raw"*metrics/cadvisor*)
      # cAdvisor's housekeeping timestamp ticks on every scrape, so the suite
      # can tell two genuinely distinct samples apart.
      n=$(( $(cat "${STATE}/scrapes" 2>/dev/null || echo 0) + 1 ))
      echo "${n}" >"${STATE}/scrapes"
      ts=$(( 1790762112465 + n * 10000 ))
      base=0.049610
      if [ "${MUT}" = "step5_cpu_still_burning" ]; then
          base="$(awk -v n="${n}" 'BEGIN{printf "%.6f", 0.049610 + n*0.025}')"
      fi
      printf 'container_cpu_usage_seconds_total{container="agent",cpu="total",id="/x",image="kusari-agent:latest",name="c",namespace="fe-signalloom-agents",pod="%s"} %s %s\n' \
          "${POD}" "${base}" "${ts}"
      exit 0 ;;
esac

exit 0
FAKE_KUBECTL

cat >"${WORK}/bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -uo pipefail
ARGS="$*"
MUT="${MUT:-none}"
STATE="${SLDC_FAKE_STATE:?SLDC_FAKE_STATE required}"
UID_="e02fe214-5d7c-423b-9fa9-f933932d6679"
CG="/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/kubelet-kubepods-burstable-pod${UID_//-/_}.slice"

case "${ARGS}" in
  *"network inspect kind"*) echo "osramp-control-plane 172.18.0.5/16"; echo "signalloom-hub-control-plane 172.18.0.6/16"; exit 0 ;;
esac

case "${ARGS}" in
  *"find /sys/fs/cgroup"*) echo "${CG}"; exit 0 ;;
  *cgroup.events*)
      if [ -f "${STATE}/frozen" ] && [ "${MUT}" != "step5_freeze_disabled" ]; then
          echo "populated 1"; echo "frozen 1"
      else
          echo "populated 1"; echo "frozen 0"
      fi
      # The suite's second read also asks for cgroup.freeze and cpu.stat.
      case "${ARGS}" in
        *cpu.stat*)
            echo "--- cgroup.freeze:"
            if [ -f "${STATE}/frozen" ] && [ "${MUT}" != "step5_freeze_disabled" ]; then echo 1; else echo 0; fi
            echo "--- cpu.stat:"; echo "usage_usec 49610"; echo "user_usec 30000"; echo "system_usec 19610" ;;
      esac
      exit 0 ;;
  *"cgroup.freeze"*) exit 0 ;;
esac

exit 0
FAKE_DOCKER

chmod +x "${WORK}/bin/kubectl" "${WORK}/bin/docker"

# The suite calls `python3 scripts/derive_tenant_hash.py` in Step 2; that is the
# real, already-verified generator (SLDC-P3-1) and is left unfaked.

# ── harness ──────────────────────────────────────────────────────────────────
# run_suite <mutation-id> -> writes TAP-ish bats output, echoes "ok"/"not ok"
# per step name on stdout of the temp log.
run_suite() {
    local mut="$1" log="$2"
    local state="${WORK}/state-${mut}"
    rm -rf "${state}"; mkdir -p "${state}"
    local ev="${WORK}/evidence-${mut}"
    rm -rf "${ev}"; mkdir -p "${ev}"
    env -i \
        HOME="${WORK}" \
        PATH="${WORK}/bin:/usr/bin:/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin" \
        TERM=dumb LC_ALL=C.UTF-8 \
        MUT="${mut}" \
        SLDC_FAKE_STATE="${state}" \
        SLDC_KUBECTL=kubectl SLDC_DOCKER=docker \
        DB_CONTEXT=kind-signalloom-hub \
        EVIDENCE_DIR="${ev}" \
        SLDC_SKIP_BRIDGE=0 \
        WAIT_QUIET=1 WAIT_DEADLINE_SCALE=0.05 WAIT_SLEEP=0.05 WAIT_HEARTBEAT_START=0 \
        SIGNAL_LOOM_EAP_SALT=signalloom-eap-salt-2026-q3 \
        bats --tap "${SUITE}" >"${log}" 2>&1
    return $?
}

# step_failed <log> <step-number> -> 0 when that step reported not ok
step_failed() { grep -qE "^not ok ${2} " "$1"; }
step_passed() { grep -qE "^ok ${2} " "$1"; }

# MUTATIONS: id | step-number-expected-to-fail | description
MUTATIONS=(
  "step1_not_ready|1|Flux Kustomization Ready=False is not reported as deployed"
  "step1_dirty_restart|1|a workload that already restarted is not accepted as a clean baseline"
  "step2_no_row|2|absent agent_registry row is not read as a successful claim"
  "step2_wrong_tenant|2|claim into tenant-demo is not accepted as tenant kusari"
  "step2_legacy_typo|2|retired typo tenant kurasi fails closed"
  "step2_no_model|2|claim with no model_name is not accepted as registered"
  "step3_act_failed|3|provocation returning ok=false is not read as provoked"
  "step3_descriptor_not_held|3|a descriptor released immediately is not accepted"
  "step3_shadow_not_attempted|3|shadow provocation that never attempted the open is rejected"
  "step4_probe_removed|4|removing the eBPF hook makes Step 4 fail"
  "step4_not_sensitive|4|an openat of a non-sensitive path is not accepted as the provocation"
  "step4_stale_timestamp|4|an observation outside the correlation window is rejected"
  "step4_wrong_tenant|4|an observation bound to the wrong tenant is rejected"
  "step4_legacy_typo|4|an observation carrying kurasi fails closed"
  "step5_freeze_disabled|5|disabling the cgroup freeze makes Step 5 fail"
  "step5_restart_h1_breach|5|restartCount=1 during the forensic window fails (Option H1)"
  "step5_no_flux_suppression|5|a Deployment without reconcile=disabled fails (Pattern 4)"
  "step5_no_pod_suppression|5|a Pod without reconcile=disabled fails (Pattern 4)"
  "step5_cpu_still_burning|5|a CPU counter that keeps advancing is not a 0.000 mCPU flatline"
  "step5_still_serving|5|a frozen pod still answering network traffic fails"
)

declare -a PLAN=()
if [ -z "${ONLY}" ] || [ "${ONLY}" = "baseline" ]; then PLAN+=("baseline"); fi
for m in "${MUTATIONS[@]}"; do
    id="${m%%|*}"
    [ -n "${ONLY}" ] && [ "${ONLY}" != "${id}" ] && continue
    PLAN+=("${m}")
done
[ ${#PLAN[@]} -eq 0 ] && { echo "Bail out! no mutation matched --only ${ONLY}"; exit 2; }

echo "TAP version 13"
echo "1..${#PLAN[@]}"

n=0; failures=0
for entry in "${PLAN[@]}"; do
    n=$(( n + 1 ))
    if [ "${entry}" = "baseline" ]; then
        log="${WORK}/log-baseline.tap"
        run_suite none "${log}"; rc=$?
        if [ "${rc}" -eq 0 ] && step_passed "${log}" 1 && step_passed "${log}" 2 \
           && step_passed "${log}" 3 && step_passed "${log}" 4 && step_passed "${log}" 5; then
            echo "ok ${n} - baseline: all five steps pass against unmutated fixtures"
        else
            echo "not ok ${n} - baseline: all five steps pass against unmutated fixtures"
            failures=$(( failures + 1 ))
            sed 's/^/  # /' "${log}"
        fi
        [ "${VERBOSE}" -eq 1 ] && sed 's/^/  # /' "${log}"
        continue
    fi

    id="${entry%%|*}"; rest="${entry#*|}"; step="${rest%%|*}"; desc="${rest#*|}"
    log="${WORK}/log-${id}.tap"
    run_suite "${id}" "${log}"; rc=$?

    if [ "${rc}" -ne 0 ] && step_failed "${log}" "${step}"; then
        echo "ok ${n} - ${id}: ${desc} (step ${step} red, suite exit ${rc})"
    else
        echo "not ok ${n} - ${id}: ${desc}"
        echo "  # expected step ${step} to report 'not ok'; suite exit ${rc}"
        sed 's/^/  # /' "${log}"
        failures=$(( failures + 1 ))
    fi
    [ "${VERBOSE}" -eq 1 ] && sed 's/^/  # /' "${log}"
done

echo "# mutations proven: $(( ${#PLAN[@]} - failures ))/${#PLAN[@]}"
[ "${failures}" -eq 0 ] || echo "# FAILED: ${failures} assertion(s) are vacuous"
exit $(( failures == 0 ? 0 : 1 ))
