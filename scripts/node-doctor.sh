#!/usr/bin/env bash
# node-doctor.sh — NODE-level health check for one GCP lane (ENV=<key>).
#
#   scripts/node-doctor.sh <env-key>          one lane
#   scripts/node-doctor.sh --all              every lane with a handoff file
#
# ═══ HOW THIS RELATES TO `make doctor` ══════════════════════════════════════
#
# `make doctor` is scripts/cluster-debug.sh. It is a good doctor and it is NOT
# limited to the Kubernetes API — it checks the docker daemon, the kind
# control-plane container, the registry-cache mirrors, the containerd certs.d
# hosts.toml files and the zot cache directory's ownership. The gaps below were
# measured against the script, not assumed from its name.
#
# The structural one first: cluster-debug has no lane concept. It inspects
# whatever `kubectl config current-context` and the LOCAL docker point at, so
# from an operator's machine it cannot reach any of the four lanes at all — it
# is run ON the VM, by the pipeline. Everything here is addressed by ENV and
# reaches the lane over IAP.
#
# Then the specific ones:
#
#   it does not check       and the consequence
#   ──────────────────────  ──────────────────────────────────────────────────
#   gcloud, at all          no instance status, labels or metadata — so no lane
#                           kind, and SUSPENDED is invisible
#   tailscale               no node-name drift, no serve config, no boot unit
#   systemd                 a serve unit that is active but not enabled passes
#   disk capacity           neither `df` nor any filesystem headroom
#   a real blob PUSH        it checks the zot pod and greps its log for
#                           `cache.db|permission denied`. The unlinked blob
#                           store produces neither: the pod is 1/1 Running and
#                           /v2/ answers 200. Only a push fails.
#   the bind-mount inode    its cache check is `stat -c '%u:%a'` on ownership,
#                           guarded by `[[ -e "$zot_cache_dir" ]]` where the
#                           default is `.cache/zot` — the LOCAL dev path. On a
#                           lane, whose cache is /opt/signalloom/zot-cache, that
#                           guard is false and the check silently does not run.
#   the AFM cluster COUNT   nothing in cluster-debug or check-backends.sh counts
#                           clusters. A platform answering 200 and holding zero
#                           passes everything.
#
# So this is a complement, not a replacement. It runs BELOW and BESIDE the
# cluster: the instance and its lane contract, the tailnet, the filesystem, and
# the two facts a green cluster actively hides — a registry that serves but
# cannot store, and a platform that is up and empty.
#
# ═══ SHAPE ═════════════════════════════════════════════════════════════════
#
#   scripts/node-doctor/probe.sh   runs ON the VM. Collects. Never adjudicates.
#   scripts/node-doctor/lib.sh     runs HERE. Pure functions over the report.
#   scripts/node-doctor/demo.sh    the demo-lane checks
#   scripts/node-doctor/ci.sh      the ci-lane checks
#
# The split is what makes the logic testable: test/node-doctor.bats drives the
# real adjudicators against recorded probe output, including states that cannot
# be produced on demand — an unlinked zot blob store, a drifted MagicDNS name, a
# demo VM wearing the reaper's label.
#
# READ-ONLY, with one deliberate exception. Everything here is a describe, a
# read or a GET, except the zot blob round trip: it pushes a 29-byte blob to
# `doctor-probe/node-doctor` and deletes it again. That is not optional
# thoroughness. A 200 on /v2/ is the exact reading the known blob-store defect
# leaves intact, so a doctor that only reads cannot see the fault it exists to
# find. Set ND_ZOT_PUSH=0 to suppress it; the check then reports UNKNOWN, never
# a pass.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/node-doctor"
HANDOFF_DIR="${GCP_TF_HANDOFF_DIR:-${REPO_ROOT}/deploy/gcp}"
SSH_TIMEOUT="${ND_SSH_TIMEOUT:-300}"

die() { printf 'node-doctor: %s\n' "$*" >&2; exit 2; }

# ─── gcloud, wrapped once ───────────────────────────────────────────────────
#
# SSH_AUTH_SOCK is emptied on EVERY call, not once at the top. A forwarded agent
# makes `gcloud compute ssh` fail with "agent refused operation", and that
# surfaces as a connection timeout — which reads as a broken VM. A node doctor
# misreporting a healthy lane as unreachable is the exact failure mode it exists
# to prevent, so the emptying lives at the call site where it cannot be lost to
# a future refactor moving code out from under a top-level export.
gc() {
  local args=(--project="$PROJECT_ID")
  [ -n "$OPERATOR_SA" ] && args+=(--impersonate-service-account="$OPERATOR_SA")
  env SSH_AUTH_SOCK='' gcloud "$@" "${args[@]}" 2>&1 \
    | grep -v '^WARNING: This command is using service account impersonation'
}

# Never collapse "we could not ask" into "the VM is absent". An expired
# credential once produced "VM not found — run provision first" against a
# healthy VM, and acting on that rebuilds an estate that was fine. The three
# outcomes are distinguished by the error text, exactly as scripts/ci/gcp-ci.sh
# does it; test/gcp-ci-vm-status.bats carries the full account.
vm_status() {
  local out rc=0
  out="$(env SSH_AUTH_SOCK='' gcloud compute instances describe "$INSTANCE_NAME" \
          --zone="$ZONE" --project="$PROJECT_ID" \
          ${OPERATOR_SA:+--impersonate-service-account="$OPERATOR_SA"} \
          --format='value(status)' 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out" | grep -v '^WARNING:' | tr -d '[:space:]'
    return 0
  fi
  case "$out" in
    *"was not found"*|*"not found"*)        printf 'NOT_FOUND' ;;
    *Reauthentication*|*"auth login"*|*"refreshing your current auth tokens"*) printf 'AUTH_REQUIRED' ;;
    *)                                       printf 'QUERY_FAILED' ;;
  esac
}

# The two facts that distinguish the lane kinds, read off the LIVE instance
# rather than off the Terraform that was supposed to have set them. ABSENT is
# emitted for a key that is genuinely not there, so lib.sh can tell it from a
# query that failed — for a demo lane, absence is the correct answer and must
# not read as an error.
vm_label() {
  local key="$1" out
  out="$(env SSH_AUTH_SOCK='' gcloud compute instances describe "$INSTANCE_NAME" \
          --zone="$ZONE" --project="$PROJECT_ID" \
          ${OPERATOR_SA:+--impersonate-service-account="$OPERATOR_SA"} \
          --format="value(labels.${key})" 2>/dev/null | grep -v '^WARNING:' | tr -d '[:space:]')" || {
    printf 'UNKNOWN'; return; }
  printf '%s' "${out:-ABSENT}"
}

vm_metadata() {
  local key="$1" out
  out="$(env SSH_AUTH_SOCK='' gcloud compute instances describe "$INSTANCE_NAME" \
          --zone="$ZONE" --project="$PROJECT_ID" \
          ${OPERATOR_SA:+--impersonate-service-account="$OPERATOR_SA"} \
          --format="value(metadata.items.filter(\"key:${key}\").extract(value))" 2>/dev/null \
          | grep -v '^WARNING:' | tr -d "[:space:]\\[\\]'")" || { printf 'UNKNOWN'; return; }
  printf '%s' "${out:-ABSENT}"
}

# ─── Handoff ────────────────────────────────────────────────────────────────
load_handoff() {
  local env_key="$1" file="${HANDOFF_DIR}/${env_key}.handoff.json"
  [ -f "$file" ] || die "no handoff for '${env_key}' at ${file}
       Regenerate it:  make gcp-tf-handoff ENV=${env_key} TF_STATE_BUCKET=<bucket>"
  command -v jq >/dev/null 2>&1 || die "jq is required to read the handoff"
  jq -e . "$file" >/dev/null 2>&1 || die "${file} is not valid JSON"

  PROJECT_ID="$(jq -r '.project_id // empty'    "$file")"
  ZONE="$(jq -r '.zone // empty'                "$file")"
  INSTANCE_NAME="$(jq -r '.instance_name // empty' "$file")"
  APP_PORT="$(jq -r '.app_port // empty'        "$file")"
  OPERATOR_SA="$(jq -r '.operator_sa // empty'  "$file")"
  TS_HOSTNAME="$(jq -r '.tailscale_hostname // empty' "$file")"
  [ -n "$TS_HOSTNAME" ] || TS_HOSTNAME="sl-${env_key}"

  local missing=""
  for pair in "project_id:$PROJECT_ID" "zone:$ZONE" "instance_name:$INSTANCE_NAME" "app_port:$APP_PORT"; do
    [ -n "${pair#*:}" ] || missing="${missing} ${pair%%:*}"
  done
  [ -z "$missing" ] || die "${file} is missing required field(s):${missing}"

  # The handoff does not carry the lane kind, so it is derived from the key. The
  # Makefile's own guard uses the same regex, which is what keeps the two from
  # disagreeing about what a valid key is.
  case "$env_key" in
    demo-*) LANE_KIND=demo ;;
    ci-*)   LANE_KIND=ci ;;
    *)      die "cannot derive a lane kind from '${env_key}' (expected demo-N or ci-N)" ;;
  esac
}

# ─── Collection ─────────────────────────────────────────────────────────────
#
# One SSH round trip carrying the whole probe. Not several: each `gcloud compute
# ssh` pays an IAP tunnel setup of a few seconds, and a doctor that takes two
# minutes is a doctor nobody runs.
collect_probe() {
  local script rc=0 out
  # The probe's TEXT goes into --command, and NOTHING goes on stdin.
  #
  # The obvious spelling is `--command='bash -s' < probe.sh`, and it is a trap
  # this repo has already paid for once: gcloud compute ssh DOES NOT FORWARD
  # STDIN. The redirect is accepted, the remote shell reads EOF immediately, the
  # command exits 0, and the script runs as zero bytes. Everything downstream
  # then reports success against an empty probe — which, for a doctor, means a
  # report with no keys in it and no error anywhere. See verify_delivered_size()
  # in scripts/gcp-tf/demo-up.sh for the original account.
  #
  # The knobs are prepended as assignments rather than passed through the
  # environment for the same reason: `gcloud ... --command` does not carry the
  # caller's environment to the far side either.
  script="$(printf 'ND_APP_PORT=%q\nND_ZOT_PUSH=%q\n%s\n' \
              "$APP_PORT" "${ND_ZOT_PUSH:-1}" "$(cat "${LIB_DIR}/probe.sh")")"
  out="$(timeout "$SSH_TIMEOUT" env SSH_AUTH_SOCK='' gcloud compute ssh "$INSTANCE_NAME" \
        --zone="$ZONE" --project="$PROJECT_ID" \
        ${OPERATOR_SA:+--impersonate-service-account="$OPERATOR_SA"} \
        --tunnel-through-iap --quiet \
        --command="$script" 2>&1 </dev/null)" || rc=$?
  printf '%s' "$out" | grep -v '^WARNING: This command is using service account impersonation'
  return "$rc"
}

# The tailnet probe, run from HERE rather than on the VM, and reported alongside
# the VM-side one rather than instead of it. The pair is the diagnosis:
#
#   VM 200, tailnet 200    healthy
#   VM 200, tailnet 000    the name does not resolve here, or serve is absent
#   VM 000, tailnet 502    serve is up and its proxy target is dead — measured
#                          on all four lanes on 2026-08-21
#   VM 000, tailnet 200    something ELSE is answering this URL. The worst of
#                          the four, and invisible to either probe alone.
# The `|| printf '000'` this used to end with printed a SECOND 000: curl's
# `-w '%{http_code}'` already emits 000 when the connection fails, and it also
# exits non-zero, so both halves fired and the function returned `000000`.
# Measured on ci-1 on 2026-08-22 — the doctor printed
#
#   ✗ / -> 000000 (unexpected status)
#
# and `000000` matches no arm of nd_http_explain, so the 000 sentence written
# for exactly this case was dead code. The verdict stayed correct (nd_verdict_http
# fails anything that is not 200), so this only ever cost the diagnosis — but the
# diagnosis is the whole product of a doctor.
#
# It hid because reproducing it needs curl to FAIL. A 502 — the state measured
# on all four lanes on 2026-08-21 — is a SUCCESSFUL curl, so the fallback never
# fired and the seam looked healthy for as long as the lanes were merely broken
# rather than unreachable.
#
# curl's own output is now the single source of the code, and the fallback only
# covers it emitting nothing at all (killed before it could write).
probe_tailnet() {
  local path="$1" code
  command -v curl >/dev/null 2>&1 || { printf 'UNKNOWN'; return; }
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "https://${TS_FQDN}${path}" 2>/dev/null)"
  printf '%s' "${code:-000}"
}

# ─── Telling the four 000s apart ────────────────────────────────────────────
#
# `000` is not a diagnosis, it is the absence of one, and FOUR quite different
# states all produce it. curl's EXIT STATUS separates them, and it costs nothing
# because curl already computed it. Measured 2026-08-23 against the live estate:
#
#   state                         http_code  curl exit  measured on
#   HTTPS answering                 200          0      sl-demo-1 (has a cert)
#   MagicDNS name does not resolve  000          6      sl-nope-9 (invented)
#   nothing listening on the port   000          7      sl-ci-1 over http :80
#   connection never completes      000         28      sl-ci-1 over https :443
#
# The last one is the state this whole change exists around: the node IS on the
# tailnet, tailscaled IS listening on 443, and it cannot present a certificate,
# so the connection stalls and curl times out with connect=0.000000. From a bare
# `%{http_code}` it is byte-identical to "not on the tailnet at all" — which is
# precisely how a certificate outage gets misdiagnosed as a networking failure.
#
# 35 is included with 28 because curl reports an SSL connect error rather than a
# timeout when the far side rejects the handshake promptly rather than stalling.
# Both mean "TLS did not complete", which is the distinction that matters here.
probe_tailnet_detail() {
  local scheme="$1" path="$2" port_suffix="$3" code rc
  command -v curl >/dev/null 2>&1 || { printf 'UNKNOWN:0'; return; }
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "${scheme}://${TS_FQDN}${port_suffix}${path}" 2>/dev/null)"
  rc=$?
  printf '%s:%s' "${code:-000}" "$rc"
}

# Classifies the tailnet surface into ONE of five named states.
#
# Deliberately not folded into nd_verdict_http: that function answers "is this
# HTTP code good", and the question here is "which of several mutually
# exclusive situations are we in", which no single status code can answer.
# HTTP_FALLBACK in particular must be its OWN value — not a pass, because the
# intended HTTPS posture is absent, and not the generic failure arm, because
# the estate IS serving and the rest of the suite must carry on against it.
nd_classify_tailnet() {
  local https_detail="$1" http_detail="$2"
  local https_code="${https_detail%%:*}" https_rc="${https_detail##*:}"
  local http_code="${http_detail%%:*}"

  if [ "$https_code" = "200" ]; then printf 'HTTPS_OK'; return; fi
  if [ "$http_code" = "200" ]; then printf 'HTTP_FALLBACK'; return; fi

  case "$https_rc" in
    6)     printf 'NAME_UNRESOLVED' ;;
    28|35) printf 'TLS_NEVER_COMPLETES' ;;
    *)     printf 'NOTHING_SERVING' ;;
  esac
}

run_one() {
  local env_key="$1"
  load_handoff "$env_key"

  # shellcheck source=scripts/node-doctor/lib.sh
  . "${LIB_DIR}/lib.sh"

  printf '%s%sSignalLoom — Node Doctor%s\n' "$ND_BLD" "$ND_CYA" "$ND_RST"
  printf 'lane:     %s (kind=%s)\n' "$env_key" "$LANE_KIND"
  printf 'instance: %s  zone=%s  project=%s\n' "$INSTANCE_NAME" "$ZONE" "$PROJECT_ID"
  printf 'time:     %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local status ci_label idle
  status="$(vm_status)"
  ci_label="$(vm_label 'ci-lane')"
  idle="$(vm_metadata 'idle-suspend-minutes')"

  # The probe is skipped for a lane that is not running, rather than attempted
  # and allowed to fail: a 300-second SSH timeout against a suspended VM is five
  # minutes spent proving something the instance status already said.
  local report=""
  case "$status" in
    RUNNING) report="$(collect_probe || true)" ;;
  esac

  # The completion marker is the positive control for the entire report. Without
  # it, every absent key is indistinguishable from a check that found nothing,
  # so refuse to adjudicate rather than emit a page of confident PASSes derived
  # from a truncated transfer.
  if [ "$status" = "RUNNING" ] && ! nd_report_complete "$report"; then
    nd_header "PROBE"
    nd_unknown "the VM-side probe did not complete — its completion marker is absent, so the report is truncated or the SSH failed. Nothing below it can be trusted and none of it has been adjudicated. Last lines received:"
    printf '%s\n' "$report" | tail -5 | sed 's/^/      /'
    nd_summary "$env_key" "$LANE_KIND"
    return $?
  fi

  TS_FQDN="$(nd_field "$report" ts.dnsname)"
  TS_FQDN="${TS_FQDN%.}"

  case "$LANE_KIND" in
    demo) . "${LIB_DIR}/demo.sh"; nd_doctor_demo "$report" "$env_key" "$APP_PORT" "$TS_HOSTNAME" "$status" "$ci_label" "$idle" ;;
    ci)   . "${LIB_DIR}/ci.sh";   nd_doctor_ci   "$report" "$env_key" "$APP_PORT" "$TS_HOSTNAME" "$status" "$ci_label" "$idle" ;;
  esac

  if [ "$status" = "RUNNING" ] && [ -n "$TS_FQDN" ] && [ "$TS_FQDN" != "UNKNOWN" ]; then
    nd_header "TAILNET SURFACE (measured from here, https://${TS_FQDN})"
    local t_root t_afm v_root
    t_root="$(probe_tailnet /)"
    t_afm="$(probe_tailnet /afm/health)"
    v_root="$(nd_field "$report" http.root)"
    nd_report "$(nd_verdict_http "$t_root")" "/ -> ${t_root} ($(nd_http_explain "$t_root" tailnet))"
    nd_report "$(nd_verdict_http "$t_afm")"  "/afm/health -> ${t_afm} ($(nd_http_explain "$t_afm" tailnet))"
    # The pairing that neither probe can produce alone, and the one worth
    # shouting about: the URL is answering and this lane is not what is behind it.
    if [ "$t_root" = "200" ] && [ "$v_root" != "200" ]; then
      nd_fail "the tailnet URL answers 200 while ${INSTANCE_NAME} itself answers ${v_root} on :${APP_PORT}. Something OTHER than this lane is behind that URL — check the MagicDNS name above for suffix drift."
    fi

    # ─── Which of the five tailnet states is this? ──────────────────────────
    #
    # Only runs when the plain probe already said "not 200", so the healthy
    # path costs one extra curl and the broken path gains a real diagnosis
    # instead of a bare 000.
    if [ "$t_root" != "200" ]; then
      local https_detail http_detail tailnet_state
      https_detail="$(probe_tailnet_detail https / '')"
      http_detail="$(probe_tailnet_detail http / '')"
      tailnet_state="$(nd_classify_tailnet "$https_detail" "$http_detail")"

      case "$tailnet_state" in
        HTTP_FALLBACK)
          # ITS OWN STATE, and nd_degraded rather than nd_warn is the whole of
          # it. Not a pass — the intended HTTPS posture is absent, and a green
          # summary would turn a certificate outage into a clean run. Not the
          # generic failure arm either — the estate IS serving, every other
          # check against it is meaningful, and the suite must carry on rather
          # than abort on a condition we may be EXPECTING and cannot fix for up
          # to 168h. And NOT nd_warn: that counter already carries an 85%-full
          # disk, and it does not move the summary verdict at all, so routing
          # this through it would leave the lane reporting HEALTHY.
          nd_degraded "serving over HTTP because the certificate is unavailable — http://${TS_FQDN}/ answers 200, https://${TS_FQDN}/ does not. Tailnet traffic is WireGuard-encrypted so this is usable, but it is NOT the intended posture. Cause and retry-after: /var/lib/signalloom/tailscale-cert-state.json on ${INSTANCE_NAME}, or 'journalctl -u tailscaled | grep getCertPEM'. The Let's Encrypt window is per exact DNS name, so this lane's retry-after says nothing about any other lane."
          ;;
        TLS_NEVER_COMPLETES)
          nd_fail "the TLS handshake to https://${TS_FQDN}/ never completes (curl times out with connect=0). The node is on the tailnet and tailscaled is listening, but it has NO CERTIFICATE to present — from curl alone this is byte-identical to not being on the tailnet at all. No HTTP fallback is configured either. Check 'journalctl -u tailscaled | grep getCertPEM' on ${INSTANCE_NAME} for a 429 and its retry-after."
          ;;
        NAME_UNRESOLVED)
          nd_fail "${TS_FQDN} does not resolve from here (curl exit 6). Either this machine is not on the tailnet, or the node's MagicDNS name has drifted from the one this lane expects."
          ;;
        NOTHING_SERVING)
          nd_fail "nothing is served on ${TS_FQDN} — the connection is refused (curl exit 7). The node may be on the tailnet with no 'tailscale serve' configuration at all."
          ;;
      esac
    fi
  fi

  nd_summary "$env_key" "$LANE_KIND"
}

# ─── Entry ──────────────────────────────────────────────────────────────────
case "${1:-}" in
  ''|-h|--help)
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2 ;;
  --all)
    # The sweep runs every lane even when an early one fails, and reports the
    # aggregate at the end. Stopping at the first fault would make the second
    # broken lane invisible, which on a four-lane estate is most of the value.
    rc=0
    for f in "${HANDOFF_DIR}"/*.handoff.json; do
      [ -e "$f" ] || die "no handoff files in ${HANDOFF_DIR}"
      key="$(basename "$f" .handoff.json)"
      printf '\n%s\n' '════════════════════════════════════════════════════════════════'
      ( run_one "$key" ) || rc=$?
    done
    exit "$rc" ;;
  *)
    printf '%s' "$1" | grep -Eq '^(demo|ci)-[1-9][0-9]*$' \
      || die "'$1' is not a valid environment key (expected demo-N or ci-N)"
    run_one "$1"
    exit $? ;;
esac
