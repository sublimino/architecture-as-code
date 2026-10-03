#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# warden-cutover.sh — execute the no-overlap cutover from stun-sentinel to signalloom-warden (ADR-07).
#
# @id     scripts/warden-cutover.sh
# @tests  test/warden-cutover.bats
# @doc    docs/Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4).md
#
# Cutover stages:
#   1. Preflight: verify new key Secrets exist before mutating anything.
#   2. Suspend legacy Flux Kustomization (agent-signalloom-stun-sentinel).
#   3. Foreground-delete legacy DaemonSet (ds/stun-sentinel) and wait for its pods to terminate.
#   4. Reconcile Flux to deploy new DaemonSet (ds/signalloom-warden).
#   5. Wait for warden rollout.
#   6. Assert exactly one probe DaemonSet across the cluster.
#
# On failure: stops immediately and prints cluster state. NEVER recreates the old probe.
# No key material is ever printed or placed on argv.

set -euo pipefail

KUBECTL="${SLDC_KUBECTL:-kubectl}"
FLUX="${SLDC_FLUX:-flux}"
AGENTS_NS="fe-signalloom-agents"
FE_NS="fe-signalloom"

REQUIRED_SECRETS=(
  "${FE_NS}/signal-ingest-key-signalloom-warden"
  "${AGENTS_NS}/signalloom-warden-ingest-token"
  "${AGENTS_NS}/signalloom-warden-fleet-key"
)

log() { printf '[warden-cutover] %s\n' "$*" >&2; }
die() { log "ERROR: $1"; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
Usage: scripts/warden-cutover.sh --context CONTEXT [--dry-run]

Options:
  --context CONTEXT   Kubernetes context name (required)
  --dry-run           Plan cutover operations without mutating cluster
  -h, --help          Show this help message
EOF
}

main() {
  local context="" dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) context="${2:-}"; shift 2 || die "--context needs a value" 2 ;;
      --dry-run) dry_run=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" 2 ;;
    esac
  done

  [[ -n "${context}" ]] || die "--context is required" 2

  log "starting cutover preflight checks on context: ${context}"

  # 1. Preflight key secret checks
  for sec_path in "${REQUIRED_SECRETS[@]}"; do
    local ns="${sec_path%%/*}"
    local name="${sec_path##*/}"
    if ! "${KUBECTL}" --context "${context}" -n "${ns}" get secret "${name}" >/dev/null 2>&1; then
      die "preflight check failed: required secret ${sec_path} is missing. Mint keys before cutover." 1
    fi
  done
  log "all required warden secrets present"

  if [[ "${dry_run}" -eq 1 ]]; then
    log "[dry-run] preflight successful; cutover plan verified without mutating cluster"
    exit 0
  fi

  # 2. Suspend legacy Flux Kustomization if it exists
  log "suspending legacy Flux Kustomization (agent-signalloom-stun-sentinel)"
  "${FLUX}" --context "${context}" suspend kustomization agent-signalloom-stun-sentinel -n "${AGENTS_NS}" 2>/dev/null || \
    "${KUBECTL}" --context "${context}" -n "${AGENTS_NS}" annotate --overwrite kustomization agent-signalloom-stun-sentinel kustomize.toolkit.fluxcd.io/reconcile=disabled 2>/dev/null || true

  # 3. Foreground delete legacy DaemonSet and wait for old pods
  log "deleting legacy DaemonSet ds/stun-sentinel (foreground cascade)"
  "${KUBECTL}" --context "${context}" -n "${AGENTS_NS}" delete ds stun-sentinel --cascade=foreground --ignore-not-found

  log "waiting for legacy stun-sentinel pods to terminate"
  local wait_count=0
  while true; do
    local pods
    pods="$("${KUBECTL}" --context "${context}" -n "${AGENTS_NS}" get pods -l app.kubernetes.io/name=stun-sentinel -o name 2>/dev/null || true)"
    if [[ -z "${pods}" ]]; then
      break
    fi
    wait_count=$((wait_count + 1))
    if [[ "${wait_count}" -ge 24 ]]; then
      die "timed out waiting for legacy stun-sentinel pods to terminate" 1
    fi
    sleep 5
  done
  log "all legacy stun-sentinel pods terminated"

  # 4. Reconcile Flux to deploy signalloom-warden
  log "reconciling Flux agent-swarm ResourceSets and tenant definitions"
  "${FLUX}" --context "${context}" reconcile kustomization tenants -n flux-system --with-source 2>/dev/null || \
    "${FLUX}" --context "${context}" reconcile kustomization agent-signalloom-warden -n "${AGENTS_NS}" 2>/dev/null || \
    "${KUBECTL}" --context "${context}" -n flux-system annotate --overwrite kustomization tenants reconcile.fluxcd.io/requestedAt="$(date +%s)" 2>/dev/null || true

  # 5. Wait for warden rollout
  log "waiting for DaemonSet ds/signalloom-warden rollout"
  if ! "${KUBECTL}" --context "${context}" -n "${AGENTS_NS}" rollout status ds/signalloom-warden --timeout=120s; then
    log "rollout failed; gathering diagnostic state"
    "${KUBECTL}" --context "${context}" -n "${AGENTS_NS}" get ds,pods -l 'signalloom.ai/role=sentinel' >&2 || true
    die "signalloom-warden rollout failed. Legacy daemonset was NOT recreated." 1
  fi

  # 6. Assert exactly one probe DaemonSet exists
  log "verifying probe DaemonSet state"
  local ds_count ds_name
  ds_count="$("${KUBECTL}" --context "${context}" -n "${AGENTS_NS}" get ds -l 'signalloom.ai/role=sentinel' -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -c . || echo 0)"
  if [[ "${ds_count}" -ne 1 ]]; then
    die "assertion failed: expected exactly 1 probe DaemonSet, found ${ds_count}" 1
  fi

  ds_name="$("${KUBECTL}" --context "${context}" -n "${AGENTS_NS}" get ds -l 'signalloom.ai/role=sentinel' -o jsonpath='{.items[0].metadata.name}')"
  if [[ "${ds_name}" != "signalloom-warden" ]]; then
    die "assertion failed: expected probe DaemonSet 'signalloom-warden', found '${ds_name}'" 1
  fi

  log "cutover successfully completed: signalloom-warden active and verified on ${context}"
}

main "$@"
