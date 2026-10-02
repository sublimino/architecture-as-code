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
recovered() { [ -f "${STATE}/recovered" ]; }

case "${ARGS}" in
  *"version --client"*)   echo '{"clientVersion":{"gitVersion":"v1.31.0"}}'; exit 0 ;;
  *cluster-info*)         echo "Kubernetes control plane is running at https://127.0.0.1:1"; exit 0 ;;
esac

# ── Step 6: fleet-manager's operator key (base64, as a Secret stores it) ─────
case "${ARGS}" in
  *"get secret fleet-manager-caller-keys"*"-n fe-signalloom"*".data.operator"*)
      printf '%s' "${FAKE_OPERATOR_KEY}" | base64 | tr -d '\n'; exit 0 ;;
  *"get pod"*"labels.signalloom\.io/stunned}"*)
      if recovered; then echo -n "false"; else echo -n "true"; fi; exit 0 ;;
esac

# ── Step 5: the sentinel's own health (resync interval, reconcile count) ─────
# Matched first: these jsonpaths would otherwise fall into the Step 1 catch-alls.
case "${ARGS}" in
  *"get pod"*"name=stun-sentinel"*) echo -n "stun-sentinel-x7k2p"; exit 0 ;;
  *"get pod"*"io/stun-reason}"*)
      # After an authorised recovery fleet-manager blanks the reason.
      recovered && [ "${MUT}" != "step6_record_left" ] && exit 0
      # step5_stun_not_from_sentinel: a stun someone else wrote, e.g. a
      # dashboard click, is not the sentinel's detection being recorded.
      if [ "${MUT}" = "step5_stun_not_from_sentinel" ]; then echo -n "fleet-manager cascade containment"
      else echo -n "stun-sentinel detection: sys_enter_openat /etc/passwd"; fi
      exit 0 ;;
  *"get --raw"*"pods/stun-sentinel-x7k2p:8081/proxy/healthz"*)
      # Every read is a later moment: reconcile_count advances (unless the
      # reconciler is idle) and, from the second read on, a resync has run.
      n=$(( $(cat "${STATE}/health_reads" 2>/dev/null || echo 0) + 1 ))
      echo "${n}" >"${STATE}/health_reads"
      rc=$(( 100 + n ))
      [ "${MUT}" = "step5_reconciler_idle" ] && rc=100
      [ "${n}" -gt 1 ] && touch "${STATE}/resynced"
      printf '{"status":"ok","reconcile_count":%s,"resync_seconds":1,"stun_record_failures":0}\n' "${rc}"
      exit 0 ;;
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
      # Recovery removes the pin, unless the teardown left it behind.
      recovered && [ "${MUT}" != "step6_left_deployment_pin" ] && exit 0
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
      recovered && [ "${MUT}" != "step6_left_pod_pin" ] && exit 0
      echo -n "disabled"; exit 0 ;;
esac

# ── Step 2: agent_registry claim ─────────────────────────────────────────────
# The baseline starts with NO row: it appears only once the fake claim command
# (below) has run, so a green baseline proves Step 2 creates the row through
# the claim path rather than finding one.
case "${ARGS}" in
  *"get pod"*"labels.signalloom"*"model"*) echo -n "deterministic"; exit 0 ;;
  *"deploy/postgresql"*)
      case "${MUT}" in
        step2_no_row)        exit 0 ;;
        step2_wrong_tenant)  echo "kusari-agent|tenant-demo|claude-3-5-sonnet" ;;
        step2_legacy_typo)   echo "kusari-agent|kurasi|deterministic" ;;
        step2_no_model)      echo "kusari-agent|kusari|" ;;
        step2_fabricated_model) echo "kusari-agent|kusari|claude-3-5-sonnet" ;;
        step2_split_claim)   printf 'kusari-agent|kusari|deterministic\nkusari-agent|tenant-demo|\n' ;;
        *)                   [ -f "${STATE}/claimed" ] && echo "kusari-agent|kusari|deterministic" ;;
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

# ── Step 4: the evidence-reader key and the port-forward it reads through ───
# Every signal-ingest route is authenticated (SLTM Phase 1), so the suite
# reads observations with the kusari-scoped sldc-evidence-reader key through
# a port-forward. The fake curl below checks the key before serving the feed.
case "${ARGS}" in
  *"get secret signal-ingest-key-sldc-evidence-reader"*)
      [ "${MUT}" = "step4_reader_key_wrong" ] && { printf '%s' 'not-the-key' | base64 -w0; exit 0; }
      printf '%s' "${SLDC_FAKE_READER_KEY}" | base64 -w0; exit 0 ;;
  *port-forward*) exec sleep 60 ;;
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
      # signal-ingest's real shape: model.Observation with the Shared Pattern 2
      # fields in labels (the correlator's wire contract, 7f8eb0b0). TWO
      # observations land in the same second. The chronologically first is the
      # provocation and is written with a trimmed fraction ("SS.1Z"), exactly
      # as RFC3339Nano trims it; the second, 23ms later, belongs to another
      # tenant. A lexical sort orders ".123Z" before ".1Z", so only a
      # genuinely chronological "first detection" passes the baseline
      # (independent review L1, 2026-10-02).
      # The id, raw_evidence_ref and description carry the target's 16-hex
      # SHA-256 digest, never the path (correlator ingest.go targetDigest):
      # signal-ingest redacts labels.target only, so the path rides there alone.
      obs() { # ts tenant target
          local d; d="$(printf '%s' "$3" | sha256sum | cut -c1-16)"
          printf '{"id":"stun-sentinel:fe-signalloom-agents/%s:%s:sys_enter_openat:%s","timestamp":"%s","layer":"endpoint_host","fidelity":"strong","source":"stun-sentinel","confidence":0.95,"actor_id":"kusari-agent","raw_evidence_ref":"ebpf://sys_enter_openat/%s","labels":{"syscall":"sys_enter_openat","target":"%s","tenant_id":"%s","pod_name":"%s","namespace":"fe-signalloom-agents","severity":"CRITICAL","direct_reaction":"cgroup_frozen","cgroup_path":"/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/pod%s.slice"},"description":"sys_enter_openat target %s by fe-signalloom-agents/%s"}' \
              "${POD}" "$1" "${d}" "$1" "${d}" "$3" "$2" "${POD}" "${UID_//-/_}" "${d}" "${POD}"
      }
      # The real store answers an UNBOUNDED query with its oldest rows, so a
      # suite that forgets ?after= only ever sees yesterday's feed.
      case "${ARGS}" in
          *"after="*) ;;
          *) printf '[%s]\n' "$(obs "2026-01-01T00:00:00.000Z" "${tenant}" "${target}")"; exit 0 ;;
      esac
      if [ "${MUT}" = "step4_stale_timestamp" ]; then
          printf '[%s]\n' "$(obs "${ts}" "${tenant}" "${target}")"
      else
          sec="$(date -u +%Y-%m-%dT%H:%M:%S)"
          printf '[%s,%s]\n' "$(obs "${sec}.1Z" "${tenant}" "${target}")" \
              "$(obs "${sec}.123Z" "tenant-demo" "${target}")"
      fi
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
      # An authorised recovery thaws the pod (the sentinel honours the resume).
      if [ -f "${STATE}/recovered" ] && [ "${MUT}" != "step6_left_frozen" ]; then
          echo "populated 1"; echo "frozen 0"; exit 0
      fi
      # The legacy-reconciler defect: frozen, then thawed by the next resync.
      if [ "${MUT}" = "step5_thawed_by_resync" ] && [ -f "${STATE}/resynced" ]; then
          echo "populated 1"; echo "frozen 0"; exit 0
      fi
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

# One fake curl, two upstreams it stands in for:
#   - signal-ingest behind the Step 4 port-forward: 401 unless the header FILE
#     carries the evidence-reader key, then the observation feed;
#   - fleet-manager's POST /recover (Step 6): only the operator key, from a
#     header FILE, and only a recovery naming exactly the kusari agent.
# Neither key may ever appear in argv.
cat >"${WORK}/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -uo pipefail
STATE="${SLDC_FAKE_STATE:?}"
args="$*"
case "${args}" in *"${FAKE_OPERATOR_KEY}"*|*"${SLDC_FAKE_READER_KEY}"*) echo "key in argv" >&2; exit 97 ;; esac
hdr=""; out=""; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in @*) hdr="${2#@}" ;; esac; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -m|-w) shift 2 ;;
    --data) data="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "${url}" in
  http://fleet-manager.fake:8082/api/v1/fleet/recover)
    code=200
    [ -n "${hdr}" ] && grep -qx "Authorization: Bearer ${FAKE_OPERATOR_KEY}" "${hdr}" || code=401
    [ "${data}" = '{"agent_ids":["agent-kusari-agent"]}' ] || code=400
    [ "${MUT:-}" = "step6_recover_refused" ] && code=403
    [ -n "${out}" ] && printf '{"overall_outcome":"%s"}' "$([ "${code}" = 200 ] && echo contained || echo refused)" >"${out}"
    [ "${code}" = 200 ] && touch "${STATE}/recovered"
    printf '%s' "${code}"; exit 0 ;;
  */api/v1/observations*)
    [ -n "${hdr}" ] && grep -qxF "Authorization: Bearer ${SLDC_FAKE_READER_KEY}" "${hdr}" || exit 22
    exec kubectl get --raw "/api/v1/namespaces/fe-signalloom/services/signal-ingest:8082/proxy${url#http://127.0.0.1:*/}" ;;
  http://127.0.0.1:*) exit 0 ;;   # port-forward readiness poll
  *) exit 7 ;;
esac
FAKE_CURL

chmod +x "${WORK}/bin/kubectl" "${WORK}/bin/docker" "${WORK}/bin/curl"

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
        SLDC_FAKE_READER_KEY="sldc-evidence-reader-fixture-key-0123456789abcdef" \
        SLDC_KUBECTL=kubectl SLDC_DOCKER=docker \
        DB_CONTEXT=kind-signalloom-hub \
        EVIDENCE_DIR="${ev}" \
        SLDC_SKIP_BRIDGE=0 \
        WAIT_QUIET=1 WAIT_DEADLINE_SCALE=0.05 WAIT_SLEEP=0.05 WAIT_HEARTBEAT_START=0 \
        SIGNAL_LOOM_EAP_SALT=signalloom-eap-salt-2026-q3 \
        SLDC_CLAIM_CMD="${WORK}/bin/claim" \
        SLDC_FLEET_URL=http://fleet-manager.fake:8082 \
        FAKE_OPERATOR_KEY=fake-operator-key-0123456789abcdef0123 \
        bats --tap "${SUITE}" >"${log}" 2>&1
    return $?
}

# step_failed <log> <step-number> -> 0 when that step reported not ok
step_failed() { grep -qE "^not ok ${2} " "$1"; }
step_passed() { grep -qE "^ok ${2} " "$1"; }

# The Step 2 claim command. It creates the row only when called as the product
# claim would be: for kusari-agent, as the kusari Dex subject, on the workload
# context. Anything else leaves the registry empty and Step 2 red.
cat >"${WORK}/bin/claim" <<'FAKE_CLAIM'
#!/usr/bin/env bash
[ "$*" = "--workload kusari-agent" ] || exit 2
[ "${DEMO_DEX_USER:-}" = "kusari-operator@signalloom.local" ] || exit 3
[ "${SLAC_KUBE_CONTEXT:-}" = "kind-osramp" ] || exit 4
[ "${MUT:-}" = "step2_claim_refused" ] && exit 1
touch "${SLDC_FAKE_STATE}/claimed"
FAKE_CLAIM
chmod +x "${WORK}/bin/claim"

# MUTATIONS: id | step-number-expected-to-fail | description
MUTATIONS=(
  "step1_not_ready|1|Flux Kustomization Ready=False is not reported as deployed"
  "step1_dirty_restart|1|a workload that already restarted is not accepted as a clean baseline"
  "step2_no_row|2|absent agent_registry row is not read as a successful claim"
  "step2_wrong_tenant|2|claim into tenant-demo is not accepted as tenant kusari"
  "step2_legacy_typo|2|retired typo tenant kurasi fails closed"
  "step2_no_model|2|claim with no model_name is not accepted as registered"
  "step2_fabricated_model|2|a model_name the workload's label does not declare is rejected"
  "step2_split_claim|2|a second registry row in another tenant is rejected"
  "step2_claim_refused|2|a refused product claim leaves no row and Step 2 red"
  "step3_act_failed|3|provocation returning ok=false is not read as provoked"
  "step3_descriptor_not_held|3|a descriptor released immediately is not accepted"
  "step3_shadow_not_attempted|3|shadow provocation that never attempted the open is rejected"
  "step4_probe_removed|4|removing the eBPF hook makes Step 4 fail"
  "step4_not_sensitive|4|an openat of a non-sensitive path is not accepted as the provocation"
  "step4_stale_timestamp|4|an observation outside the correlation window is rejected"
  "step4_wrong_tenant|4|an observation bound to the wrong tenant is rejected"
  "step4_reader_key_wrong|4|signal-ingest refuses a read without the evidence-reader key (Step 4 must not pass unauthenticated)"
  "step4_legacy_typo|4|an observation carrying kurasi fails closed"
  "step5_freeze_disabled|5|disabling the cgroup freeze makes Step 5 fail"
  "step5_restart_h1_breach|5|restartCount=1 during the forensic window fails (Option H1)"
  "step5_no_flux_suppression|5|a Deployment without reconcile=disabled fails (Pattern 4)"
  "step5_no_pod_suppression|5|a Pod without reconcile=disabled fails (Pattern 4)"
  "step5_cpu_still_burning|5|a CPU counter that keeps advancing is not a 0.000 mCPU flatline"
  "step5_still_serving|5|a frozen pod still answering network traffic fails"
  "step5_thawed_by_resync|5|a freeze the reconciler thaws on its next resync fails"
  "step5_reconciler_idle|5|persistence is not claimed until the sentinel has reconciled after the freeze"
  "step5_stun_not_from_sentinel|5|a stun record that does not name the sentinel's detection fails"
  "step6_recover_refused|6|a recovery fleet-manager refused is not a clean teardown"
  "step6_left_deployment_pin|6|teardown that left the Deployment's reconcile=disabled pin fails"
  "step6_left_pod_pin|6|teardown that left the Pod's reconcile=disabled pin fails"
  "step6_record_left|6|teardown that left the stun reason on the pod fails"
  "step6_left_frozen|6|teardown that left the cgroup frozen fails"
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
           && step_passed "${log}" 3 && step_passed "${log}" 4 && step_passed "${log}" 5 \
           && step_passed "${log}" 6; then
            echo "ok ${n} - baseline: all six steps pass against unmutated fixtures"
        else
            echo "not ok ${n} - baseline: all six steps pass against unmutated fixtures"
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
